import AppKit
import ApplicationServices
import Foundation

public struct NowPlayingMetadata: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var sourceApp: String
    public var isPlaying: Bool
    public var elapsed: Double?
    public var duration: Double?
    public var canSeek: Bool
    public var canControlPlayback: Bool

    public init(
        title: String,
        subtitle: String,
        sourceApp: String,
        isPlaying: Bool,
        elapsed: Double?,
        duration: Double?,
        canSeek: Bool,
        canControlPlayback: Bool
    ) {
        self.title = title
        self.subtitle = subtitle
        self.sourceApp = sourceApp
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
        self.canSeek = canSeek
        self.canControlPlayback = canControlPlayback
    }

    public static let idle = NowPlayingMetadata(
        title: "System Audio Output",
        subtitle: "Waiting for signal",
        sourceApp: "CORE AUDIO",
        isPlaying: false,
        elapsed: nil,
        duration: nil,
        canSeek: false,
        canControlPlayback: false
    )
}

/// Sanctioned macOS media transport + metadata observer.
/// Shows transport controls only when a working control channel exists (Spotify/Music AppleScript or Accessibility-trusted HID media keys).
public final class MediaController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.strangechances.Satie.media", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var deniedBundles: Set<String> = []
    private var activeProvider: String?

    public var onMetadataUpdate: ((NowPlayingMetadata) -> Void)?

    public init() {}

    public static var hasMediaKeyPermission: Bool {
        #if APP_STORE
        return false
        #else
        return AXIsProcessTrusted()
        #endif
    }

    /// Prompts macOS Accessibility permission so global HID media keys work across Chrome, Safari, YouTube, etc.
    public static func requestMediaKeyPermission() {
        #if !APP_STORE
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        #endif
    }

    public func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 1.5)
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func playPause() {
        #if !APP_STORE
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeProvider == "Spotify", self.isAppRunning("com.spotify.client") {
                _ = self.runAppleScript(#"tell application "Spotify" to playpause"#)
                self.poll()
                return
            }
            if self.activeProvider == "Music", self.isAppRunning("com.apple.Music") {
                _ = self.runAppleScript(#"tell application "Music" to playpause"#)
                self.poll()
                return
            }
            if Self.hasMediaKeyPermission {
                self.sendHIDMediaKey(16) // NX_KEYTYPE_PLAY
            }
        }
        #endif
    }

    public func nextTrack() {
        #if !APP_STORE
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeProvider == "Spotify", self.isAppRunning("com.spotify.client") {
                _ = self.runAppleScript(#"tell application "Spotify" to next track"#)
                self.poll()
                return
            }
            if self.activeProvider == "Music", self.isAppRunning("com.apple.Music") {
                _ = self.runAppleScript(#"tell application "Music" to next track"#)
                self.poll()
                return
            }
            if Self.hasMediaKeyPermission {
                self.sendHIDMediaKey(17) // NX_KEYTYPE_NEXT
            }
        }
        #endif
    }

    public func previousTrack() {
        #if !APP_STORE
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeProvider == "Spotify", self.isAppRunning("com.spotify.client") {
                _ = self.runAppleScript(#"tell application "Spotify" to previous track"#)
                self.poll()
                return
            }
            if self.activeProvider == "Music", self.isAppRunning("com.apple.Music") {
                _ = self.runAppleScript(#"tell application "Music" to previous track"#)
                self.poll()
                return
            }
            if Self.hasMediaKeyPermission {
                self.sendHIDMediaKey(18) // NX_KEYTYPE_PREVIOUS
            }
        }
        #endif
    }

    public func seek(to fraction: Double) {
        #if !APP_STORE
        let clamped = max(0, min(1, fraction))
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeProvider == "Spotify", self.isAppRunning("com.spotify.client") {
                _ = self.runAppleScript("""
                tell application "Spotify"
                    set d to (duration of current track) / 1000
                    set player position to d * \(clamped)
                end tell
                """)
                self.poll()
            } else if self.activeProvider == "Music", self.isAppRunning("com.apple.Music") {
                _ = self.runAppleScript("""
                tell application "Music"
                    set d to duration of current track
                    set player position to d * \(clamped)
                end tell
                """)
                self.poll()
            }
        }
        #endif
    }

    // MARK: - Polling

    private func poll() {
        let activeProcs = ProcessAudioTap.listAudioProcesses().filter { $0.isRunningOutput }
        #if !APP_STORE
        let hidReady = Self.hasMediaKeyPermission

        if isAppRunning("com.spotify.client"), !deniedBundles.contains("com.spotify.client") {
            if let meta = querySpotify(), meta.isPlaying || activeProcs.isEmpty {
                activeProvider = "Spotify"
                emit(meta)
                return
            }
        }

        if isAppRunning("com.apple.Music"), !deniedBundles.contains("com.apple.Music") {
            if let meta = queryAppleMusic(), meta.isPlaying || activeProcs.isEmpty {
                activeProvider = "Music"
                emit(meta)
                return
            }
        }

        if let top = activeProcs.first {
            activeProvider = nil
            if top.bundleID == "com.google.Chrome", !deniedBundles.contains("com.google.Chrome"),
               let tabTitle = queryChromeTabTitle(), !tabTitle.isEmpty {
                emit(NowPlayingMetadata(
                    title: tabTitle,
                    subtitle: "Google Chrome · Tab Audio",
                    sourceApp: "CHROME",
                    isPlaying: true,
                    elapsed: nil,
                    duration: nil,
                    canSeek: false,
                    canControlPlayback: hidReady
                ))
                return
            }

            if top.bundleID == "com.apple.Safari", !deniedBundles.contains("com.apple.Safari"),
               let tabTitle = querySafariTabTitle(), !tabTitle.isEmpty {
                emit(NowPlayingMetadata(
                    title: tabTitle,
                    subtitle: "Safari · Tab Audio",
                    sourceApp: "SAFARI",
                    isPlaying: true,
                    elapsed: nil,
                    duration: nil,
                    canSeek: false,
                    canControlPlayback: hidReady
                ))
                return
            }

            let isMediaCapableApp = Self.isLikelyMediaApp(bundleID: top.bundleID)
            emit(NowPlayingMetadata(
                title: top.name,
                subtitle: "Live Process Tap · PID \(top.pid)",
                sourceApp: top.name.uppercased(),
                isPlaying: true,
                elapsed: nil,
                duration: nil,
                canSeek: false,
                canControlPlayback: hidReady && isMediaCapableApp
            ))
            return
        }
        #else
        if let top = activeProcs.first {
            activeProvider = nil
            emit(NowPlayingMetadata(
                title: top.name,
                subtitle: "Live Process Tap",
                sourceApp: top.name.uppercased(),
                isPlaying: true,
                elapsed: nil,
                duration: nil,
                canSeek: false,
                canControlPlayback: false
            ))
            return
        }
        #endif

        activeProvider = nil
        emit(.idle)
    }

    #if !APP_STORE

    private static func isLikelyMediaApp(bundleID: String?) -> Bool {
        guard let bid = bundleID?.lowercased() else { return false }
        let known = [
            "chrome", "safari", "firefox", "brave", "thebrowser", "edge", "opera",
            "spotify", "music", "tidal", "vlc", "iina", "quicktime", "podcasts", "sonos"
        ]
        return known.contains(where: { bid.contains($0) })
    }

    private func querySpotify() -> NowPlayingMetadata? {
        let script = """
        tell application "Spotify"
            set st to player state as string
            if st is "stopped" then return ""
            set tName to name of current track
            set tArtist to artist of current track
            set tDur to (duration of current track) / 1000
            set tPos to player position
            return st & "||" & tName & "||" & tArtist & "||" & tPos & "||" & tDur
        end tell
        """
        guard let out = runAppleScript(script, bundleID: "com.spotify.client"), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "||")
        guard parts.count >= 5 else { return nil }
        let playing = parts[0] == "playing"
        let title = parts[1]
        let artist = parts[2]
        return NowPlayingMetadata(
            title: artist.isEmpty ? title : "\(title) — \(artist)",
            subtitle: "Spotify",
            sourceApp: "SPOTIFY",
            isPlaying: playing,
            elapsed: Double(parts[3]),
            duration: Double(parts[4]),
            canSeek: true,
            canControlPlayback: true
        )
    }

    private func queryAppleMusic() -> NowPlayingMetadata? {
        let script = """
        tell application "Music"
            set st to player state as string
            if st is "stopped" then return ""
            set tName to name of current track
            set tArtist to artist of current track
            set tDur to duration of current track
            set tPos to player position
            return st & "||" & tName & "||" & tArtist & "||" & tPos & "||" & tDur
        end tell
        """
        guard let out = runAppleScript(script, bundleID: "com.apple.Music"), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "||")
        guard parts.count >= 5 else { return nil }
        let playing = parts[0] == "playing"
        let title = parts[1]
        let artist = parts[2]
        return NowPlayingMetadata(
            title: artist.isEmpty ? title : "\(title) — \(artist)",
            subtitle: "Apple Music",
            sourceApp: "APPLE MUSIC",
            isPlaying: playing,
            elapsed: Double(parts[3]),
            duration: Double(parts[4]),
            canSeek: true,
            canControlPlayback: true
        )
    }

    private func queryChromeTabTitle() -> String? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            return title of active tab of front window
        end tell
        """
        return runAppleScript(script, bundleID: "com.google.Chrome")
    }

    private func querySafariTabTitle() -> String? {
        let script = """
        tell application "Safari"
            if (count of windows) is 0 then return ""
            return name of current tab of front window
        end tell
        """
        return runAppleScript(script, bundleID: "com.apple.Safari")
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func runAppleScript(_ source: String, bundleID: String? = nil) -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errorDict)
        if let err = errorDict {
            if let code = err[NSAppleScript.errorNumber] as? Int, code == -1743, let bid = bundleID {
                Log.media.info("Automation declined for \(bid, privacy: .public); backing off silently")
                deniedBundles.insert(bid)
            }
            return nil
        }
        return result.stringValue
    }

    /// Posts a hardware-equivalent system media key event via CGEvent (requires Accessibility trust).
    private func sendHIDMediaKey(_ keyCode: Int32) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((keyCode << 16) | (down ? 0xa00 : 0xb00))
            guard let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent else { return }
            ev.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
    #endif

    private func emit(_ meta: NowPlayingMetadata) {
        let cb = onMetadataUpdate
        DispatchQueue.main.async { cb?(meta) }
    }
}
