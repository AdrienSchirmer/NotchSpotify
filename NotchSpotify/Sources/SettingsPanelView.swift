import SwiftUI
import AppKit

enum SettingsSectionID: String, CaseIterable {
    case side = "Lateral"
    case panel = "Panel"
    case behavior = "Behavior"
    case equalizer = "EQ"
}

private struct SettingsSectionOffsetKey: PreferenceKey {
    static var defaultValue: [SettingsSectionID: CGFloat] = [:]

    static func reduce(value: inout [SettingsSectionID: CGFloat], nextValue: () -> [SettingsSectionID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SettingsPanelView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var spotify: SpotifyBridge
    @Binding var isVisible: Bool

    @State private var activeSection: SettingsSectionID = .side

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            isVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.82))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider().background(Color.white.opacity(0.12))

                ScrollViewReader { proxy in
                    HStack(spacing: 12) {
                        SettingsSidebar(activeSection: $activeSection) { section in
                            withAnimation(.easeInOut(duration: 0.22)) {
                                proxy.scrollTo(section, anchor: .top)
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.top, 12)

                        Divider().background(Color.white.opacity(0.1))

                        ZStack(alignment: .trailing) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 14) {
                                    sectionMarker(.side)
                                    SettingsCard(title: "ELEMENTOS LATERALES", subtitle: "Vista previa en vivo") {
                                        SideDistanceLivePreview(
                                            artworkImage: spotify.artworkImage,
                                            sideDistance: settings.sideDistance,
                                            equalizerColor: settings.equalizerColor,
                                            isPlaying: spotify.currentTrack.isPlaying
                                        )

                                        SettingsSlider(
                                            label: "Distancia al notch",
                                            value: $settings.sideDistance,
                                            range: 60...220,
                                            unit: "px",
                                            format: "%.0f"
                                        )
                                    }

                                    sectionMarker(.panel)
                                    SettingsCard(title: "PANEL EXPANDIDO") {
                                        SettingsSlider(
                                            label: "Anchura",
                                            value: $settings.expandedWidth,
                                            range: 500...760,
                                            unit: "px",
                                            format: "%.0f"
                                        )

                                        SettingsSlider(
                                            label: "Altura",
                                            value: $settings.expandedHeight,
                                            range: 210...300,
                                            unit: "px",
                                            format: "%.0f"
                                        )
                                    }

                                    sectionMarker(.behavior)
                                    SettingsCard(title: "COMPORTAMIENTO") {
                                        SettingsSlider(
                                            label: "Delay al colapsar",
                                            value: $settings.collapseDelay,
                                            range: 0.0...0.6,
                                            unit: "s",
                                            format: "%.2f"
                                        )
                                    }

                                    sectionMarker(.equalizer)
                                    SettingsCard(title: "EQUALIZER") {
                                        HStack {
                                            Text("Color")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.6))
                                            Spacer()

                                            MiniEqualizerPreview(color: settings.equalizerColor)

                                            ColorPicker("", selection: $settings.equalizerColor, supportsOpacity: false)
                                                .labelsHidden()
                                                .frame(width: 28, height: 28)
                                        }

                                        HStack(spacing: 8) {
                                            Text("Presets")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.6))
                                            Spacer()
                                            ForEach(colorPresets, id: \.label) { preset in
                                                ColorPresetDot(
                                                    color: preset.color,
                                                    isSelected: isColorSelected(preset.color),
                                                    label: preset.label
                                                ) {
                                                    settings.equalizerColor = preset.color
                                                }
                                            }
                                        }
                                    }

                                    HStack {
                                        Spacer()
                                        Button {
                                            withAnimation { settings.reset() }
                                        } label: {
                                            Text("Restaurar valores")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.34))
                                                .underline()
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 2)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            .coordinateSpace(name: "settingsScroll")

                            ScrollProgressRail(activeSection: activeSection)
                                .padding(.trailing, 4)
                                .padding(.vertical, 10)
                        }
                    }
                    .onPreferenceChange(SettingsSectionOffsetKey.self) { values in
                        if let nearest = values.min(by: { abs($0.value) < abs($1.value) })?.key {
                            activeSection = nearest
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(
                TopAttachedSettingsShape(topRadius: 14, bottomRadius: 40)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.95), Color(red: 0.1, green: 0.11, blue: 0.13).opacity(0.93)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        TopAttachedSettingsShape(topRadius: 14, bottomRadius: 40)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 8)
            )
            .padding(.bottom, 2)
        }
    }

    private func sectionMarker(_ section: SettingsSectionID) -> some View {
        Color.clear
            .frame(height: 1)
            .id(section)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsSectionOffsetKey.self,
                        value: [section: proxy.frame(in: .named("settingsScroll")).minY]
                    )
                }
            )
    }

    private let colorPresets: [(label: String, color: Color)] = [
        ("Blanco", .white),
        ("Verde", Color(red: 0.12, green: 0.85, blue: 0.45)),
        ("Azul", Color(red: 0.2, green: 0.6, blue: 1.0)),
        ("Rosa", Color(red: 1.0, green: 0.3, blue: 0.6)),
        ("Naranja", Color(red: 1.0, green: 0.6, blue: 0.1))
    ]

    private func isColorSelected(_ color: Color) -> Bool {
        NSColor(color).isApproximatelyEqual(to: NSColor(settings.equalizerColor))
    }
}

private struct TopAttachedSettingsShape: Shape {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, min(rect.width * 0.5, rect.height * 0.5))
        let br = min(bottomRadius, min(rect.width * 0.5, rect.height * 0.5))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tr, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + tr),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - br, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - br),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct SettingsSidebar: View {
    @Binding var activeSection: SettingsSectionID
    let onSelect: (SettingsSectionID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SettingsSectionID.allCases, id: \.self) { section in
                Button {
                    activeSection = section
                    onSelect(section)
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(activeSection == section ? .white : .white.opacity(0.42))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(activeSection == section ? Color.white.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 82)
    }
}

private struct ScrollProgressRail: View {
    let activeSection: SettingsSectionID

    private var progress: CGFloat {
        switch activeSection {
        case .side: return 0.08
        case .panel: return 0.35
        case .behavior: return 0.62
        case .equalizer: return 0.88
        }
    }

    var body: some View {
        GeometryReader { geo in
            let railHeight = max(geo.size.height - 22, 20)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 4, height: railHeight)

                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 4, height: 34)
                    .offset(y: railHeight * progress - 17)
                    .animation(.spring(response: 0.24, dampingFraction: 0.9), value: activeSection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 12)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.34))
                    .kerning(1.1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

private struct SideDistanceLivePreview: View {
    let artworkImage: NSImage?
    let sideDistance: CGFloat
    let equalizerColor: Color
    let isPlaying: Bool

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width * 0.5
            let centerY = geo.size.height * 0.5
            let normalized = min(max(sideDistance, 60), 220)
            let previewDistance = 42 + ((normalized - 60) / 160) * 58

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.4))

                Capsule()
                    .fill(Color.black.opacity(0.9))
                    .frame(width: 120, height: 22)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .position(x: centerX, y: centerY)

                PreviewArtwork(image: artworkImage)
                    .frame(width: 24, height: 24)
                    .position(x: centerX - previewDistance, y: centerY)

                PreviewBars(color: equalizerColor, isPlaying: isPlaying)
                    .frame(width: 24, height: 14)
                    .position(x: centerX + previewDistance, y: centerY)
            }
        }
        .frame(height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PreviewArtwork: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct PreviewBars: View {
    let color: Color
    let isPlaying: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.8) {
            ForEach(0..<5, id: \.self) { i in
                let height: CGFloat = [0.4, 0.8, 0.55, 1.0, 0.65][i]

                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 14 * height * (isPlaying ? 1 : 0.25))
            }
        }
    }
}

private struct SettingsSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let unit: String
    let format: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("\(String(format: format, Double(value))) \(unit)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 72, alignment: .trailing)
            }

            Slider(value: $value, in: range)
                .tint(.white.opacity(0.84))
        }
    }
}

private extension SettingsSlider {
    init(label: String, value: Binding<Double>, range: ClosedRange<CGFloat>, unit: String, format: String) {
        self.label = label
        self._value = Binding(
            get: { CGFloat(value.wrappedValue) },
            set: { value.wrappedValue = Double($0) }
        )
        self.range = range
        self.unit = unit
        self.format = format
    }
}

private struct ColorPresetDot: View {
    let color: Color
    let isSelected: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.95 : 0.2), lineWidth: isSelected ? 2 : 0.5)
                )
                .scaleEffect(isSelected ? 1.12 : 1)
                .animation(.easeOut(duration: 0.14), value: isSelected)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

private struct MiniEqualizerPreview: View {
    let color: Color
    @State private var phase = false
    private let heights: [CGFloat] = [0.5, 0.9, 0.65, 1.0, 0.7]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 14 * heights[i] * (phase ? 1 : 0.3))
                    .animation(
                        Animation.easeInOut(duration: 0.4 + Double(i) * 0.06)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.08),
                        value: phase
                    )
            }
        }
        .frame(width: 24, height: 14)
        .onAppear { phase = true }
    }
}

private extension NSColor {
    func isApproximatelyEqual(to other: NSColor, threshold: CGFloat = 0.05) -> Bool {
        guard let c1 = usingColorSpace(.sRGB),
              let c2 = other.usingColorSpace(.sRGB) else { return false }

        return abs(c1.redComponent - c2.redComponent) < threshold &&
            abs(c1.greenComponent - c2.greenComponent) < threshold &&
            abs(c1.blueComponent - c2.blueComponent) < threshold
    }
}
