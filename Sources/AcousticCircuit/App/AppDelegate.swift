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
    private var lastMeasuredPopoverHeight: CGFloat = 0
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
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
            let s = AppState.shared
            self?.menuBarIconView.update(snapshot: snap, isPlaying: s.isFocusPlaying, isMuted: s.isSystemMuted)
        }
        state.$isSystemMuted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] muted in
                let s = AppState.shared
                self?.menuBarIconView.update(snapshot: s.snapshot, isPlaying: s.isFocusPlaying, isMuted: muted)
            }
            .store(in: &layoutCancellables)
        state.$isFocusPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                let s = AppState.shared
                self?.menuBarIconView.update(snapshot: s.snapshot, isPlaying: playing, isMuted: s.isSystemMuted)
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
            state.$isStatusItemBehindNotch.removeDuplicates(),
            state.$preset.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            guard let self, self.floatingPanel.isVisible else { return }
            DispatchQueue.main.async {
                self.repositionFloatingPanel()
            }
        }
        .store(in: &layoutCancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.floatingPanel.isVisible else { return }
                self.repositionFloatingPanel()
            }
        }

        state.boot()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
        removeDismissMonitors()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
        AppState.shared.shutdown()
    }

    // MARK: - Handoff: continue a session started on an iPhone or iPad

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == SatieHandoff.activityType
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == SatieHandoff.activityType,
              let session = SatieHandoff(userInfo: userActivity.userInfo) else { return false }
        AppState.shared.continueHandoff(session)
        return true
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
        appMenu.addItem(NSMenuItem(title: SatieL10n.string("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: SatieL10n.string("menu.quit"), action: #selector(menuQuit), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Window / View Menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: SatieL10n.string("menu.view"))

        let closeItem = NSMenuItem(title: SatieL10n.string("menu.close_window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        viewMenu.addItem(closeItem)

        let miniItem = NSMenuItem(title: SatieL10n.string("menu.floating_mini_hud"), action: #selector(menuOpenMiniHUD), keyEquivalent: "m")
        miniItem.target = self
        viewMenu.addItem(miniItem)

        let fsItem = NSMenuItem(title: SatieL10n.string("menu.toggle_fullscreen"), action: #selector(menuOpenFullscreen), keyEquivalent: "f")
        fsItem.target = self
        viewMenu.addItem(fsItem)

        viewMenu.addItem(.separator())
        for (index, mode) in FocusSoundscape.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(menuSelectSoundscape(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            item.tag = index + 1
            viewMenu.addItem(item)
        }

        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar & Notch-Safe Floating Panel

    private func setupMenuBar() {
        // Match standard macOS 22pt square status item width (38pt total with system margins instead of 44pt)
        // so Satie stays visible in crowded notched MacBook menu bars.
        statusItem = NSStatusBar.system.statusItem(withLength: 22)
        statusItem.autosaveName = "SatieStatusItem"
        guard let button = statusItem.button else { return }

        menuBarIconView = MenuBarIconView(frame: button.bounds)
        menuBarIconView.autoresizingMask = [.width, .height]
        button.addSubview(menuBarIconView)
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = SatieL10n.string("statusbar.tooltip")
    }

    private func setupFloatingPanel() {
        let rootView = PopoverView(
            state: AppState.shared,
            onOpenMiniHUD: { [weak self] in self?.openMiniHUD() },
            onOpenStudio: { [weak self] in self?.openStudio(fullscreen: false) },
            onOpenFullscreen: { [weak self] in self?.openStudio(fullscreen: true) },
            onQuit: { NSApp.terminate(nil) },
            onRequestResize: { [weak self] in self?.repositionFloatingPanel() },
            onContentHeightChange: { [weak self] height in
                self?.handlePopoverContentHeightChange(height)
            }
        )

        let hc = NSHostingController(rootView: rootView)
        // Own the panel frame exclusively in repositionFloatingPanel() so AppKit never auto-grows
        // the borderless panel upward behind the menu bar or fights SwiftUI height updates.
        hc.sizingOptions = []
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
                case "1", "2", "3", "4", "5", "6": AppState.shared.selectFocusMode(number: Int(chars) ?? 0); return true
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

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        floatingPanel.alphaValue = reduceMotion ? 1.0 : 0.0
        NSApp.activate(ignoringOtherApps: true)
        floatingPanel.orderFrontRegardless()
        floatingPanel.makeKey()

        // Animate opacity ONLY (never `animator().setFrame`), so a frame animation can never clobber
        // a SwiftUI intrinsic height update (such as the notch hint appearing/disappearing on open).
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                floatingPanel.animator().alphaValue = 1.0
            }
        }

        // Re-verify exact layout on the next runloop turn after SwiftUI commits any state diff from open.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.floatingPanel.isVisible else { return }
            self.repositionFloatingPanel()
        }
        installDismissMonitors()
    }

    private func handlePopoverContentHeightChange(_ newHeight: CGFloat) {
        let rounded = ceil(newHeight)
        guard rounded >= 240 else { return }
        lastMeasuredPopoverHeight = rounded
        guard floatingPanel.isVisible else { return }
        repositionFloatingPanel(preferredHeight: rounded)
    }

    private func repositionFloatingPanel(preferredHeight: CGFloat? = nil) {
        let btnWindow = statusItem.button?.window
        let screen = btnWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        // Use the full status item window frame (including macOS's 8pt horizontal padding) so Control Center's
        // notch-collision boundary is detected accurately even when only the padded edge touches the notch.
        let statusItemRect: CGRect?
        let isStatusItemWindowVisible: Bool
        if let win = btnWindow, win.frame.width > 1, win.frame.height > 1 {
            statusItemRect = win.frame
            // When the menu bar itself is visible (not auto-hidden in fullscreen), an occluded status-item
            // window means Control Center hid the icon because the menu bar overflowed into the notch.
            let menuBarVisible = (screen.frame.maxY - screen.visibleFrame.maxY) >= 18
            isStatusItemWindowVisible = menuBarVisible ? win.occlusionState.contains(.visible) : true
        } else {
            statusItemRect = nil
            isStatusItemWindowVisible = false
        }

        // Update notch-occlusion state FIRST before measuring panel height so SwiftUI includes/excludes the notch hint.
        let occluded = MenuBarPositioner.isStatusItemOccluded(
            buttonScreenRect: statusItemRect,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea,
            isWindowVisible: isStatusItemWindowVisible
        )
        let occlusionChanged = AppState.shared.isStatusItemBehindNotch != occluded
        if occlusionChanged {
            AppState.shared.isStatusItemBehindNotch = occluded
        }

        let panelWidth: CGFloat = 392
        let fitted = hostingController.sizeThatFits(
            in: CGSize(width: panelWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let rawHeight: CGFloat
        if let preferredHeight, preferredHeight >= 240 {
            rawHeight = preferredHeight
        } else if fitted.height >= 240 {
            rawHeight = fitted.height
        } else if lastMeasuredPopoverHeight >= 240 {
            rawHeight = lastMeasuredPopoverHeight
        } else {
            rawHeight = 352
        }

        let maxAllowedHeight = max(320, screen.visibleFrame.height - 20)
        let size = CGSize(
            width: panelWidth,
            height: min(max(320, ceil(rawHeight)), maxAllowedHeight)
        )

        let placement = MenuBarPositioner.computePlacement(
            buttonScreenRect: statusItemRect,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea,
            panelSize: size,
            isStatusItemWindowVisible: isStatusItemWindowVisible
        )

        let targetFrame = NSRect(origin: placement.origin, size: size)
        if !floatingPanel.frame.equalTo(targetFrame) {
            floatingPanel.setFrame(targetFrame, display: true, animate: false)
        }
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
        // Defer one runloop turn so the borderless menu-bar panel finishes ordering out cleanly before Studio activates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.studio.show(fullscreen: fullscreen) { [weak self] in
                self?.openMiniHUD()
            }
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        let state = AppState.shared

        let playTitle = state.isFocusPlaying
            ? SatieL10n.format("common.pause_mode", state.focusMode.title)
            : SatieL10n.format("common.play_mode", state.focusMode.title)
        let playItem = NSMenuItem(title: "\(playTitle)  (⌥⌘Space)", action: #selector(menuTogglePlay), keyEquivalent: "")
        playItem.target = self
        menu.addItem(playItem)

        let soundItem = NSMenuItem(title: SatieL10n.string("menu.soundscape"), action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for mode in FocusSoundscape.allCases {
            let sItem = NSMenuItem(title: mode.title, action: #selector(menuToggleSoundscape(_:)), keyEquivalent: "")
            sItem.target = self
            sItem.representedObject = mode.rawValue
            sItem.state = (state.isFocusPlaying && state.focusMode == mode) ? .on : .off
            soundMenu.addItem(sItem)
        }
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        menu.addItem(.separator())

        let studioItem = NSMenuItem(title: SatieL10n.string("menu.studio_window"), action: #selector(menuOpenStudio), keyEquivalent: "")
        studioItem.target = self
        menu.addItem(studioItem)

        let miniItem = NSMenuItem(title: SatieL10n.string("menu.mini_hud"), action: #selector(menuOpenMiniHUD), keyEquivalent: "")
        miniItem.target = self
        menu.addItem(miniItem)

        let fsItem = NSMenuItem(title: SatieL10n.string("menu.fullscreen"), action: #selector(menuOpenFullscreen), keyEquivalent: "")
        fsItem.target = self
        menu.addItem(fsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: SatieL10n.string("menu.launch_at_login"), action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = state.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: SatieL10n.string("menu.quit"), action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuTogglePlay() { AppState.shared.togglePlayOrStartFocus() }
    @objc private func menuOpenStudio() { openStudio(fullscreen: false) }
    @objc private func menuOpenMiniHUD() { openMiniHUD() }
    @objc private func menuOpenFullscreen() { openStudio(fullscreen: true) }
    @objc private func menuSelectSoundscape(_ sender: NSMenuItem) {
        AppState.shared.selectFocusMode(number: sender.tag)
    }
    @objc private func menuToggleSoundscape(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = FocusSoundscape(rawValue: raw) {
            AppState.shared.toggleFocusSound(mode)
        }
    }
    @objc private func menuToggleLaunchAtLogin() { AppState.shared.toggleLaunchAtLogin() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
