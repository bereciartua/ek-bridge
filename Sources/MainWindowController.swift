import AppKit
import SwiftUI

/// Owns the single main window across close and reopen. A bare programmatic
/// NSWindow can release itself when closed; the controller keeps it alive.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let defaultSize = NSSize(width: 900, height: 640)
    static let minimumSize = NSSize(width: 760, height: 520)

    let model: BridgeAppModel

    init(model: BridgeAppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: MainView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = AppIdentity.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        #if EVENTKIT_UI_REVIEW
        // Review builds share the bundle ID; keep their frames out of the real app's defaults.
        window.center()
        #else
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
        #endif
        model.window = window
        model.showWindow = { [weak self] in self?.present() }
        model.windowIsVisible = { [weak window] in window?.isVisible == true }
        model.dockModeChanged = { [weak self] in self?.applyDockPolicy() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        guard let window else { return }
        if model.dockMode == .whileWindowOpen && NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowDidShow()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges else { return true }
        model.confirmUnsaved { [weak sender] in sender?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyDockPolicy() }
    }

    /// While the window is open (default): in the Dock and ⌘-Tab only while the
    /// window is visible. Always: from launch. Never: as a menu bar app only.
    func applyDockPolicy() {
        let visible = window?.isVisible == true
        let wanted: NSApplication.ActivationPolicy = switch model.dockMode {
        case .always: .regular
        case .never: .accessory
        case .whileWindowOpen: visible ? .regular : .accessory
        }
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .accessory && visible {
            // Without this, the window can drop behind other apps.
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
