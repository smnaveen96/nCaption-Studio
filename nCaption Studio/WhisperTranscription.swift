import AVFoundation
import Foundation
import Speech

#if canImport(FluidAudio)
import FluidAudio
#endif

#if canImport(WhisperKit)
import WhisperKit
#endif

struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let downloadSize: String

    static let available: [WhisperModel] = [
        WhisperModel(id: "tiny.en", name: "Tiny", detail: "Fastest English model", downloadSize: "153 MB"),
        WhisperModel(id: "small.en", name: "Small", detail: "Fast English model", downloadSize: "487 MB"),
        WhisperModel(id: "medium.en", name: "Medium", detail: "High English accuracy", downloadSize: "1.53 GB"),
        WhisperModel(id: "large-v3", name: "Large", detail: "Highest accuracy", downloadSize: "3.09 GB")
    ]
}

enum WhisperTranscriptionError: LocalizedError {
    case unavailable
    case modelNotDownloaded
    case noAudio
    case noSpeech
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Whisper transcription is unavailable in this target."
        case .modelNotDownloaded:
            "Download the selected Whisper model first."
        case .noAudio:
            "The selected media does not contain a readable audio track."
        case .noSpeech:
            "Whisper did not find any speech in the media."
        case .exportFailed(let message):
            "Audio conversion failed: \(message)"
        }
    }
}

enum TranscriptionEngine: String, CaseIterable, Sendable {
    case apple
    case parakeet
    case whisper

    var name: String {
        switch self {
        case .apple: "Apple On-Device"
        case .parakeet: "Parakeet Ultra"
        case .whisper: "Whisper"
        }
    }
}

enum AppleTranscriptionLibrary {
    static func transcribe(mediaURL: URL) async throws -> [CaptionCue] {
        guard #available(macOS 26.0, *) else {
            throw WhisperTranscriptionError.exportFailed("Apple On-Device transcription requires macOS 26 or later.")
        }
        return try await transcribeWithSpeechAnalyzer(mediaURL: mediaURL)
    }

    @available(macOS 26.0, *)
    private static func transcribeWithSpeechAnalyzer(mediaURL: URL) async throws -> [CaptionCue] {
        let locale = Locale(identifier: "en-US")
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw WhisperTranscriptionError.exportFailed("Apple English transcription is unavailable on this Mac.")
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let audioURL = try await audioFileForTranscription(from: mediaURL)
        defer {
            if audioURL != mediaURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )
        _ = analyzer

        var cues: [CaptionCue] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = result.range.start.seconds
            let end = result.range.end.seconds
            if !text.isEmpty, start.isFinite, end > start {
                cues.append(CaptionCue(start: start, end: end, text: text))
            }
        }
        guard !cues.isEmpty else { throw WhisperTranscriptionError.noSpeech }
        return cues
    }
}

enum ParakeetModelLibrary {
    static let displaySize = "≈630 MB"

    static func isDownloaded() -> Bool {
#if canImport(FluidAudio)
        let directory = AsrModels.defaultCacheDirectory(for: .ultra)
        return AsrModels.modelsExist(at: directory, version: .ultra)
#else
        return false
#endif
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
#if canImport(FluidAudio)
        _ = try await AsrModels.download(version: .ultra) { value in
            progress(value.fractionCompleted)
        }
        try Task.checkCancellation()
#else
        throw WhisperTranscriptionError.unavailable
#endif
    }

    static func delete() throws {
#if canImport(FluidAudio)
        let directory = AsrModels.defaultCacheDirectory(for: .ultra)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
#endif
    }

    static func transcribe(mediaURL: URL) async throws -> [CaptionCue] {
#if canImport(FluidAudio)
        guard isDownloaded() else { throw WhisperTranscriptionError.modelNotDownloaded }
        let directory = AsrModels.defaultCacheDirectory(for: .ultra)
        let models = try await AsrModels.load(from: directory, version: .ultra)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(mediaURL, decoderState: &decoderState)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        let cues: [CaptionCue]
        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            cues = text.isEmpty
                ? []
                : [CaptionCue(start: 0, end: max(result.duration, 0.1), text: text)]
        } else {
            cues = stride(from: 0, to: words.count, by: 8).map { startIndex in
                let group = Array(words[startIndex..<min(startIndex + 8, words.count)])
                return CaptionCue(
                    start: group[0].startTime,
                    end: max(group.last?.endTime ?? group[0].endTime, group[0].startTime + 0.1),
                    text: group.map(\.word).joined(separator: " ")
                )
            }
        }
        guard !cues.isEmpty else { throw WhisperTranscriptionError.noSpeech }
        return cues
#else
        throw WhisperTranscriptionError.unavailable
#endif
    }
}

private func audioFileForTranscription(from mediaURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: mediaURL)
    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
        throw WhisperTranscriptionError.noAudio
    }

    let audioExtensions = ["wav", "mp3", "m4a", "flac", "aac", "caf"]
    if audioExtensions.contains(mediaURL.pathExtension.lowercased()) {
        return mediaURL
    }

    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw WhisperTranscriptionError.noAudio
    }
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ncaption-\(UUID().uuidString)")
        .appendingPathExtension("m4a")
    try await exporter.export(to: outputURL, as: .m4a)
    return outputURL
}

enum WhisperModelLibrary {
    private static let defaultsKey = "whisper.downloadedModelPaths"

    static func downloadedModelIDs() -> Set<String> {
        let paths = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        return Set(paths.compactMap { id, path in
            FileManager.default.fileExists(atPath: path) ? id : nil
        })
    }

    static func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
#if canImport(WhisperKit)
        let directory = try modelsDirectory()
        let downloadedURL = try await WhisperKit.download(
            variant: model.id,
            downloadBase: directory,
            useBackgroundSession: false
        ) { value in
            progress(value.fractionCompleted)
        }
        try Task.checkCancellation()

        var paths = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        paths[model.id] = downloadedURL.path
        UserDefaults.standard.set(paths, forKey: defaultsKey)
#else
        throw WhisperTranscriptionError.unavailable
#endif
    }

    static func delete(_ model: WhisperModel) throws {
        var paths = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let path = paths[model.id], FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        paths.removeValue(forKey: model.id)
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }

    static func transcribe(mediaURL: URL, model: WhisperModel) async throws -> [CaptionCue] {
#if canImport(WhisperKit)
        let paths = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard let modelPath = paths[model.id],
              FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperTranscriptionError.modelNotDownloaded
        }

        let audioURL = try await audioFile(for: mediaURL)
        defer {
            if audioURL != mediaURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let config = WhisperKitConfig(
            model: model.id,
            modelFolder: modelPath,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        let options = DecodingOptions(task: .transcribe, language: "en", skipSpecialTokens: true)
        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let cues = results.flatMap(\.segments).compactMap { segment -> CaptionCue? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.end > segment.start else { return nil }
            return CaptionCue(start: Double(segment.start), end: Double(segment.end), text: text)
        }
        guard !cues.isEmpty else { throw WhisperTranscriptionError.noSpeech }
        return cues
#else
        throw WhisperTranscriptionError.unavailable
#endif
    }

    private static func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("nCaption Studio", isDirectory: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func audioFile(for mediaURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: mediaURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw WhisperTranscriptionError.noAudio
        }

        let audioExtensions = ["wav", "mp3", "m4a", "flac", "aac", "caf"]
        if audioExtensions.contains(mediaURL.pathExtension.lowercased()) {
            return mediaURL
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperTranscriptionError.noAudio
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncaption-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try await exporter.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
