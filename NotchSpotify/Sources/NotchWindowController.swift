import AppKit
import SwiftUI
import Combine

final class NotchWindowController: NSWindowController {
    private let collapsedSize = NSSize(width: 600, height: 36)

    private var isExpanded = false
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var settingsCancellables = Set<AnyCancellable>()
    
    var isExpandedState: Bool { isExpanded }

    convenience init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        self.init(window: panel)

        setupContent()
        positionWindow(expanded: false, animated: false)
        SpotifyBridge.shared.startPolling()

        AppSettings.shared.$expandedWidth
            .combineLatest(AppSettings.shared.$expandedHeight)
            .sink { [weak self] _, _ in
                guard let self, self.isExpanded else { return }
                self.positionWindow(expanded: true, animated: false)
            }
            .store(in: &settingsCancellables)
    }

    private func setupContent() {
        let rootView = NotchContentView()
            .environmentObject(SpotifyBridge.shared)
            .environmentObject(AppSettings.shared)

        let host = NotchHostingView(rootView: rootView, controller: self)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window?.contentView = host
    }

    func positionWindow(expanded: Bool, animated: Bool) {
        guard let screen = NSScreen.main else { return }

        let settings = AppSettings.shared
        let size = expanded
            ? NSSize(width: settings.expandedWidth, height: settings.expandedHeight)
            : collapsedSize

        let x = (screen.frame.width - size.width) / 2
        let y = screen.frame.maxY - size.height
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.42 : 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window?.animator().setFrame(frame, display: true)
            }
        } else {
            window?.setFrame(frame, display: true)
        }

        isExpanded = expanded
    }

    func handleMouseEntered() {
        expandWorkItem?.cancel()
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard !isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.positionWindow(expanded: true, animated: true)
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: work)
    }

    func handleMouseExited() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isMouseInsideWindow() else { return }
            self.positionWindow(expanded: false, animated: true)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.collapseDelay, execute: work)
    }

    private func isMouseInsideWindow() -> Bool {
        guard let window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    func hoverTrackingRect(in bounds: CGRect) -> CGRect {
        guard !isExpanded else { return bounds }

        let sideDistance = AppSettings.shared.sideDistance
        let artworkHalfWidth: CGFloat = 14
        let barsHalfWidth: CGFloat = 8
        let horizontalPadding: CGFloat = 8
        let centerX = bounds.midX

        let minX = max(
            0,
            centerX - sideDistance - artworkHalfWidth - horizontalPadding
        )
        let maxX = min(
            bounds.maxX,
            centerX + sideDistance + barsHalfWidth + horizontalPadding
        )

        return CGRect(
            x: minX,
            y: 0,
            width: max(maxX - minX, 1),
            height: bounds.height
        )
    }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    weak var controller: NotchWindowController?

    init(rootView: Content, controller: NotchWindowController) {
        self.controller = controller
        super.init(rootView: rootView)
    }

    @objc required dynamic init?(coder: NSCoder) { fatalError() }
    required init(rootView: Content) { super.init(rootView: rootView) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let trackingRect = controller?.hoverTrackingRect(in: bounds) ?? bounds
        let area = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { controller?.handleMouseEntered() }
    override func mouseExited(with event: NSEvent) { controller?.handleMouseExited() }
}
