import AppKit
import Foundation
import MediaPlayer

/// Native Apple MediaPlayer bridge so physical MacBook media keys (Play/Pause, Next, Previous),
/// AirPods stem taps, and macOS Control Center control Satie seamlessly while focus audio is active,
/// and release Control Center cleanly when stopped or auto-ducked.
@MainActor
public final class NowPlayingBridge {
    private var isRegistered = false
    private var cachedArtwork: MPMediaItemArtwork?

    public init() {}

    public func configureCommands(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void
    ) {
        guard !isRegistered else { return }
        isRegistered = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { _ in
            Task { @MainActor in onPlay() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in onPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in onToggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in onNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in onPrevious() }
            return .success
        }
    }

    public func update(isPlaying: Bool, title: String, subtitle: String) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard isPlaying else {
            infoCenter.playbackState = .stopped
            infoCenter.nowPlayingInfo = nil
            return
        }

        if cachedArtwork == nil, let icon = NSApp.applicationIconImage {
            cachedArtwork = MPMediaItemArtwork(boundsSize: CGSize(width: 256, height: 256)) { _ in icon }
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Satie",
            MPMediaItemPropertyAlbumTitle: subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if let art = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = .playing
    }

    public func clear() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
    }
}
