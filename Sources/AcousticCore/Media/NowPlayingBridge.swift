#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import MediaPlayer

/// Native Apple MediaPlayer bridge so physical MacBook media keys (Play/Pause, Next, Previous),
/// AirPods stem taps, Lock Screen, Dynamic Island, and Control Center control Satie seamlessly
/// while focus audio is active, and release Control Center cleanly when stopped.
///
/// IMPORTANT (Swift 6 concurrency): MediaPlayer invokes BOTH `MPMediaItemArtwork`'s `requestHandler`
/// and `MPRemoteCommandCenter`'s `addTarget` blocks on its private background `accessQueue`.
/// This class intentionally avoids `@MainActor` class isolation so closures handed to Objective-C
/// MediaPlayer APIs never carry a Swift 6 main-executor assertion (`_swift_task_checkIsolatedSwift`).
public final class NowPlayingBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var isRegistered = false
    private var cachedArtwork: MPMediaItemArtwork?

    public init() {}

    /// Builds a thread-safe `MPMediaItemArtwork` backed by immutable PNG bytes so MediaPlayer can
    /// safely invoke the handler from its background `accessQueue` without tripping Swift 6 isolation checks.
    public static func makeArtwork(pngData: Data, boundsSize: CGSize = CGSize(width: 256, height: 256)) -> MPMediaItemArtwork {
        #if os(macOS)
        MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            NSImage(data: pngData) ?? NSImage(size: boundsSize)
        }
        #else
        MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            UIImage(data: pngData) ?? UIImage()
        }
        #endif
    }

    public func configureCommands(
        onPlay: @escaping @MainActor @Sendable () -> Void,
        onPause: @escaping @MainActor @Sendable () -> Void,
        onToggle: @escaping @MainActor @Sendable () -> Void,
        onNext: @escaping @MainActor @Sendable () -> Void,
        onPrevious: @escaping @MainActor @Sendable () -> Void
    ) {
        lock.lock()
        guard !isRegistered else {
            lock.unlock()
            return
        }
        isRegistered = true
        lock.unlock()

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

    @MainActor
    public func update(isPlaying: Bool, title: String, subtitle: String) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard isPlaying else {
            infoCenter.playbackState = .stopped
            infoCenter.nowPlayingInfo = nil
            return
        }

        lock.lock()
        var art = cachedArtwork
        lock.unlock()

        if art == nil {
            #if os(macOS)
            if let icon = NSApp.applicationIconImage,
               let tiff = icon.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let built = Self.makeArtwork(pngData: png)
                lock.lock()
                cachedArtwork = built
                art = built
                lock.unlock()
            }
            #else
            if let img = UIImage(named: "NowPlayingArt") ?? UIImage(named: "AppIcon"),
               let png = img.pngData() {
                let built = Self.makeArtwork(pngData: png, boundsSize: CGSize(width: 512, height: 512))
                lock.lock()
                cachedArtwork = built
                art = built
                lock.unlock()
            }
            #endif
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Satie",
            MPMediaItemPropertyAlbumTitle: subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if let art {
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
