import SwiftUI
import AppKit

@main
struct NotchSpotifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window scenes — we manage everything via AppDelegate
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — pure menu bar / notch app
        NSApp.setActivationPolicy(.accessory)

        setupStatusBarItem()
        setupNotchWindow()
    }

    // MARK: Status bar fallback (right-click to quit)
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NotchSpotify")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit NotchSpotify", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setupNotchWindow() {
        notchController = NotchWindowController()
        notchController?.showWindow(nil)
    }
}
