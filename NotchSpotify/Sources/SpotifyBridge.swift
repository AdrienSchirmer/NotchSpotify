import Foundation
import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct SpotifyTrack: Equatable {
    let title: String
    let artist: String
    let duration: Double
    let position: Double
    let isPlaying: Bool
    let artworkURL: String?

    static let empty = SpotifyTrack(
        title: "Not Playing",
        artist: "Open Spotify",
        duration: 1,
        position: 0,
        isPlaying: false,
        artworkURL: nil
    )
}

@MainActor
final class SpotifyBridge: ObservableObject {
    @Published private(set) var currentTrack: SpotifyTrack = .empty
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var artworkDominantColor: Color?
    @Published private(set) var volume: Double = 65
    @Published private(set) var debugStatus: String = "Build-2026-02-17"

    private var pollTimer: Timer?
    private var progressTimer: Timer?
    private var currentPollInterval: TimeInterval = 0
    private var lastArtworkURL: String?
    private var artworkColorCache: [String: NSColor] = [:]
    private var volumeWorkItem: DispatchWorkItem?

    private var lastProgressTick = Date()
    private var ignoreRemotePositionUntil: Date = .distantPast
    private var ignoreRemotePlaybackStateUntil: Date = .distantPast
    private var forcedPlaybackState: Bool?

    private let scriptQueue = DispatchQueue(
        label: "com.notchspotify.spotifybridge.script",
        qos: .userInitiated
    )
    private var isFetchingState = false
    private var hasQueuedFetch = false
    private var fetchFailureCount = 0
    private var transientNoTrackStartedAt: Date?
    private var isUserInteractionActive = false
    private var interactionBoostUntil: Date = .distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    
    private let pollIntervalPlayingInteractive: TimeInterval = 0.55
    private let pollIntervalPlayingPassive: TimeInterval = 1.2
    private let pollIntervalPausedInteractive: TimeInterval = 1.05
    private let pollIntervalPausedPassive: TimeInterval = 3.4
    private let pollIntervalNotRunningInteractive: TimeInterval = 1.8
    private let pollIntervalNotRunningPassive: TimeInterval = 5.0
    private let progressTickInterval: TimeInterval = 0.1
    private let transientNoTrackGraceInterval: TimeInterval = 0.7

    nonisolated private static let payloadSeparator = "|||NSP_SEP|||"
    nonisolated private static let spotifyBundleID = "com.spotify.client"
    nonisolated private static let colorContext = CIContext(options: [.workingColorSpace: NSNull()])

    static let shared = SpotifyBridge()
    private init() {
        registerWorkspaceObservers()
    }
    
    deinit {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
    }

    var isSpotifyRunning: Bool {
        runningSpotifyApplication() != nil
    }
    
    func setUserInteractionActive(_ isActive: Bool) {
        if isActive {
            boostPolling(for: 8.0)
        }
        guard isUserInteractionActive != isActive else { return }
        isUserInteractionActive = isActive
        applyCurrentEnergyPolicy()
    }

    func startPolling() {
        guard pollTimer == nil else { return }

        scheduleFetchState()
        lastProgressTick = Date()
        applyCurrentEnergyPolicy()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentPollInterval = 0

        progressTimer?.invalidate()
        progressTimer = nil

        volumeWorkItem?.cancel()
        volumeWorkItem = nil

        isFetchingState = false
        hasQueuedFetch = false
    }

    func playPause() {
        guard isSpotifyRunning else { return }

        if currentTrack != .empty {
            let targetPlaybackState = !currentTrack.isPlaying
            currentTrack = SpotifyTrack(
                title: currentTrack.title,
                artist: currentTrack.artist,
                duration: currentTrack.duration,
                position: currentTrack.position,
                isPlaying: targetPlaybackState,
                artworkURL: currentTrack.artworkURL
            )
            forcedPlaybackState = targetPlaybackState
            ignoreRemotePlaybackStateUntil = Date().addingTimeInterval(0.65)
        }

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.25)
        lastProgressTick = Date()
        boostPolling(for: 10.0)
        applyCurrentEnergyPolicy(track: currentTrack)

        enqueueSpotifyCommand("playpause")
        refreshAfterCommand()
    }

    func nextTrack() {
        guard isSpotifyRunning else { return }

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.45)
        lastProgressTick = Date()
        boostPolling(for: 10.0)
        updatePollTimer(interval: pollIntervalPlayingInteractive)

        enqueueSpotifyCommand("next track")
        refreshAfterCommand()
    }

    func previousTrack() {
        guard isSpotifyRunning else { return }

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.45)
        lastProgressTick = Date()
        boostPolling(for: 10.0)
        updatePollTimer(interval: pollIntervalPlayingInteractive)

        enqueueSpotifyCommand("previous track")
        refreshAfterCommand()
    }

    func seek(to seconds: Double) {
        guard currentTrack != .empty else { return }
        guard isSpotifyRunning else { return }

        let clamped = min(max(seconds, 0), max(currentTrack.duration, 1))
        let scriptValue = formattedScriptNumber(clamped)

        currentTrack = SpotifyTrack(
            title: currentTrack.title,
            artist: currentTrack.artist,
            duration: currentTrack.duration,
            position: clamped,
            isPlaying: currentTrack.isPlaying,
            artworkURL: currentTrack.artworkURL
        )

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.5)
        lastProgressTick = Date()
        boostPolling(for: 10.0)
        updatePollTimer(interval: pollIntervalPlayingInteractive)

        enqueueSpotifyCommand("set player position to \(scriptValue)")
        refreshAfterCommand(immediate: false)
    }

    func setVolume(_ newValue: Double) {
        guard isSpotifyRunning else { return }

        let clamped = min(max(newValue, 0), 100)
        volume = clamped

        volumeWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let commandVolume = Int(clamped.rounded())
            self.enqueueSpotifyCommand("set sound volume to \(commandVolume)")
        }

        volumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func refreshNow() {
        boostPolling(for: 6.0)
        scheduleFetchState()
    }

    private func refreshAfterCommand(immediate: Bool = true) {
        boostPolling(for: 10.0)

        if immediate {
            scheduleFetchState()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            self?.scheduleFetchState()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.scheduleFetchState()
        }
    }

    private func advanceLocalProgress() {
        let now = Date()
        let delta = now.timeIntervalSince(lastProgressTick)
        lastProgressTick = now

        guard currentTrack.isPlaying, currentTrack != .empty else { return }
        guard delta > 0 else { return }

        let nextPosition = min(currentTrack.position + delta, max(currentTrack.duration, 1))
        guard nextPosition != currentTrack.position else { return }

        currentTrack = SpotifyTrack(
            title: currentTrack.title,
            artist: currentTrack.artist,
            duration: currentTrack.duration,
            position: nextPosition,
            isPlaying: currentTrack.isPlaying,
            artworkURL: currentTrack.artworkURL
        )
    }

    private func scheduleFetchState() {
        guard isSpotifyRunning else {
            isFetchingState = false
            hasQueuedFetch = false
            fetchFailureCount = 0
            transientNoTrackStartedAt = nil
            applyCurrentEnergyPolicy(isSpotifyRunning: false)
            setNotPlayingArtist("Open Spotify")
            debugStatus = "Spotify process not running"
            if artworkImage != nil { artworkImage = nil }
            if artworkDominantColor != nil { artworkDominantColor = nil }
            lastArtworkURL = nil
            return
        }

        if isFetchingState {
            hasQueuedFetch = true
            return
        }

        isFetchingState = true

        let preferredTarget = Self.spotifyTargetSpecifier(bundleID: spotifyTargetBundleID())
        let primaryFetchScript = Self.makeFetchStateScript(
            targetSpecifier: "application \"Spotify\""
        )
        let fallbackFetchScript = Self.makeFetchStateScript(targetSpecifier: preferredTarget)

        scriptQueue.async { [weak self] in
            let primaryResult = Self.runAppleScript(primaryFetchScript, logErrors: true)
            let result = Self.retryOnErrorCode(
                primaryResult,
                code: "-600",
                fallbackScript: fallbackFetchScript
            )

            Task { @MainActor in
                guard let self else { return }

                self.applyFetchResult(result)
                self.isFetchingState = false

                if self.hasQueuedFetch {
                    self.hasQueuedFetch = false
                    self.scheduleFetchState()
                }
            }
        }
    }

    private func applyFetchResult(_ result: String?) {
        guard let result else {
            fetchFailureCount += 1
            if fetchFailureCount >= 5 {
                setNotPlayingArtist("AppleScript unavailable")
                debugStatus = "AppleScript returned nil"
                if artworkImage != nil { artworkImage = nil }
                if artworkDominantColor != nil { artworkDominantColor = nil }
                lastArtworkURL = nil
            }
            return
        }
        fetchFailureCount = 0

        if result == "NOTRUNNING" {
            if shouldDeferNoTrackTransition() {
                applyCurrentEnergyPolicy(track: currentTrack)
                debugStatus = "Spotify transition (not running)"
                boostPolling(for: 2.0)
                return
            }

            applyCurrentEnergyPolicy(isSpotifyRunning: false)
            setNotPlayingArtist("Open Spotify")
            debugStatus = "Spotify not running"
            if artworkImage != nil { artworkImage = nil }
            if artworkDominantColor != nil { artworkDominantColor = nil }
            lastArtworkURL = nil
            return
        }

        if result.hasPrefix("IDLE") {
            if shouldDeferNoTrackTransition() {
                applyCurrentEnergyPolicy(track: currentTrack)
                debugStatus = "Spotify transition (idle)"
                boostPolling(for: 2.0)
                return
            }

            applyCurrentEnergyPolicy(track: .empty)
            setNotPlayingArtist("Open Spotify")
            debugStatus = "Spotify idle"
            if artworkImage != nil { artworkImage = nil }
            if artworkDominantColor != nil { artworkDominantColor = nil }
            lastArtworkURL = nil
            return
        }

        if result.hasPrefix("ERROR") {
            applyCurrentEnergyPolicy(track: .empty)
            let components = result.components(separatedBy: Self.payloadSeparator)
            if components.count >= 3 {
                let code = components[1]
                let message = components[2]
                setNotPlayingArtist("Spotify error \(code)")
                if code == "-600" {
                    debugStatus = "AppleScript error -600 [target: \(spotifyTargetBundleID())]: \(message)"
                } else {
                    debugStatus = "AppleScript error \(code): \(message)"
                }
            } else {
                setNotPlayingArtist("Spotify script error")
                debugStatus = result
            }
            return
        }

        transientNoTrackStartedAt = nil
        debugStatus = "OK"

        let parts = result.components(separatedBy: Self.payloadSeparator)
        guard parts.count == 8, parts[0] == "OK" else {
            setNotPlayingArtist("Payload parse failed")
            debugStatus = "Malformed payload (\(parts.count))"
            return
        }

        let parsedTitle = parts[1].isEmpty ? "Not Playing" : parts[1]
        let parsedArtist = parts[2].isEmpty ? "Open Spotify" : parts[2]
        let parsedDuration = max(Double(parts[3]) ?? 1, 1)
        let parsedPosition = min(max(Double(parts[4]) ?? 0, 0), parsedDuration)
        let parsedIsPlaying = parts[5].lowercased() == "true"
        let artURL = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)

        let sameTrack = isSameTrack(title: parsedTitle, artist: parsedArtist, duration: parsedDuration)
        let shouldHoldPosition = Date() < ignoreRemotePositionUntil && sameTrack
        let shouldHoldPlaybackState = Date() < ignoreRemotePlaybackStateUntil && sameTrack
        
        let resolvedIsPlaying: Bool
        if shouldHoldPlaybackState, let forcedPlaybackState {
            resolvedIsPlaying = forcedPlaybackState
        } else {
            resolvedIsPlaying = parsedIsPlaying
        }
        
        if let forcedPlaybackState, parsedIsPlaying == forcedPlaybackState {
            self.forcedPlaybackState = nil
            ignoreRemotePlaybackStateUntil = .distantPast
        } else if !shouldHoldPlaybackState {
            self.forcedPlaybackState = nil
        }

        let resolvedPosition: Double
        if shouldHoldPosition {
            resolvedPosition = currentTrack.position
        } else if sameTrack && resolvedIsPlaying && currentTrack.isPlaying {
            resolvedPosition = max(parsedPosition, currentTrack.position - 0.04)
        } else {
            resolvedPosition = parsedPosition
        }

        let track = SpotifyTrack(
            title: parsedTitle,
            artist: parsedArtist,
            duration: parsedDuration,
            position: resolvedPosition,
            isPlaying: resolvedIsPlaying,
            artworkURL: artURL.isEmpty ? nil : artURL
        )

        if track != currentTrack {
            currentTrack = track
        }
        
        applyCurrentEnergyPolicy(track: track)

        let fetchedVolume = min(max(Double(parts[7]) ?? volume, 0), 100)
        if abs(fetchedVolume - volume) > 0.5 {
            volume = fetchedVolume
        }

        if artURL != lastArtworkURL {
            lastArtworkURL = artURL
            fetchArtwork(for: artURL)
        }

        lastProgressTick = Date()
    }

    private func applyCurrentEnergyPolicy(isSpotifyRunning: Bool? = nil, track: SpotifyTrack? = nil) {
        let spotifyRunning = isSpotifyRunning ?? self.isSpotifyRunning
        let isActiveMode = isUserInteractionActive || Date() < interactionBoostUntil

        guard spotifyRunning else {
            let interval = isActiveMode
                ? pollIntervalNotRunningInteractive
                : pollIntervalNotRunningPassive
            updatePollTimer(interval: interval)
            updateProgressTimer(isActive: false)
            return
        }

        let resolvedTrack = track ?? currentTrack
        let isPlayingTrack = resolvedTrack.isPlaying && resolvedTrack != .empty
        let interval: TimeInterval

        if isPlayingTrack {
            interval = isActiveMode
                ? pollIntervalPlayingInteractive
                : pollIntervalPlayingPassive
        } else {
            interval = isActiveMode
                ? pollIntervalPausedInteractive
                : pollIntervalPausedPassive
        }

        updateProgressTimer(isActive: isPlayingTrack)
        updatePollTimer(interval: interval)
    }

    private func boostPolling(for duration: TimeInterval) {
        let expiry = Date().addingTimeInterval(duration)
        if expiry > interactionBoostUntil {
            interactionBoostUntil = expiry
        }
        applyCurrentEnergyPolicy()
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleWorkspaceNotification(notification)
            }
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleWorkspaceNotification(notification)
            }
        }
        
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.boostPolling(for: 10.0)
                self.scheduleFetchState()
            }
        }

        workspaceObservers = [launchObserver, terminateObserver, wakeObserver]
    }

    private func handleWorkspaceNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        let isSpotifyProcess = app.bundleIdentifier == Self.spotifyBundleID
        guard isSpotifyProcess else { return }

        boostPolling(for: 10.0)
        scheduleFetchState()
    }

    private func updatePollTimer(interval: TimeInterval) {
        guard interval > 0 else { return }

        if let timer = pollTimer, abs(currentPollInterval - interval) < 0.02 {
            timer.tolerance = interval * 0.28
            return
        }

        pollTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleFetchState()
            }
        }
        timer.tolerance = interval * 0.28

        pollTimer = timer
        currentPollInterval = interval
    }

    private func updateProgressTimer(isActive: Bool) {
        if isActive {
            guard progressTimer == nil else { return }

            let timer = Timer.scheduledTimer(withTimeInterval: progressTickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.advanceLocalProgress()
                }
            }
            timer.tolerance = progressTickInterval * 0.35

            progressTimer = timer
            lastProgressTick = Date()
            return
        }

        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func fetchArtwork(for urlString: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            artworkImage = nil
            artworkDominantColor = nil
            return
        }

        let requestedURL = urlString
        if let cachedColor = artworkColorCache[requestedURL] {
            artworkDominantColor = Color(cachedColor)
        }

        Task(priority: .utility) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let image = NSImage(data: data)
                let extractedColor = Self.dominantColor(from: data)

                await MainActor.run {
                    guard self.lastArtworkURL == requestedURL else { return }

                    self.artworkImage = image

                    if let extractedColor {
                        self.artworkColorCache[requestedURL] = extractedColor
                        if self.artworkColorCache.count > 120,
                           let staleKey = self.artworkColorCache.keys.first {
                            self.artworkColorCache.removeValue(forKey: staleKey)
                        }
                        self.artworkDominantColor = Color(extractedColor)
                    } else if let cachedColor = self.artworkColorCache[requestedURL] {
                        self.artworkDominantColor = Color(cachedColor)
                    } else {
                        self.artworkDominantColor = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.lastArtworkURL == requestedURL else { return }
                    self.artworkImage = nil
                    self.artworkDominantColor = nil
                }
            }
        }
    }

    private func formattedScriptNumber(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func isSameTrack(title: String, artist: String, duration: Double) -> Bool {
        currentTrack.title == title &&
            currentTrack.artist == artist &&
            abs(currentTrack.duration - duration) < 0.2
    }

    nonisolated private static func dominantColor(from data: Data) -> NSColor? {
        guard let ciImage = CIImage(data: data) else { return nil }
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = extent

        guard let outputImage = filter.outputImage else { return nil }

        var rgba = [UInt8](repeating: 0, count: 4)
        colorContext.render(
            outputImage,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let color = NSColor(
            calibratedRed: CGFloat(rgba[0]) / 255.0,
            green: CGFloat(rgba[1]) / 255.0,
            blue: CGFloat(rgba[2]) / 255.0,
            alpha: 1
        )
        return tunedEqualizerColor(from: color)
    }

    nonisolated private static func tunedEqualizerColor(from base: NSColor) -> NSColor {
        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }

        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let tunedS = min(max(s * 1.25, 0.38), 0.95)
        let tunedB = min(max(b * 1.18, 0.58), 0.98)
        return NSColor(calibratedHue: h, saturation: tunedS, brightness: tunedB, alpha: 1)
    }

    private func runningSpotifyApplication() -> NSRunningApplication? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.spotifyBundleID)
            .first(where: { !$0.isTerminated })
    }

    private func spotifyTargetBundleID() -> String {
        runningSpotifyApplication()?.bundleIdentifier ?? Self.spotifyBundleID
    }

    private func setNotPlayingArtist(_ artist: String) {
        let track = SpotifyTrack(
            title: "Not Playing",
            artist: artist,
            duration: 1,
            position: 0,
            isPlaying: false,
            artworkURL: nil
        )
        if currentTrack != track {
            currentTrack = track
        }
    }

    private func shouldDeferNoTrackTransition() -> Bool {
        guard isSpotifyRunning, currentTrack != .empty else {
            transientNoTrackStartedAt = nil
            return false
        }

        let now = Date()
        if let startedAt = transientNoTrackStartedAt {
            if now.timeIntervalSince(startedAt) < transientNoTrackGraceInterval {
                return true
            }
            transientNoTrackStartedAt = nil
            return false
        }

        transientNoTrackStartedAt = now
        return true
    }

    private func enqueueAppleScript(_ source: String, logErrors: Bool = true) {
        scriptQueue.async {
            _ = Self.runAppleScript(source, logErrors: logErrors)
        }
    }

    private func enqueueSpotifyCommand(_ commandBody: String, logErrors: Bool = true) {
        let primary = Self.makeCommandScript(
            commandBody: commandBody,
            targetSpecifier: "application \"Spotify\""
        )
        let fallback = Self.makeCommandScript(
            commandBody: commandBody,
            targetSpecifier: Self.spotifyTargetSpecifier(bundleID: spotifyTargetBundleID())
        )

        scriptQueue.async {
            let primaryResult = Self.runAppleScript(primary, logErrors: logErrors)
            _ = Self.retryOnErrorCode(
                primaryResult,
                code: "-600",
                fallbackScript: fallback
            )
        }
    }

    nonisolated private static func escapeAppleScriptString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func spotifyTargetSpecifier(bundleID: String) -> String {
        let escapedBundleID = escapeAppleScriptString(bundleID)
        return #"application id "\#(escapedBundleID)""#
    }

    nonisolated private static func makeFetchStateScript(targetSpecifier: String) -> String {
        let separator = escapeAppleScriptString(payloadSeparator)
        let target = targetSpecifier
        let spotifyBundleID = escapeAppleScriptString(Self.spotifyBundleID)

        return #"""
        set sep to "\#(separator)"

        on nsp_read_state(sep)
            tell \#(target)
                set trackVolume to sound volume
                set stateText to (player state as text)
                set trackPlaying to (stateText is "playing")
                set trackPosition to player position

                if stateText is "stopped" then
                    return "IDLE" & sep & "" & sep & "" & sep & 1 & sep & 0 & sep & false & sep & "" & sep & trackVolume
                end if

                set trackName to (name of current track as text)
                set trackArtist to (artist of current track as text)
                set trackDuration to (duration of current track) / 1000
                set trackArtURL to ""

                try
                    set trackArtURL to artwork url of current track
                on error
                    set trackArtURL to ""
                end try

                return "OK" & sep & trackName & sep & trackArtist & sep & trackDuration & sep & trackPosition & sep & trackPlaying & sep & trackArtURL & sep & trackVolume
            end tell
        end nsp_read_state

        try
            if application id "\#(spotifyBundleID)" is not running then
                return "NOTRUNNING"
            end if
        on error
            return "NOTRUNNING"
        end try

        try
            return nsp_read_state(sep)
        on error errMsg number errNum
            if errNum is -600 then
                return "NOTRUNNING"
            end if

            return "ERROR" & sep & errNum & sep & errMsg
        end try
        """#
    }

    nonisolated private static func makeCommandScript(commandBody: String, targetSpecifier: String) -> String {
        let target = targetSpecifier
        let spotifyBundleID = escapeAppleScriptString(Self.spotifyBundleID)

        return #"""
        on nsp_run_command()
            tell \#(target)
                \#(commandBody)
            end tell
        end nsp_run_command

        try
            if application id "\#(spotifyBundleID)" is not running then
                return "NOTRUNNING"
            end if
        on error
            return "NOTRUNNING"
        end try

        try
            nsp_run_command()
        on error errMsg number errNum
            if errNum is -600 then
                return "NOTRUNNING"
            end if
            error errMsg number errNum
        end try
        """#
    }

    @discardableResult
    nonisolated private static func runAppleScript(_ source: String, logErrors: Bool = true) -> String? {
        runAppleScriptCLI(source, logErrors: logErrors)
    }

    nonisolated private static func runAppleScriptCLI(_ source: String, logErrors: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = []

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            if let data = source.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.write(Data("\n".utf8))
            inputPipe.fileHandleForWriting.closeFile()

            process.waitUntilExit()
        } catch {
            if logErrors {
                print("osascript launch error: \(error)")
            }
            return scriptError(code: "CLI_LAUNCH", message: "\(error)")
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            return stdout
        }

        if logErrors {
            print("osascript error (\(process.terminationStatus)): \(stderr)")
        }
        return scriptError(
            code: "CLI_\(process.terminationStatus)",
            message: stderr.isEmpty ? "osascript failed without stderr output" : stderr
        )
    }

    nonisolated private static func errorCode(from result: String?) -> String? {
        guard let result, result.hasPrefix("ERROR") else { return nil }
        let components = result.components(separatedBy: payloadSeparator)
        guard components.count >= 2 else { return nil }
        return components[1]
    }

    nonisolated private static func retryOnErrorCode(
        _ primaryResult: String?,
        code: String,
        fallbackScript: String
    ) -> String? {
        guard errorCode(from: primaryResult) == code else { return primaryResult }
        return runAppleScript(fallbackScript, logErrors: true) ?? primaryResult
    }

    nonisolated private static func scriptError(code: String, message: String) -> String {
        let cleanedMessage = message
            .replacingOccurrences(of: payloadSeparator, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "ERROR\(payloadSeparator)\(code)\(payloadSeparator)\(cleanedMessage)"
    }
}
