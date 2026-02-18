import Foundation
import AppKit

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
    @Published private(set) var volume: Double = 65
    @Published private(set) var debugStatus: String = "Build-2026-02-17"

    private var pollTimer: Timer?
    private var progressTimer: Timer?
    private var lastArtworkURL: String?
    private var volumeWorkItem: DispatchWorkItem?

    private var lastProgressTick = Date()
    private var ignoreRemotePositionUntil: Date = .distantPast

    private let scriptQueue = DispatchQueue(
        label: "com.notchspotify.spotifybridge.script",
        qos: .userInitiated
    )
    private var isFetchingState = false
    private var hasQueuedFetch = false
    private var fetchFailureCount = 0

    nonisolated private static let payloadSeparator = "|||NSP_SEP|||"
    nonisolated private static let spotifyBundleID = "com.spotify.client"

    static let shared = SpotifyBridge()
    private init() {}

    var isSpotifyRunning: Bool {
        runningSpotifyApplication() != nil
    }

    func startPolling() {
        guard pollTimer == nil else { return }

        scheduleFetchState()
        lastProgressTick = Date()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleFetchState()
            }
        }

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceLocalProgress()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil

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
            currentTrack = SpotifyTrack(
                title: currentTrack.title,
                artist: currentTrack.artist,
                duration: currentTrack.duration,
                position: currentTrack.position,
                isPlaying: !currentTrack.isPlaying,
                artworkURL: currentTrack.artworkURL
            )
        }

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.25)
        lastProgressTick = Date()

        enqueueSpotifyCommand("playpause")
        refreshAfterCommand()
    }

    func nextTrack() {
        guard isSpotifyRunning else { return }

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.45)
        lastProgressTick = Date()

        enqueueSpotifyCommand("next track")
        refreshAfterCommand()
    }

    func previousTrack() {
        guard isSpotifyRunning else { return }

        ignoreRemotePositionUntil = Date().addingTimeInterval(0.45)
        lastProgressTick = Date()

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

        enqueueSpotifyCommand("set player position to \(scriptValue)")
        refreshAfterCommand(immediate: false)
    }

    func setVolume(_ newValue: Double) {
        guard isSpotifyRunning else { return }

        let clamped = min(max(newValue, 0), 100)
        volume = clamped

        volumeWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let commandVolume = Int(clamped.rounded())
                self.enqueueSpotifyCommand("set sound volume to \(commandVolume)")
            }
        }

        volumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func refreshNow() {
        scheduleFetchState()
    }

    private func refreshAfterCommand(immediate: Bool = true) {
        if immediate {
            scheduleFetchState()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            Task { @MainActor in
                self?.scheduleFetchState()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            Task { @MainActor in
                self?.scheduleFetchState()
            }
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
            setNotPlayingArtist("Open Spotify")
            debugStatus = "Spotify process not running"
            if artworkImage != nil { artworkImage = nil }
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
                lastArtworkURL = nil
            }
            return
        }
        fetchFailureCount = 0

        if result == "NOTRUNNING" {
            setNotPlayingArtist("Open Spotify")
            debugStatus = "Spotify not running"
            if artworkImage != nil { artworkImage = nil }
            lastArtworkURL = nil
            return
        }

        if result.hasPrefix("IDLE") {
            setNotPlayingArtist("Open Spotify")
            debugStatus = "Spotify idle"
            if artworkImage != nil { artworkImage = nil }
            lastArtworkURL = nil
            return
        }

        if result.hasPrefix("ERROR") {
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

        let resolvedPosition: Double
        if shouldHoldPosition {
            resolvedPosition = currentTrack.position
        } else if sameTrack && parsedIsPlaying && currentTrack.isPlaying {
            resolvedPosition = max(parsedPosition, currentTrack.position - 0.04)
        } else {
            resolvedPosition = parsedPosition
        }

        let track = SpotifyTrack(
            title: parsedTitle,
            artist: parsedArtist,
            duration: parsedDuration,
            position: resolvedPosition,
            isPlaying: parsedIsPlaying,
            artworkURL: artURL.isEmpty ? nil : artURL
        )

        if track != currentTrack {
            currentTrack = track
        }

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

    private func fetchArtwork(for urlString: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            artworkImage = nil
            return
        }

        Task(priority: .utility) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let image = NSImage(data: data)
                await MainActor.run { self.artworkImage = image }
            } catch {
                await MainActor.run { self.artworkImage = nil }
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

    private func runningSpotifyApplication() -> NSRunningApplication? {
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.spotifyBundleID)
            .first(where: { !$0.isTerminated }) {
            return app
        }

        return NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated else { return false }
            guard let name = app.localizedName?.lowercased() else { return false }
            return name.contains("spotify")
        }
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
            return nsp_read_state(sep)
        on error errMsg number errNum
            if errNum is -600 then
                try
                    tell \#(target) to launch
                    delay 0.12
                    return nsp_read_state(sep)
                on error retryErrMsg number retryErrNum
                    return "ERROR" & sep & retryErrNum & sep & retryErrMsg
                end try
            end if

            return "ERROR" & sep & errNum & sep & errMsg
        end try
        """#
    }

    nonisolated private static func makeCommandScript(commandBody: String, targetSpecifier: String) -> String {
        let target = targetSpecifier

        return #"""
        on nsp_run_command()
            tell \#(target)
                \#(commandBody)
            end tell
        end nsp_run_command

        try
            nsp_run_command()
        on error errMsg number errNum
            if errNum is -600 then
                tell \#(target) to launch
                delay 0.08
                nsp_run_command()
            else
                error errMsg number errNum
            end if
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
