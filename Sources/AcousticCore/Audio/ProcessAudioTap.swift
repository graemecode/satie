import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

public struct AudioProcessInfo: Identifiable, Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let isRunningOutput: Bool

    public var id: AudioObjectID { objectID }

    public init(objectID: AudioObjectID, pid: pid_t, name: String, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public enum TapTarget: Hashable, Sendable {
    case systemAll
    case process(AudioProcessInfo)

    public var displayLabel: String {
        switch self {
        case .systemAll:
            return "SYSTEM OUTPUT (ALL)"
        case .process(let proc):
            return "\(proc.name.uppercased()) (PID \(proc.pid))"
        }
    }

    public var shortLabel: String {
        switch self {
        case .systemAll:
            return "SYSTEM OUTPUT"
        case .process(let proc):
            return proc.name.uppercased()
        }
    }
}

public enum TapStatus: Equatable, Sendable {
    case stopped
    case sleeping
    case active(sampleRate: Double, channels: Int)
    case permissionOrError(String)
}

/// Production-hardened driverless Core Audio Process Tap (macOS 14.2+) with automatic
/// output-device switching, sleep/wake recovery, and terminated-process fallback.
public final class ProcessAudioTap: @unchecked Sendable {
    public let ringBuffer: StereoRingBuffer

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let stateLock = NSLock()
    private let lifecycleQueue = DispatchQueue(label: "com.strangechances.AcousticCircuit.tapLifecycle", qos: .userInitiated)

    private var currentTarget: TapTarget = .systemAll
    private var isSleeping = false
    private var hasInstalledListeners = false
    private var defaultOutListener: AudioObjectPropertyListenerBlock?
    private var sysOutListener: AudioObjectPropertyListenerBlock?
    private var reattachWorkItem: DispatchWorkItem?
    private var terminatedObserver: NSObjectProtocol?

    public private(set) var sampleRate: Double = 48_000
    public private(set) var status: TapStatus = .stopped

    public var onStatusChange: ((TapStatus) -> Void)?
    public var onTargetFallback: ((TapTarget) -> Void)?

    public init(ringBuffer: StereoRingBuffer = StereoRingBuffer()) {
        self.ringBuffer = ringBuffer
    }

    deinit {
        uninstallListeners()
        stop()
    }

    // MARK: - Process Enumeration

    public static func listAudioProcesses() -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objectIDs) == noErr else {
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var results: [AudioProcessInfo] = []
        results.reserveCapacity(count)

        for oid in objectIDs {
            guard let pid = readPID(for: oid), pid != selfPID else { continue }
            let runningOut = readBool(for: oid, selector: kAudioProcessPropertyIsRunningOutput)
            let rawBundleID = readString(for: oid, selector: kAudioProcessPropertyBundleID)
            let runningApp = NSRunningApplication(processIdentifier: pid)

            if let bid = rawBundleID, bid.hasPrefix("com.apple.audio") || bid.hasPrefix("com.apple.coreaudio") { continue }
            if !runningOut && runningApp == nil { continue }

            let execPath = Self.executablePath(for: pid)
            let resolved = Self.resolveAppIdentity(
                runningAppName: runningApp?.localizedName,
                runningAppBundleID: runningApp?.bundleIdentifier,
                executablePath: execPath,
                rawBundleID: rawBundleID,
                pid: pid
            )

            results.append(AudioProcessInfo(
                objectID: oid,
                pid: pid,
                name: resolved.name,
                bundleID: resolved.bundleID,
                isRunningOutput: runningOut
            ))
        }

        return results.sorted { a, b in
            if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Resolves child helper processes (e.g. `com.google.Chrome.helper`, Electron Helpers, WebKit GPU)
    /// back to their enclosing macOS parent app name & bundle ID.
    public static func resolveAppIdentity(
        runningAppName: String? = nil,
        runningAppBundleID: String? = nil,
        executablePath: String?,
        rawBundleID: String?,
        pid: pid_t = 0
    ) -> (name: String, bundleID: String?) {
        // 1. Walk up the executable path to the outermost `.app` bundle (handles Chrome/Electron/Arc/Brave helpers)
        if let path = executablePath, let appPath = outermostAppBundlePath(from: path) {
            let bundle = Bundle(path: appPath)
            let bName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            let bID = bundle?.bundleIdentifier ?? stripHelperSuffix(from: rawBundleID)
            if !bName.isEmpty {
                return (bName, bID)
            }
        }

        // 2. Known WebKit / system browser media helpers
        if let raw = rawBundleID {
            if raw.hasPrefix("com.apple.WebKit") {
                return ("Safari", "com.apple.Safari")
            }
            if let stripped = stripHelperSuffix(from: raw) {
                if let parentApp = NSRunningApplication.runningApplications(withBundleIdentifier: stripped).first,
                   let locName = parentApp.localizedName, !locName.isEmpty {
                    return (locName, stripped)
                }
                if stripped == "com.google.Chrome" { return ("Google Chrome", stripped) }
                if stripped == "company.thebrowser.Browser" { return ("Arc", stripped) }
                if stripped == "com.brave.Browser" { return ("Brave Browser", stripped) }
                if stripped == "com.microsoft.edgemac" { return ("Microsoft Edge", stripped) }
                if stripped == "com.spotify.client" { return ("Spotify", stripped) }
                let fallback = stripped.components(separatedBy: ".").last ?? stripped
                return (fallback, stripped)
            }
        }

        // 3. Direct top-level NSRunningApplication
        if let name = runningAppName, !name.isEmpty {
            return (name, runningAppBundleID ?? rawBundleID)
        }

        if let raw = rawBundleID, let last = raw.components(separatedBy: ".").last, !last.isEmpty {
            return (last, raw)
        }
        return ("PID \(pid)", rawBundleID)
    }

    public static func outermostAppBundlePath(from executablePath: String) -> String? {
        let components = (executablePath as NSString).pathComponents
        for (idx, comp) in components.enumerated() {
            if comp.hasSuffix(".app") {
                return NSString.path(withComponents: Array(components[0...idx]))
            }
        }
        return nil
    }

    private static func stripHelperSuffix(from bundleID: String?) -> String? {
        guard let raw = bundleID else { return nil }
        let patterns = [".helper.renderer", ".helper.gpu", ".helper.plugin", ".helper.audio", ".helper", ".Helper"]
        for suffix in patterns {
            if raw.hasSuffix(suffix) {
                return String(raw.dropLast(suffix.count))
            }
        }
        return nil
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return nil }
        let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func selfAudioProcessObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var oid: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &oid
        )
        return (err == noErr && oid != kAudioObjectUnknown) ? oid : nil
    }

    public static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        if err != noErr || devID == kAudioObjectUnknown {
            addr.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice
            err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        }
        guard err == noErr, devID != kAudioObjectUnknown else { return nil }
        return readString(for: devID, selector: kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Lifecycle

    public func start(target: TapTarget = .systemAll) {
        installListenersIfNeeded()
        lifecycleQueue.async { [weak self] in
            self?.startSync(target: target)
        }
    }

    public func stop() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.reattachWorkItem?.cancel()
            self.reattachWorkItem = nil
            self.teardownLocked()
            self.setStatusLocked(.stopped)
            self.stateLock.unlock()
        }
    }

    public func pauseForSleep() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.isSleeping = true
            self.reattachWorkItem?.cancel()
            self.teardownLocked()
            self.ringBuffer.clear()
            self.setStatusLocked(.sleeping)
            self.stateLock.unlock()
            Log.audio.info("ProcessAudioTap paused for sleep")
        }
    }

    public func resumeFromSleep() {
        lifecycleQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.isSleeping = false
            let target = self.currentTarget
            self.stateLock.unlock()
            Log.audio.info("ProcessAudioTap resuming after wake")
            self.startSync(target: target)
        }
    }

    private func scheduleReattach(reason: String) {
        stateLock.lock()
        guard !isSleeping else {
            stateLock.unlock()
            return
        }
        reattachWorkItem?.cancel()
        let target = currentTarget
        let item = DispatchWorkItem { [weak self] in
            Log.audio.info("Re-attaching Core Audio Process Tap (reason: \(reason, privacy: .public))")
            self?.startSync(target: target)
        }
        reattachWorkItem = item
        stateLock.unlock()
        lifecycleQueue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func startSync(target: TapTarget) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isSleeping else { return }
        teardownLocked()
        currentTarget = target
        ringBuffer.clear()

        let tapDesc: CATapDescription
        switch target {
        case .systemAll:
            let excluded: [AudioObjectID] = Self.selfAudioProcessObjectID().map { [$0] } ?? []
            tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .process(let proc):
            tapDesc = CATapDescription(stereoMixdownOfProcesses: [proc.objectID])
        }

        let tapUUID = UUID()
        tapDesc.uuid = tapUUID
        tapDesc.name = "AcousticCircuitTap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapErr == noErr, newTapID != kAudioObjectUnknown else {
            let msg = "Process Tap failed (OSStatus \(tapErr)). Grant System Audio Recording permission."
            Log.audio.error("\(msg, privacy: .public)")
            setStatusLocked(.permissionOrError(msg))
            return
        }
        self.tapID = newTapID

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(newTapID, &formatAddr, 0, nil, &formatSize, &format) == noErr,
           format.mSampleRate > 0 {
            self.sampleRate = format.mSampleRate
        } else {
            self.sampleRate = 48_000
        }

        let aggUID = "com.strangechances.AcousticCircuit.agg.\(UUID().uuidString)"
        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AcousticCircuitTapDevice",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        if let outUID = Self.defaultOutputDeviceUID() {
            aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outUID]
            ]
        }

        var newAggID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggErr == noErr, newAggID != kAudioObjectUnknown else {
            teardownLocked()
            let msg = "Aggregate device failed (OSStatus \(aggErr))"
            Log.audio.error("\(msg, privacy: .public)")
            setStatusLocked(.permissionOrError(msg))
            return
        }
        self.aggregateDeviceID = newAggID

        let rb = self.ringBuffer
        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, newAggID, nil) { _, inInputData, _, _, _ in
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !bufferList.isEmpty else { return }

            if bufferList.count >= 2,
               bufferList[0].mNumberChannels == 1,
               bufferList[1].mNumberChannels == 1,
               let ptr0 = bufferList[0].mData?.assumingMemoryBound(to: Float.self),
               let ptr1 = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
                let f0 = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
                let f1 = Int(bufferList[1].mDataByteSize) / MemoryLayout<Float>.size
                let frames = min(f0, f1)
                rb.writePlanar(leftSrc: ptr0, rightSrc: ptr1, frameCount: frames)
            } else if let ptr = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
                let channels = max(1, Int(bufferList[0].mNumberChannels))
                let totalFloats = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
                let frames = totalFloats / channels
                rb.writeInterleaved(ptr, frameCount: frames, channels: channels)
            }
        }

        guard ioErr == noErr, let validProcID = procID else {
            teardownLocked()
            let msg = "IOProc setup failed (OSStatus \(ioErr))"
            Log.audio.error("\(msg, privacy: .public)")
            setStatusLocked(.permissionOrError(msg))
            return
        }
        self.ioProcID = validProcID

        let startErr = AudioDeviceStart(newAggID, validProcID)
        guard startErr == noErr else {
            teardownLocked()
            let msg = "AudioDeviceStart failed (OSStatus \(startErr)). Check System Audio Recording permission."
            Log.audio.error("\(msg, privacy: .public)")
            setStatusLocked(.permissionOrError(msg))
            return
        }

        let channels = max(2, Int(format.mChannelsPerFrame))
        Log.audio.info("ProcessAudioTap active: \(target.displayLabel, privacy: .public) @ \(Int(self.sampleRate))Hz (\(channels)ch)")
        setStatusLocked(.active(sampleRate: self.sampleRate, channels: channels))
    }

    private func teardownLocked() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateDeviceID, proc)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func setStatusLocked(_ newStatus: TapStatus) {
        status = newStatus
        let cb = onStatusChange
        DispatchQueue.main.async { cb?(newStatus) }
    }

    // MARK: - Hardware Output Change & Process Termination Listeners

    private func installListenersIfNeeded() {
        stateLock.lock()
        guard !hasInstalledListeners else {
            stateLock.unlock()
            return
        }
        hasInstalledListeners = true
        stateLock.unlock()

        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReattach(reason: "default output device changed")
        }
        defaultOutListener = outBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddr, lifecycleQueue, outBlock)

        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReattach(reason: "system output device changed")
        }
        sysOutListener = sysBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &sysAddr, lifecycleQueue, sysBlock)

        terminatedObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let exitedPID = app.processIdentifier
            self.stateLock.lock()
            let shouldFallback: Bool
            if case .process(let proc) = self.currentTarget, proc.pid == exitedPID {
                shouldFallback = true
            } else {
                shouldFallback = false
            }
            self.stateLock.unlock()
            if shouldFallback {
                Log.audio.info("Isolated app PID \(exitedPID) exited; falling back to System Output (All)")
                self.start(target: .systemAll)
                let cb = self.onTargetFallback
                DispatchQueue.main.async { cb?(.systemAll) }
            }
        }
    }

    private func uninstallListeners() {
        if let block = defaultOutListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, lifecycleQueue, block)
            defaultOutListener = nil
        }
        if let block = sysOutListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, lifecycleQueue, block)
            sysOutListener = nil
        }
        if let obs = terminatedObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            terminatedObserver = nil
        }
    }

    // MARK: - Core Audio Property Helpers

    private static func readPID(for oid: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(oid, &addr, 0, nil, &size, &pid)
        return err == noErr ? pid : nil
    }

    private static func readBool(for oid: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(oid, &addr, 0, nil, &size, &val)
        return err == noErr && val != 0
    }

    private static func readString(for oid: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(oid, &addr, 0, nil, &size, &cfStr)
        guard err == noErr, let str = cfStr?.takeRetainedValue() else { return nil }
        return str as String
    }
}
