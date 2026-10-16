import Foundation

// MARK: - XML Helpers
func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&",  with: "&amp;")
     .replacingOccurrences(of: "<",  with: "&lt;")
     .replacingOccurrences(of: ">",  with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'",  with: "&apos;")
}

func getTimeInfo(fps: Double) -> (num: Int, den: Int, name: String) {
    switch fps {
    case 23.98: return (1001, 24000, "FFVideoFormat1080p2398")
    case 24.0:  return (100,  2400,  "FFVideoFormat1080p24")
    case 25.0:  return (100,  2500,  "FFVideoFormat1080p25")
    case 29.97: return (1001, 30000, "FFVideoFormat1080p2997")
    case 30.0:  return (100,  3000,  "FFVideoFormat1080p30")
    case 60.0:  return (100,  6000,  "FFVideoFormat1080p60")
    default:    return (1001, 30000, "FFVideoFormat1080p2997")
    }
}

// MARK: - Parsing
func parseTime(_ t: String, fps: Double) -> Double {
    let clean = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let parts = clean.split(separator: ":")
    guard parts.count >= 3 else { return 0 }
    let h = Double(parts[0]) ?? 0
    let m = Double(parts[1]) ?? 0
    if parts.count == 3 { return h * 3600 + m * 60 + (Double(parts[2]) ?? 0) }
    if parts.count == 4 { return h * 3600 + m * 60 + (Double(parts[2]) ?? 0) + ((Double(parts[3]) ?? 0) / fps) }
    return 0
}

func parseSRT(_ text: String, fps: Double) -> [CaptionCue] {
    var cues: [CaptionCue] = []
    for block in text.components(separatedBy: "\n\n") {
        let lines = block.components(separatedBy: "\n")
        if lines.count >= 3, lines[1].contains("-->") {
            let times = lines[1].components(separatedBy: " --> ")
            let s = parseTime(times[0], fps: fps)
            let e = parseTime(times[1], fps: fps)
            let txt = lines.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            cues.append(CaptionCue(start: s, end: e, text: txt))
        }
    }
    return cues
}

func parseITTFrameRate(_ text: String) -> Double? {
    func attribute(named name: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:[A-Za-z_][A-Za-z0-9_.-]*:)?\(escapedName)\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    guard let frameRateText = attribute(named: "frameRate"),
          var detectedRate = Double(frameRateText) else { return nil }

    if let multiplierText = attribute(named: "frameRateMultiplier") {
        let values = multiplierText
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Double($0) }
        if values.count == 2, values[1] != 0 {
            detectedRate *= values[0] / values[1]
        }
    }

    let supportedRates = [23.98, 24.0, 25.0, 29.97, 30.0, 60.0]
    guard let nearestRate = supportedRates.min(by: {
        abs($0 - detectedRate) < abs($1 - detectedRate)
    }), abs(nearestRate - detectedRate) < 0.06 else { return nil }
    return nearestRate
}

func parseITT(_ text: String, fps: Double) -> [CaptionCue] {
    var cues: [CaptionCue] = []
    guard let regex = try? NSRegularExpression(
        pattern: "<p[^>]*begin=\"([^\"]*)\"[^>]*end=\"([^\"]*)\"[^>]*>(.*?)<\\/p>",
        options: [.dotMatchesLineSeparators]
    ) else { return cues }
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        var content = ns.substring(with: match.range(at: 3))
        content = content.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            cues.append(CaptionCue(
                start: parseTime(ns.substring(with: match.range(at: 1)), fps: fps),
                end:   parseTime(ns.substring(with: match.range(at: 2)), fps: fps),
                text:  content
            ))
        }
    }
    return cues
}

func splitCues(_ cues: [CaptionCue], mode: SplitMode, limit: Int) -> [CaptionCue] {
    var result: [CaptionCue] = []
    for cue in cues {
        let words = cue.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var chunks: [[String]] = []
        var current: [String] = []
        var count = 0
        for word in words {
            let added: Int
            if mode == .characters {
                added = current.isEmpty ? word.count : word.count + 1
            } else {
                added = 1
            }
            if count + added > limit && !current.isEmpty {
                chunks.append(current); current = [word]; count = added
            } else {
                current.append(word); count += added
            }
        }
        if !current.isEmpty { chunks.append(current) }
        let totalChars = Double(words.joined().count)
        let duration = cue.end - cue.start
        var t = cue.start
        for chunk in chunks {
            let txt = chunk.joined(separator: " ")
            let chars = Double(chunk.joined().count)
            let endT = totalChars > 0 ? t + (duration * (chars / totalChars)) : t + 1.0
            result.append(CaptionCue(start: t, end: endT, text: txt))
            t = endT
        }
    }
    return result
}

// MARK: - SRT Export
func formatSRTTime(_ t: Double) -> String {
    String(format: "%02d:%02d:%02d,%03d",
           Int(t) / 3600, (Int(t) / 60) % 60, Int(t) % 60,
           Int(t.truncatingRemainder(dividingBy: 1) * 1000))
}

func buildSRT(cues: [CaptionCue]) -> String {
    cues.enumerated().map { i, cue in
        "\(i + 1)\n\(formatSRTTime(cue.start)) --> \(formatSRTTime(cue.end))\n\(cue.text)\n"
    }.joined(separator: "\n")
}

// MARK: - FCPXML (Titles) Export
func buildXML(cues: [CaptionCue], templateURL: URL, fps: Double, mediaName: String = "") -> String {
    let info = getTimeInfo(fps: fps)
    let fd = "\(info.num)/\(info.den)s"
    let pathComponents = templateURL.path.components(separatedBy: "/")
    var templateUID = templateURL.lastPathComponent
    if let i = pathComponents.lastIndex(where: { $0.hasPrefix("Titles") }) {
        templateUID = "~/\(pathComponents[i...].joined(separator: "/"))"
    }
    let effectName = escapeXML(templateURL.deletingPathExtension().lastPathComponent)
    let srcString  = escapeXML(templateURL.absoluteString)
    let lastTime   = cues.last?.end ?? 3600.0
    let seqFrames  = Int(ceil(lastTime * fps))
    let seqDur      = "\(seqFrames * info.num)/\(info.den)s"
    let base = mediaName.isEmpty ? "Captions" : escapeXML(mediaName)
    let projectName = mediaName.isEmpty ? "Captions" : "\(base) - Captions"

    var xml  = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    xml += "<!DOCTYPE fcpxml>\n<fcpxml version=\"1.11\">\n<resources>\n"
    xml += "<format id=\"r1\" name=\"\(info.name)\" frameDuration=\"\(fd)\" width=\"1920\" height=\"1080\"/>\n"
    xml += "<effect id=\"r2\" name=\"\(effectName)\" uid=\"\(templateUID)\" src=\"\(srcString)\"/>\n"
    xml += "</resources>\n<library>\n<event name=\"\(projectName)\">\n<project name=\"\(projectName)\">\n"
    xml += "<sequence format=\"r1\" tcStart=\"0s\" tcFormat=\"NDF\">\n<spine>\n"
    xml += "<gap name=\"Gap\" offset=\"0s\" duration=\"\(seqDur)\">\n"

    for (i, cue) in cues.enumerated() {
        let sf  = Int(round(cue.start * fps))
        let ef  = Int(round(cue.end * fps))
        let off = sf == 0 ? "0s" : "\(sf * info.num)/\(info.den)s"
        let dur = "\(max(ef - sf, 1) * info.num)/\(info.den)s"
        xml += "<title name=\"\(effectName)\" lane=\"1\" offset=\"\(off)\" ref=\"r2\" duration=\"\(dur)\">\n"
        xml += "<text>\n<text-style ref=\"ts\(i)\">\(escapeXML(cue.text))</text-style>\n</text>\n"
        xml += "<text-style-def id=\"ts\(i)\">\n"
        xml += "<text-style font=\"Helvetica Neue\" fontSize=\"90\" fontColor=\"1 1 1 1\" alignment=\"center\"/>\n"
        xml += "</text-style-def>\n"
        xml += "<adjust-transform position=\"0 -28\"/>\n"
        xml += "</title>\n"
    }
    xml += "</gap>\n</spine>\n</sequence>\n</project>\n</event>\n</library>\n</fcpxml>\n"
    return xml
}
