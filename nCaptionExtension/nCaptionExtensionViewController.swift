import Cocoa
import SwiftUI
import ProExtensionHost

@objc class nCaptionExtensionViewController: NSViewController {

    override func loadView() {
        let containerView = NSView()
        let hostingController = NSHostingController(
            rootView: ContentView(usesEmbeddedToolbar: true)
                .preferredColorScheme(.dark)
        )

        // Let the Final Cut Pro window drive the available size while preserving
        // the same minimum layout requirements as the standalone app.
        hostingController.sizingOptions = [.minSize]
        hostingController.sceneBridgingOptions = [.title, .toolbars]

        addChild(hostingController)
        containerView.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        view = containerView
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard let window = view.window else { return }
        FCPBridge.hostWindow = window

        // Final Cut Pro completes its own window ordering after this callback.
        // Promote the extension on the next run-loop pass so it remains visible.
        DispatchQueue.main.async {
            self.bringExtensionToFront(window)
        }
    }

    override func viewWillDisappear() {
        if FCPBridge.hostWindow === view.window {
            FCPBridge.hostWindow = nil
        }
        super.viewWillDisappear()
    }

    private func bringExtensionToFront(_ window: NSWindow) {
        window.level = .normal
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Final Cut may finish ordering its extension window after a companion
        // window has opened. Restore that active popup once the host is in place.
        // The popup's delegate still lowers it when the host is clicked, so both
        // windows continue to behave independently afterward.
        if let companionWindow = FCPBridge.activeCompanionWindow,
           companionWindow.isVisible {
            companionWindow.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            companionWindow.makeKeyAndOrderFront(nil)
            companionWindow.orderFrontRegardless()
        }
    }

    @objc var hostInfoString: String {
        guard let host = ProExtensionHostSingleton() as? FCPXHost else {
            return "Final Cut Pro"
        }
        return String(format: "%@ %@", host.name, host.versionString)
    }
}
