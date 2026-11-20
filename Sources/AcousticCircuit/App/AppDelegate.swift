import AcousticCore
import AppKit
import Combine
import SwiftUI

private let wakeupNotificationName = Notification.Name("com.strangechances.Satie.wakeup")

/// Borderless, notch-safe floating panel replacing NSPopover so Satie NEVER renders
/// behind a MacBook camera notch or off the top edge of the display.
final class SatieFloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onSpace: (() -> Void)?
    var onKeyAction: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        if event.keyCode == 49 { // Space -> instant play/stop/mute
            onSpace?()
            return
        }
        if let handled = onKeyAction?(event), handled {
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuBarIconView: MenuBarIconView!
    private var floatingPanel: SatieFloatingPanel!
    private var hostingController: NSHostingController<PopoverView>!
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var layoutCancellables: Set<AnyCancellable> = []
    private let hotKeys = GlobalHotKeyManager()

    private let miniHUD = MiniHUDPanelController()
    private let studio = StudioWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another Satie is already running, wake it and exit
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    wakeupNotificationName,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                others.first?.activate()
                NSApp.terminate(nil)
                return
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalWakeup),
            name: wakeupNotificationName,
            object: nil
        )

        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        setupMainMenu()
        setupMenuBar()
        setupFloatingPanel()

        let state = AppState.shared
        state.onFrameTick = { [weak self] snap in
            self?.menuBarIconView.update(snapshot: snap, isMuted: AppState.shared.isSystemMuted)
        }
        state.$isSystemMuted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] muted in
                self?.menuBarIconView.update(snapshot: AppState.shared.snapshot, isMuted: muted)
            }
            .store(in: &layoutCancellables)

        // Register zero-permission Carbon global hotkeys (⌥⌘S, ⌥⌘Space, ⌥⌘], ⌥⌘M)
        hotKeys.register { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePanel:
                self.togglePopover()
            case .togglePlayStop:
                AppState.shared.togglePlayOrStartFocus()
            case .cycleMode:
                AppState.shared.cycleFocusMode(forward: true)
            case .toggleMute:
                AppState.shared.toggleSystemMute()
            }
        }

        // Keep panel height crisp and anchored downward whenever expandable rows appear/disappear
        Publishers.CombineLatest3(
            state.$isFocusPlaying.removeDuplicates(),
            state.$tapStatus.map { if case .permissionOrError = $0 { return true } else { return false } }.removeDuplicates(),
            state.$isStatusItemBehindNotch.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            guard let self, self.floatingPanel.isVisible else { return }
            DispatchQueue.main.async {
                self.repositionFloatingPanel()
            }
        }
        .store(in: &layoutCancellables)

        state.boot()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
        removeDismissMonitors()
        DistributedNotificationCenter.default().removeObserver(self)
        AppState.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    @objc private func handleExternalWakeup() {
        showPopover()
    }

    // MARK: - Native macOS Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Satie", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Satie", action: #selector(menuQuit), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Window / View Menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        viewMenu.addItem(closeItem)

        let miniItem = NSMenuItem(title: "Floating Mini HUD", action: #selector(menuOpenMiniHUD), keyEquivalent: "m")
        miniItem.target = self
        viewMenu.addItem(miniItem)

        let fsItem = NSMenuItem(title: "Toggle Fullscreen", action: #selector(menuOpenFullscreen), keyEquivalent: "f")
        fsItem.target = self
        viewMenu.addItem(fsItem)

        viewMenu.addItem(.separator())
        for preset in VisualPreset.allCases {
            let pItem = NSMenuItem(title: preset.title, action: #selector(menuSelectPreset(_:)), keyEquivalent: "\(preset.rawValue + 1)")
            pItem.keyEquivalentModifierMask = [.command]
            pItem.target = self
            pItem.tag = preset.rawValue
            viewMenu.addItem(pItem)
        }

        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar & Notch-Safe Floating Panel

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "SatieStatusItem"
        guard let button = statusItem.button else { return }

        menuBarIconView = MenuBarIconView(frame: button.bounds)
        menuBarIconView.autoresizingMask = [.width, .height]
        button.addSubview(menuBarIconView)
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Satie — Click to open · ⌥-Click to stop/mute · Right-click for menu"
    }

    private func setupFloatingPanel() {
        let rootView = PopoverView(
            state: AppState.shared,
            onOpenMiniHUD: { [weak self] in self?.openMiniHUD() },
            onOpenStudio: { [weak self] in self?.openStudio(fullscreen: false) },
            onOpenFullscreen: { [weak self] in self?.openStudio(fullscreen: true) },
            onQuit: { NSApp.terminate(nil) },
            onRequestResize: { [weak self] in self?.repositionFloatingPanel() }
        )

        let hc = NSHostingController(rootView: rootView)
        hc.sizingOptions = [.preferredContentSize]
        self.hostingController = hc

        let panel = SatieFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 392, height: 410),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = hc
        panel.onEscape = { [weak self] in self?.closePopover() }
        panel.onSpace = { AppState.shared.togglePlayOrStartFocus() }
        panel.onKeyAction = { [weak self] event in
            guard let self else { return false }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if mods == .command {
                if chars == "m" { self.openMiniHUD(); return true }
                if chars == "f" { self.openStudio(fullscreen: true); return true }
                if chars == "q" { NSApp.terminate(nil); return true }
            }
            if mods.isEmpty {
                switch chars {
                case "1": AppState.shared.preset = .circuit; AppState.shared.performHaptic(); return true
                case "2": AppState.shared.preset = .ecology; AppState.shared.performHaptic(); return true
                case "3": AppState.shared.preset = .phosphor; AppState.shared.performHaptic(); return true
                case "4": AppState.shared.preset = .liquid; AppState.shared.performHaptic(); return true
                case "m": AppState.shared.toggleSystemMute(); return true
                default: break
                }
                if event.keyCode == 126 { // Up arrow
                    AppState.shared.adjustFocusVolume(delta: 0.08); return true
                }
                if event.keyCode == 125 { // Down arrow
                    AppState.shared.adjustFocusVolume(delta: -0.08); return true
                }
            }
            return false
        }
        self.floatingPanel = panel
    }

    // MARK: - Actions

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else if event.modifierFlags.contains(.option) {
            AppState.shared.stopPlayingAudioImmediately()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if floatingPanel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        AppState.shared.isPopoverOpen = true
        repositionFloatingPanel()
        let finalFrame = floatingPanel.frame
        var startFrame = finalFrame
        startFrame.origin.y += 5
        floatingPanel.alphaValue = 0.0
        floatingPanel.setFrame(startFrame, display: false)
        NSApp.activate(ignoringOtherApps: true)
        floatingPanel.orderFrontRegardless()
        floatingPanel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            floatingPanel.animator().alphaValue = 1.0
            floatingPanel.animator().setFrame(finalFrame, display: true)
        }
        installDismissMonitors()
    }

    private func repositionFloatingPanel() {
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        let size = CGSize(
            width: max(392, ceil(fitting.width)),
            height: max(320, ceil(fitting.height))
        )

        let btnWindow = statusItem.button?.window
        let screen = btnWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let btnRect: CGRect?
        if let btn = statusItem.button, let win = btn.window {
            let inWin = btn.convert(btn.bounds, to: nil)
            btnRect = win.convertToScreen(inWin)
        } else {
            btnRect = nil
        }

        let placement = MenuBarPositioner.computePlacement(
            buttonScreenRect: btnRect,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea,
            panelSize: size
        )

        if AppState.shared.isStatusItemBehindNotch != placement.statusItemOccludedByNotch {
            AppState.shared.isStatusItemBehindNotch = placement.statusItemOccludedByNotch
        }

        floatingPanel.setFrame(NSRect(origin: placement.origin, size: size), display: true, animate: false)
    }

    private func closePopover() {
        removeDismissMonitors()
        floatingPanel.orderOut(nil)
        AppState.shared.isPopoverOpen = false
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.floatingPanel.isVisible else { return event }
            if let win = event.window, win !== self.floatingPanel, win !== self.statusItem.button?.window {
                self.closePopover()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let g = globalMouseMonitor {
            NSEvent.removeMonitor(g)
            globalMouseMonitor = nil
        }
        if let l = localMouseMonitor {
            NSEvent.removeMonitor(l)
            localMouseMonitor = nil
        }
    }

    private func openMiniHUD() {
        closePopover()
        studio.close()
        miniHUD.show(
            onExpandStudio: { [weak self] in self?.openStudio(fullscreen: false) },
            onExpandFullscreen: { [weak self] in self?.openStudio(fullscreen: true) },
            onClose: {}
        )
    }

    private func openStudio(fullscreen: Bool) {
        closePopover()
        miniHUD.close()
        studio.show(fullscreen: fullscreen) { [weak self] in
            self?.openMiniHUD()
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        let state = AppState.shared

        let stopTitle: String
        if state.isFocusPlaying {
            stopTitle = "Stop \(state.focusMode.title)"
        } else if state.metadata.canControlPlayback && state.metadata.isPlaying {
            stopTitle = "Pause \(state.metadata.sourceApp)"
        } else {
            stopTitle = state.isSystemMuted ? "Unmute Mac Audio" : "Mute Mac Audio"
        }
        let stopNowItem = NSMenuItem(title: "\(stopTitle)  (⌥⌘Space)", action: #selector(menuStopImmediately), keyEquivalent: "")
        stopNowItem.target = self
        menu.addItem(stopNowItem)

        let summonItem = NSMenuItem(title: "Show Satie Panel  (⌥⌘S)", action: #selector(menuSummonPanel), keyEquivalent: "")
        summonItem.target = self
        menu.addItem(summonItem)

        menu.addItem(.separator())

        let openStudioItem = NSMenuItem(title: "Open Studio Window", action: #selector(menuOpenStudio), keyEquivalent: "")
        openStudioItem.target = self
        menu.addItem(openStudioItem)

        let miniItem = NSMenuItem(title: "Floating Mini HUD", action: #selector(menuOpenMiniHUD), keyEquivalent: "")
        miniItem.target = self
        menu.addItem(miniItem)

        let fsItem = NSMenuItem(title: "Fullscreen Wall", action: #selector(menuOpenFullscreen), keyEquivalent: "")
        fsItem.target = self
        menu.addItem(fsItem)

        menu.addItem(.separator())

        for preset in VisualPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(menuSelectPreset(_:)), keyEquivalent: "\(preset.rawValue + 1)")
            item.target = self
            item.tag = preset.rawValue
            item.state = state.preset == preset ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Work Soundscape submenu
        let soundItem = NSMenuItem(title: "Work Soundscape", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for mode in FocusSoundscape.allCases {
            let sItem = NSMenuItem(title: mode.title, action: #selector(menuToggleSoundscape(_:)), keyEquivalent: "")
            sItem.target = self
            sItem.representedObject = mode.rawValue
            sItem.state = (state.isFocusPlaying && state.focusMode == mode) ? .on : .off
            soundMenu.addItem(sItem)
        }
        if state.isFocusPlaying {
            soundMenu.addItem(.separator())
            let stopItem = NSMenuItem(title: "Stop Soundscape", action: #selector(menuStopSoundscape), keyEquivalent: "")
            stopItem.target = self
            soundMenu.addItem(stopItem)
        }
        soundMenu.addItem(.separator())
        let duckItem = NSMenuItem(title: "Auto-Duck for Calls & Media", action: #selector(menuToggleAutoDuck), keyEquivalent: "")
        duckItem.target = self
        duckItem.state = state.autoDuckEnabled ? .on : .off
        soundMenu.addItem(duckItem)
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        // Sensitivity submenu
        let sensItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let sensMenu = NSMenu()
        for mode in SensitivityMode.allCases {
            let mItem = NSMenuItem(title: mode.label, action: #selector(menuSelectSensitivity(_:)), keyEquivalent: "")
            mItem.target = self
            mItem.representedObject = mode.rawValue
            mItem.state = state.sensitivity == mode ? .on : .off
            sensMenu.addItem(mItem)
        }
        sensItem.submenu = sensMenu
        menu.addItem(sensItem)

        #if !APP_STORE
        if !MediaController.hasMediaKeyPermission {
            let mediaKeyItem = NSMenuItem(title: "Enable Browser Play/Pause (Accessibility)…", action: #selector(menuRequestMediaKeys), keyEquivalent: "")
            mediaKeyItem.target = self
            menu.addItem(mediaKeyItem)
        }
        #endif

        menu.addItem(.separator())

        let feedbackItem = NSMenuItem(title: "Send Feedback…", action: #selector(menuSendFeedback), keyEquivalent: "")
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        let privacyItem = NSMenuItem(title: "Privacy Policy", action: #selector(menuPrivacyPolicy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = state.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "Quit Satie", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuStopImmediately() { AppState.shared.stopPlayingAudioImmediately() }
    @objc private func menuSummonPanel() { showPopover() }
    @objc private func menuOpenStudio() { openStudio(fullscreen: false) }
    @objc private func menuOpenMiniHUD() { openMiniHUD() }
    @objc private func menuOpenFullscreen() { openStudio(fullscreen: true) }
    @objc private func menuSelectPreset(_ sender: NSMenuItem) {
        if let p = VisualPreset(rawValue: sender.tag) {
            AppState.shared.preset = p
        }
    }
    @objc private func menuSelectSensitivity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = SensitivityMode(rawValue: raw) {
            AppState.shared.sensitivity = mode
        }
    }
    @objc private func menuToggleSoundscape(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = FocusSoundscape(rawValue: raw) {
            AppState.shared.toggleFocusSound(mode)
        }
    }
    @objc private func menuStopSoundscape() { AppState.shared.stopFocusSound() }
    @objc private func menuToggleAutoDuck() { AppState.shared.autoDuckEnabled.toggle() }
    @objc private func menuRequestMediaKeys() { MediaController.requestMediaKeyPermission() }
    @objc private func menuSendFeedback() {
        if let url = URL(string: "https://github.com/graemecode/satie/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func menuPrivacyPolicy() {
        if let url = URL(string: "https://strangechances.com/satie/privacy/") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func menuToggleLaunchAtLogin() { AppState.shared.toggleLaunchAtLogin() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
