import AppKit
import SwiftUI

@main
struct LosslessSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller: LosslessSwitcherController

    init() {
        let controller = LosslessSwitcherController()
        _controller = StateObject(wrappedValue: controller)
        MainWindowPresenter.configure(controller: controller)
        if !controller.isMenuBarOnlyModeEnabled {
            MainWindowPresenter.showMainWindowSoon(force: false)
        }
    }

    var body: some Scene {
        MenuBarExtra(
            "LosslessSwitcher",
            systemImage: "waveform.path.badge.plus",
            isInserted: Binding(
                get: { controller.isMenuBarEnabled },
                set: { isInserted in
                    if controller.isMenuBarEnabled != isInserted {
                        controller.isMenuBarEnabled = isInserted
                    }
                }
            )
        ) {
            MenuBarView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show LosslessSwitcher") {
                    MainWindowPresenter.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(controller)
                .frame(width: 460)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didFinishRestoringWindows),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: NSApplication.shared
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainWindowPresenter.presentInitialWindowIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.handleReopenRequest()
        return true
    }

    @objc private func didFinishRestoringWindows() {
        MainWindowPresenter.closeRestoredWindowIfMenuBarOnly()
    }
}

enum MainWindowPresenter {
    @MainActor private static var controller: LosslessSwitcherController?
    @MainActor private static var window: NSWindow?
    @MainActor private static var windowDelegate: MainWindowDelegate?

    @MainActor
    static func configure(controller: LosslessSwitcherController) {
        self.controller = controller
        applyUserPreferences()
    }

    @MainActor
    static func presentInitialWindowIfNeeded() {
        applyUserPreferences()
        guard controller?.isMenuBarOnlyModeEnabled != true else {
            closeMainWindowSoon()
            applyUserPreferences()
            return
        }

        showMainWindowSoon(force: false)
    }

    @MainActor
    static func applyUserPreferences() {
        let hasVisibleWindow = window?.isVisible == true
        let shouldHideDock = controller?.isMenuBarOnlyModeEnabled == true && !hasVisibleWindow
        NSApplication.shared.setActivationPolicy(shouldHideDock ? .accessory : .regular)
    }

    @MainActor
    static func showMainWindowSoon(force: Bool = true) {
        DispatchQueue.main.async {
            showMainWindow(force: force)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showMainWindow(force: force)
        }
    }

    @MainActor
    static func handleReopenRequest() {
        guard controller?.isMenuBarOnlyModeEnabled == false else {
            closeMainWindowSoon()
            applyUserPreferences()
            return
        }

        showMainWindowSoon()
    }

    @MainActor
    static func closeRestoredWindowIfMenuBarOnly() {
        guard controller?.isMenuBarOnlyModeEnabled == true else {
            return
        }

        closeMainWindowSoon()
        applyUserPreferences()
    }

    @MainActor
    static func showMainWindow(force: Bool = true) {
        guard force || controller?.isMenuBarOnlyModeEnabled != true else {
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        if let window {
            window.centerIfNeeded()
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let controller else {
            return
        }

        let contentView = ContentView()
            .environmentObject(controller)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LosslessSwitcher"
        window.isRestorable = false
        window.restorationClass = nil
        window.disableSnapshotRestoration()
        window.minSize = NSSize(width: 760, height: 620)
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        let delegate = MainWindowDelegate()
        window.delegate = delegate
        windowDelegate = delegate
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    @MainActor
    private static func closeMainWindowSoon() {
        closeMainWindow()
        DispatchQueue.main.async {
            closeMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            closeMainWindow()
        }
    }

    @MainActor
    private static func closeMainWindow() {
        window?.close()
        NSApplication.shared.windows.forEach { $0.close() }
    }

    @MainActor
    static func mainWindowDidClose() {
        applyUserPreferences()
    }
}

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        MainWindowPresenter.mainWindowDidClose()
    }
}

private extension NSWindow {
    func centerIfNeeded() {
        guard !isVisible || frame.origin.x < 0 || frame.origin.y < 0 else {
            return
        }

        center()
    }
}
