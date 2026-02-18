import SwiftUI
import Combine

// MARK: - AppSettings (persisted via UserDefaults)
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // ── Collapsed side elements ──
    @Published var sideDistance: CGFloat {
        didSet { UserDefaults.standard.set(Double(sideDistance), forKey: "sideDistance") }
    }

    // ── Expanded panel ──
    @Published var expandedWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(expandedWidth), forKey: "expandedWidth") }
    }
    @Published var expandedHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(expandedHeight), forKey: "expandedHeight") }
    }

    // ── Anti-temblor delay ──
    @Published var collapseDelay: Double {
        didSet { UserDefaults.standard.set(collapseDelay, forKey: "collapseDelay") }
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

    private init() {
        let ud = UserDefaults.standard

        self.sideDistance = ud.object(forKey: "sideDistance") != nil
            ? max(CGFloat(ud.double(forKey: "sideDistance")), 60)
            : 110
        self.expandedWidth = ud.object(forKey: "expandedWidth") != nil
            ? min(max(CGFloat(ud.double(forKey: "expandedWidth")), 500), 760)
            : 660
        self.expandedHeight = ud.object(forKey: "expandedHeight") != nil
            ? min(max(CGFloat(ud.double(forKey: "expandedHeight")), 210), 300)
            : 250
        self.collapseDelay   = ud.object(forKey: "collapseDelay")   != nil ? ud.double(forKey: "collapseDelay")            : 0.12

        if let data = ud.data(forKey: "equalizerColor"),
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            self.equalizerColor = Color(nsColor)
        } else {
            self.equalizerColor = .white
        }
    }

    func reset() {
        sideDistance   = 110
        expandedWidth  = 660
        expandedHeight = 250
        collapseDelay  = 0.12
        equalizerColor = .white
    }
}
