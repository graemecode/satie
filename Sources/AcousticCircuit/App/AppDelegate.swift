import AcousticCore
import AppKit
import SwiftUI

private let wakeupNotificationName = Notification.Name("com.strangechances.AcousticCircuit.wakeup")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var menuBarIconView: MenuBarIconView!
    private var popover: NSPopover!
    private let miniHUD = MiniHUDPanelController()
    private let studio = StudioWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another Acoustic Circuit is already running, wake it and exit
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
        setupPopover()

        let state = AppState.shared
        state.onFrameTick = { [weak self] snap in
            guard let self else { return }
            let wantKey = state.showMenuBarKey && !snap.isSilent && snap.shortKey != "—"
            let desiredWidth: CGFloat = wantKey ? 76.0 : 38.0
            if abs(self.statusItem.length - desiredWidth) > 0.5 {
                self.statusItem.length = desiredWidth
                self.menuBarIconView.frame = NSRect(x: 0, y: 0, width: desiredWidth, height: 22)
            }
            self.menuBarIconView.update(snapshot: snap, showKey: state.showMenuBarKey)
        }

        state.boot()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        AppState.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openStudio(fullscreen: false)
        return true
    }

    @objc private func handleExternalWakeup() {
        openStudio(fullscreen: false)
    }

    // MARK: - Native macOS Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Acoustic Circuit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Acoustic Circuit", action: #selector(menuQuit), keyEquivalent: "q"))
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

    // MARK: - Status Bar & Popover

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 38)
        guard let button = statusItem.button else { return }

        menuBarIconView = MenuBarIconView(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        menuBarIconView.autoresizingMask = [.width, .height]
        button.addSubview(menuBarIconView)
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self

        let rootView = PopoverView(
            state: AppState.shared,
            onOpenMiniHUD: { [weak self] in self?.openMiniHUD() },
            onOpenStudio: { [weak self] in self?.openStudio(fullscreen: false) },
            onOpenFullscreen: { [weak self] in self?.openStudio(fullscreen: true) },
            onQuit: { NSApp.terminate(nil) }
        )
        p.contentViewController = NSHostingController(rootView: rootView)
        self.popover = p
    }

    // MARK: - Actions

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        AppState.shared.isPopoverOpen = true
    }

    private func closePopover() {
        popover.performClose(nil)
        AppState.shared.isPopoverOpen = false
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

        let keyToggle = NSMenuItem(title: "Show Musical Key in Menu Bar", action: #selector(menuToggleMenuBarKey), keyEquivalent: "")
        keyToggle.target = self
        keyToggle.state = state.showMenuBarKey ? .on : .off
        menu.addItem(keyToggle)

        if !MediaController.hasMediaKeyPermission {
            let mediaKeyItem = NSMenuItem(title: "Enable Global Media Keys (Accessibility)…", action: #selector(menuRequestMediaKeys), keyEquivalent: "")
            mediaKeyItem.target = self
            menu.addItem(mediaKeyItem)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = state.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "Quit Acoustic Circuit", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

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
    @objc private func menuToggleMenuBarKey() { AppState.shared.showMenuBarKey.toggle() }
    @objc private func menuRequestMediaKeys() { MediaController.requestMediaKeyPermission() }
    @objc private func menuToggleLaunchAtLogin() { AppState.shared.toggleLaunchAtLogin() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    func popoverDidClose(_ notification: Notification) {
        AppState.shared.isPopoverOpen = false
    }
}
