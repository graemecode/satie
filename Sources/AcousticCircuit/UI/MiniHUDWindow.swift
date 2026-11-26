import AcousticCore
import AppKit
import SwiftUI

struct MiniHUDContentView: View {
    @ObservedObject var state: AppState
    let onExpandStudio: () -> Void
    let onExpandFullscreen: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private let hair = Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.24)

    var body: some View {
        ZStack {
            MetalVisualizerRepresentable(compactMode: true, isActive: state.isMiniHUDOpen)

            VStack {
                HStack {
                    Text(state.displayKey)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.78))
                    Spacer()
                    Text(String(format: "E %.2f", state.displayEnergy))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.54))
                }

                Spacer()

                if isHovering {
                    HStack(spacing: 5) {
                        if state.canTogglePrimaryPlayback {
                            Button {
                                state.togglePrimaryPlayback()
                            } label: {
                                Image(systemName: state.isPrimaryPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 9.5))
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(HUDChipButtonStyle())
                        }

                        Button {
                            state.stepFocusMode(forward: true)
                        } label: {
                            Text(state.focusMode.title)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                        }
                        .buttonStyle(HUDChipButtonStyle())

                        Spacer()

                        Button(action: onExpandStudio) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 9.5))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(HUDChipButtonStyle())
                        .help(SatieL10n.string("hud.open_studio"))

                        Button(action: onExpandFullscreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9.5))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(HUDChipButtonStyle())
                        .help(SatieL10n.string("menu.fullscreen"))

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(HUDChipButtonStyle())
                        .help(SatieL10n.string("hud.close"))
                    }
                    .transition(.opacity)
                }
            }
            .padding(10)
        }
        .frame(width: 286, height: 214)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(hair, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
    }
}

struct HUDChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(Color(red: 0.03, green: 0.05, blue: 0.09).opacity(configuration.isPressed ? 0.92 : 0.72))
            .overlay(Rectangle().stroke(Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.28), lineWidth: 0.75))
    }
}

@MainActor
final class MiniHUDPanelController {
    private var panel: NSPanel?

    func show(onExpandStudio: @escaping () -> Void, onExpandFullscreen: @escaping () -> Void, onClose: @escaping () -> Void) {
        if let existing = panel {
            existing.orderFrontRegardless()
            AppState.shared.isMiniHUDOpen = true
            return
        }

        let content = MiniHUDContentView(
            state: AppState.shared,
            onExpandStudio: onExpandStudio,
            onExpandFullscreen: onExpandFullscreen,
            onClose: { [weak self] in
                self?.close()
                onClose()
            }
        )

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 214),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: content)

        if let saved = AppState.shared.settings.miniHUDOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -120, dy: -120).contains(saved) }) {
            p.setFrameOrigin(saved)
        } else if let screen = NSScreen.main?.visibleFrame {
            let x = screen.maxX - 286 - 26
            let y = screen.minY + 26
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()
        self.panel = p
        AppState.shared.isMiniHUDOpen = true
    }

    func close() {
        if let origin = panel?.frame.origin {
            AppState.shared.settings.miniHUDOrigin = origin
        }
        panel?.orderOut(nil)
        panel = nil
        AppState.shared.isMiniHUDOpen = false
    }
}
