import SwiftUI
import Combine
import AppKit

enum PanelBackgroundStyle: String, CaseIterable {
    case black
    case glass
}

enum EqualizerColorMode: String, CaseIterable {
    case manual
    case artwork
}

// MARK: - AppSettings (persisted via UserDefaults)
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    @Published private(set) var activeDisplayName: String
    @Published private(set) var activeDisplayNotchWidth: CGFloat

    // ── Collapsed side elements ──
    @Published var artworkDistance: CGFloat {
        didSet { UserDefaults.standard.set(Double(artworkDistance), forKey: "artworkDistance") }
    }
    @Published var equalizerDistance: CGFloat {
        didSet { UserDefaults.standard.set(Double(equalizerDistance), forKey: "equalizerDistance") }
    }
    @Published var notchCenterOffsetX: CGFloat {
        didSet { persistActiveCalibrationIfNeeded() }
    }
    @Published var collapsedArtworkSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(collapsedArtworkSize), forKey: "collapsedArtworkSize") }
    }
    @Published var collapsedEqualizerScale: CGFloat {
        didSet { UserDefaults.standard.set(Double(collapsedEqualizerScale), forKey: "collapsedEqualizerScale") }
    }

    // ── Expanded panel ──
    @Published var expandedWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(expandedWidth), forKey: "expandedWidth") }
    }
    @Published var expandedHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(expandedHeight), forKey: "expandedHeight") }
    }
    @Published var panelBackgroundStyle: PanelBackgroundStyle {
        didSet { UserDefaults.standard.set(panelBackgroundStyle.rawValue, forKey: "panelBackgroundStyle") }
    }

    // ── Anti-temblor delay ──
    @Published var collapseDelay: Double {
        didSet { UserDefaults.standard.set(collapseDelay, forKey: "collapseDelay") }
    }
    
    // ── Hover expand delay ──
    @Published var hoverExpandDelay: Double {
        didSet { UserDefaults.standard.set(hoverExpandDelay, forKey: "hoverExpandDelay") }
    }

    // ── Equalizer color ──
    @Published var equalizerColor: Color {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(
                withRootObject: NSColor(equalizerColor),
                requiringSecureCoding: false
            ) {
                UserDefaults.standard.set(data, forKey: "equalizerColor")
            }
        }
    }
    @Published var equalizerColorMode: EqualizerColorMode {
        didSet { UserDefaults.standard.set(equalizerColorMode.rawValue, forKey: "equalizerColorMode") }
    }

    private var notchCalibrations: [String: [String: Double]]
    private var activeDisplayKey: String
    private var isApplyingCalibration = false

    private init() {
        let ud = UserDefaults.standard
        
        self.notchCalibrations = ud.dictionary(forKey: "notchCalibrations") as? [String: [String: Double]] ?? [:]
        self.activeDisplayKey = "default"
        self.activeDisplayName = "Pantalla principal"
        self.activeDisplayNotchWidth = 120

        let defaultCalibration = notchCalibrations[activeDisplayKey] ?? [:]

        let legacySideDistance: CGFloat = ud.object(forKey: "sideDistance") != nil
            ? max(CGFloat(ud.double(forKey: "sideDistance")), 60)
            : 110
        self.artworkDistance = ud.object(forKey: "artworkDistance") != nil
            ? min(max(CGFloat(ud.double(forKey: "artworkDistance")), 60), 220)
            : legacySideDistance
        self.equalizerDistance = ud.object(forKey: "equalizerDistance") != nil
            ? min(max(CGFloat(ud.double(forKey: "equalizerDistance")), 60), 220)
            : legacySideDistance
        self.notchCenterOffsetX = min(max(CGFloat(defaultCalibration["centerOffsetX"] ?? 0), -140), 140)
        self.collapsedArtworkSize = ud.object(forKey: "collapsedArtworkSize") != nil
            ? min(max(CGFloat(ud.double(forKey: "collapsedArtworkSize")), 24), 42)
            : 28
        self.collapsedEqualizerScale = ud.object(forKey: "collapsedEqualizerScale") != nil
            ? min(max(CGFloat(ud.double(forKey: "collapsedEqualizerScale")), 0.75), 1.8)
            : 1.0
        self.expandedWidth = ud.object(forKey: "expandedWidth") != nil
            ? min(max(CGFloat(ud.double(forKey: "expandedWidth")), 500), 760)
            : 660
        self.expandedHeight = ud.object(forKey: "expandedHeight") != nil
            ? min(max(CGFloat(ud.double(forKey: "expandedHeight")), 210), 300)
            : 250
        self.panelBackgroundStyle = PanelBackgroundStyle(
            rawValue: ud.string(forKey: "panelBackgroundStyle") ?? ""
        ) ?? .black
        self.collapseDelay   = ud.object(forKey: "collapseDelay")   != nil ? ud.double(forKey: "collapseDelay")            : 0.12
        self.hoverExpandDelay = ud.object(forKey: "hoverExpandDelay") != nil
            ? min(max(ud.double(forKey: "hoverExpandDelay"), 0.0), 1.2)
            : 0.55

        if let data = ud.data(forKey: "equalizerColor"),
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            self.equalizerColor = Color(nsColor)
        } else {
            self.equalizerColor = .white
        }
        self.equalizerColorMode = EqualizerColorMode(
            rawValue: ud.string(forKey: "equalizerColorMode") ?? ""
        ) ?? .manual

        // Prime display-derived values for preview calibration as soon as settings load.
        activateDisplay(NSScreen.main)
    }

    func reset() {
        artworkDistance = 110
        equalizerDistance = 110
        notchCenterOffsetX = 0
        collapsedArtworkSize = 28
        collapsedEqualizerScale = 1.0
        expandedWidth  = 660
        expandedHeight = 250
        panelBackgroundStyle = .black
        collapseDelay  = 0.12
        hoverExpandDelay = 0.55
        equalizerColor = .white
        equalizerColorMode = .manual
    }

    func resolvedEqualizerColor(from artworkColor: Color?) -> Color {
        if equalizerColorMode == .artwork, let artworkColor {
            return artworkColor
        }
        return equalizerColor
    }

    func activateDisplay(_ screen: NSScreen?) {
        let key = Self.displayKey(for: screen)
        let name = screen?.localizedName ?? "Pantalla principal"
        let notchWidth = Self.detectedNotchWidth(for: screen)
        let hasDisplayChanged = key != activeDisplayKey || name != activeDisplayName
        let hasNotchWidthChanged = abs(activeDisplayNotchWidth - notchWidth) > 0.5

        guard hasDisplayChanged || hasNotchWidthChanged else { return }

        activeDisplayNotchWidth = notchWidth
        guard hasDisplayChanged else { return }

        activeDisplayKey = key
        activeDisplayName = name
        applyCalibrationForActiveDisplay()
    }

    private func applyCalibrationForActiveDisplay() {
        let calibration = notchCalibrations[activeDisplayKey] ?? notchCalibrations["default"] ?? [:]
        isApplyingCalibration = true
        notchCenterOffsetX = min(max(CGFloat(calibration["centerOffsetX"] ?? 0), -140), 140)
        isApplyingCalibration = false
    }

    private func persistActiveCalibrationIfNeeded() {
        guard !isApplyingCalibration else { return }
        notchCalibrations[activeDisplayKey] = [
            "centerOffsetX": Double(notchCenterOffsetX)
        ]
        UserDefaults.standard.set(notchCalibrations, forKey: "notchCalibrations")
    }

    private static func displayKey(for screen: NSScreen?) -> String {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "default"
        }
        return String(number.uint32Value)
    }

    private static func detectedNotchWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 120 }

        if #available(macOS 12.0, *) {
            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                let cutoutWidth = screen.frame.width - leftArea.width - rightArea.width
                if cutoutWidth > 20 {
                    return min(max(cutoutWidth, 120), 240)
                }
            }

            if screen.safeAreaInsets.top > 0 {
                // Hardware notch but no auxiliary areas available: use a conservative ratio.
                return min(max(screen.frame.width * 0.118, 165), 205)
            }
        }

        return 120
    }
}
