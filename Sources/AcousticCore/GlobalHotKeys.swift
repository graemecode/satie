import Carbon
import Foundation

public enum GlobalHotKeyAction: UInt32, CaseIterable, Sendable {
    case togglePanel = 1      // ⌥⌘S
    case togglePlayStop = 2   // ⌥⌘Space
    case cycleMode = 3        // ⌥⌘]
    case toggleMute = 4       // ⌥⌘M

    public var shortcutLabel: String {
        switch self {
        case .togglePanel: return "⌥⌘S"
        case .togglePlayStop: return "⌥⌘Space"
        case .cycleMode: return "⌥⌘]"
        case .toggleMute: return "⌥⌘M"
        }
    }
}

/// Sanctioned macOS Carbon global hotkey registrar (`RegisterEventHotKey`).
/// Works system-wide across all apps with ZERO Accessibility or Input Monitoring permissions.
@MainActor
public final class GlobalHotKeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var handler: ((GlobalHotKeyAction) -> Void)?

    private static let signature: OSType = 0x53415449 // 'SATI'

    public init() {}

    public func register(onAction: @escaping (GlobalHotKeyAction) -> Void) {
        unregister()
        self.handler = onAction

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
                    return noErr
                }
                if let action = GlobalHotKeyAction(rawValue: hotKeyID.id) {
                    let mgr = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        mgr.handler?(action)
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else {
            Log.app.error("Failed to install Carbon global hotkey handler: \(status)")
            return
        }

        let mods = UInt32(cmdKey | optionKey)
        let bindings: [(GlobalHotKeyAction, UInt32)] = [
            (.togglePanel, UInt32(kVK_ANSI_S)),
            (.togglePlayStop, UInt32(kVK_Space)),
            (.cycleMode, UInt32(kVK_ANSI_RightBracket)),
            (.toggleMute, UInt32(kVK_ANSI_M)),
        ]

        for (action, keyCode) in bindings {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let regStatus = RegisterEventHotKey(
                keyCode,
                mods,
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if regStatus == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                Log.app.info("Global hotkey \(action.shortcutLabel, privacy: .public) unavailable (status \(regStatus))")
            }
        }
        Log.app.info("Registered \(self.hotKeyRefs.count) global hotkeys")
    }

    public func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let h = eventHandlerRef {
            RemoveEventHandler(h)
            eventHandlerRef = nil
        }
        handler = nil
    }
}
