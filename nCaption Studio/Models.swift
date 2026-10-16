import Foundation

// MARK: - Split Mode
enum SplitMode { case characters, words }

// MARK: - Caption Cue
struct CaptionCue: Identifiable, Equatable, Sendable {
    let id: UUID
    var start: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

// MARK: - Undo Target
class UndoStateTarget: NSObject {
    var apply: ([CaptionCue], String) -> Void
    init(apply: @escaping ([CaptionCue], String) -> Void) { self.apply = apply }

    func register(undoManager: UndoManager?, oldCues: [CaptionCue], newCues: [CaptionCue],
                  oldName: String, newName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.apply(oldCues, oldName)
            target.register(undoManager: undoManager, oldCues: newCues, newCues: oldCues,
                            oldName: newName, newName: oldName)
        }
    }
}
