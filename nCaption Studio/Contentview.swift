import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import AVKit

// MARK: - Content View
struct ContentView: View {
    let usesEmbeddedToolbar: Bool

    @Environment(\.undoManager) var undoManager
    @State private var undoTarget: UndoStateTarget?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var workspaceMode: StudioWorkspaceMode = .transcribe
    @Namespace private var workspaceSelectorNamespace
    @FocusState private var invisibleFocusTrap: Bool

    init(usesEmbeddedToolbar: Bool = false) {
        self.usesEmbeddedToolbar = usesEmbeddedToolbar
    }

    @State private var cues: [CaptionCue] = []
    @State private var rawCues: [CaptionCue] = []
    @State private var snapshotCues: [CaptionCue] = []
    @State private var editedRawCues: [CaptionCue] = []

    @State private var isDropTargeted = false

    @State private var searchText = ""
    @State private var searchResults: [UUID] = []
    @State private var currentSearchIndex = 0
    @FocusState private var isSearchFocused: Bool
    @State private var searchScrollTrigger = UUID()
    @State private var manualScrollTrigger: UUID?
    @State private var splitScrollTrigger: UUID?

    @State private var templateURL: URL?
    @State private var templateName = ""
    @State private var motionTitles: [MotionTitle] = []
    @State private var isMotionTitlePickerPresented = false
    @State private var isMotionTitlePickerHovered = false
    @State private var hoveredMotionTitleID: String?
    @State private var motionTitlePendingDeletion: MotionTitle?
    @State private var fileName = ""
    @State private var fps: Double = 29.97

    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngineRaw = TranscriptionEngine.apple.rawValue
    @AppStorage("selectedWhisperModelID") private var selectedWhisperModelID = "small.en"
    @State private var downloadedWhisperModelIDs: Set<String> = []
    @State private var isParakeetDownloaded = false
    @State private var parakeetDownloadProgress: Double?
    @State private var parakeetDownloadTask: Task<Void, Never>?
    @State private var whisperModelPendingDeletion: WhisperModel?
    @State private var whisperDownloadProgress: [String: Double] = [:]
    @State private var whisperDownloadTasks: [String: Task<Void, Never>] = [:]
    @State private var isWhisperModelPickerPresented = false
    @State private var isTranscribing = false
    @State private var transcriptionStatus = ""
    @State private var transcriptionSourceURL: URL?
    @State private var transcriptionSourceName = ""

    @State private var enableAutoSplit = false
    @State private var isApplyingSplit = false
    @State private var splitMode: SplitMode = .characters
    @State private var maxChars = 22.0
    @State private var maxWords = 4.0
    @State private var splitDebounceTask: Task<Void, Never>?
    @State private var isApplySplitHovered = false

    @AppStorage("aiProvider") private var providerRaw = AIProvider.defaultProvider.rawValue
    @AppStorage("aiModelClaude") private var modelClaude = "claude-haiku-5-5"
    @AppStorage("aiModelOpenAI") private var modelOpenAI = "gpt-4o-mini"
    @AppStorage("aiPromptsJSON") private var promptsJSON = ""
    @AppStorage("aiSelectedPromptID") private var selectedPromptID = ""
    @State private var prompts: [SavedPrompt] = []
    @State private var promptPendingDelete: SavedPrompt?
    @State private var activeSheet: AISheet?
    @State private var companionActivationID = UUID()
    @State private var availableModels: [String] = []
    @State private var modelsTask: Task<Void, Never>?
    @State private var changes: [CueChange] = []

    private enum AISheet: Identifiable {
        case editor(UUID), changes
        var id: String {
            switch self {
            case .editor(let id): return id.uuidString
            case .changes:        return "changes"
            }
        }
    }

    private struct ProjectSnapshot {
        let cues: [CaptionCue]
        let rawCues: [CaptionCue]
        let snapshotCues: [CaptionCue]
        let editedRawCues: [CaptionCue]
        let templateURL: URL?
        let templateName: String
        let fileName: String
        let transcriptionSourceURL: URL?
        let transcriptionSourceName: String
        let fps: Double
        let enableAutoSplit: Bool
        let splitMode: SplitMode
        let maxChars: Double
        let maxWords: Double
        let searchText: String
        let changes: [CueChange]
    }

    private final class ProjectUndoTarget: NSObject {
        var apply: (ProjectSnapshot) -> Void

        init(apply: @escaping (ProjectSnapshot) -> Void) {
            self.apply = apply
        }

        func register(undoManager: UndoManager?, restoring snapshot: ProjectSnapshot, redo: ProjectSnapshot) {
            undoManager?.registerUndo(withTarget: self) { target in
                target.apply(snapshot)
                target.register(undoManager: undoManager, restoring: redo, redo: snapshot)
            }
            undoManager?.setActionName("Delete Project")
        }
    }

    private struct CompressionSnapshot {
        let sourceURL: URL?
        let sourceName: String
        let metadata: CompressionMetadata?
        let outputURL: URL?
        let status: String
    }

    private final class CompressionUndoTarget: NSObject {
        var apply: (CompressionSnapshot) -> Void

        init(apply: @escaping (CompressionSnapshot) -> Void) {
            self.apply = apply
        }

        func register(undoManager: UndoManager?, restoring snapshot: CompressionSnapshot, redo: CompressionSnapshot) {
            undoManager?.registerUndo(withTarget: self) { target in
                target.apply(snapshot)
                target.register(undoManager: undoManager, restoring: redo, redo: snapshot)
            }
            undoManager?.setActionName("Remove Video")
        }
    }

    @State private var projectUndoTarget: ProjectUndoTarget?
    @State private var compressionUndoTarget: CompressionUndoTarget?
    @State private var apiKey = ""
    @State private var isRefining = false
    @State private var refineStatus = ""
    @State private var refineStatusIsError = false
    @State private var refineStatusDismissTask: Task<Void, Never>?
    @State private var hoveredPromptID: UUID?
    @State private var isCleanupHovered = false
    @State private var isPromptDoneHovered = false
    @State private var isExportTitlesHovered = false
    @State private var isExportSRTHovered = false
    @State private var isSendFCPHovered = false
    @State private var isClearProjectHovered = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isSmartSplitHovered = false

    @State private var compressionSourceURL: URL?
    @State private var compressionSourceName = ""
    @State private var compressionPlayer: AVPlayer?
    @State private var compressionMetadata: CompressionMetadata?
    @State private var compressionQuality: CompressionQuality = .balanced
    @State private var compressionResolution: CompressionResolution = .source
    @State private var compressionFormat: CompressionFormat = .mp4
    @State private var compressionDestination: CompressionDestination = .besideSource
    @State private var compressionFolderURL: URL?
    @State private var removeCompressionAudio = false
    @State private var isCompressing = false
    @State private var compressionProgress = 0.0
    @State private var compressionStatus = ""
    @State private var compressionResult: CompressionResult?
    @State private var compressionOutputURL: URL?
    @State private var compressionExportSession: AVAssetExportSession?
    @State private var compressionTask: Task<Void, Never>?
    @State private var replaceCompressionOriginal = false

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .claude }
    private var isTranscriptionWorkspace: Bool { usesEmbeddedToolbar || workspaceMode == .transcribe }
    private var modelBinding: Binding<String> { provider == .openai ? $modelOpenAI : $modelClaude }

    private var apiKeyPrefix: String {
        provider == .claude ? "sk-ant-" : "sk-"
    }

    private var apiKeySecretBinding: Binding<String> {
        Binding(
            get: {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return key.hasPrefix(apiKeyPrefix)
                    ? String(key.dropFirst(apiKeyPrefix.count))
                    : key
            },
            set: { pastedValue in
                let value = pastedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    apiKey = ""
                    return
                }
                apiKey = value.hasPrefix(apiKeyPrefix) ? value : apiKeyPrefix + value
            }
        )
    }

    private var selectedIndex: Int? { prompts.firstIndex { $0.id.uuidString == selectedPromptID } }
    private var editingIndex: Int? {
        if case .editor(let id) = activeSheet { return prompts.firstIndex { $0.id == id } }
        return nil
    }
    private var nameBinding: Binding<String> {
        Binding(get: { editingIndex.map { prompts[$0].name } ?? "" },
                set: { v in if let i = editingIndex { prompts[i].name = v } })
    }
    private var textBinding: Binding<String> {
        Binding(get: { editingIndex.map { prompts[$0].text } ?? "" },
                set: { v in if let i = editingIndex { prompts[i].text = v } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            leftControlPanel
                .frame(minWidth: 260)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 450)
        } detail: {
            Group {
                if isTranscriptionWorkspace {
                    rightEditorPanel
                        .transition(.opacity)
                } else {
                    compressionPreviewPanel
                        .transition(.opacity)
                }
            }
                .frame(minWidth: 300)
                .navigationSplitViewColumnWidth(min: 400, ideal: 800)
        }
        .modifier(SubtitleDropZone(isTargeted: $isDropTargeted, onDrop: handleDrop))
        .navigationTitle(isTranscriptionWorkspace ? StudioWorkspaceMode.transcribe.title : StudioWorkspaceMode.compress.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !usesEmbeddedToolbar {
                    clearProjectButton
                }
            }
        }
        .alert(
            isTranscriptionWorkspace ? "Delete this project?" : "Remove this video?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button(isTranscriptionWorkspace ? "Delete Project" : "Remove Video", role: .destructive) {
                if isTranscriptionWorkspace { deleteProject() } else { clearCompressionSource(registeringUndo: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isTranscriptionWorkspace
                 ? "The project will be cleared. You can restore it with Undo."
                 : "The video will be removed from the workspace. You can restore it with Undo.")
        }
        .tint(.blue)
        .animation(.easeInOut(duration: 0.18), value: workspaceMode)
        .onAppear { setupOnAppear() }
        .onOpenURL { url in
            let fileExtension = url.pathExtension.lowercased()
            if ["srt", "itt"].contains(fileExtension) {
                workspaceMode = .transcribe
                loadSubtitles(from: url)
            } else {
                workspaceMode = .compress
                loadCompressionSource(from: url)
            }
        }
        .overlay {
            if usesEmbeddedToolbar {
                switch activeSheet {
                case .some(.editor):
                    ExtensionCompanionOverlay(preferredSize: NSSize(width: 720, height: 520)) {
                        promptEditorSheet
                    }
                case .some(.changes):
                    ExtensionCompanionOverlay(preferredSize: NSSize(width: 700, height: 500)) {
                        changesSheet
                    }
                case nil:
                    EmptyView()
                }
            }
        }
    }

    private var embeddedSidebarButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color.white.opacity(0.06))
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.75)
            }
            .frame(width: 34, height: 34)
        }
        .clipShape(Circle())
        .contentShape(Circle())
        .accessibilityLabel("Toggle Sidebar")
        .help("Show or hide the sidebar")
    }

    @ViewBuilder
    private var clearProjectButton: some View {
        let isDisabled = isTranscriptionWorkspace ? !projectHasContent : compressionSourceURL == nil
        Button { isDeleteConfirmationPresented = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.red.opacity(isDisabled ? 0.35 : (isClearProjectHovered ? 0.95 : 0.72)))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 34, height: 34)
        .fixedSize()
        .background {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color.red.opacity(isClearProjectHovered && !isDisabled ? 0.16 : 0.08))
                Circle().stroke(Color.red.opacity(0.24), lineWidth: 0.75)
            }
            .frame(width: 34, height: 34)
            .aspectRatio(1, contentMode: .fit)
        }
        .clipShape(Circle())
        .contentShape(Circle())
        .scaleEffect(isClearProjectHovered && !isDisabled ? 1.08 : 1)
        .disabled(isDisabled)
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isClearProjectHovered = isHovering
            }
        }
        .accessibilityLabel(isTranscriptionWorkspace ? "Delete Project" : "Clear Video")
        .help(isTranscriptionWorkspace ? "Clear the project (Undo to restore)" : "Remove the current video")
    }

    private var projectHasContent: Bool {
        !cues.isEmpty || !rawCues.isEmpty || !fileName.isEmpty || templateURL != nil ||
        enableAutoSplit || !searchText.isEmpty || !changes.isEmpty
    }

    private func makeProjectSnapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            cues: cues,
            rawCues: rawCues,
            snapshotCues: snapshotCues,
            editedRawCues: editedRawCues,
            templateURL: templateURL,
            templateName: templateName,
            fileName: fileName,
            transcriptionSourceURL: transcriptionSourceURL,
            transcriptionSourceName: transcriptionSourceName,
            fps: fps,
            enableAutoSplit: enableAutoSplit,
            splitMode: splitMode,
            maxChars: maxChars,
            maxWords: maxWords,
            searchText: searchText,
            changes: changes
        )
    }

    private func applyProjectSnapshot(_ snapshot: ProjectSnapshot) {
        cues = snapshot.cues
        rawCues = snapshot.rawCues
        snapshotCues = snapshot.snapshotCues
        editedRawCues = snapshot.editedRawCues
        templateURL = snapshot.templateURL
        templateName = snapshot.templateName
        fileName = snapshot.fileName
        transcriptionSourceURL = snapshot.transcriptionSourceURL
        transcriptionSourceName = snapshot.transcriptionSourceName
        fps = snapshot.fps
        enableAutoSplit = snapshot.enableAutoSplit
        splitMode = snapshot.splitMode
        maxChars = snapshot.maxChars
        maxWords = snapshot.maxWords
        searchText = snapshot.searchText
        changes = snapshot.changes
        performSearch()
    }

    private func deleteProject() {
        guard projectHasContent else { return }

        let previous = makeProjectSnapshot()
        splitDebounceTask?.cancel()
        refineStatusDismissTask?.cancel()

        cues.removeAll()
        rawCues.removeAll()
        snapshotCues.removeAll()
        editedRawCues.removeAll()
        templateURL = nil
        templateName = ""
        fileName = ""
        transcriptionSourceURL = nil
        transcriptionSourceName = ""
        fps = 29.97
        enableAutoSplit = false
        splitMode = .characters
        maxChars = 22
        maxWords = 4
        searchText = ""
        searchResults.removeAll()
        currentSearchIndex = 0
        changes.removeAll()
        transcriptionStatus = ""
        refineStatus = ""

        let cleared = makeProjectSnapshot()
        projectUndoTarget?.register(
            undoManager: undoManager,
            restoring: previous,
            redo: cleared
        )
    }

    private func setupOnAppear() {
        undoTarget = UndoStateTarget { newCues, name in
            self.cues = newCues; self.fileName = name
            if self.rawCues.isEmpty { self.rawCues = newCues; self.editedRawCues = newCues }
        }
        projectUndoTarget = ProjectUndoTarget { snapshot in
            applyProjectSnapshot(snapshot)
        }
        compressionUndoTarget = CompressionUndoTarget { snapshot in
            applyCompressionSnapshot(snapshot)
        }
        apiKey = Keychain.get(provider.rawValue)
        loadPrompts()
        refreshMotionTitles()
        downloadedWhisperModelIDs = WhisperModelLibrary.downloadedModelIDs()
        isParakeetDownloaded = ParakeetModelLibrary.isDownloaded()
        if TranscriptionEngine(rawValue: selectedTranscriptionEngineRaw) == nil {
            selectedTranscriptionEngineRaw = TranscriptionEngine.apple.rawValue
        }
        if !WhisperModel.available.contains(where: { $0.id == selectedWhisperModelID }) {
            selectedWhisperModelID = WhisperModel.available[0].id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { invisibleFocusTrap = true }
    }

    private func registerUndo(oldCues: [CaptionCue], oldName: String? = nil) {
        undoTarget?.register(undoManager: undoManager, oldCues: oldCues, newCues: cues,
                             oldName: oldName ?? fileName, newName: fileName)
    }

    // MARK: - Left Panel
    private var leftControlPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                Color.clear.frame(width: 0, height: 0).focusable(true).focused($invisibleFocusTrap)

                VStack(spacing: 10) {
                    if !usesEmbeddedToolbar {
                        workspacePicker
                    }
                    if isTranscriptionWorkspace {
                        VStack(spacing: 10) {
                            frameRateSection
                            importSection
                            HStack(spacing: 8) {
                        TranscriptionModelPicker(
                            selectedEngineRaw: $selectedTranscriptionEngineRaw,
                            selectedWhisperModelID: $selectedWhisperModelID,
                            downloadedWhisperModelIDs: downloadedWhisperModelIDs,
                            whisperDownloadProgress: whisperDownloadProgress,
                            isParakeetDownloaded: isParakeetDownloaded,
                            parakeetDownloadProgress: parakeetDownloadProgress,
                            isPresented: $isWhisperModelPickerPresented,
                            whisperModelPendingDeletion: $whisperModelPendingDeletion,
                            onDownloadWhisper: downloadWhisperModel,
                            onCancelWhisperDownload: cancelWhisperModelDownload,
                            onDeleteWhisper: deleteWhisperModel,
                            onDownloadParakeet: downloadParakeetModel,
                            onCancelParakeetDownload: cancelParakeetModelDownload,
                            onDeleteParakeet: deleteParakeetModel
                        )
                        .layoutPriority(1)

                        RetranscribeButton(
                            isWorking: isTranscribing,
                            isDisabled: transcriptionSourceURL == nil || isTranscribing,
                            action: retranscribeMedia
                        )
                    }
                    if isTranscribing || !transcriptionStatus.isEmpty {
                        HStack(spacing: 8) {
                            if isTranscribing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(transcriptionStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                    smartSplitView
                    aiCleanupView

                    motionTitlePicker

                    exportSectionView
                            sendToFCPView
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        compressionControls
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(12)
                .background(Color(white: 0.10))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 1))

                Spacer(minLength: 20)
            }
            .padding(12)
        }
        .background {
            if !usesEmbeddedToolbar {
                WorkspaceSwipeSensor { direction in
                    let mode: StudioWorkspaceMode = direction < 0 ? .compress : .transcribe
                    guard workspaceMode != mode else { return }
                    withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.38)) {
                        workspaceMode = mode
                    }
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: .top,
                endPoint:   .bottom
            )
        )
    }

    private var workspacePicker: some View {
        HStack(spacing: 0) {
            ForEach(StudioWorkspaceMode.allCases) { mode in
                Button {
                    guard workspaceMode != mode else { return }
                    withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.38)) {
                        workspaceMode = mode
                    }
                } label: {
                    Text(mode.label)
                        .font(.body)
                        .foregroundStyle(workspaceMode == mode ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .background {
                            if workspaceMode == mode {
                                Capsule()
                                    .fill(Color.blue)
                                    .matchedGeometryEffect(id: "workspaceSelection", in: workspaceSelectorNamespace)
                                    .shadow(color: Color.blue.opacity(0.22), radius: 5, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.75))
        .padding(.bottom, 2)
        .onChange(of: workspaceMode) { _, mode in
            if mode == .compress {
                isSearchFocused = false
                compressionPlayer?.play()
                compressionPlayer?.pause()
            }
        }
    }

    private var motionTitlePicker: some View {
        Button {
            refreshMotionTitles()
            isMotionTitlePickerPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(templateName.isEmpty ? "Choose Motion Title (.moti)" : templateName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .focusEffectDisabled()
        .background(
            isMotionTitlePickerHovered ? Color.blue.opacity(0.12) : Color.gray.opacity(0.15),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isMotionTitlePickerHovered ? Color.blue.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 0.75)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isMotionTitlePickerHovered = hovering
            }
        }
        .popover(isPresented: $isMotionTitlePickerPresented, arrowEdge: .trailing) {
            motionTitlePickerContent
        }
        .alert("Delete Motion Title?", isPresented: Binding(
            get: { motionTitlePendingDeletion != nil },
            set: { if !$0 { motionTitlePendingDeletion = nil } }
        ), presenting: motionTitlePendingDeletion) { title in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteMotionTitle(title) }
        } message: { title in
            Text("This removes “\(title.name)” from nCaption Studio. The original file is not deleted.")
        }
    }

    private var motionTitlePickerContent: some View {
        let builtInTitles = motionTitles.filter(\.isBuiltIn)
        let importedTitles = motionTitles.filter { !$0.isBuiltIn }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Built-in")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if builtInTitles.isEmpty {
                Text("Add .moti files to the MotionTitles resource folder.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(builtInTitles) { title in
                    motionTitleSelectionButton(title)
                }
            }

            if !importedTitles.isEmpty {
                Divider()
                Text("My Motion Titles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(importedTitles) { title in
                    HStack(spacing: 6) {
                        motionTitleSelectionButton(title)
                        Button {
                            motionTitlePendingDeletion = title
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Delete \(title.name)")
                    }
                }
            }

            Divider()
            Button(action: pickMoti) {
                Label("Add New Motion Title…", systemImage: "plus")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(12)
        .frame(width: 300)
    }

    private func motionTitleSelectionButton(_ title: MotionTitle) -> some View {
        Button {
            selectMotionTitle(title)
        } label: {
            HStack {
                Text(title.name).lineLimit(1)
                Spacer(minLength: 8)
                if templateName == title.name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(
            hoveredMotionTitleID == title.id ? Color.white.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredMotionTitleID = hovering ? title.id : nil
            }
        }
        .focusEffectDisabled()
    }

    private var frameRateSection: some View {
        HStack {
            Text("Frame Rate:").foregroundColor(.secondary).font(.caption)
            Picker("", selection: $fps) {
                Text("23.98").tag(23.98); Text("24").tag(24.0); Text("25").tag(25.0)
                Text("29.97").tag(29.97); Text("30").tag(30.0); Text("60").tag(60.0)
            }
            .frame(width: 80)
            .labelsHidden()
            .focusEffectDisabled()
            .tint(Color.white.opacity(0.78))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
            )
            Spacer()
        }
    }

    private var importSection: some View {
        HStack(spacing: 0) {
            Button(action: importSubtitles) {
                Text(fileName.isEmpty ? "Import Subtitles (.srt, .itt)" : fileName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).padding(.leading, 12)
                    .padding(.trailing, fileName.isEmpty ? 12 : 4)
                    .contentShape(Rectangle())
            }.buttonStyle(PlainButtonStyle())
            if !fileName.isEmpty { ClearMediaButton(action: clearSubtitles).padding(.trailing, 8) }
        }
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.24), lineWidth: 0.75))
    }

    private var smartSplitView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    enableAutoSplit.toggle()
                }
            } label: {
                HStack {
                    Text("Smart Caption Splitter").font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Toggle("", isOn: .constant(enableAutoSplit))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if enableAutoSplit {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: Binding(
                        get: { splitMode },
                        set: { nv in withAnimation(.easeInOut(duration: 0.25)) { splitMode = nv } }
                    )) {
                        Text("Chars").tag(SplitMode.characters)
                        Text("Words").tag(SplitMode.words)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)

                    let sliderBinding: Binding<Double> = splitMode == .characters ? $maxChars : $maxWords
                    let sliderRange: ClosedRange<Double> = splitMode == .characters ? 10...48 : 1...10
                    Slider(value: sliderBinding, in: sliderRange, step: 1)

                    let limitVal = Int(splitMode == .characters ? maxChars : maxWords)
                    let limitLabel = splitMode == .characters ? "Chars" : "Words"
                    Text("Max \(limitLabel): \(limitVal)").font(.caption).foregroundColor(.secondary)

                    Button(action: applySmartSplit) {
                        Text("Apply Split").font(.caption.weight(.medium))
                            .foregroundColor(isApplySplitHovered ? .blue : .white.opacity(0.9))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                                if isApplySplitHovered {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.15))
                                }
                            })
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(isApplySplitHovered
                                        ? Color.blue.opacity(0.4)
                                        : Color.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isApplySplitHovered = h } }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(10)
        .background(
            isSmartSplitHovered ? Color.white.opacity(0.075) : Color.gray.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSmartSplitHovered ? Color.blue.opacity(0.30) : Color.white.opacity(0.10), lineWidth: 0.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isSmartSplitHovered = hovering
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: enableAutoSplit)
        .onChange(of: enableAutoSplit) { _, isOn in handleAutoSplitToggle(isOn: isOn) }
        .onChange(of: maxChars) { _, _ in if enableAutoSplit { debounceSmartSplit() } }
        .onChange(of: maxWords) { _, _ in if enableAutoSplit { debounceSmartSplit() } }
        .onChange(of: splitMode) { _, _ in if enableAutoSplit { debounceSmartSplit() } }
    }

    private var aiCleanupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Cleanup").font(.caption)
            Picker("", selection: $providerRaw) {
                ForEach(AIProvider.available) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .tint(Color.white.opacity(0.78))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
            )

            if provider != .apple {
                HStack(spacing: 6) {
                    TextField("Model", text: modelBinding).textFieldStyle(.roundedBorder).font(.caption)
                    Menu {
                        if availableModels.isEmpty {
                            Button(apiKey.isEmpty ? "Enter API key to load models" : "Load available models") { loadModels() }
                                .disabled(apiKey.isEmpty)
                        } else {
                            ForEach(availableModels, id: \.self) { m in Button(m) { setModel(m) } }
                            Divider()
                            Button("Refresh list") { loadModels() }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                HStack(spacing: 0) {
                    Text(apiKeyPrefix)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 7)
                    SecureField("API key", text: apiKeySecretBinding)
                        .font(.caption.monospaced())
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                }
                .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                )
                .help("The key prefix is visible; the secret portion is securely masked.")
            }

            VStack(spacing: 2) {
                ForEach(prompts) { p in
                    let isSelected = p.id.uuidString == selectedPromptID
                    HStack(spacing: 2) {
                        Button {
                            selectedPromptID = p.id.uuidString
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .blue : .secondary)
                                Text(p.name.isEmpty ? "Untitled" : p.name).font(.caption).lineLimit(1)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { presentPromptEditor(p.id) })

                        Button(action: { presentPromptEditor(p.id) }) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Edit prompt")

                        if prompts.count > 1 {
                            Button(action: { promptPendingDelete = p }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Delete prompt")
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 2)
                    .padding(.vertical, 2)
                    .background(
                        isSelected
                            ? Color.blue.opacity(0.12)
                            : (hoveredPromptID == p.id ? Color.white.opacity(0.06) : Color.clear)
                    )
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            hoveredPromptID = isHovering ? p.id : nil
                        }
                    }
                }
                Button(action: addPrompt) {
                    Label("Add New Prompt", systemImage: "plus").font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            let cleanUnavailable = cues.isEmpty || enableAutoSplit
            let cleanDisabled = cleanUnavailable || isRefining
            Button(action: runCleanup) {
                Label(
                    isRefining ? "Cleaning..." : "Clean Up Captions",
                    systemImage: "wand.and.stars"
                )
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.white.opacity(isCleanupHovered && !cleanDisabled ? 0.10 : 0))
                    })
                    .overlay {
                        ZStack {
                            if isRefining {
                                CleanupSheen()
                            }
                            Capsule().stroke(
                                Color.white.opacity(isRefining ? 0.26 : (isCleanupHovered && !cleanDisabled ? 0.35 : 0.18)),
                                lineWidth: 0.5
                            )
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(cleanDisabled)
            .opacity(cleanUnavailable ? 0.5 : 1.0)
            .scaleEffect(isCleanupHovered && !cleanDisabled ? 1.01 : 1.0)
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.12)) { isCleanupHovered = isHovering }
            }

            if !refineStatus.isEmpty {
                if refineStatusIsError {
                    Text(refineStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.red.opacity(0.20), lineWidth: 0.75)
                        )
                } else {
                    Text(refineStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !changes.isEmpty {
                Button(action: presentCleanupChanges) {
                    Text("View Changes (\(changes.count))").font(.caption.weight(.medium)).foregroundColor(.blue)
                }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10), lineWidth: 0.75))
        .onChange(of: providerRaw) { _, _ in
            availableModels = []
            apiKey = Keychain.get(provider.rawValue)
        }
        .onChange(of: apiKey) { _, new in
            if provider != .apple { Keychain.set(new, account: provider.rawValue) }
            modelsTask?.cancel()
            guard provider != .apple, !new.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            modelsTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if !Task.isCancelled { await MainActor.run { loadModels(silent: true) } }
            }
        }
        .onChange(of: prompts) { _, _ in savePrompts() }
        .background {
            if !usesEmbeddedToolbar {
                MovableCompanionWindow(
                    isPresented: promptEditorPresented,
                    activationID: companionActivationID,
                    title: "Edit Cleanup Prompt",
                    minimumSize: NSSize(width: 720, height: 520)
                ) {
                    promptEditorSheet
                }
            }
        }
        .background {
            if !usesEmbeddedToolbar {
                MovableCompanionWindow(
                    isPresented: cleanupChangesPresented,
                    activationID: companionActivationID,
                    title: "Cleanup Changes",
                    minimumSize: NSSize(width: 700, height: 500)
                ) {
                    changesSheet
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(promptPendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { promptPendingDelete != nil },
                                 set: { if !$0 { promptPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = promptPendingDelete { deletePrompt(p.id) }
                promptPendingDelete = nil
            }
        }
    }

    private func presentPromptEditor(_ id: UUID) {
        activeSheet = .editor(id)
        companionActivationID = UUID()
    }

    private func presentCleanupChanges() {
        activeSheet = .changes
        companionActivationID = UUID()
    }

    private var promptEditorPresented: Binding<Bool> {
        Binding(
            get: {
                if case .some(.editor) = activeSheet { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .some(.editor) = activeSheet {
                    activeSheet = nil
                }
            }
        )
    }

    private var cleanupChangesPresented: Binding<Bool> {
        Binding(
            get: {
                if case .some(.changes) = activeSheet { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .some(.changes) = activeSheet {
                    activeSheet = nil
                }
            }
        )
    }

    private var promptEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Prompt name", text: nameBinding)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .onSubmit { activeSheet = nil }
                Spacer()
                Button {
                    activeSheet = nil
                } label: {
                    Text("Done (Esc)")
                        .foregroundStyle(isPromptDoneHovered ? Color.white : Color.white.opacity(0.82))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Color.white.opacity(isPromptDoneHovered ? 0.10 : 0.045),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    Color.white.opacity(isPromptDoneHovered ? 0.30 : 0.14),
                                    lineWidth: 0.75
                                )
                        }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isPromptDoneHovered = hovering
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
            TextEditor(text: textBinding)
                .font(.system(size: 13, design: .monospaced))
                .padding(6).background(Color.black.opacity(0.2)).cornerRadius(8)
        }
        .padding(16)
        .frame(
            minWidth: usesEmbeddedToolbar ? 0 : 720,
            minHeight: usesEmbeddedToolbar ? 0 : 520
        )
        .onExitCommand { activeSheet = nil }
    }

    private var changesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(changes.count) captions changed").font(.headline)
                Spacer()
                Button {
                    activeSheet = nil
                } label: {
                    Text("Done (Esc)")
                        .foregroundStyle(isPromptDoneHovered ? Color.white : Color.white.opacity(0.82))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Color.white.opacity(isPromptDoneHovered ? 0.10 : 0.045),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    Color.white.opacity(isPromptDoneHovered ? 0.30 : 0.14),
                                    lineWidth: 0.75
                                )
                        }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isPromptDoneHovered = hovering
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(changes) { c in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(format: "#%d  %.2fs", c.index + 1, c.time))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(c.edits.enumerated()), id: \.offset) { _, e in
                                    HStack(spacing: 6) {
                                        if e.from.isEmpty {
                                            Text("+").foregroundColor(.green)
                                            Text(e.to).foregroundColor(.green)
                                        } else {
                                            Text(e.from).foregroundColor(.red.opacity(0.85))
                                            Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                                            Text(e.to.isEmpty ? "(removed)" : e.to)
                                                .foregroundColor(e.to.isEmpty ? .secondary : .green)
                                        }
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(
            minWidth: usesEmbeddedToolbar ? 0 : 520,
            minHeight: usesEmbeddedToolbar ? 0 : 380
        )
        .onExitCommand { activeSheet = nil }
    }

    private func setModel(_ m: String) {
        if provider == .openai { modelOpenAI = m } else { modelClaude = m }
    }

    private func loadModels(silent: Bool = false) {
        let p = provider, key = apiKey
        guard p != .apple, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            if !silent { showTemporaryRefineStatus("Enter your API key first.") }
            return
        }
        if !silent { refineStatus = "Loading models..." }
        Task {
            do {
                let list = try await AIRefiner.listModels(provider: p, apiKey: key)
                await MainActor.run {
                    availableModels = list
                    if !silent { refineStatus = list.isEmpty ? "No models returned." : "Loaded \(list.count) models." }
                }
            } catch {
                if !silent {
                    await MainActor.run { showTemporaryRefineStatus(error.localizedDescription) }
                }
            }
        }
    }

    private func loadPrompts() {
        if let data = promptsJSON.data(using: .utf8),
           let saved = try? JSONDecoder().decode([SavedPrompt].self, from: data), !saved.isEmpty {
            prompts = saved
        } else {
            prompts = [SavedPrompt(name: "Prompt 1", text: "")]
        }
        if selectedIndex == nil { selectedPromptID = prompts[0].id.uuidString }
    }

    private func savePrompts() {
        if let data = try? JSONEncoder().encode(prompts), let str = String(data: data, encoding: .utf8) {
            promptsJSON = str
        }
    }

    private func addPrompt() {
        let p = SavedPrompt(name: "Prompt \(prompts.count + 1)", text: "")
        prompts.append(p)
        selectedPromptID = p.id.uuidString
        presentPromptEditor(p.id)
    }

    private func deletePrompt(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        if selectedIndex == nil, let first = prompts.first { selectedPromptID = first.id.uuidString }
    }

    private func showTemporaryRefineStatus(_ message: String) {
        refineStatusDismissTask?.cancel()
        refineStatus = message
        let displayedMessage = message
        refineStatusDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, refineStatus == displayedMessage else { return }
            withAnimation(.easeOut(duration: 0.2)) { refineStatus = "" }
        }
    }

    private func runCleanup() {
        guard let idx = selectedIndex else { return }
        refineStatusDismissTask?.cancel()
        refineStatus = ""
        refineStatusIsError = false
        let prompt = prompts[idx].text
        let model = (provider == .openai ? modelOpenAI : modelClaude).trimmingCharacters(in: .whitespaces)
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showTemporaryRefineStatus("The selected prompt is empty.")
            return
        }
        if provider != .apple && model.isEmpty {
            showTemporaryRefineStatus("Enter a model name.")
            return
        }
        let old = cues
        changes = []
        refineStatusDismissTask?.cancel()
        isRefining = true
        refineStatus = "Cleaning 0/\(old.count)"
        Task {
            do {
                let result = try await AIRefiner.refine(cues: old, prompt: prompt, provider: provider,
                                                        model: model, apiKey: apiKey) { done in
                    await MainActor.run { refineStatus = "Cleaning \(done)/\(old.count)" }
                }
                await MainActor.run {
                    cues = result.cues; rawCues = result.cues; editedRawCues = result.cues
                    registerUndo(oldCues: old)
                    changes = AIRefiner.changes(old: old, new: result.cues)
                    var status = changes.isEmpty ? "Done. No changes needed." : "Done. \(changes.count) captions changed."
                    if result.failedBatches > 0 {
                        status += " \(result.failedBatches) batch(es) could not be cleaned and were left unchanged."
                    }
                    refineStatus = status
                    refineStatusIsError = false
                    isRefining = false
                }
            } catch {
                await MainActor.run {
                    isRefining = false
                    refineStatus = error.localizedDescription
                    refineStatusIsError = true
                }
            }
        }
    }

    private var exportSectionView: some View {
        HStack(spacing: 8) {
            let exportDisabled = cues.isEmpty || templateURL == nil
            Button(action: exportXML) {
                Text("Export Titles").font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(isExportTitlesHovered && !exportDisabled ? 0.95 : 0.75))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.white.opacity(isExportTitlesHovered && !exportDisabled ? 0.12 : 0.04))
                    })
                    .overlay(Capsule().stroke(
                        Color.white.opacity(isExportTitlesHovered && !exportDisabled ? 0.35 : 0.18),
                        lineWidth: 0.5
                    ))
            }
            .buttonStyle(.plain)
            .disabled(exportDisabled)
            .opacity(exportDisabled ? 0.5 : 1.0)
            .scaleEffect(isExportTitlesHovered && !exportDisabled ? 1.02 : 1.0)
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.12)) { isExportTitlesHovered = isHovering }
            }

            let srtDisabled = cues.isEmpty
            Button(action: exportSRT) {
                Text("Export SRT").font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(isExportSRTHovered && !srtDisabled ? 0.95 : 0.75))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.white.opacity(isExportSRTHovered && !srtDisabled ? 0.12 : 0.04))
                    })
                    .overlay(Capsule().stroke(
                        Color.white.opacity(isExportSRTHovered && !srtDisabled ? 0.35 : 0.18),
                        lineWidth: 0.5
                    ))
            }
            .buttonStyle(.plain)
            .disabled(srtDisabled)
            .opacity(srtDisabled ? 0.5 : 1.0)
            .scaleEffect(isExportSRTHovered && !srtDisabled ? 1.02 : 1.0)
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.12)) { isExportSRTHovered = isHovering }
            }
        }
    }

    private var sendToFCPView: some View {
        let disabled = cues.isEmpty || templateURL == nil
        return Button(action: sendToFinalCutPro) {
            Text("Open in Final Cut Pro").font(.caption.weight(.medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(Color.orange.opacity(isSendFCPHovered && !disabled ? 0.86 : 0.70))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .scaleEffect(isSendFCPHovered && !disabled ? 1.02 : 1.0)
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.12)) { isSendFCPHovered = isHovering }
        }
    }

    private func applySmartSplit() {
        let oldCues = snapshotCues
        let appliedCues = cues
        isApplyingSplit = true
        withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) { enableAutoSplit = false }
        snapshotCues = appliedCues
        editedRawCues = appliedCues
        registerUndo(oldCues: oldCues)
    }

    private func handleAutoSplitToggle(isOn: Bool) {
        if isOn {
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                snapshotCues = cues
                let allText = cues.map { $0.text }.joined(separator: " ")
                let words = allText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let totalWords = words.count
                var wordIndex = 0
                var patched = rawCues
                for i in 0..<patched.count {
                    let srcWords = rawCues[i].text
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }.count
                    let take: Int
                    if i == patched.count - 1 {
                        take = totalWords - wordIndex
                    } else {
                        take = min(srcWords, totalWords - wordIndex)
                    }
                    if take > 0 {
                        patched[i].text = words[wordIndex..<(wordIndex + take)].joined(separator: " ")
                        wordIndex += take
                    }
                }
                editedRawCues = patched
                let limit = Int(splitMode == .characters ? maxChars : maxWords)
                cues = splitCues(editedRawCues, mode: splitMode, limit: limit)
            }
        } else {
            splitDebounceTask?.cancel()
            if isApplyingSplit { isApplyingSplit = false } else { cues = snapshotCues }
        }
    }

    // MARK: - Compression Workspace
    private var compressionControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Button(action: importCompressionSource) {
                    Label(
                        compressionSourceName.isEmpty ? "Import Video or FCPXML" : compressionSourceName,
                        systemImage: compressionSourceName.isEmpty ? "plus" : "film"
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if compressionSourceURL != nil {
                    ClearMediaButton { clearCompressionSource(registeringUndo: true) }
                        .padding(.trailing, 8)
                }
            }
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.28), lineWidth: 0.75))

            compressionSettingsCard

            if isCompressing || !compressionStatus.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        if isCompressing { ProgressView().controlSize(.small) }
                        Text(compressionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    if isCompressing {
                        ProgressView(value: compressionProgress)
                            .tint(.blue)
                    }
                }
            }

            if let result = compressionResult {
                HStack(spacing: 5) {
                    Text(result.originalSize).foregroundStyle(.primary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(result.outputSize).foregroundStyle(.green)
                    Text("• \(result.reduction)% smaller").foregroundStyle(.green)
                }
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: isCompressing ? cancelCompression : beginCompression) {
                Label(isCompressing ? "Cancel Compression" : "Compress Video",
                      systemImage: isCompressing ? "xmark" : "arrow.down.right.and.arrow.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(isCompressing ? Color.red.opacity(0.72) : Color.orange.opacity(0.72), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(compressionSourceURL == nil)
            .opacity(compressionSourceURL == nil ? 0.45 : 1)
        }
    }

    private var compressionSettingsCard: some View {
        VStack(spacing: 0) {
            compressionDestinationRow
            Divider().opacity(0.35)
            compressionPickerRow("Output Format", selection: $compressionFormat)
            Divider().opacity(0.35)
            compressionPickerRow("Video Quality", selection: $compressionQuality)
            Divider().opacity(0.35)
            compressionPickerRow("Resolution", selection: $compressionResolution)
            Divider().opacity(0.35)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replace Original").font(.caption)
                    Text("The source is replaced after a successful export.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("Replace Original", isOn: $replaceCompressionOriginal)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.vertical, 9)
        }
        .padding(.horizontal, 10)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10), lineWidth: 0.75))
    }

    private func compressionPickerRow<Value>(_ title: LocalizedStringKey, selection: Binding<Value>) -> some View
    where Value: Hashable & CaseIterable & Identifiable, Value.AllCases: RandomAccessCollection {
        HStack {
            Text(title).font(.caption).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(Value.allCases) { value in
                    Text(String(describing: value)).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
            .tint(Color.white.opacity(0.85))
        }
        .padding(.vertical, 6)
    }

    private var compressionDestinationRow: some View {
        HStack {
            Text("Output Folder").font(.caption)
            Spacer()
            Menu {
                Button("Same as Input") {
                    compressionDestination = .besideSource
                    compressionFolderURL = nil
                }
                Button("Choose Folder…") { chooseCompressionFolder() }
            } label: {
                HStack(spacing: 5) {
                    Text(compressionDestination == .besideSource
                         ? "Same as Input"
                         : compressionFolderURL?.lastPathComponent ?? "Choose Folder…")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.white.opacity(0.88))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.11), lineWidth: 0.75))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    private func compressionStat(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    private var compressionPreviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if usesEmbeddedToolbar { embeddedSidebarButton }
                VStack(alignment: .leading, spacing: 2) {
                    Text(compressionSourceName.isEmpty ? "Video Preview" : compressionSourceName)
                        .font(.headline)
                        .lineLimit(1)
                    if let metadata = compressionMetadata {
                        Text("\(metadata.resolutionText)  •  \(metadata.frameRateText) fps  •  \(metadata.durationText)  •  \(metadata.fileSizeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let outputURL = compressionOutputURL {
                    Button("Show Output", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if usesEmbeddedToolbar { clearProjectButton }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(ZStack { Rectangle().fill(.thickMaterial); Rectangle().fill(Color.black.opacity(0.4)) })
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.black.opacity(0.6)), alignment: .bottom)

            if let player = compressionPlayer {
                ModernVideoPlayer(player: player)
                    .id(ObjectIdentifier(player))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(Color.black.opacity(0.72))
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.gray.opacity(0.42))
                    Text("No Video Yet")
                        .font(.title3.bold())
                        .foregroundStyle(.gray.opacity(0.8))
                    Text("Import or drop a video or Final Cut Pro XML file here.")
                        .font(.subheadline)
                        .foregroundStyle(.gray.opacity(0.6))
                    Button(action: importCompressionSource) {
                        Label("Import Video", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.1))
            }
        }
        .frame(minWidth: 300)
        .background(Color.black.opacity(0.1))
    }

    // MARK: - Right Editor Panel
    private var rightEditorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if usesEmbeddedToolbar {
                    embeddedSidebarButton
                }

                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search subtitles...", text: $searchText)
                        .textFieldStyle(.plain).focused($isSearchFocused)
                        .onChange(of: searchText) { _, _ in performSearch() }
                        .onSubmit { isSearchFocused = false; searchScrollTrigger = UUID() }
                        .onExitCommand { searchText = ""; performSearch(); isSearchFocused = false }
                    if !searchText.isEmpty {
                        Button(action: { searchText = ""; performSearch() }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8).background(.ultraThinMaterial).cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))

                if !searchResults.isEmpty {
                    Text("\(currentSearchIndex + 1) of \(searchResults.count)")
                        .font(.caption).foregroundColor(.secondary).layoutPriority(1)
                    HStack(spacing: 4) {
                        Button(action: nextSearchResult) {
                            Image(systemName: "chevron.down").padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider().frame(height: 12).background(Color.white.opacity(0.3))
                        Button(action: prevSearchResult) {
                            Image(systemName: "chevron.up").padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.ultraThinMaterial).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .layoutPriority(1)
                }

                if usesEmbeddedToolbar {
                    clearProjectButton
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(ZStack { Rectangle().fill(.thickMaterial); Rectangle().fill(Color.black.opacity(0.4)) })
            .overlay(Rectangle().frame(height: 1).foregroundColor(.black.opacity(0.6)), alignment: .bottom)
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4).zIndex(1)

            if cues.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "text.quote").font(.system(size: 48, weight: .light))
                        .foregroundColor(.gray.opacity(0.4))
                    Text("No Subtitles Yet").font(.title3.bold()).foregroundColor(.gray.opacity(0.8))
                    Text("Import or drop an SRT or ITT file here.")
                        .font(.subheadline).foregroundColor(.gray.opacity(0.6))
                    Button(action: importSubtitles) {
                        Label("Import Subtitles", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.90))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain).padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.1))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                                SubtitleRowView(
                                    index: index, cue: $cues[index],
                                    totalCount: cues.count,
                                    isSearchResult: !searchResults.isEmpty && searchResults[currentSearchIndex] == cue.id,
                                    currentSearchText: searchText,
                                    isPreviewing: enableAutoSplit,
                                    onSplit: { splitCue(at: index, left: $0, right: $1) },
                                    onMerge: { mergeCues(at: index) },
                                    onDelete: { deleteIndividualCue(at: index) }
                                )
                                .equatable().id(cue.id)
                                .padding(.bottom, index == cues.count - 1 ? 40 : 0)
                            }
                        }.padding(.horizontal).padding(.top, 10)
                    }
                    .onChange(of: manualScrollTrigger) { _, id in
                        if let id {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: splitScrollTrigger) { _, id in
                        if let id {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: searchScrollTrigger) { _, _ in
                        if !searchResults.isEmpty {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                proxy.scrollTo(searchResults[currentSearchIndex], anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300).background(Color.black.opacity(0.1))
    }

    // MARK: - Logic Helpers
    private func debounceSmartSplit() {
        splitDebounceTask?.cancel()
        let source = editedRawCues
        let mode   = splitMode
        let limit  = Int(mode == .characters ? maxChars : maxWords)
        splitDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled {
                await MainActor.run { cues = splitCues(source, mode: mode, limit: limit) }
            }
        }
    }

    private func deleteIndividualCue(at index: Int) {
        let old = cues; cues.remove(at: index)
        registerUndo(oldCues: old)
    }

    private func clearSubtitles() {
        let old = cues, oldName = fileName
        cues.removeAll(); rawCues.removeAll(); snapshotCues.removeAll()
        editedRawCues.removeAll(); enableAutoSplit = false; fileName = ""
        registerUndo(oldCues: old, oldName: oldName)
    }

    private func importCompressionSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, FCPBridge.xmlType]
        panel.allowsMultipleSelection = false
        FCPBridge.present(panel, folderKey: "lastFolder.compressionImport") {
            if $0 == .OK, let url = panel.url {
                loadCompressionSource(from: url)
            }
        }
    }

    private func loadCompressionSource(from url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        if ["srt", "itt"].contains(fileExtension) {
            withAnimation(.easeInOut(duration: 0.2)) { workspaceMode = .transcribe }
            loadSubtitles(from: url)
            transcriptionStatus = "Subtitle files open in Transcribe. Compression accepts video files."
        } else if fileExtension.hasPrefix("fcpxml") {
            compressionStatus = "Reading Final Cut Pro project…"
            Task {
                let hasAccess = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                guard let data else {
                    compressionStatus = "The Final Cut Pro XML could not be read."
                    return
                }
                let importResult = await Task.detached(priority: .userInitiated) {
                    guard let result = FCPXMLCaptionReader.read(data) else { return nil as FCPCompressionImport? }
                    if result.containsProjectTimeline {
                        return FCPCompressionImport.renderedProjectRequired(name: result.name)
                    }
                    guard let mediaURL = result.mediaURLs.first else { return nil }
                    return .media(mediaURL, result.name.isEmpty ? mediaURL.lastPathComponent : result.name)
                }.value
                guard let importResult else {
                    compressionStatus = "No accessible video was found in that Final Cut Pro XML."
                    return
                }
                handleFCPCompressionImport(importResult)
            }
        } else if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                  contentType.conforms(to: .movie) {
            configureCompressionSource(url, displayName: url.lastPathComponent)
            if !isTranscribing {
                transcriptionSourceURL = url
                transcriptionSourceName = url.lastPathComponent
            }
        } else if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                  contentType.conforms(to: .audio) {
            withAnimation(.easeInOut(duration: 0.2)) { workspaceMode = .transcribe }
            transcriptionStatus = "Audio files open in Transcribe. Compression accepts video files."
            transcribeMedia(at: url, displayName: url.lastPathComponent)
        } else {
            compressionStatus = "That file isn’t supported here. Drop a video, or switch to Transcribe for SRT and ITT files."
        }
    }

    private func handleFCPCompressionImport(_ result: FCPCompressionImport) {
        switch result {
        case .media(let url, let name):
            configureCompressionSource(url, displayName: name)
        case .renderedProjectRequired(let name):
            compressionStatus = "\(name.isEmpty ? "This Final Cut Pro project" : name) is an edited timeline. In Final Cut Pro, create an Export File Share destination with Open With set to nCaption Studio; the rendered movie will open here automatically."
        }
    }

    private func configureCompressionSource(_ url: URL, displayName: String) {
        compressionPlayer?.pause()
        compressionPlayer?.replaceCurrentItem(with: nil)
        compressionSourceURL = url
        compressionSourceName = displayName
        compressionOutputURL = nil
        compressionResult = nil
        compressionStatus = "Reading video details…"
        let asset = AVURLAsset(url: url)
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        compressionPlayer = newPlayer

        Task {
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw CompressionError.noVideoTrack }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let rate = try await track.load(.nominalFrameRate)
                let transformedSize = size.applying(transform)
                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                let formatMetadata = (try? await asset.load(.metadata)) ?? []
                let tagItem = formatMetadata.first(where: { $0.commonKey == .commonKeyDescription })
                let previousTag = try? await tagItem?.load(.stringValue)
                let metadata = CompressionMetadata(
                    width: Int(abs(transformedSize.width)),
                    height: Int(abs(transformedSize.height)),
                    frameRate: Double(rate),
                    duration: duration.seconds.isFinite ? duration.seconds : 0,
                    fileSize: Int64(resourceValues?.fileSize ?? 0),
                    previousCompressionTag: previousTag
                )
                await MainActor.run {
                    guard compressionSourceURL == url, compressionPlayer === newPlayer else { return }
                    compressionMetadata = metadata
                    compressionStatus = "Ready to compress."
                }
            } catch {
                await MainActor.run {
                    guard compressionSourceURL == url, compressionPlayer === newPlayer else { return }
                    compressionMetadata = nil
                    compressionStatus = error.localizedDescription
                }
            }
        }
    }

    private func makeCompressionSnapshot() -> CompressionSnapshot {
        CompressionSnapshot(
            sourceURL: compressionSourceURL,
            sourceName: compressionSourceName,
            metadata: compressionMetadata,
            outputURL: compressionOutputURL,
            status: compressionStatus
        )
    }

    private func applyCompressionSnapshot(_ snapshot: CompressionSnapshot) {
        compressionSourceURL = snapshot.sourceURL
        compressionSourceName = snapshot.sourceName
        compressionMetadata = snapshot.metadata
        compressionOutputURL = snapshot.outputURL
        compressionStatus = snapshot.status
        compressionPlayer?.pause()
        compressionPlayer = snapshot.sourceURL.map { AVPlayer(url: $0) }
    }

    private func clearCompressionSource(registeringUndo: Bool = false) {
        let previous = makeCompressionSnapshot()
        cancelCompression()
        compressionPlayer?.pause()
        compressionPlayer = nil
        compressionSourceURL = nil
        compressionSourceName = ""
        compressionMetadata = nil
        compressionOutputURL = nil
        compressionResult = nil
        compressionStatus = ""
        if registeringUndo {
            compressionUndoTarget?.register(
                undoManager: undoManager,
                restoring: previous,
                redo: makeCompressionSnapshot()
            )
        }
    }

    private func chooseCompressionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        FCPBridge.present(panel, folderKey: "lastFolder.compressionOutput") {
            if $0 == .OK, let url = panel.url {
                compressionFolderURL = url
                compressionDestination = .chooseFolder
            }
        }
    }

    private func beginCompression() {
        guard let sourceURL = compressionSourceURL else { return }
        if compressionMetadata?.previousCompressionTag == compressionTag(quality: compressionQuality, resolution: compressionResolution, format: compressionFormat) {
            compressionStatus = "Already compressed at this setting — skipped."
            return
        }
        if compressionDestination == .chooseFolder, compressionFolderURL == nil {
            chooseCompressionFolder()
            compressionStatus = "Choose an output folder, then compress again."
            return
        }

        let folder = compressionDestination == .besideSource
            ? sourceURL.deletingLastPathComponent()
            : compressionFolderURL!
        let baseName = sourceURL.deletingPathExtension().lastPathComponent + "-compressed"
        let selectedFormat = compressionFormat
        let outputURL = replaceCompressionOriginal
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(selectedFormat.fileExtension)
            : uniqueOutputURL(in: folder, baseName: baseName, extension: selectedFormat.fileExtension)
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        let folderAccess = folder.startAccessingSecurityScopedResource()

        isCompressing = true
        compressionProgress = 0
        compressionStatus = "Preparing compression…"
        compressionOutputURL = nil
        compressionResult = nil

        compressionTask = Task {
            defer {
                if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
                if folderAccess { folder.stopAccessingSecurityScopedResource() }
            }
            do {
                let asset = try await compressionAsset(from: sourceURL, removingAudio: removeCompressionAudio)
                let preset = compressionResolution.preset(for: compressionQuality, sourceHeight: compressionMetadata?.height)
                guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                    throw CompressionError.unsupportedSettings
                }
                session.shouldOptimizeForNetworkUse = true
                if let sourceBytes = compressionMetadata?.fileSize, sourceBytes > 0, compressionQuality != .highest {
                    let ratio = compressionQuality == .balanced ? 0.55 : 0.32
                    session.fileLengthLimit = Int64(Double(sourceBytes) * ratio)
                }
                let tagItem = AVMutableMetadataItem()
                tagItem.keySpace = .common
                tagItem.key = AVMetadataKey.commonKeyDescription as NSString
                tagItem.value = compressionTag(quality: compressionQuality, resolution: compressionResolution, format: selectedFormat) as NSString
                session.metadata = [tagItem]
                await MainActor.run {
                    compressionExportSession = session
                    compressionStatus = "Compressing…"
                }

                let progressTask: Task<Void, Never>
                if #available(macOS 15.0, *) {
                    progressTask = Task {
                        for await state in session.states(updateInterval: 0.15) {
                            guard !Task.isCancelled else { break }
                            if case .exporting(let progress) = state {
                                await MainActor.run {
                                    compressionProgress = progress.fractionCompleted
                                }
                            }
                        }
                    }
                } else {
                    progressTask = Task {
                        while !Task.isCancelled {
                            await MainActor.run {
                                compressionProgress = Double(session.progress)
                            }
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                    }
                }
                defer { progressTask.cancel() }
                try await session.export(to: outputURL, as: selectedFormat.fileType)
                progressTask.cancel()

                let newSize = Int64((try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let oldSize = compressionMetadata?.fileSize ?? 0

                let finalURL: URL
                if replaceCompressionOriginal {
                    if sourceURL.pathExtension.lowercased() == selectedFormat.fileExtension {
                        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: outputURL)
                        finalURL = sourceURL
                    } else {
                        let renamedURL = sourceURL.deletingPathExtension().appendingPathExtension(selectedFormat.fileExtension)
                        if FileManager.default.fileExists(atPath: renamedURL.path) {
                            _ = try FileManager.default.replaceItemAt(renamedURL, withItemAt: outputURL)
                        } else {
                            try FileManager.default.moveItem(at: outputURL, to: renamedURL)
                        }
                        try? FileManager.default.removeItem(at: sourceURL)
                        finalURL = renamedURL
                    }
                } else {
                    finalURL = outputURL
                }
                await MainActor.run {
                    compressionProgress = 1
                    compressionOutputURL = finalURL
                    compressionResult = makeCompressionResult(originalBytes: oldSize, outputBytes: newSize)
                    compressionStatus = "Compression complete."
                    NSSound(named: NSSound.Name("Glass"))?.play()
                    if replaceCompressionOriginal {
                        compressionSourceURL = finalURL
                        compressionSourceName = finalURL.lastPathComponent
                        compressionPlayer = AVPlayer(url: finalURL)
                        if let metadata = compressionMetadata {
                            compressionMetadata = CompressionMetadata(
                                width: metadata.width,
                                height: metadata.height,
                                frameRate: metadata.frameRate,
                                duration: metadata.duration,
                                fileSize: newSize,
                                previousCompressionTag: compressionTag(quality: compressionQuality, resolution: compressionResolution, format: selectedFormat)
                            )
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run { compressionStatus = "Compression cancelled." }
            } catch {
                await MainActor.run {
                    compressionStatus = Task.isCancelled ? "Compression cancelled." : error.localizedDescription
                }
            }
            await MainActor.run {
                isCompressing = false
                compressionExportSession = nil
                compressionTask = nil
            }
        }
    }

    private func cancelCompression() {
        compressionTask?.cancel()
        compressionTask = nil
        compressionExportSession?.cancelExport()
        isCompressing = false
    }

    private func compressionAsset(from url: URL, removingAudio: Bool) async throws -> AVAsset {
        let source = AVURLAsset(url: url)
        guard removingAudio else { return source }
        let duration = try await source.load(.duration)
        let videoTracks = try await source.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw CompressionError.noVideoTrack }
        let composition = AVMutableComposition()
        for sourceTrack in videoTracks {
            guard let targetTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try targetTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
            targetTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
        }
        return composition
    }

    private func uniqueOutputURL(in folder: URL, baseName: String, extension fileExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func makeCompressionResult(originalBytes: Int64, outputBytes: Int64) -> CompressionResult? {
        guard originalBytes > 0, outputBytes > 0 else { return nil }
        let original = ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)
        let output = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
        let reduction = compressionReduction(originalBytes: originalBytes, outputBytes: outputBytes)
        return CompressionResult(originalSize: original, outputSize: output, reduction: reduction)
    }

    private func compressionReduction(originalBytes: Int64, outputBytes: Int64) -> Int {
        guard originalBytes > 0, outputBytes > 0 else { return 0 }
        return max(0, Int((1 - Double(outputBytes) / Double(originalBytes)) * 100))
    }

    private func compressionTag(quality: CompressionQuality, resolution: CompressionResolution, format: CompressionFormat) -> String {
        "nCaptionStudio:\(quality.rawValue):\(resolution.rawValue):\(format.rawValue)"
    }

    private func importSubtitles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt")!,
            UTType(filenameExtension: "itt")!,
            UTType(filenameExtension: "fcpxml")!,
            .audio,
            .movie
        ]
        FCPBridge.present(panel, folderKey: "lastFolder.import") { if $0 == .OK, let url = panel.url { loadSubtitles(from: url) } }
    }

    private func loadSubtitles(from url: URL) {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()
        if ext == "fcpxml", let data = try? Data(contentsOf: url) {
            loadFCPXML(data, fallbackName: url.deletingPathExtension().lastPathComponent)
            return
        }
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           contentType.conforms(to: .audio) || contentType.conforms(to: .movie) {
            transcribeMedia(at: url, displayName: url.lastPathComponent)
            if contentType.conforms(to: .movie), !isCompressing, !usesEmbeddedToolbar {
                configureCompressionSource(url, displayName: url.lastPathComponent)
            }
            return
        }
        guard ["srt", "itt"].contains(ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            transcriptionStatus = "That file type is not supported."
            return
        }
        let importFrameRate: Double
        if ext == "itt", let detectedFrameRate = parseITTFrameRate(text) {
            fps = detectedFrameRate
            importFrameRate = detectedFrameRate
        } else {
            importFrameRate = fps
        }
        let parsed = ext == "srt"
            ? parseSRT(text, fps: importFrameRate)
            : parseITT(text, fps: importFrameRate)
        rawCues = parsed; editedRawCues = parsed; cues = parsed
        enableAutoSplit = false; fileName = url.lastPathComponent
    }

    private func loadFCPXML(_ data: Data, fallbackName: String) {
        guard let result = FCPXMLCaptionReader.read(data) else {
            transcriptionStatus = "Could not read that Final Cut Pro XML."
            return
        }
        if let rate = result.fps { fps = rate }
        let projectName = result.name.isEmpty ? fallbackName : result.name

        if !result.cues.isEmpty {
            applyImportedCues(result.cues, fileName: projectName + ".fcpxml")
            transcriptionStatus = "Imported Final Cut Pro captions."
        } else if let mediaURL = result.mediaURLs.first {
            transcriptionStatus = "No Final Cut captions found. Using Whisper…"
            transcribeMedia(at: mediaURL, displayName: projectName + ".fcpxml")
        } else {
            transcriptionStatus = "No captions or accessible media were found in that Final Cut Pro item."
        }
    }

    private func retranscribeMedia() {
        guard let url = transcriptionSourceURL else { return }
        transcribeMedia(at: url, displayName: transcriptionSourceName)
    }

    private func transcribeMedia(at url: URL, displayName: String) {
        guard !isTranscribing else { return }
        let engine = TranscriptionEngine(rawValue: selectedTranscriptionEngineRaw) ?? .apple
        let whisperModel = WhisperModel.available.first { $0.id == selectedWhisperModelID }
        transcriptionSourceURL = url
        transcriptionSourceName = displayName

        if engine == .whisper {
            guard let whisperModel, downloadedWhisperModelIDs.contains(whisperModel.id) else {
                isWhisperModelPickerPresented = true
                transcriptionStatus = "Download the selected Whisper model before transcribing."
                return
            }
        } else if engine == .parakeet, !isParakeetDownloaded {
            isWhisperModelPickerPresented = true
            transcriptionStatus = "Download Parakeet Ultra before transcribing."
            return
        }

        isTranscribing = true
        transcriptionStatus = "Preparing audio and loading \(engine.name)…"
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let imported: [CaptionCue]
                switch engine {
                case .apple:
                    imported = try await AppleTranscriptionLibrary.transcribe(mediaURL: url)
                case .parakeet:
                    imported = try await ParakeetModelLibrary.transcribe(mediaURL: url)
                case .whisper:
                    guard let whisperModel else { throw WhisperTranscriptionError.modelNotDownloaded }
                    imported = try await WhisperModelLibrary.transcribe(mediaURL: url, model: whisperModel)
                }
                await MainActor.run {
                    applyImportedCues(imported, fileName: displayName)
                    isTranscribing = false
                    transcriptionStatus = "Transcription complete."
                }
            } catch {
                await MainActor.run {
                    isTranscribing = false
                    transcriptionStatus = error.localizedDescription
                }
            }
        }
    }

    private func applyImportedCues(_ imported: [CaptionCue], fileName: String) {
        rawCues = imported
        editedRawCues = imported
        cues = imported
        enableAutoSplit = false
        self.fileName = fileName
    }

    private func downloadWhisperModel(_ model: WhisperModel) {
        guard whisperDownloadTasks[model.id] == nil else { return }
        whisperDownloadProgress[model.id] = 0
        transcriptionStatus = "Downloading \(model.name)…"

        whisperDownloadTasks[model.id] = Task { @MainActor in
            do {
                try await WhisperModelLibrary.download(model) { progress in
                    Task { @MainActor in
                        whisperDownloadProgress[model.id] = progress
                    }
                }
                try Task.checkCancellation()
                whisperDownloadProgress.removeValue(forKey: model.id)
                whisperDownloadTasks.removeValue(forKey: model.id)
                downloadedWhisperModelIDs = WhisperModelLibrary.downloadedModelIDs()
                selectedWhisperModelID = model.id
                transcriptionStatus = "\(model.name) is ready."
            } catch is CancellationError {
                whisperDownloadProgress.removeValue(forKey: model.id)
                whisperDownloadTasks.removeValue(forKey: model.id)
                transcriptionStatus = "\(model.name) download cancelled."
            } catch {
                whisperDownloadProgress.removeValue(forKey: model.id)
                whisperDownloadTasks.removeValue(forKey: model.id)
                transcriptionStatus = "Model download failed: \(error.localizedDescription)"
            }
        }
    }

    private func cancelWhisperModelDownload(_ model: WhisperModel) {
        whisperDownloadTasks[model.id]?.cancel()
    }

    private func downloadParakeetModel() {
        guard parakeetDownloadTask == nil else { return }
        parakeetDownloadProgress = 0
        transcriptionStatus = "Downloading Parakeet Ultra…"

        parakeetDownloadTask = Task { @MainActor in
            do {
                try await ParakeetModelLibrary.download { progress in
                    Task { @MainActor in
                        parakeetDownloadProgress = progress
                    }
                }
                try Task.checkCancellation()
                parakeetDownloadProgress = nil
                parakeetDownloadTask = nil
                isParakeetDownloaded = ParakeetModelLibrary.isDownloaded()
                selectedTranscriptionEngineRaw = TranscriptionEngine.parakeet.rawValue
                transcriptionStatus = "Parakeet Ultra is ready."
            } catch is CancellationError {
                parakeetDownloadProgress = nil
                parakeetDownloadTask = nil
                transcriptionStatus = "Parakeet Ultra download cancelled."
            } catch {
                parakeetDownloadProgress = nil
                parakeetDownloadTask = nil
                transcriptionStatus = "Parakeet download failed: \(error.localizedDescription)"
            }
        }
    }

    private func cancelParakeetModelDownload() {
        parakeetDownloadTask?.cancel()
    }

    private func deleteParakeetModel() {
        do {
            try ParakeetModelLibrary.delete()
            isParakeetDownloaded = false
            if selectedTranscriptionEngineRaw == TranscriptionEngine.parakeet.rawValue {
                selectedTranscriptionEngineRaw = TranscriptionEngine.apple.rawValue
            }
            transcriptionStatus = "Parakeet Ultra was deleted."
        } catch {
            transcriptionStatus = "Could not delete Parakeet Ultra: \(error.localizedDescription)"
        }
    }

    private func deleteWhisperModel(_ model: WhisperModel) {
        do {
            try WhisperModelLibrary.delete(model)
            downloadedWhisperModelIDs = WhisperModelLibrary.downloadedModelIDs()
            transcriptionStatus = "\(model.name) was deleted."
        } catch {
            transcriptionStatus = "Could not delete \(model.name): \(error.localizedDescription)"
        }
        whisperModelPendingDeletion = nil
    }

    private func sendToFinalCutPro() {
        guard let tURL = templateURL else { return }
        let xml = buildXML(cues: cues, templateURL: tURL, fps: fps, mediaName: exportBaseName)
        if !FCPBridge.openInFinalCutPro(xml: xml, name: exportBaseName) {
            showTemporaryRefineStatus("Could not open Final Cut Pro.")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(FCPBridge.xmlType.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: FCPBridge.xmlType.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        if !usesEmbeddedToolbar && workspaceMode == .compress {
                            compressionStatus = "Reading Final Cut Pro project…"
                            Task {
                                let importResult = await Task.detached(priority: .userInitiated) {
                                    guard let result = FCPXMLCaptionReader.read(data) else { return nil as FCPCompressionImport? }
                                    if result.containsProjectTimeline {
                                        return FCPCompressionImport.renderedProjectRequired(name: result.name)
                                    }
                                    guard let mediaURL = result.mediaURLs.first else { return nil }
                                    return .media(mediaURL, result.name.isEmpty ? mediaURL.lastPathComponent : result.name)
                                }.value
                                if let importResult {
                                    handleFCPCompressionImport(importResult)
                                } else {
                                    compressionStatus = "No accessible video was found in that Final Cut Pro project."
                                }
                            }
                        } else {
                            loadFCPXML(data, fallbackName: "Final Cut Pro")
                        }
                    }
                }
            } else if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if url.pathExtension.lowercased() == "moti" {
                            self.importMotionTitle(at: url)
                        } else if !self.usesEmbeddedToolbar && self.workspaceMode == .compress {
                            self.loadCompressionSource(from: url)
                        } else {
                            self.loadSubtitles(from: url)
                        }
                    }
                }
            }
        }
        return true
    }

    private func performSearch() {
        guard !searchText.isEmpty else { searchResults = []; currentSearchIndex = 0; return }
        searchResults = cues.filter { $0.text.localizedCaseInsensitiveContains(searchText) }.map { $0.id }
        currentSearchIndex = 0
        if !searchResults.isEmpty { manualScrollTrigger = searchResults[0] }
    }

    private func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        if currentSearchIndex < searchResults.count - 1 { currentSearchIndex += 1 }
        else { currentSearchIndex = 0 }
        manualScrollTrigger = searchResults[currentSearchIndex]
    }

    private func prevSearchResult() {
        guard !searchResults.isEmpty else { return }
        if currentSearchIndex > 0 { currentSearchIndex -= 1 }
        else { currentSearchIndex = searchResults.count - 1 }
        manualScrollTrigger = searchResults[currentSearchIndex]
    }

    private func splitCue(at index: Int, left: String, right: String) {
        guard index < cues.count else { return }
        let old = cues, cue = cues[index]
        let newCue: CaptionCue
        if left.isEmpty && right.isEmpty {
            newCue = CaptionCue(start: cue.end, end: cue.end + 1.0, text: "")
            cues.insert(newCue, at: index + 1)
        } else if right.isEmpty {
            newCue = CaptionCue(start: cue.end, end: cue.end + 1.0, text: "")
            cues[index].text = left; cues.insert(newCue, at: index + 1)
        } else {
            let ratio = Double(left.count) / max(1.0, Double(left.count + right.count))
            let midTime = cue.start + (cue.end - cue.start) * ratio
            newCue = CaptionCue(start: midTime, end: cue.end, text: right)
            cues[index].text = left; cues[index].end = midTime; cues.insert(newCue, at: index + 1)
        }
        registerUndo(oldCues: old)
        DispatchQueue.main.async { self.splitScrollTrigger = newCue.id }
    }

    private func mergeCues(at index: Int) {
        guard index < cues.count - 1 else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { [self] in
            guard index < cues.count - 1 else { return }
            let old = cues
            let sep = cues[index].text.isEmpty ? "" : " "
            cues[index].text += sep + cues[index + 1].text
            cues[index].end = cues[index + 1].end
            cues.remove(at: index + 1)
            registerUndo(oldCues: old)
        }
    }

    private func addBlankLine(at index: Int) {
        let old = cues, cue = cues[index]
        var newEnd = cue.end + 1.0
        if index < cues.count - 1 {
            let next = cues[index + 1]
            if next.start > cue.end { newEnd = min(cue.end + 1.0, next.start) }
        }
        cues.insert(CaptionCue(start: cue.end, end: newEnd, text: ""), at: index + 1)
        registerUndo(oldCues: old)
    }

    // MARK: - Export
    func pickMoti() {
        isMotionTitlePickerPresented = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "moti")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Movies/Motion Templates.localized/Titles.localized")
        FCPBridge.present(panel) {
            if $0 == .OK, let url = panel.url {
                importMotionTitle(at: url)
            }
        }
    }

    private func refreshMotionTitles() {
        motionTitles = MotionTitleLibrary.loadTitles()
    }

    private func importMotionTitle(at sourceURL: URL) {
        do {
            let title = try MotionTitleLibrary.importTitle(from: sourceURL)
            refreshMotionTitles()
            selectMotionTitle(title)
        } catch {
            showTemporaryRefineStatus("Could not add Motion Title: \(error.localizedDescription)")
        }
    }

    private func selectMotionTitle(_ title: MotionTitle) {
        do {
            templateURL = try MotionTitleLibrary.installForFinalCut(title)
            templateName = title.name
            isMotionTitlePickerPresented = false
        } catch {
            showTemporaryRefineStatus("Could not install Motion Title: \(error.localizedDescription)")
        }
    }

    private func deleteMotionTitle(_ title: MotionTitle) {
        do {
            try MotionTitleLibrary.delete(title)
            if templateURL == title.url {
                templateURL = nil
                templateName = ""
            }
            refreshMotionTitles()
        } catch {
            showTemporaryRefineStatus("Could not delete Motion Title: \(error.localizedDescription)")
        }
        motionTitlePendingDeletion = nil
    }

    private var exportBaseName: String {
        let raw = fileName.isEmpty ? "Captions" : fileName
        return (raw as NSString).deletingPathExtension
    }

    func exportXML() {
        let save = NSSavePanel(); save.allowedContentTypes = [.xml]
        save.nameFieldStringValue = "\(exportBaseName).fcpxml"
        FCPBridge.present(save, folderKey: "lastFolder.export") { if $0 == .OK, let url = save.url, let tURL = templateURL {
            try? buildXML(cues: cues, templateURL: tURL, fps: fps, mediaName: self.exportBaseName).write(to: url, atomically: true, encoding: .utf8)
        }}
    }

    func exportSRT() {
        let save = NSSavePanel(); save.allowedContentTypes = [UTType(filenameExtension: "srt")!]
        save.nameFieldStringValue = "\(exportBaseName).srt"
        FCPBridge.present(save, folderKey: "lastFolder.export") { if $0 == .OK, let url = save.url {
            try? buildSRT(cues: cues).write(to: url, atomically: true, encoding: .utf8)
        }}
    }
}

private enum StudioWorkspaceMode: String, CaseIterable, Identifiable {
    case transcribe
    case compress

    var id: Self { self }
    var label: String { self == .transcribe ? "Transcribe" : "Compress" }
    var title: String { self == .transcribe ? "nCaption Studio" : "nCompress Studio" }
}

private enum FCPCompressionImport: Sendable {
    case media(URL, String)
    case renderedProjectRequired(name: String)
}

private enum CompressionDestination: String, CaseIterable, Identifiable, CustomStringConvertible {
    case besideSource
    case chooseFolder

    var id: Self { self }
    var description: String { self == .besideSource ? "Same as Input" : "Choose Folder" }
}

private enum CompressionFormat: String, CaseIterable, Identifiable, CustomStringConvertible {
    case mp4
    case mov

    var id: Self { self }
    var description: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }

    init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}

private enum CompressionQuality: String, CaseIterable, Identifiable, CustomStringConvertible {
    case smaller
    case balanced
    case highest

    var id: Self { self }
    var description: String { rawValue.capitalized }
}

private enum CompressionResolution: String, CaseIterable, Identifiable, CustomStringConvertible {
    case source
    case p1080
    case p720
    case p480

    var id: Self { self }
    var description: String {
        switch self {
        case .source: "Same as Input"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    func preset(for quality: CompressionQuality, sourceHeight: Int?) -> String {
        switch self {
        case .p1080: return AVAssetExportPreset1920x1080
        case .p720: return AVAssetExportPreset1280x720
        case .p480: return AVAssetExportPreset640x480
        case .source:
            switch quality {
            case .smaller, .balanced: return AVAssetExportPresetHEVCHighestQuality
            case .highest: return AVAssetExportPresetHighestQuality
            }
        }
    }
}

private struct CompressionMetadata {
    let width: Int
    let height: Int
    let frameRate: Double
    let duration: Double
    let fileSize: Int64
    var previousCompressionTag: String? = nil

    var frameRateText: String { String(format: frameRate.rounded() == frameRate ? "%.0f" : "%.2f", frameRate) }
    var resolutionText: String { "\(width) × \(height)" }
    var durationText: String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
}

private struct CompressionResult {
    let originalSize: String
    let outputSize: String
    let reduction: Int
}

private enum CompressionError: LocalizedError {
    case noVideoTrack
    case unsupportedSettings
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The selected file does not contain a video track."
        case .unsupportedSettings: "This video does not support the selected compression settings."
        case .exportFailed: "The video could not be compressed."
        }
    }
}

private struct ModernVideoPlayer: View {
    let player: AVPlayer

    @State private var isPlaying = false
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var volume: Double = 1
    @State private var previousVolume: Double = 1
    @State private var isVolumePresented = false
    @State private var isScrubbing = false
    @State private var gestureSeekTask: Task<Void, Never>?
    @State private var pendingGestureTime = 0.0

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(
                player: player,
                onTogglePlayback: togglePlayback,
                onScrub: scrubByGesture
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 0.75))

            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20, height: 20)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(isPlaying ? "Pause (Space)" : "Play (Space)")

                Button { seek(by: -5) } label: {
                    Image(systemName: "gobackward.5")
                }
                .help("Back 5 seconds")

                Button { seek(by: 5) } label: {
                    Image(systemName: "goforward.5")
                }
                .help("Forward 5 seconds")

                Text(timeText(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { value in
                            currentTime = value
                            player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    ),
                    in: 0...max(duration, 0.01),
                    onEditingChanged: { isScrubbing = $0 }
                )
                .frame(minWidth: 150)
                .layoutPriority(1)

                Text(timeText(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                        isVolumePresented.toggle()
                    }
                } label: {
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggleMute() })
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.075))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 0.75))
            .overlay(alignment: .topTrailing) {
                if isVolumePresented {
                    VStack(spacing: 8) {
                        Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1)
                            .frame(width: 92)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 28, height: 100)
                            .onChange(of: volume) { _, value in
                                if value > 0 { previousVolume = value }
                                player.volume = Float(value)
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .offset(x: 4, y: -132)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                    .zIndex(10)
                }
            }
            .padding(.top, 10)
        }
        .task(id: ObjectIdentifier(player)) {
            volume = Double(player.volume)
            while !Task.isCancelled {
                if !isScrubbing { currentTime = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) }
                if let seconds = try? await player.currentItem?.asset.load(.duration).seconds, seconds.isFinite {
                    duration = max(0, seconds)
                }
                isPlaying = player.rate != 0
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .onDisappear { player.pause() }
    }

    private func togglePlayback() {
        if player.rate == 0 {
            if duration > 0, currentTime >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    private func seek(by offset: Double) {
        let target = min(max(currentTime + offset, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
    }

    private func scrubByGesture(_ offset: Double) {
        let target = min(max(currentTime + offset, 0), max(duration, 0))
        currentTime = target
        pendingGestureTime = target
        guard gestureSeekTask == nil else { return }
        gestureSeekTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(28))
            guard !Task.isCancelled else {
                gestureSeekTask = nil
                return
            }
            let seekTime = pendingGestureTime
            await player.seek(
                to: CMTime(seconds: seekTime, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.12, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.12, preferredTimescale: 600)
            )
            gestureSeekTask = nil
            if abs(pendingGestureTime - seekTime) > 0.01 {
                scrubByGesture(0)
            }
        }
    }

    private func toggleMute() {
        if volume > 0 {
            previousVolume = volume
            volume = 0
        } else {
            volume = max(previousVolume, 0.5)
        }
        player.volume = Float(volume)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let onTogglePlayback: () -> Void
    let onScrub: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTogglePlayback: onTogglePlayback)
    }

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = player
        view.onTogglePlayback = onTogglePlayback
        view.onScrub = onScrub
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: PlayerSurfaceView, context: Context) {
        view.playerLayer.player = player
        view.onTogglePlayback = onTogglePlayback
        view.onScrub = onScrub
        context.coordinator.onTogglePlayback = onTogglePlayback
    }

    static func dismantleNSView(_ view: PlayerSurfaceView, coordinator: Coordinator) {
        coordinator.tearDown()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        var onTogglePlayback: () -> Void
        private weak var surfaceView: PlayerSurfaceView?
        private var keyMonitor: Any?

        init(onTogglePlayback: @escaping () -> Void) {
            self.onTogglePlayback = onTogglePlayback
        }

        func install(for view: PlayerSurfaceView) {
            surfaceView = view
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 49,
                      let view = self?.surfaceView,
                      view.window?.isKeyWindow == true else { return event }
                self?.onTogglePlayback()
                return nil
            }
        }

        func tearDown() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }
}

private final class PlayerSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()
    var onTogglePlayback: (() -> Void)?
    var onScrub: ((Double) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onTogglePlayback?()
    }

    override func scrollWheel(with event: NSEvent) {
        let dominantDelta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : -event.scrollingDeltaY
        guard abs(dominantDelta) > 0.01 else { return }
        onScrub?(dominantDelta * 0.12)
    }
}

private struct WorkspaceSwipeSensor: NSViewRepresentable {
    let onSwipe: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        var onSwipe: (CGFloat) -> Void
        private weak var view: NSView?
        private var eventMonitor: Any?
        private var accumulatedDelta: CGFloat = 0
        private var didTrigger = false

        init(onSwipe: @escaping (CGFloat) -> Void) {
            self.onSwipe = onSwipe
        }

        func install(for view: NSView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.hasPreciseScrollingDeltas,
                      let view = self.view,
                      event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else {
                    return event
                }

                if event.phase == .began {
                    self.accumulatedDelta = 0
                    self.didTrigger = false
                }

                let horizontal = event.scrollingDeltaX
                guard abs(horizontal) > abs(event.scrollingDeltaY) * 1.2 else { return event }
                self.accumulatedDelta += horizontal

                if !self.didTrigger, abs(self.accumulatedDelta) >= 45 {
                    self.didTrigger = true
                    self.onSwipe(self.accumulatedDelta)
                }

                if event.phase == .ended || event.phase == .cancelled {
                    self.accumulatedDelta = 0
                    self.didTrigger = false
                }
                return event
            }
        }

        func tearDown() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
        }
    }
}

private struct ExtensionCompanionOverlay<Content: View>: View {
    let preferredSize: NSSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 48)
            let availableHeight = max(0, geometry.size.height - 48)

            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()

                content()
                    .frame(
                        width: min(preferredSize.width, availableWidth),
                        height: min(preferredSize.height, availableHeight)
                    )
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            }
        }
        .zIndex(100)
    }
}

private struct MovableCompanionWindow<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let activationID: UUID
    let title: String
    let minimumSize: NSSize
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(
            isPresented: isPresented,
            activationID: activationID,
            title: title,
            minimumSize: minimumSize,
            ownerWindow: nsView.window ?? FCPBridge.hostWindow,
            content: AnyView(content())
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        private var window: NSWindow?
        private weak var ownerWindow: NSWindow?
        private var ownerKeyObserver: NSObjectProtocol?
        private var lastActivationID: UUID?
        private var hostingController: NSHostingController<AnyView>?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(
            isPresented: Bool,
            activationID: UUID,
            title: String,
            minimumSize: NSSize,
            ownerWindow: NSWindow?,
            content: AnyView
        ) {
            if let hostingController {
                hostingController.rootView = content
            }

            guard isPresented else {
                window?.orderOut(nil)
                stopObservingOwner()
                self.ownerWindow = nil
                lastActivationID = nil
                if let window, FCPBridge.activeCompanionWindow === window {
                    FCPBridge.activeCompanionWindow = nil
                }
                return
            }

            let companionWindow: NSWindow
            if let window {
                companionWindow = window
            } else {
                let hostingController = NSHostingController(rootView: content)
                let contentRect = NSRect(origin: .zero, size: minimumSize)
                let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
                let newWindow: NSWindow
                if FCPBridge.hostWindow != nil {
                    let panel = NSPanel(
                        contentRect: contentRect,
                        styleMask: styleMask,
                        backing: .buffered,
                        defer: false
                    )
                    panel.isFloatingPanel = false
                    panel.becomesKeyOnlyIfNeeded = false
                    panel.worksWhenModal = true
                    panel.hidesOnDeactivate = false
                    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                    newWindow = panel
                } else {
                    newWindow = NSWindow(
                        contentRect: contentRect,
                        styleMask: styleMask,
                        backing: .buffered,
                        defer: false
                    )
                    newWindow.hidesOnDeactivate = true
                }
                newWindow.contentViewController = hostingController
                newWindow.isReleasedWhenClosed = false
                newWindow.delegate = self
                if let ownerWindow {
                    let ownerFrame = ownerWindow.frame
                    let windowFrame = newWindow.frame
                    newWindow.setFrameOrigin(
                        NSPoint(
                            x: ownerFrame.midX - windowFrame.width / 2,
                            y: ownerFrame.midY - windowFrame.height / 2
                        )
                    )
                } else {
                    newWindow.center()
                }
                self.hostingController = hostingController
                self.window = newWindow
                companionWindow = newWindow
            }

            companionWindow.title = title
            companionWindow.minSize = minimumSize
            if FCPBridge.hostWindow != nil {
                FCPBridge.activeCompanionWindow = companionWindow
            }

            observeOwner(ownerWindow)
            let shouldActivate = lastActivationID != activationID || !companionWindow.isVisible
            lastActivationID = activationID

            if shouldActivate {
                bringCompanionWindowToFront()
            }
        }

        private func bringCompanionWindowToFront() {
            guard let window else { return }
            // Never use addChildWindow here because the Final Cut host is a remote window proxy.
            // Keep the popup one level above it while allowing both windows to receive clicks.
            if let host = FCPBridge.hostWindow {
                // One level above the host so the popup is in front while it is the active window.
                window.level = NSWindow.Level(rawValue: host.level.rawValue + 1)
                NSLog("nCaption levels - host: %d popup: %d", host.level.rawValue, window.level.rawValue)
            } else {
                let ownerLevel = ownerWindow?.level.rawValue ?? NSWindow.Level.normal.rawValue
                window.level = NSWindow.Level(rawValue: ownerLevel + 1)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        private func observeOwner(_ ownerWindow: NSWindow?) {
            guard self.ownerWindow !== ownerWindow else { return }
            stopObservingOwner()
            self.ownerWindow = ownerWindow
            guard let ownerWindow else { return }

            ownerKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: ownerWindow,
                queue: .main
            ) { [weak self, weak ownerWindow] _ in
                MainActor.assumeIsolated {
                    guard let self, let ownerWindow, let window = self.window else { return }
                    // Final Cut owns the extension host window and can reorder it after it becomes key.
                    // Keep an open companion one level above that host so it cannot be pushed behind.
                    // orderFrontRegardless preserves its visible position without stealing keyboard focus
                    // back from the host window the user just clicked.
                    if FCPBridge.hostWindow != nil {
                        window.level = NSWindow.Level(rawValue: ownerWindow.level.rawValue + 1)
                        window.orderFrontRegardless()
                        return
                    }
                    window.level = ownerWindow.level
                    ownerWindow.orderFrontRegardless()
                }
            }
        }

        private func stopObservingOwner() {
            if let ownerKeyObserver {
                NotificationCenter.default.removeObserver(ownerKeyObserver)
                self.ownerKeyObserver = nil
            }
        }

        func windowDidBecomeKey(_ notification: Notification) {
            bringCompanionWindowToFront()
        }

        func windowWillClose(_ notification: Notification) {
            isPresented.wrappedValue = false
        }

        func tearDown() {
            stopObservingOwner()
            if let window, FCPBridge.activeCompanionWindow === window {
                FCPBridge.activeCompanionWindow = nil
            }
            window?.delegate = nil
            window?.close()
            window = nil
            ownerWindow = nil
            hostingController = nil
        }
    }
}

private struct CleanupSheen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let width = geometry.size.width
                let cycle = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8

                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: Color.white.opacity(0.04), location: 0.18),
                                .init(color: Color.white.opacity(0.16), location: 0.50),
                                .init(color: Color.white.opacity(0.04), location: 0.82),
                                .init(color: .clear, location: 1.00)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(width * 0.58, 90))
                    .blur(radius: 7)
                    .offset(
                        x: reduceMotion
                            ? 0
                            : (-width * 0.82 + cycle * width * 1.64)
                    )
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RetranscribeButton: View {
    let isWorking: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(isHovered && !isDisabled ? Color.blue : Color.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(isHovered && !isDisabled ? Color.blue.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                Circle()
                    .stroke(
                        isHovered && !isDisabled ? Color.blue.opacity(0.38) : Color.white.opacity(0.12),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("Retranscribe Media")
        .help("Transcribe the current video or audio again")
    }
}

private struct TranscriptionModelPicker: View {
    @Binding var selectedEngineRaw: String
    @Binding var selectedWhisperModelID: String
    let downloadedWhisperModelIDs: Set<String>
    let whisperDownloadProgress: [String: Double]
    let isParakeetDownloaded: Bool
    let parakeetDownloadProgress: Double?
    @Binding var isPresented: Bool
    @Binding var whisperModelPendingDeletion: WhisperModel?
    let onDownloadWhisper: (WhisperModel) -> Void
    let onCancelWhisperDownload: (WhisperModel) -> Void
    let onDeleteWhisper: (WhisperModel) -> Void
    let onDownloadParakeet: () -> Void
    let onCancelParakeetDownload: () -> Void
    let onDeleteParakeet: () -> Void

    @State private var isHovered = false
    @State private var hoveredWhisperModelID: String?

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngineRaw) ?? .apple
    }

    private var selectedDisplayName: String {
        if selectedEngine == .whisper {
            let model = WhisperModel.available.first { $0.id == selectedWhisperModelID }
            return "Whisper \(model?.name ?? "Small")"
        }
        return selectedEngine.name
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
                Text(selectedDisplayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .focusEffectDisabled()
        .background(
            isHovered ? Color.blue.opacity(0.12) : Color.gray.opacity(0.15),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isHovered ? Color.blue.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 0.75)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Transcription Models")
                    .font(.headline)
                Text("Choose an on-device engine. Downloaded models stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        AppleTranscriptionRow(
                            isSelected: selectedEngine == .apple,
                            onSelect: {
                                selectedEngineRaw = TranscriptionEngine.apple.rawValue
                                isPresented = false
                            }
                        )

                        Divider().padding(.vertical, 4)

                        ParakeetTranscriptionRow(
                            isSelected: selectedEngine == .parakeet,
                            isDownloaded: isParakeetDownloaded,
                            progress: parakeetDownloadProgress,
                            onSelectOrDownload: {
                                if isParakeetDownloaded {
                                    selectedEngineRaw = TranscriptionEngine.parakeet.rawValue
                                    isPresented = false
                                } else if parakeetDownloadProgress == nil {
                                    onDownloadParakeet()
                                }
                            },
                            onCancel: onCancelParakeetDownload,
                            onDelete: onDeleteParakeet
                        )

                        Divider().padding(.vertical, 4)

                        Text("Whisper")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)

                        ForEach(WhisperModel.available) { model in
                            modelRow(model)
                        }
                    }
                }
                .frame(width: 360, height: 360)
            }
            .padding(14)
        }
        .alert("Delete Whisper Model?", isPresented: Binding(
            get: { whisperModelPendingDeletion != nil },
            set: { if !$0 { whisperModelPendingDeletion = nil } }
        ), presenting: whisperModelPendingDeletion) { model in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDeleteWhisper(model)
            }
        } message: { model in
            Text("This removes \(model.name) from this Mac. You can download it again later.")
        }
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        let isDownloaded = downloadedWhisperModelIDs.contains(model.id)
        let progress = whisperDownloadProgress[model.id]

        return HStack(spacing: 10) {
            Button {
                if isDownloaded {
                    selectedWhisperModelID = model.id
                    selectedEngineRaw = TranscriptionEngine.whisper.rawValue
                    isPresented = false
                } else if progress == nil {
                    onDownloadWhisper(model)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedEngine == .whisper && selectedWhisperModelID == model.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selectedEngine == .whisper && selectedWhisperModelID == model.id ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.caption.weight(.medium))
                        Text("\(model.detail) • \(model.downloadSize)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                    }
                    Spacer(minLength: 4)
                    if !isDownloaded && progress == nil {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .focusEffectDisabled()

            if progress != nil {
                Button {
                    onCancelWhisperDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("Cancel \(model.name) download")
            } else if isDownloaded {
                Button(role: .destructive) {
                    whisperModelPendingDeletion = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("Delete \(model.name)")
            }
        }
        .padding(8)
        .background(
            selectedEngine == .whisper && selectedWhisperModelID == model.id
                ? Color.blue.opacity(0.10)
                : (hoveredWhisperModelID == model.id ? Color.white.opacity(0.07) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredWhisperModelID = hovering ? model.id : nil
            }
        }
    }
}

private struct AppleTranscriptionRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple On-Device")
                        .font(.caption.weight(.medium))
                    Text("System-managed • no separate download")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            isSelected ? Color.blue.opacity(0.10) : (isHovered ? Color.white.opacity(0.07) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct ParakeetTranscriptionRow: View {
    let isSelected: Bool
    let isDownloaded: Bool
    let progress: Double?
    let onSelectOrDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelectOrDownload) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parakeet Ultra")
                            .font(.caption.weight(.medium))
                        Text("Recommended Parakeet • ≈630 MB")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                    }
                    Spacer(minLength: 4)
                    if !isDownloaded && progress == nil {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .focusEffectDisabled()

            if progress != nil {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("Cancel Parakeet download")
            } else if isDownloaded {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("Delete Parakeet Ultra")
            }
        }
        .padding(8)
        .background(
            isSelected ? Color.blue.opacity(0.10) : (isHovered ? Color.white.opacity(0.07) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct MotionTitle: Identifiable, Hashable {
    let url: URL
    let isBuiltIn: Bool

    var id: String { url.standardizedFileURL.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
private enum MotionTitleLibrary {
    private static let appGroupIdentifier = "group.smnaveen.ncaptionstudio"
    private static let resourceFolderName = "MotionTitles"

    static func loadTitles() -> [MotionTitle] {
        let builtIn = motiFiles(in: Bundle.main.resourceURL)
            .map { MotionTitle(url: $0, isBuiltIn: true) }
        let imported = motiFiles(in: try? importedTitlesDirectory())
            .map { MotionTitle(url: $0, isBuiltIn: false) }

        return (builtIn + imported).sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func importTitle(from sourceURL: URL) throws -> MotionTitle {
        guard sourceURL.pathExtension.lowercased() == "moti" else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let directory = try importedTitlesDirectory()
        let titleDirectory = uniqueDirectory(for: sourceURL.deletingPathExtension().lastPathComponent, in: directory)
        try FileManager.default.createDirectory(at: titleDirectory, withIntermediateDirectories: true)
        let destination = titleDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try copyCompanionPreviews(from: sourceURL.deletingLastPathComponent(), to: titleDirectory)
        return MotionTitle(url: destination, isBuiltIn: false)
    }

    static func delete(_ title: MotionTitle) throws {
        guard !title.isBuiltIn else { return }
        let libraryDirectory = try importedTitlesDirectory().standardizedFileURL
        let parentDirectory = title.url.deletingLastPathComponent().standardizedFileURL
        if parentDirectory == libraryDirectory {
            try FileManager.default.removeItem(at: title.url)
        } else {
            try FileManager.default.removeItem(at: parentDirectory)
        }
    }

    static func installForFinalCut(_ title: MotionTitle) throws -> URL {
        let fileManager = FileManager.default
        let titlesDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent("Titles.localized", isDirectory: true)
            .appendingPathComponent("nCaption", isDirectory: true)
        let templateDirectory = titlesDirectory
            .appendingPathComponent(safeFolderName(title.name), isDirectory: true)
        try fileManager.createDirectory(at: templateDirectory, withIntermediateDirectories: true)

        let installedMoti = templateDirectory.appendingPathComponent(title.url.lastPathComponent)
        try replaceFile(at: installedMoti, with: title.url)
        try copyCompanionPreviews(from: title.url.deletingLastPathComponent(), to: templateDirectory)
        return installedMoti
    }

    private static func importedTitlesDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(resourceFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func motiFiles(in directory: URL?) -> [URL] {
        guard let directory,
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "moti" else { return nil }
            return url
        }
    }

    private static func uniqueDirectory(for name: String, in directory: URL) -> URL {
        var destination = directory.appendingPathComponent(safeFolderName(name), isDirectory: true)
        var suffix = 2

        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(safeFolderName(name)) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return destination
    }

    private static func copyCompanionPreviews(from sourceDirectory: URL, to destinationDirectory: URL) throws {
        for fileName in ["large.png", "small.png"] {
            let source = sourceDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try replaceFile(at: destinationDirectory.appendingPathComponent(fileName), with: source)
        }
    }

    private static func replaceFile(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func safeFolderName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let cleaned = name.components(separatedBy: invalidCharacters).joined(separator: "-")
        return cleaned.isEmpty ? "Motion Title" : cleaned
    }
}
