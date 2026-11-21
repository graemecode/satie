import AcousticCore
import AVKit
import SwiftUI

struct SatieiOSRootView: View {
    @ObservedObject var state: SatieiOSState

    @State private var showOptions: Bool = false
    @State private var immersionMode: Bool = false
    @Namespace private var visualPillNS

    private let timerPresets: [Int] = [0, 15, 25, 45, 60, 90]
    private let hair = Color.white.opacity(0.14)
    private let hairSoft = Color.white.opacity(0.09)
    private let inkSoft = Color.white.opacity(0.74)
    private let inkDim = Color.white.opacity(0.46)

    var body: some View {
        ZStack {
            // 1. Full-bleed edge-to-edge 120Hz Metal OLED stage
            iOSMetalVisualizerRepresentable(isActive: state.isForeground, preset: state.preset)
                .ignoresSafeArea()

            // Soundscape-matched whisper-subtle atmospheric light aura
            RadialGradient(
                colors: [soundscapeAuraColor.opacity(0.20), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.40),
                startRadius: 24,
                endRadius: 340
            )
            .blendMode(.screen)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.9), value: state.focusMode)
            .allowsHitTesting(false)

            // Soft top & bottom vignettes so chrome floats effortlessly over bright peaks
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.68), Color.black.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 150)

                Spacer()

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.84)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 310)
            }
            .ignoresSafeArea()
            .opacity(immersionMode ? 0.15 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: immersionMode)
            .allowsHitTesting(false)

            // Full-canvas touch surface: tap for Immersion Mode, swipe left/right to switch visualizations
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    state.performHaptic()
                    withAnimation(.easeInOut(duration: 0.28)) {
                        immersionMode.toggle()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 36, coordinateSpace: .local)
                        .onEnded { value in
                            if abs(value.translation.width) > abs(value.translation.height) * 1.4 {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    state.cycleVisual(forward: value.translation.width < 0)
                                }
                            }
                        }
                )

            // 2. Floating Editorial HUD (hides cleanly in Immersion Mode)
            VStack(spacing: 0) {
                // Top Header: Title + Acoustic Palette on left, quiet AirPlay picker on right
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.focusMode.title)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(heroSubtitle)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundColor(inkSoft)
                            .tracking(0.6)
                            .lineLimit(1)
                    }
                    .allowsHitTesting(false)

                    Spacer()

                    AirPlayRouteButton()
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(hairSoft, lineWidth: 1))
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                Spacer()

                // Bottom Tactile Control Dock (centered nicely on both iPhone & iPad)
                VStack(spacing: 20) {
                    // Frosted Visual Mode Switcher Pill (Circuit · Ecology · Scope · Liquid)
                    HStack(spacing: 2) {
                        ForEach(iOSVisualPreset.allCases) { p in
                            let selected = (state.preset == p)
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    state.preset = p
                                }
                                state.performHaptic()
                            } label: {
                                Text(p.cleanName)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .foregroundColor(selected ? .black : Color.white.opacity(0.74))
                                    .padding(.horizontal, 12)
                                    .frame(height: 26)
                                    .background {
                                        if selected {
                                            Capsule()
                                                .fill(Color.white)
                                                .matchedGeometryEffect(id: "iosVisualPill", in: visualPillNS)
                                        }
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .background(Color.black.opacity(0.50))
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8))

                    // Five Iconic Circular Geometric Soundscape Glyphs (FOCUS · PULSE · RAIN · STILL · NIGHT)
                    HStack(spacing: 0) {
                        ForEach(FocusSoundscape.allCases) { mode in
                            let isSelected = (state.focusMode == mode)
                            let isActive = state.isFocusPlaying && (state.focusMode == mode)
                            Button {
                                if isActive {
                                    state.stopFocusSound()
                                } else {
                                    state.toggleFocusSound(mode)
                                }
                            } label: {
                                VStack(spacing: 7) {
                                    SoundscapeGlyph(mode: mode, isActive: isActive, isSelected: isSelected, size: 46)
                                    Text(mode.shortLabel)
                                        .font(.system(size: 9.5, weight: isActive ? .semibold : .regular, design: .monospaced))
                                        .foregroundColor(isActive ? .white : (isSelected ? inkSoft : inkDim))
                                        .tracking(0.6)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Dead-Center Play / Pause + One Consolidated Options Button
                    HStack(spacing: 22) {
                        // Left wing: live countdown pill ONLY when a sleep timer is counting down
                        HStack {
                            if let countdown = compactCountdown {
                                Button {
                                    state.performHaptic()
                                    showOptions = true
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "timer")
                                            .font(.system(size: 12, weight: .medium))
                                        Text(countdown)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(hairSoft, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)

                        // Hero Pure-White Play / Pause Circle (dead center beneath RAIN)
                        Button {
                            state.togglePlayOrPause()
                        } label: {
                            Image(systemName: state.isFocusPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.black)
                                .offset(x: state.isFocusPlaying ? 0 : 2)
                                .frame(width: 64, height: 64)
                                .background(Color.white)
                                .clipShape(Circle())
                                .shadow(color: Color.white.opacity(state.isFocusPlaying ? 0.22 : 0.08), radius: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(state.isFocusPlaying ? "Pause \(state.focusMode.title)" : "Play \(state.focusMode.title)")

                        // Right wing: Single Consolidated Options Button
                        HStack {
                            Button {
                                state.performHaptic()
                                showOptions = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(Color.white.opacity(0.84))
                                        .frame(width: 44, height: 44)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(hair, lineWidth: 1))

                                    if state.maskingBed != .off || state.flowMinutes > 0 {
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 6, height: 6)
                                            .offset(x: -3, y: 3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Options")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
            .opacity(immersionMode ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.28), value: immersionMode)
            .allowsHitTesting(!immersionMode)
        }
        .sheet(isPresented: $showOptions) {
            optionsSheet
                .presentationDetents([.height(state.preset == .phosphor ? 345 : 295)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(red: 0.055, green: 0.062, blue: 0.078))
        }
    }

    // MARK: - Consolidated Native Options Sheet

    private var optionsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Sleep / Focus Timer
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("TIMER")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                        .tracking(0.8)
                    Spacer()
                    Text(timerStatusLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(state.flowMinutes > 0 ? .white : inkDim)
                }

                HStack(spacing: 6) {
                    ForEach(timerPresets, id: \.self) { mins in
                        let on = state.flowMinutes == mins
                        Button {
                            state.setFlowMinutes(mins)
                            state.performHaptic()
                        } label: {
                            Text(mins == 0 ? "∞" : "\(mins)m")
                                .font(.system(size: 12, weight: on ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(on ? .black : inkSoft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(on ? Color.white : Color.white.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Optional Background Noise Layer
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BACKGROUND NOISE")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                        .tracking(0.8)
                    Text("Layer gentle rain or brown noise under any mode")
                        .font(.system(size: 12))
                        .foregroundColor(inkDim)
                }

                HStack(spacing: 6) {
                    ForEach(MaskingBed.allCases) { bed in
                        let on = state.maskingBed == bed
                        Button {
                            state.maskingBed = bed
                            state.performHaptic()
                        } label: {
                            Text(bed.label)
                                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                                .foregroundColor(on ? .black : inkSoft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(on ? Color.white : Color.white.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if state.preset == .phosphor {
                HStack {
                    Text("CRT PHOSPHOR")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                        .tracking(0.8)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach([(false, "P31 Emerald"), (true, "P39 Amber")], id: \.0) { isAmber, label in
                            let on = state.amberPhosphor == isAmber
                            Button {
                                state.amberPhosphor = isAmber
                                state.performHaptic()
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: on ? .semibold : .regular, design: .monospaced))
                                    .foregroundColor(on ? .black : inkSoft)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(on ? Color.white : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider().overlay(hairSoft)

            Toggle(isOn: $state.keepScreenAwake) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KEEP SCREEN AWAKE")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                        .tracking(0.8)
                    Text("Keep the visual display glowing on a desk or stand")
                        .font(.system(size: 12))
                        .foregroundColor(inkDim)
                }
            }
            .tint(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    private var heroSubtitle: String {
        let base = state.focusMode.subtitle.uppercased()
        if state.isFocusPlaying && state.maskingBed != .off {
            return "\(base) · +\(state.maskingBed.label.uppercased())"
        }
        return base
    }

    private var compactCountdown: String? {
        guard state.isFocusPlaying, let rem = state.flowRemainingSeconds else { return nil }
        let sec = max(0, Int(ceil(rem)))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private var timerStatusLabel: String {
        if let countdown = compactCountdown {
            return "\(countdown) REMAINING"
        }
        return state.flowMinutes > 0 ? "FADES OUT AFTER \(state.flowMinutes)M" : "NO LIMIT"
    }

    private var soundscapeAuraColor: Color {
        guard state.isFocusPlaying else {
            return Color(red: 0.72, green: 0.80, blue: 0.92)
        }
        switch state.focusMode {
        case .focus: return Color(red: 1.00, green: 0.78, blue: 0.52)
        case .pulse: return Color(red: 0.62, green: 0.78, blue: 1.00)
        case .rain:  return Color(red: 0.52, green: 0.82, blue: 0.84)
        case .still: return Color(red: 0.78, green: 0.82, blue: 0.88)
        case .drift: return Color(red: 0.92, green: 0.84, blue: 0.74)
        }
    }
}

private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.75)
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
