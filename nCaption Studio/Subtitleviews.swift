import SwiftUI
import AppKit
import UniformTypeIdentifiers

private func splitCueTextAtCurrentSelection(_ text: String) -> (left: String, right: String) {
    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
          editor.string == text else {
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    let source = text as NSString
    let location = min(max(editor.selectedRange().location, 0), source.length)
    let left = source.substring(to: location).trimmingCharacters(in: .whitespacesAndNewlines)
    let right = source.substring(from: location).trimmingCharacters(in: .whitespacesAndNewlines)
    return (left, right)
}

// MARK: - Cue Editor
// ⚠️ BUG AREA (previously fixed): When searchText is active, non-matching cues were going .clear.
// Fix: Show highlighted overlay only when search is active + cue matches.
// Non-matching cues get .white.opacity(0.9) foreground regardless of search state.
struct CueEditor: View {
    @Binding var text: String
    var searchText: String
    var onSplit: (String, String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private func flush() {
        if draft != text { text = draft }
    }

    private func liveUpdate() {
        text = draft
    }

    private func highlightedText(_ str: String, search: String) -> AttributedString {
        var result = AttributedString(str)
        result.foregroundColor = .white
        guard !search.isEmpty else { return result }
        var searchRange = str.startIndex..<str.endIndex
        while let range = str.range(of: search, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = .yellow
                result[attrRange].foregroundColor = .black
            }
            searchRange = range.upperBound..<str.endIndex
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Highlight overlay: only shown when search is active AND this cue matches
            if !focused && !searchText.isEmpty && draft.localizedCaseInsensitiveContains(searchText) {
                Text(highlightedText(draft, search: searchText))
                    .font(.system(size: 14))
            }

            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                // FIX: non-matching cues stay visible (.white.opacity(0.9)) when search is active
                .foregroundColor(focused ? .white : (searchText.isEmpty ? .white.opacity(0.9) : (draft.localizedCaseInsensitiveContains(searchText) ? .clear : .white.opacity(0.9))))
                .focused($focused)
                .onChange(of: draft) { _, _ in liveUpdate() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { flush() }
                }
                .onKeyPress(.escape) { flush(); focused = false; return .handled }
                .onKeyPress(.return) {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        draft += "\n"; return .handled
                    }
                    let parts = splitCueTextAtCurrentSelection(draft)
                    draft = parts.left
                    text = parts.left
                    focused = false
                    onSplit(parts.left, parts.right)
                    return .handled
                }
        }
        .frame(minHeight: 28)
        .onAppear { draft = text }
        .onChange(of: text) { _, newVal in if !focused { draft = newVal } }
    }
}

// MARK: - Row Action Components
struct RowActionButton<Icon: View>: View {
    let title: String
    let icon: Icon
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(title); icon }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                    if isHovering { RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.15)) }
                })
                .foregroundColor(isHovering ? .blue : .white.opacity(0.8))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isHovering ? Color.blue.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovering = h } }
    }
}

struct RowActionZone: View {
    var onMerge: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(height: 40)
            HStack(spacing: 12) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                RowActionButton(
                    title: "Merge",
                    icon: VStack(spacing: 1) {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
                    },
                    action: onMerge
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            .opacity(isHovering ? 1.0 : 0.0)
            .scaleEffect(isHovering ? 1.0 : 0.98)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovering = h } }
    }
}

// MARK: - Subtitle Row View
struct SubtitleRowView: View, Equatable {
    let index: Int
    @Binding var cue: CaptionCue
    let totalCount: Int
    let isSearchResult: Bool
    let currentSearchText: String
    let isPreviewing: Bool
    let onSplit: (String, String) -> Void
    let onMerge: () -> Void
    let onDelete: () -> Void

    static func == (lhs: SubtitleRowView, rhs: SubtitleRowView) -> Bool {
        lhs.index == rhs.index && lhs.cue == rhs.cue && lhs.totalCount == rhs.totalCount &&
        lhs.isSearchResult == rhs.isSearchResult &&
        lhs.currentSearchText == rhs.currentSearchText && lhs.isPreviewing == rhs.isPreviewing
    }

    @State private var isTrashHovered = false
    @State private var isAddLineHovered = false

    private var rowBackground: Color {
        isSearchResult ? Color.yellow.opacity(0.15) : Color(nsColor: .windowBackgroundColor).opacity(0.8)
    }

    private var rowBorderColor: Color {
        isSearchResult ? Color.yellow.opacity(0.5) : Color.white.opacity(0.05)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.2fs → %.2fs", cue.start, cue.end))
                    Text(String(format: "duration %.2fs", cue.end - cue.start))
                }
                .foregroundColor(.gray)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 120, alignment: .leading)

                CueEditor(text: $cue.text, searchText: currentSearchText, onSplit: onSplit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isPreviewing ? 0.4 : 1.0)
                    .allowsHitTesting(!isPreviewing)

                VStack(spacing: 8) {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 12))
                            .foregroundColor(isTrashHovered ? .red.opacity(0.8) : .gray.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isTrashHovered = h }
                    }

                    Text("#\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Capsule())

                    if index < totalCount - 1 {
                        Button {
                            let parts = splitCueTextAtCurrentSelection(cue.text)
                            onSplit(parts.left, parts.right)
                        } label: {
                            Image(systemName: "return").font(.system(size: 12))
                                .foregroundColor(isAddLineHovered ? .blue.opacity(0.9) : .gray.opacity(0.4))
                        }
                        .buttonStyle(.plain).help("Add Line")
                        .onHover { h in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isAddLineHovered = h }
                        }
                    }
                }
            }
            .padding()
            .background(rowBackground)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(rowBorderColor, lineWidth: 1))

            if index < totalCount - 1 { RowActionZone(onMerge: onMerge) }
        }
    }
}

// MARK: - Drop Zone
struct SubtitleDropZone: ViewModifier {
    @Binding var isTargeted: Bool
    var onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, FCPBridge.xmlType], isTargeted: $isTargeted, perform: onDrop)
            .overlay(Group {
                if isTargeted {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        Color.black.opacity(0.6)
                        VStack(spacing: 16) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 48))
                            Text("Drop a Final Cut Pro project, SRT, ITT or .moti").font(.title2.bold())
                        }.foregroundColor(.white)
                    }
                }
            }.allowsHitTesting(false))
    }
}

// MARK: - UI Components
struct ClearMediaButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isHovering ? .white : .gray.opacity(0.5))
                .frame(width: 16, height: 16)
                .scaleEffect(isHovering ? 1.2 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovering = h }
        }
    }
}
