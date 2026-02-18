import SwiftUI
import AppKit

struct NotchContentView: View {
    @EnvironmentObject private var spotify: SpotifyBridge
    @EnvironmentObject private var settings: AppSettings

    @State private var activePanel: ActivePanel = .none

    private enum ActivePanel { case none, music, settings }

    var body: some View {
        GeometryReader { geo in
            let collapsedHeight: CGFloat = 36
            let expandedHeight = max(settings.expandedHeight, collapsedHeight + 1)
            let expansionProgress = min(
                max((geo.size.height - collapsedHeight) / (expandedHeight - collapsedHeight), 0),
                1
            )
            let expanded = expansionProgress > 0.62

            ZStack(alignment: .top) {
                CollapsedSideElements()
                    .environmentObject(spotify)
                    .environmentObject(settings)
                    .opacity(1 - expansionProgress)
                    .scaleEffect(1 - (0.04 * expansionProgress))
                    .offset(y: -4 * expansionProgress)

                if activePanel == .music && expansionProgress > 0.06 {
                    ExpandedMusicPanel(onSettingsTap: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9, blendDuration: 0.08)) {
                            activePanel = .settings
                        }
                    })
                    .environmentObject(spotify)
                    .opacity(expansionProgress)
                    .scaleEffect(0.985 + (0.015 * expansionProgress), anchor: .top)
                    .offset(y: -8 * (1 - expansionProgress))
                }

                if activePanel == .settings && expansionProgress > 0.06 {
                    SettingsPanelView(
                        isVisible: Binding(
                            get: { activePanel == .settings },
                            set: { if !$0 { activePanel = .music } }
                        )
                    )
                    .environmentObject(settings)
                    .environmentObject(spotify)
                    .opacity(expansionProgress)
                    .offset(x: 12 * (1 - expansionProgress))
                }
            }
            .animation(.easeInOut(duration: 0.24), value: expansionProgress)
            .animation(.spring(response: 0.3, dampingFraction: 0.9, blendDuration: 0.1), value: activePanel)
            .onChange(of: expanded) { isExpanded in
                activePanel = isExpanded ? .music : .none
            }
        }
    }
}

private struct CollapsedSideElements: View {
    @EnvironmentObject private var spotify: SpotifyBridge
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width * 0.5
            let centerY = geo.size.height * 0.5

            ZStack {
                ArtworkThumb(image: spotify.artworkImage)
                    .frame(width: 28, height: 28)
                    .position(x: centerX - settings.sideDistance, y: centerY)

                MusicBarsView(
                    isPlaying: spotify.currentTrack.isPlaying,
                    color: settings.equalizerColor
                )
                .frame(width: 16, height: 14)
                .position(x: centerX + settings.sideDistance, y: centerY)
            }
        }
    }
}

private struct ExpandedMusicPanel: View {
    @EnvironmentObject private var spotify: SpotifyBridge

    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    @State private var volumeValue: Double = 65
    @State private var isVolumeOpen = false

    let onSettingsTap: () -> Void

    private var displayedPosition: Double {
        isSeeking ? seekValue : spotify.currentTrack.position
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep the panel attached to screen top while real content starts below the hardware notch area.
            Color.clear.frame(height: 34)

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ArtworkLarge(
                        image: spotify.artworkImage,
                        showSpotifyBadge: spotify.artworkImage != nil,
                        badgeIsActive: spotify.currentTrack.isPlaying,
                        isPlaying: spotify.currentTrack.isPlaying
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(spotify.currentTrack.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(spotify.currentTrack.artist)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.64))
                            .lineLimit(1)

                        if spotify.currentTrack.title == "Not Playing" && !spotify.debugStatus.isEmpty {
                            Text(spotify.debugStatus)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(
                                    spotify.debugStatus == "OK"
                                        ? .white.opacity(0.35)
                                        : Color(red: 1.0, green: 0.48, blue: 0.48)
                                )
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onSettingsTap) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.82))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 6) {
                    SeekBar(
                        value: Binding(
                            get: { displayedPosition },
                            set: { seekValue = $0 }
                        ),
                        range: 0...max(spotify.currentTrack.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                isSeeking = true
                                seekValue = spotify.currentTrack.position
                            } else {
                                isSeeking = false
                                spotify.seek(to: seekValue)
                            }
                        }
                    )
                    .frame(height: 14)

                    HStack {
                        Text(formatTime(displayedPosition))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))

                        Spacer()

                        Text("-\(formatTime(max(spotify.currentTrack.duration - displayedPosition, 0)))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                VStack(spacing: 10) {
                    HStack {
                        Spacer()

                        HStack(spacing: 46) {
                            Control(icon: "backward.fill", size: 25) { spotify.previousTrack() }
                            Control(icon: spotify.currentTrack.isPlaying ? "pause.fill" : "play.fill", size: 29) { spotify.playPause() }
                            Control(icon: "forward.fill", size: 25) { spotify.nextTrack() }
                        }

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                isVolumeOpen.toggle()
                            }
                        } label: {
                            Image(systemName: "headphones")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(.white.opacity(0.75))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }

                    if isVolumeOpen {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.64))

                            Slider(
                                value: Binding(
                                    get: { volumeValue },
                                    set: {
                                        volumeValue = $0
                                        spotify.setVolume($0)
                                    }
                                ),
                                in: 0...100
                            )
                            .tint(.white.opacity(0.84))

                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.72))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(
            TopAttachedPanelShape(topRadius: 14, bottomRadius: 34)
                .fill(Color.black.opacity(0.97))
                .overlay(
                    TopAttachedPanelShape(topRadius: 14, bottomRadius: 34)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.9)
                )
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                }
                .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 7)
        )
        .padding(.horizontal, 6)
        .onAppear {
            seekValue = spotify.currentTrack.position
            volumeValue = spotify.volume
            spotify.refreshNow()
        }
        .onChange(of: spotify.currentTrack.position) { newValue in
            guard !isSeeking else { return }
            seekValue = newValue
        }
        .onChange(of: spotify.volume) { newValue in
            if abs(newValue - volumeValue) > 1.0 {
                volumeValue = newValue
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TopAttachedPanelShape: Shape {
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

private struct SeekBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001))
            let clampedProgress = min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 7)

                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: width * clampedProgress, height: 7)

                Circle()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 11, height: 11)
                    .offset(x: (width * clampedProgress) - 5.5)
                    .opacity(isDragging ? 1 : 0.86)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }

                        let normalized = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + Double(normalized) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { gesture in
                        let normalized = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + Double(normalized) * (range.upperBound - range.lowerBound)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
    }
}

private struct ArtworkThumb: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
    }
}

private struct ArtworkLarge: View {
    let image: NSImage?
    let showSpotifyBadge: Bool
    let badgeIsActive: Bool
    let isPlaying: Bool

    private let artworkSize: CGFloat = 68
    private let cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .compositingGroup()
        .scaleEffect(isPlaying ? 1.0 : 0.92)
        .animation(.spring(response: 0.26, dampingFraction: 0.92), value: isPlaying)
        .overlay(alignment: .bottomTrailing) {
            if showSpotifyBadge {
                SpotifyBadge(isActive: badgeIsActive)
                .offset(x: 4, y: 4)
            }
        }
    }
}

private struct SpotifyBadge: View {
    let isActive: Bool
    var size: CGFloat = 19

    var body: some View {
        Group {
            if let image = NSImage(named: "SpotifyLogo") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.11, green: 0.73, blue: 0.33))
                        .frame(width: size, height: size)
                        .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))

                    VStack(spacing: 2) {
                        Capsule().fill(Color.black.opacity(0.82)).frame(width: 8.6, height: 1.5).rotationEffect(.degrees(-10))
                        Capsule().fill(Color.black.opacity(0.82)).frame(width: 7.2, height: 1.4).rotationEffect(.degrees(-10))
                        Capsule().fill(Color.black.opacity(0.82)).frame(width: 5.9, height: 1.3).rotationEffect(.degrees(-10))
                    }
                }
            }
        }
        .scaleEffect(isActive ? 1.0 : 0.94)
        .saturation(isActive ? 1.0 : 0.45)
        .opacity(isActive ? 1.0 : 0.9)
        .animation(.easeOut(duration: 0.2), value: isActive)
        .shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 1)
    }
}

private struct Control: View {
    let icon: String
    var size: CGFloat = 16
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white.opacity(hovered ? 0.98 : 0.84))
                .scaleEffect(hovered ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.14), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct MusicBarsView: View {
    let isPlaying: Bool
    let color: Color

    private let heights: [CGFloat] = [0.44, 0.78, 1.0, 0.68]
    private let durations: [Double] = [0.92, 0.76, 0.64, 0.82]
    private let idleScale: CGFloat = 0.26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .bottom, spacing: 2.2) {
                ForEach(0..<heights.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.1, style: .continuous)
                        .fill(color.opacity(0.92))
                        .frame(width: 2.0, height: 12 * heights[i] * barScale(for: i, at: time))
                }
            }
        }
    }

    private func barScale(for index: Int, at time: TimeInterval) -> CGFloat {
        guard isPlaying else { return idleScale }

        let wave = (sin((time / durations[index] + Double(index) * 0.27) * 2 * .pi) + 1) * 0.5
        return 0.36 + (0.64 * CGFloat(wave))
    }
}
