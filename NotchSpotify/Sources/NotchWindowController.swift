import AppKit
import SwiftUI
import Combine

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NotchWindowController: NSWindowController {
    private let collapsedSize = NSSize(width: 600, height: 36)
    private let expandDuration: TimeInterval = 0.32
    private let collapseDuration: TimeInterval = 0.24
    private let hoverScanInterval: TimeInterval = 1.0 / 24.0
    private let hoverScreenHitSlopX: CGFloat = 4
    private let hoverScreenHitSlopY: CGFloat = 8

    private var isExpanded = false
    private var isPointerInsideHotzone = false
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var hoverScanTimer: Timer?
    private var settingsCancellables = Set<AnyCancellable>()
    
    var isExpandedState: Bool { isExpanded }

    convenience init() {
        let panel = NotchPanel(
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
        startHoverScan()
        SpotifyBridge.shared.startPolling()
        SpotifyBridge.shared.setUserInteractionActive(false)

        AppSettings.shared.$expandedWidth
            .combineLatest(AppSettings.shared.$expandedHeight)
            .sink { [weak self] _, _ in
                guard let self, self.isExpanded else { return }
                self.positionWindow(expanded: true, animated: false)
            }
            .store(in: &settingsCancellables)
    }
    
    deinit {
        hoverScanTimer?.invalidate()
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

    func positionWindow(expanded: Bool, animated: Bool, duration: TimeInterval? = nil) {
        guard let screen = NSScreen.main else { return }
        AppSettings.shared.activateDisplay(screen)

        let settings = AppSettings.shared
        let size = expanded
            ? NSSize(width: settings.expandedWidth, height: settings.expandedHeight)
            : collapsedSize

        let x = (screen.frame.width - size.width) / 2
        let y = screen.frame.maxY - size.height
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration ?? (expanded ? expandDuration : collapseDuration)
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window?.animator().setFrame(frame, display: true)
            }
        } else {
            window?.setFrame(frame, display: true)
        }

        isExpanded = expanded
    }

    func handleMouseEntered() {
        guard !isPointerInsideHotzone else { return }
        isPointerInsideHotzone = true
        pointerEnteredHotzone()
    }

    func handleMouseExited() {
        guard isPointerInsideHotzone else { return }
        isPointerInsideHotzone = false
        pointerExitedHotzone()
    }

    private func pointerEnteredHotzone() {
        expandWorkItem?.cancel()
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        SpotifyBridge.shared.setUserInteractionActive(true)
        SpotifyBridge.shared.refreshNow()
        guard !isExpanded else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isExpanded, self.isPointerInsideHotzone else { return }
            self.positionWindow(expanded: true, animated: true)
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.hoverExpandDelay, execute: work)
    }

    private func pointerExitedHotzone() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        SpotifyBridge.shared.setUserInteractionActive(false)

        if !isExpanded {
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPointerInsideHotzone else { return }
            self.positionWindow(expanded: false, animated: true)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.collapseDelay, execute: work)
    }

    private func startHoverScan() {
        hoverScanTimer?.invalidate()
        let timer = Timer(timeInterval: hoverScanInterval, repeats: true) { [weak self] _ in
            self?.evaluatePointerForHover()
        }
        timer.tolerance = hoverScanInterval * 0.4
        hoverScanTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func evaluatePointerForHover() {
        guard let hoverRect = hoverRectInScreenCoordinates() else { return }
        let isInside = hoverRect.contains(NSEvent.mouseLocation)
        if isInside != isPointerInsideHotzone {
            if isInside {
                handleMouseEntered()
            } else {
                handleMouseExited()
            }
        }
    }

    private func hoverRectInScreenCoordinates() -> CGRect? {
        guard let window, let contentView = window.contentView else { return nil }
        let localRect = hoverTrackingRect(in: contentView.bounds)
        let windowRect = contentView.convert(localRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        return screenRect.insetBy(dx: -hoverScreenHitSlopX, dy: -hoverScreenHitSlopY)
    }

    func hoverTrackingRect(in bounds: CGRect) -> CGRect {
        guard !isExpanded else { return bounds }

        let artworkDistance = AppSettings.shared.artworkDistance
        let equalizerDistance = AppSettings.shared.equalizerDistance
        let artworkHalfWidth: CGFloat = AppSettings.shared.collapsedArtworkSize * 0.5
        let barsHalfWidth: CGFloat = (16 * AppSettings.shared.collapsedEqualizerScale) * 0.5
        let horizontalPadding: CGFloat = 8
        let centerX = bounds.midX + AppSettings.shared.notchCenterOffsetX

        let minX = max(
            0,
            centerX - artworkDistance - artworkHalfWidth - horizontalPadding
        )
        let maxX = min(
            bounds.maxX,
            centerX + equalizerDistance + barsHalfWidth + horizontalPadding
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
