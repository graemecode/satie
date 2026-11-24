import Foundation

/// Formally verified (TLA+ / TLC) state machine governing the macOS Studio window & Metal renderer lifecycle.
/// Eliminates four TLC-proven freeze classes:
/// 1. `updateNSView` 250ms telemetry thrashing (`isPaused` toggle + sync `draw()` inside SwiftUI layout)
/// 2. Fullscreen `toggleFullScreen` + synchronous `orderOut` zombie Space deadlock
/// 3. Reopening a minimized Studio window without `deminiaturize`
/// 4. Post-sleep/wake dead `CVDisplayLink` with no recovery signal
public struct StudioLifecycleMachine: Sendable, Equatable {
    public enum WindowState: String, Sendable, Equatable {
        case none
        case hidden
        case visible
        case minimized
        case fullscreen
        case exitingFullscreen
    }

    public enum Effect: Sendable, Equatable {
        case createAndShowWindow(fullscreen: Bool)
        case deminiaturizeAndShow(fullscreen: Bool)
        case orderFrontWindow(fullscreen: Bool)
        case orderOutWindow
        case requestToggleFullscreen
        case setMetalActive(Bool)
        case recoverMetalIfStalled
    }

    public private(set) var winState: WindowState = .none
    public private(set) var isStudioOpen: Bool = false
    public private(set) var isFullscreen: Bool = false
    public private(set) var metalActive: Bool = false
    public private(set) var pendingCloseAfterFullScreenExit: Bool = false

    public init() {}

    /// User requests opening Studio (from Popover, Mini HUD, menu, or hotkey).
    public mutating func requestOpen(fullscreen: Bool) -> [Effect] {
        pendingCloseAfterFullScreenExit = false
        switch winState {
        case .none:
            winState = .visible
            isStudioOpen = true
            metalActive = true
            return [.createAndShowWindow(fullscreen: fullscreen), .setMetalActive(true), .recoverMetalIfStalled]

        case .hidden:
            winState = .visible
            isStudioOpen = true
            metalActive = true
            return [.orderFrontWindow(fullscreen: fullscreen), .setMetalActive(true), .recoverMetalIfStalled]

        case .minimized:
            winState = .visible
            isStudioOpen = true
            metalActive = true
            return [.deminiaturizeAndShow(fullscreen: fullscreen), .setMetalActive(true), .recoverMetalIfStalled]

        case .visible:
            isStudioOpen = true
            metalActive = true
            return [.orderFrontWindow(fullscreen: fullscreen), .setMetalActive(true), .recoverMetalIfStalled]

        case .fullscreen:
            isStudioOpen = true
            metalActive = true
            return [.orderFrontWindow(fullscreen: false), .setMetalActive(true), .recoverMetalIfStalled]

        case .exitingFullscreen:
            // Cancel deferred close so when macOS finishes exiting fullscreen, the window stays visible and live
            isStudioOpen = true
            return []
        }
    }

    /// Programmatic close (e.g. switching from Studio to Mini HUD).
    /// Never calls `orderOut` synchronously while in fullscreen (prevents zombie Space deadlock).
    public mutating func requestClose() -> [Effect] {
        switch winState {
        case .none, .hidden:
            isStudioOpen = false
            isFullscreen = false
            metalActive = false
            return []

        case .fullscreen:
            winState = .exitingFullscreen
            pendingCloseAfterFullScreenExit = true
            return [.requestToggleFullscreen]

        case .exitingFullscreen:
            pendingCloseAfterFullScreenExit = true
            return []

        case .visible, .minimized:
            winState = .hidden
            isStudioOpen = false
            isFullscreen = false
            metalActive = false
            pendingCloseAfterFullScreenExit = false
            return [.setMetalActive(false), .orderOutWindow]
        }
    }

    /// OS delegate callback: user clicked red traffic light / ⌘W.
    public mutating func handleWindowWillClose() -> [Effect] {
        winState = .hidden
        isStudioOpen = false
        isFullscreen = false
        metalActive = false
        pendingCloseAfterFullScreenExit = false
        return [.setMetalActive(false)]
    }

    /// OS delegate callback: user clicked yellow minimize button.
    public mutating func handleWindowDidMiniaturize() -> [Effect] {
        guard winState == .visible else { return [] }
        winState = .minimized
        metalActive = false
        return [.setMetalActive(false)]
    }

    /// OS delegate callback: user restored minimized window from Dock or `deminiaturize`.
    public mutating func handleWindowDidDeminiaturize() -> [Effect] {
        winState = .visible
        isStudioOpen = true
        metalActive = true
        return [.setMetalActive(true), .recoverMetalIfStalled]
    }

    /// OS delegate callback: window entered native macOS Fullscreen Space.
    public mutating func handleDidEnterFullScreen() -> [Effect] {
        winState = .fullscreen
        isFullscreen = true
        isStudioOpen = true
        metalActive = true
        return [.setMetalActive(true), .recoverMetalIfStalled]
    }

    /// OS delegate callback: window began exiting Fullscreen Space.
    public mutating func handleWillExitFullScreen() {
        if winState == .fullscreen {
            winState = .exitingFullscreen
        }
    }

    /// OS delegate callback: macOS completed the async Fullscreen exit transition.
    public mutating func handleDidExitFullScreen() -> [Effect] {
        isFullscreen = false
        if pendingCloseAfterFullScreenExit {
            pendingCloseAfterFullScreenExit = false
            winState = .hidden
            isStudioOpen = false
            metalActive = false
            return [.setMetalActive(false), .orderOutWindow]
        } else {
            winState = .visible
            isStudioOpen = true
            metalActive = true
            return [.setMetalActive(true), .recoverMetalIfStalled]
        }
    }

    /// SwiftUI 250ms telemetry refresh — strictly idempotent NO-OP when desired active state is unchanged.
    public mutating func handleSwiftUISync(isActive: Bool) -> [Effect] {
        guard metalActive != isActive else { return [] }
        metalActive = isActive
        return [.setMetalActive(isActive)]
    }

    /// macOS system or display wake — triggers stall recovery if visible.
    public mutating func handleSystemWake() -> [Effect] {
        guard (winState == .visible || winState == .fullscreen), isStudioOpen else { return [] }
        metalActive = true
        return [.setMetalActive(true), .recoverMetalIfStalled]
    }
}
