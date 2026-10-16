import Foundation

struct FCPXMLCaptions {
    var cues: [CaptionCue]
    var fps: Double?
    var name: String
    var mediaURLs: [URL]
    var containsProjectTimeline: Bool
}

// Reads <caption> elements from an FCPXML document (for example a project dragged out of Final Cut Pro).
// Cue times are 0-based, matching the project start. Captions inside compound clips are not read.
enum FCPXMLCaptionReader {
    static func read(_ data: Data) -> FCPXMLCaptions? {
        guard let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement(), root.name == "fcpxml",
              let sequence = (try? root.nodes(forXPath: ".//sequence"))?.first as? XMLElement
        else { return nil }

        var found: [(role: String, cue: CaptionCue)] = []

        // A child's local time zero maps to (base + offset - start) on the sequence timeline.
        func walk(_ container: XMLElement, base: Double) {
            for case let e as XMLElement in container.children ?? [] {
                let off = seconds(e, "offset") ?? 0
                if e.name == "caption" {
                    let text = captionText(e)
                    guard !text.isEmpty else { continue }
                    let start = base + off
                    let duration = seconds(e, "duration") ?? 0
                    found.append((e.attribute(forName: "role")?.stringValue ?? "",
                                  CaptionCue(start: start, end: start + duration, text: text)))
                } else {
                    walk(e, base: base + off - (seconds(e, "start") ?? 0))
                }
            }
        }
        walk(sequence, base: -(seconds(sequence, "tcStart") ?? 0))

        // If the project has several caption roles (languages), keep the one with the most captions.
        let byRole = Dictionary(grouping: found, by: { $0.role })
        let chosen = byRole.values.max(by: { $0.count < $1.count }) ?? []
        let cues = chosen.map { $0.cue }.sorted { $0.start < $1.start }

        var fps: Double?
        if let formatID = sequence.attribute(forName: "format")?.stringValue,
           let format = (try? root.nodes(forXPath: ".//format[@id='\(formatID)']"))?.first as? XMLElement,
           let frameDuration = seconds(format, "frameDuration"), frameDuration > 0 {
            fps = nearestRate(1 / frameDuration)
        }

        let name = (sequence.parent as? XMLElement)?.attribute(forName: "name")?.stringValue ?? ""
        let mediaURLs = originalMediaURLs(in: root)
        let containsProjectTimeline = ((try? root.nodes(forXPath: ".//project/sequence"))?.isEmpty == false)
        return FCPXMLCaptions(
            cues: cues,
            fps: fps,
            name: name,
            mediaURLs: mediaURLs,
            containsProjectTimeline: containsProjectTimeline
        )
    }

    private static func originalMediaURLs(in root: XMLElement) -> [URL] {
        let nodes = (try? root.nodes(forXPath: ".//resources/asset/media-rep[@src]")) ?? []
        var seen = Set<String>()
        return nodes.compactMap { node in
            guard let element = node as? XMLElement,
                  let source = element.attribute(forName: "src")?.stringValue,
                  let url = URL(string: source),
                  url.isFileURL,
                  seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return url
        }
    }

    private static func captionText(_ e: XMLElement) -> String {
        let nodes = (try? e.nodes(forXPath: "./text/text-style")) ?? []
        let raw = nodes.compactMap { $0.stringValue }.joined()
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // FCPXML times look like "3600s" or "1001/30000s".
    private static func seconds(_ e: XMLElement, _ attribute: String) -> Double? {
        guard var s = e.attribute(forName: attribute)?.stringValue, !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        if parts.count == 1 { return Double(parts[0]) }
        return nil
    }

    private static func nearestRate(_ rate: Double) -> Double? {
        let supported = [23.98, 24.0, 25.0, 29.97, 30.0, 60.0]
        guard let nearest = supported.min(by: { abs($0 - rate) < abs($1 - rate) }),
              abs(nearest - rate) < 0.06 else { return nil }
        return nearest
    }
}
