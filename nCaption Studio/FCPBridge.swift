import AppKit
import UniformTypeIdentifiers

enum FCPBridge {
    // Pasteboard type Final Cut Pro uses when items are dragged out of its browser or sidebar.
    static let xmlType = UTType(importedAs: "com.apple.finalcutpro.xml")

    // The Final Cut Pro extension window. Set by the extension's view controller; stays nil in the app.
    @MainActor static weak var hostWindow: NSWindow?

    // The currently presented companion popup (Edit Prompt / Cleanup Changes), if any. Final Cut
    // re-promotes hostWindow on its own schedule (see nCaptionExtensionViewController.viewDidAppear);
    // that re-promotion re-floats this window afterward so the popup doesn't end up stuck behind it.
    @MainActor static weak var activeCompanionWindow: NSWindow?

    // Shows an open or save panel. In the extension it is attached to the extension window as a sheet,
    // so it always appears on top of that window instead of behind it.
    // folderKey gives a panel its own remembered folder, so it doesn't reopen where another panel
    // (for example the Motion Titles picker) last was. Panels without a key set their own folder.
    @MainActor
    static func present(_ panel: NSSavePanel, folderKey: String? = nil,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let defaults = UserDefaults.standard
        if let key = folderKey {
            panel.directoryURL = defaults.url(forKey: key)
                ?? URL(fileURLWithPath: "/Users/\(NSUserName())/Downloads")
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if let key = folderKey, response == .OK, let url = panel.url {
                let selectedDirectory = (panel as? NSOpenPanel)?.canChooseDirectories == true
                    ? url
                    : url.deletingLastPathComponent()
                defaults.set(selectedDirectory, forKey: key)
            }
            completion(response)
        }
        if let window = hostWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // Writes the FCPXML to a temporary file and opens it in Final Cut Pro, which imports it
    // as a new event and project.
    @discardableResult
    static func openInFinalCutPro(xml: String, name: String) -> Bool {
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).fcpxml")
        guard (try? xml.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }

        for id in ["com.apple.FinalCut", "com.apple.FinalCutTrial"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
        }
        return NSWorkspace.shared.open(url)
    }
}
