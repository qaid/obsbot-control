// ObsbotApp.swift — menubar app controlling an OBSBOT Meet 2 via the vendored VVUVCKit framework.
//
// Route (A): we call VVUVCController directly from Swift through a bridging header.
// Chosen because it gives live two-way binding (read real values on open, write on drag)
// with no subprocess latency, and the same framework is already proven by the CLI.
//
// ponytail: single file, one ObservableObject + one view. No MVVM ceremony for one panel.

import SwiftUI
import AppKit
import AVFoundation
import IOKit
import IOKit.usb
import CoreAudio
import ServiceManagement

// MARK: - Device discovery (duplicated tiny IOKit lookup from main.m, translated to Swift)

let obsbotVID = 13668
let obsbotPID = 65275

func findOBSBOTLocationID() -> UInt32 {
    let matching = IOServiceMatching(kIOUSBDeviceClassName)
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iter) }

    var locationID: UInt32 = 0
    while case let device = IOIteratorNext(iter), device != 0 {
        defer { IOObjectRelease(device) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let vid = (prop("idVendor") as? Int) ?? 0
        let pid = (prop("idProduct") as? Int) ?? 0
        var matches = (vid == obsbotVID && pid == obsbotPID)
        if !matches, let name = prop("USB Product Name") as? String {
            matches = name.localizedCaseInsensitiveContains("OBSBOT") || name.localizedCaseInsensitiveContains("Meet 2")
        }
        if matches, let loc = prop("locationID") as? UInt32 {
            locationID = loc
            break
        }
    }
    return locationID
}

func findOBSBOTProductName() -> String {
    let matching = IOServiceMatching(kIOUSBDeviceClassName)
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return "OBSBOT" }
    defer { IOObjectRelease(iter) }
    while case let device = IOIteratorNext(iter), device != 0 {
        defer { IOObjectRelease(device) }
        if let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
           name.localizedCaseInsensitiveContains("OBSBOT") {
            return name
        }
    }
    return "OBSBOT"
}

// MARK: - Audio device discovery (ported from main.m's CoreAudio helpers)

func findOBSBOTAudioDeviceID() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return 0 }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return 0 }

    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() as String? else { continue }
        guard name.localizedCaseInsensitiveContains("OBSBOT") else { continue }

        // Confirm it has input channels.
        var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

        return id
    }
    return 0
}

func audioHasProperty(_ objID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
    return AudioObjectHasProperty(objID, &address)
}

func audioGetVolume(_ objID: AudioObjectID) -> Float32 {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    AudioObjectGetPropertyData(objID, &address, 0, nil, &size, &value)
    return value
}

func audioSetVolume(_ objID: AudioObjectID, _ value: Float32) {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
    var v = value
    AudioObjectSetPropertyData(objID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

func audioGetMute(_ objID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(objID, &address, 0, nil, &size, &value)
    return value == 1
}

func audioSetMute(_ objID: AudioObjectID, _ mute: Bool) {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = mute ? 1 : 0
    AudioObjectSetPropertyData(objID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
}

// MARK: - Model

enum PreviewState {
    case idle          // panel closed, session stopped
    case starting      // session configured, waiting for first frame
    case running       // frames flowing
    case denied        // camera permission denied
    case inUse         // device present but feed unavailable (another app holds it)
    case unavailable   // no OBSBOT capture device found
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var connected = false
    @Published var deviceName = "OBSBOT"

    @Published var zoom: Double = 0
    @Published var exposure: Double = 100
    @Published var whiteBalance: Double = 5000
    @Published var brightness: Double = 50

    @Published var zoomRange: ClosedRange<Double> = 0...100
    @Published var exposureRange: ClosedRange<Double> = 1...2500
    @Published var whiteBalanceRange: ClosedRange<Double> = 2000...10000
    @Published var brightnessRange: ClosedRange<Double> = 0...100

    @Published var autoMode = true

    // MARK: Mic (CoreAudio, mirrors the CLI's OBSBOT audio device lookup)
    @Published var micAvailable = false
    @Published var micVolume: Double = 100   // 0-100
    @Published var micMuted = false
    private var audioDeviceID: AudioObjectID = 0

    // MARK: Mic level meter (separate AVCaptureSession tapping the OBSBOT mic's audio channel)
    // ponytail: AVCaptureAudioChannel.averagePowerLevel is peak-ish dBFS already smoothed by
    // AVFoundation internally; polling it on a timer is far simpler than writing our own
    // RMS/peak accumulator over raw CMSampleBuffers, and it's plenty accurate for a UI meter.
    @Published var micLevel: Double = 0 // 0...1, smoothed (fast attack / slow release)
    private let audioSession = AVCaptureSession()
    private var audioSessionConfigured = false
    private var audioChannel: AVCaptureAudioChannel?
    private var levelTimer: Timer?

    // MARK: Keep-mic-live-during-calls (opt-in; independent of panel visibility)
    // ponytail: the OBSBOT Meet 2's mic only carries real audio while the video stream is open
    // (confirmed live) — otherwise it reports as a healthy device but sends silence. This holds a
    // dedicated, hidden, output-less video session open exactly while (a) the user opted in AND
    // (b) some app is actually capturing the mic, so the camera light isn't on any more than needed.
    // DELIBERATELY NOT gated by `visiblePanels`: the whole point is to keep working while the panel/
    // popover is closed and the user is on a call elsewhere. Do not add a visiblePanels guard here.
    @Published var keepMicLiveDuringCalls: Bool = UserDefaults.standard.bool(forKey: "keepMicLiveDuringCalls") {
        didSet { UserDefaults.standard.set(keepMicLiveDuringCalls, forKey: "keepMicLiveDuringCalls") }
    }

    // MARK: Launch at login (SMAppService; source of truth is SMAppService.mainApp.status, NOT
    // UserDefaults — it must stay correct across reboots and reflect changes made in System
    // Settings > General > Login Items, neither of which a persisted bool would track.)
    private static var isLoginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }
    @Published var launchAtLogin: Bool = CameraModel.isLoginItemEnabled
    private let keepAliveSession = AVCaptureSession()
    // Seconds to keep the mic-alive stream open after IsRunningSomewhere goes false, so a brief
    // probe/release or a switch between call apps doesn't force a teardown+rebuild. Tunable.
    private let keepAliveStopDelay: TimeInterval = 3
    private var keepAliveConfigured = false
    private var keepAliveRunning = false
    // Cancellable hold-off before actually stopping the keep-alive session when
    // IsRunningSomewhere goes false, so a brief probe/release or a switch between call apps
    // doesn't tear the stream down and rebuild it.
    private var pendingKeepAliveStop: DispatchWorkItem?
    private var micRunningSomewhereListenerInstalled = false
    // CoreAudio matches AudioObjectRemovePropertyListenerBlock to Add by exact block reference,
    // so the actual registered block (and the device ID it was registered against) must be kept
    // around for removal — a freshly-allocated closure at remove time is a silent no-op and leaks
    // the listener.
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var micListenerDeviceID: AudioObjectID = 0
    private let micListenerQueue = DispatchQueue.global(qos: .utility)

    private var controller: VVUVCController?

    // MARK: Preview (one AVCaptureSession owned by the model, shared by popover and pinned window)
    @Published var previewState: PreviewState = .idle
    let session = AVCaptureSession()
    private var sessionConfigured = false
    private var loggedFirstFrame = false
    var previewMirrorApplied = false // set once mirror is confirmed; reset in stopPreview so a fresh session re-applies
    private var frameTimeoutWork: DispatchWorkItem?
    private let videoQueue = DispatchQueue(label: "obsbot.preview") // sample-buffer delegate callbacks ONLY
    // ponytail: all AVCaptureSession mutation (beginConfiguration/addInput/addOutput/
    // commitConfiguration/startRunning/stopRunning) for ALL THREE sessions (preview, mic-meter,
    // keep-alive) goes through this single serial queue. Previously configuration ran on main
    // while startRunning/stopRunning ran on videoQueue, so AVFoundation could enumerate a
    // session's connections on one thread while another thread mutated it — that's the
    // "mutated a collection while enumerating" NSFastEnumerationMutation abort that crashed the
    // app. One shared serial queue for lifecycle, kept separate from videoQueue (which only
    // receives frames), removes the race without introducing new ones between the three sessions.
    private let sessionQueue = DispatchQueue(label: "obsbot.sessionLifecycle")

    // MARK: Pin (floating detached window)
    @Published var pinned = false
    private var pinWindow: NSWindow?

    // MARK: Escape-to-close
    // ponytail: one local keyDown monitor (keyCode 53 == Escape) covers both display modes
    // instead of subclassing NSWindow/NSView for cancelOperation(_:) — simpler, and it's already
    // scoped to "a panel is visible" via the same visiblePanels lifecycle as the preview/meter,
    // so it's not a global always-on hook and never intercepts a hypothetical future text field
    // (there are none today) beyond the Escape key itself.
    private var escapeMonitor: Any?

    // Shared handle so the AppDelegate's reopen handler (a separate object from the SwiftUI
    // App's @StateObject) can reach the live model. Weak: the StateObject owns it, this must not
    // extend its lifetime or form a cycle.
    static weak var current: CameraModel?

    override init() {
        super.init()
        CameraModel.current = self
        // Read real values at launch so a headless run proves the camera link works (logged to stderr).
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
    }

    // Reference-count panel appearances: the popover and the pinned window share the session.
    private var visiblePanels = 0
    func panelAppeared() {
        visiblePanels += 1
        if visiblePanels == 1 {
            startPreview()
            startMicLevelMeter()
            installEscapeMonitor()
        }
    }
    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        if visiblePanels == 0 {
            stopPreview()
            stopMicLevelMeter()
            removeEscapeMonitor()
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // 53 == Escape
            self.handleEscape()
            return nil // swallow so it doesn't beep/propagate further
        }
        FileHandle.standardError.write("esc: monitor installed\n".data(using: .utf8)!)
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        escapeMonitor = nil
    }

    private func handleEscape() {
        if pinned {
            // Same path as clicking the pin button to unpin: keeps `pinned` and the popover's
            // dismissal logic coherent instead of just calling pinWindow?.close() directly.
            setPinned(false)
            FileHandle.standardError.write("esc: unpinned floating window\n".data(using: .utf8)!)
        } else {
            for w in NSApp.windows where w.isVisible && w.className.contains("MenuBarExtra") {
                w.close()
            }
            if let key = NSApp.keyWindow, key !== pinWindow {
                key.close()
            }
            FileHandle.standardError.write("esc: dismissed popover\n".data(using: .utf8)!)
        }
    }

    func startPreview() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startPreviewAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    granted ? self.startPreviewAuthorized() : (self.previewState = .denied)
                }
            }
        default:
            previewState = .denied
        }
    }

    private func findCaptureDevice() -> AVCaptureDevice? {
        // ponytail: .externalUnknown is deprecated on 14+ but is the only external type on our 13.0 target.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        return discovery.devices.first { $0.localizedName.localizedCaseInsensitiveContains("OBSBOT") }
    }

    private func startPreviewAuthorized() {
        guard visiblePanels > 0 else { return } // panel may have closed while permission prompt was up
        previewState = .starting
        loggedFirstFrame = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.sessionConfigured {
                guard let device = self.findCaptureDevice() else {
                    DispatchQueue.main.async { self.previewState = .unavailable }
                    return
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw NSError(domain: "obsbot", code: 1) }
                    self.session.addInput(input)
                } catch {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.previewState = .inUse } // couldn't attach: someone else holds the device
                    return
                }
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: self.videoQueue)
                if self.session.canAddOutput(output) { self.session.addOutput(output) }
                self.session.commitConfiguration()
                self.sessionConfigured = true
            }
            self.session.startRunning()
        }

        // No frames within 5s -> provisionally show "in use by another app". This is only a guess:
        // a frame arriving later flips the state back to .running (see captureOutput), because a real
        // frame is proof the camera is ours and working. The OBSBOT Meet 2's first frame can lag a
        // few seconds on a cold start (sensor/light warm-up), so the window is generous to avoid a
        // spurious "in use" flash before the preview appears.
        frameTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewState == .starting else { return }
            self.previewState = .inUse
        }
        frameTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    func stopPreview() {
        frameTimeoutWork?.cancel()
        sessionQueue.async { self.session.stopRunning() }
        previewState = .idle
        previewMirrorApplied = false // reset so the next preview session re-applies mirroring
    }

    // ponytail: attaching a preview layer to the session is a session-GRAPH mutation
    // (AVCaptureVideoPreviewLayer(session:) internally runs begin/commitConfiguration). Doing it on
    // the main thread while startRunning enumerates the session's connections on sessionQueue is the
    // NSFastEnumerationMutation abort that crashed on the second popover open. So the layer is built
    // empty on main (CALayer geometry keeps its main-thread affinity) and its `session` is assigned
    // here on sessionQueue, serialized against every other session mutation. Async, never sync:
    // callers are on the main thread and sessionQueue.sync would deadlock.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async { layer.session = self.session }
    }

    // Mirror the DISPLAYED preview only (selfie-view); capture output to other apps must be untouched.
    // AVCaptureVideoPreviewLayer manages its own `transform` internally and overrides/ignores a
    // manually-set layer transform, so that route silently does nothing (confirmed: preview stayed
    // unmirrored). Instead we mirror via the preview layer's AVCaptureConnection (`isVideoMirrored`),
    // which only affects what's displayed, not the session's captured/output frames. If the
    // connection isn't available yet or doesn't support mirroring, we fall back to flipping the HOST
    // NSView's layer (not the preview layer) via `sublayerTransform`, which the preview layer can't
    // override since it's the parent's transform, not its own.
    //
    // Mirror config touches the preview layer's AVCaptureConnection, a session-graph mutation, so it
    // runs on sessionQueue too. The host-view fallback is pure CALayer geometry and hops back to
    // main. Idempotent: re-called on every updateNSView pass until the connection exists, then
    // early-returns once mirrored.
    func applyPreviewMirror(to layer: AVCaptureVideoPreviewLayer, hostView: NSView) {
        sessionQueue.async {
            if let connection = layer.connection, connection.isVideoMirroringSupported {
                if connection.isVideoMirrored {
                    // already applied; mark confirmed so updateNSView stops dispatching
                    DispatchQueue.main.async { self.previewMirrorApplied = true }
                    return
                }
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
                FileHandle.standardError.write("mirror: connection.isVideoMirrored=\(connection.isVideoMirrored)\n".data(using: .utf8)!)
                DispatchQueue.main.async { self.previewMirrorApplied = true }
            } else {
                DispatchQueue.main.async {
                    guard hostView.layer?.sublayerTransform.m11 != -1 else { return }
                    hostView.layer?.sublayerTransform = CATransform3DMakeScale(-1, 1, 1)
                    FileHandle.standardError.write("mirror: applied container transform (connection unavailable or unsupported)\n".data(using: .utf8)!)
                    self.previewMirrorApplied = true
                }
            }
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        DispatchQueue.main.async { self.previewState = .inUse }
    }

    // MARK: Mic level meter

    private func findAudioCaptureDevice() -> AVCaptureDevice? {
        // ponytail: .microphone (AVCaptureDevice.DeviceType) needs macOS 14+; our 13.0 deployment
        // target uses AVCaptureDevice.devices(for:) instead, which enumerates all audio input
        // devices without a type filter.
        AVCaptureDevice.devices(for: .audio)
            .first { $0.localizedName.localizedCaseInsensitiveContains("OBSBOT") }
    }

    func startMicLevelMeter() {
        guard micAvailable else { return } // no OBSBOT audio device: hide/skip gracefully
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        FileHandle.standardError.write("meter: mic authorization status=\(status.rawValue)\n".data(using: .utf8)!)
        switch status {
        case .authorized:
            startMicLevelMeterAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.startMicLevelMeterAuthorized() } }
            }
        default:
            break // denied/restricted: meter just stays at 0, no crash
        }
    }

    private func startMicLevelMeterAuthorized() {
        guard visiblePanels > 0 else { return } // panel may have closed while permission prompt was up
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.audioSessionConfigured {
                guard let device = self.findAudioCaptureDevice() else { return }
                self.audioSession.beginConfiguration()
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.audioSession.canAddInput(input) else { throw NSError(domain: "obsbot", code: 2) }
                    self.audioSession.addInput(input)
                } catch {
                    self.audioSession.commitConfiguration()
                    return
                }
                let output = AVCaptureAudioDataOutput()
                if self.audioSession.canAddOutput(output) { self.audioSession.addOutput(output) }
                self.audioSession.commitConfiguration()
                self.audioChannel = output.connection(with: .audio)?.audioChannels.first
                self.audioSessionConfigured = true
            }
            self.audioSession.startRunning()
        }

        levelTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.pollMicLevel()
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
        FileHandle.standardError.write("meter: audio tap running\n".data(using: .utf8)!)
    }

    func stopMicLevelMeter() {
        levelTimer?.invalidate()
        levelTimer = nil
        if audioSessionConfigured {
            sessionQueue.async { self.audioSession.stopRunning() }
        }
        micLevel = 0
    }

    private func pollMicLevel() {
        guard let channel = audioChannel else { return }
        // averagePowerLevel is dBFS, roughly -160 (silence) ... 0 (full scale). Map to 0...1.
        let db = channel.averagePowerLevel
        let normalized = Double(max(0, min(1, (db + 60) / 60))) // -60dB..0dB -> 0..1, clamps quiet noise floor to 0
        // Smooth: fast attack (jump up quickly) so transients read immediately, slow release
        // (decay gradually) so the meter doesn't flicker between polls.
        if normalized > micLevel {
            micLevel = normalized
        } else {
            micLevel = micLevel * 0.85 + normalized * 0.15
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        DispatchQueue.main.async {
            // Only preview-output frames drive state recovery; keep-alive frames must not claim
            // the preview is live (the keep-alive session delivers frames independently of the
            // preview session). A preview frame is ground truth: the camera is ours and working,
            // so recover even if the 5s timeout already flipped us to .inUse (a late first frame
            // on the OBSBOT's cold start). Guard against .idle/.denied so a stray frame arriving
            // after stopPreview can't resurrect a torn-down preview.
            if output !== self.keepAliveOutput {
                if self.previewState == .starting || self.previewState == .inUse {
                    self.previewState = .running
                }
                if !self.loggedFirstFrame {
                    self.loggedFirstFrame = true
                    FileHandle.standardError.write("preview: first frame received\n".data(using: .utf8)!)
                }
            }
            if output === self.keepAliveOutput, !self.loggedKeepAliveFrame {
                self.loggedKeepAliveFrame = true
                FileHandle.standardError.write("keepalive: session running / frame received\n".data(using: .utf8)!)
            }
        }
    }

    // MARK: Keep-mic-live-during-calls

    // Called when the toggle flips (UserDefaults-persisted @Published property above; call this
    // from the setter site in the view / an explicit setter since didSet already persists it).
    func setKeepMicLiveDuringCalls(_ on: Bool) {
        keepMicLiveDuringCalls = on
        if on {
            // Pre-build the capture graph now (device discovery + addInput/addOutput +
            // commitConfiguration) so the trigger path only has to call startRunning. This does
            // NOT call startRunning, so the camera indicator light stays off until an app
            // actually grabs the mic.
            sessionQueue.async { [weak self] in
                _ = self?.configureKeepAliveSessionIfNeeded()
            }
            installMicRunningSomewhereListener()
        } else {
            removeMicRunningSomewhereListener()
            pendingKeepAliveStop?.cancel()
            pendingKeepAliveStop = nil
            stopKeepAliveSession()
        }
    }

    // Re-reads the real status from SMAppService so the toggle reflects reality even if the
    // user changed it in System Settings > General > Login Items since we last checked.
    func refreshLaunchAtLogin() {
        launchAtLogin = CameraModel.isLoginItemEnabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write("launchAtLogin: failed to \(on ? "register" : "unregister") (\(error)); reverting toggle to actual status\n".data(using: .utf8)!)
            // Don't leave the UI showing a state that didn't actually take effect.
            launchAtLogin = CameraModel.isLoginItemEnabled
        }
    }

    private func installMicRunningSomewhereListener() {
        guard !micRunningSomewhereListenerInstalled, audioDeviceID != 0 else {
            if audioDeviceID == 0 {
                FileHandle.standardError.write("keepalive: no OBSBOT audio device, toggle has nothing to listen to\n".data(using: .utf8)!)
            }
            return
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleMicRunningSomewhereChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(audioDeviceID, &address, micListenerQueue, block)
        guard status == noErr else {
            FileHandle.standardError.write("keepalive: failed to install IsRunningSomewhere listener, status=\(status)\n".data(using: .utf8)!)
            return
        }
        micListenerBlock = block
        micListenerDeviceID = audioDeviceID
        micRunningSomewhereListenerInstalled = true
        FileHandle.standardError.write("keepalive: listener installed\n".data(using: .utf8)!)
        // Poll once now in case the mic is already in use when the toggle turns on.
        handleMicRunningSomewhereChanged()
    }

    private func removeMicRunningSomewhereListener() {
        guard micRunningSomewhereListenerInstalled, let block = micListenerBlock, micListenerDeviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        // Must pass the SAME block reference (and the device ID it was registered against, which
        // may differ from the current audioDeviceID if the device was replugged since) that was
        // given to AudioObjectAddPropertyListenerBlock — CoreAudio matches by block identity, so a
        // freshly-allocated closure here would silently fail to remove anything.
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &address, micListenerQueue, block)
        micListenerBlock = nil
        micListenerDeviceID = 0
        micRunningSomewhereListenerInstalled = false
        FileHandle.standardError.write("keepalive: listener removed\n".data(using: .utf8)!)
    }

    private func handleMicRunningSomewhereChanged() {
        guard audioDeviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &value)
        let running = value == 1
        FileHandle.standardError.write("keepalive: IsRunningSomewhere=\(running)\n".data(using: .utf8)!)
        if running {
            pendingKeepAliveStop?.cancel()
            pendingKeepAliveStop = nil
            startKeepAliveSession()
        } else {
            // Don't tear the stream down immediately: a brief mic probe/release, or switching
            // between call apps, can flip IsRunningSomewhere false-then-true within a second or
            // two. Hold off a few seconds before actually stopping, and cancel the hold-off if
            // IsRunningSomewhere comes back true first.
            pendingKeepAliveStop?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopKeepAliveSession() }
            pendingKeepAliveStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + keepAliveStopDelay, execute: work)
        }
    }

    private var keepAliveOutput: AVCaptureVideoDataOutput?
    private var loggedKeepAliveFrame = false

    private func startKeepAliveSession() {
        guard keepMicLiveDuringCalls, !keepAliveRunning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startKeepAliveSessionAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.startKeepAliveSessionAuthorized()
                    } else {
                        // Can't run without permission: don't silently wedge the toggle in an "on
                        // but broken" state — flip it back off so the UI reflects reality.
                        self.setKeepMicLiveDuringCalls(false)
                        FileHandle.standardError.write("keepalive: camera permission denied, toggle reset off\n".data(using: .utf8)!)
                    }
                }
            }
        default:
            setKeepMicLiveDuringCalls(false)
            FileHandle.standardError.write("keepalive: camera permission unavailable, toggle reset off\n".data(using: .utf8)!)
        }
    }

    // Must be called on sessionQueue. Builds the keep-alive session's capture graph (device
    // discovery + beginConfiguration + addInput + addOutput + commitConfiguration) exactly once
    // and leaves it configured but NOT running — beginConfiguration/commitConfiguration alone do
    // not open the video stream, so this does not light the camera indicator. Returns whether the
    // session is (now, or already) configured.
    private func configureKeepAliveSessionIfNeeded() -> Bool {
        if keepAliveConfigured { return true }
        guard let device = findCaptureDevice() else {
            FileHandle.standardError.write("keepalive: no OBSBOT video device found\n".data(using: .utf8)!)
            return false
        }
        keepAliveSession.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            // Multiple AVCaptureSessions can generally read one camera concurrently (this one
            // deliberately overlaps with the preview session when both are active); if adding
            // the input fails anyway, fail gracefully instead of crashing or wedging the toggle.
            guard keepAliveSession.canAddInput(input) else { throw NSError(domain: "obsbot", code: 3) }
            keepAliveSession.addInput(input)
        } catch {
            keepAliveSession.commitConfiguration()
            FileHandle.standardError.write("keepalive: could not attach video input (\(error)); leaving mic possibly silent, toggle stays on and will retry on the next IsRunningSomewhere change\n".data(using: .utf8)!)
            return false
        }
        // Throwaway output, no preview layer, no window: this session exists purely to keep
        // the camera's video pipeline open so the mic carries real audio.
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if keepAliveSession.canAddOutput(output) { keepAliveSession.addOutput(output) }
        keepAliveSession.commitConfiguration()
        keepAliveOutput = output
        keepAliveConfigured = true
        return true
    }

    private func startKeepAliveSessionAuthorized() {
        guard keepMicLiveDuringCalls, !keepAliveRunning else { return }
        loggedKeepAliveFrame = false
        keepAliveRunning = true
        FileHandle.standardError.write("keepalive: session starting\n".data(using: .utf8)!)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configureKeepAliveSessionIfNeeded() else {
                DispatchQueue.main.async { self.keepAliveRunning = false }
                return
            }
            self.keepAliveSession.startRunning()
        }
    }

    private func stopKeepAliveSession() {
        guard keepAliveRunning else { return }
        keepAliveRunning = false
        sessionQueue.async { self.keepAliveSession.stopRunning() }
        FileHandle.standardError.write("keepalive: session stopped\n".data(using: .utf8)!)
    }

    #if DEBUG
    // Headless-verification-only entry point: manually exercises the keep-alive session's start
    // path (input attach + startRunning + first-frame log) without needing IsRunningSomewhere to
    // actually flip true, since no other app is capturing the mic in a headless test run.
    func startKeepAliveSessionForTest() {
        startKeepAliveSession()
    }
    #endif

    // MARK: Pinned floating window

    func setPinned(_ on: Bool) {
        guard on != pinned else { return }
        pinned = on
        if on {
            if pinWindow == nil {
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                win.isOpaque = false
                win.backgroundColor = .clear
                win.hasShadow = true
                win.level = .floating
                // ponytail: WindowDragGesture() on just the header/preview (see PanelView) replaces
                // whole-surface dragging, so slider gestures underneath no longer get stolen by the window.
                win.isMovableByWindowBackground = false
                win.isReleasedWhenClosed = false
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                win.contentView = NSHostingView(rootView:
                    PanelView(model: self, countsAppearance: false)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                // ponytail: fixed initial spot near the top-center (under most webcams); position isn't persisted.
                if let screen = NSScreen.main {
                    let f = screen.visibleFrame
                    win.setFrameTopLeftPoint(NSPoint(x: f.midX - 150, y: f.maxY - 8))
                }
                pinWindow = win
            }
            pinWindow?.orderFront(nil)
            panelAppeared() // window content counts as a visible panel (orderOut won't fire onDisappear)
            FileHandle.standardError.write("pin: floating window shown, level==.floating: \(pinWindow?.level == .floating)\n".data(using: .utf8)!)
            // Dismiss the MenuBarExtra popover so only the floating window remains visible.
            // MenuBarExtra(.window) has no public dismiss API, so we close its NSWindow directly:
            // it's the key/frontmost app window that isn't our own pin window.
            for w in NSApp.windows where w !== self.pinWindow && w.isVisible && w.className.contains("MenuBarExtra") {
                w.close()
            }
            // Fallback: some macOS versions back MenuBarExtra's popover with a window whose
            // class name doesn't contain "MenuBarExtra"; closing the key window covers that case
            // as long as it isn't the pin window itself.
            if let key = NSApp.keyWindow, key !== self.pinWindow {
                key.close()
            }
            FileHandle.standardError.write("pin: popover dismissed\n".data(using: .utf8)!)
        } else if pinWindow?.isVisible == true {
            pinWindow?.orderOut(nil)
            panelDisappeared()
        }
    }

    // Surface the control panel on demand (e.g. the user re-invokes the app from a launcher while
    // it's already running). MenuBarExtra's popover has no public "open programmatically" API, so
    // the visible surface we can reliably show is the floating pinned panel — same PanelView, it
    // just floats until dismissed instead of closing on click-away. If it's already pinned, bring
    // it forward rather than no-op (setPinned early-returns when the state is unchanged).
    func showPanel() {
        refresh()
        if pinned {
            pinWindow?.makeKeyAndOrderFront(nil)
        } else {
            setPinned(true)
        }
    }

    // Connect (or reconnect) and pull live values from the camera.
    func refresh() {
        if controller == nil {
            let loc = findOBSBOTLocationID()
            if loc != 0, let c = VVUVCController(locationID: loc) {
                controller = c
                deviceName = findOBSBOTProductName()
            }
        }
        guard let c = controller else {
            connected = false
            return
        }
        // If the camera was unplugged, reads return stale values; re-check IOKit presence.
        if findOBSBOTLocationID() == 0 {
            controller = nil
            connected = false
            return
        }
        connected = true

        zoomRange = Double(c.minZoom())...Double(c.maxZoom())
        exposureRange = Double(c.minExposureTime())...Double(c.maxExposureTime())
        whiteBalanceRange = Double(c.minWhiteBalance())...Double(c.maxWhiteBalance())
        brightnessRange = Double(c.minBright())...Double(c.maxBright())

        zoom = Double(c.zoom())
        exposure = Double(c.exposureTime())
        whiteBalance = Double(c.whiteBalance())
        brightness = Double(c.bright())

        // Auto reflects the camera's actual state: all three auto-capable controls in auto.
        autoMode = c.autoFocus() && c.autoWhiteBalance() && c.autoExposureMode() != UVC_AEMode_Manual

        FileHandle.standardError.write("obsbot-gui: connected to \(deviceName), zoom=\(Int(zoom)) exposure=\(Int(exposure)) wb=\(Int(whiteBalance))K bright=\(Int(brightness))\n".data(using: .utf8)!)

        refreshMic()
    }

    // Read current mic volume + mute state from CoreAudio. Hides the row gracefully if no
    // OBSBOT audio device is found (device name lookup is ephemeral like the USB locationID).
    func refreshMic() {
        let id = findOBSBOTAudioDeviceID()
        guard id != 0, audioHasProperty(id, kAudioDevicePropertyVolumeScalar) else {
            audioDeviceID = 0
            micAvailable = false
            return
        }
        audioDeviceID = id
        micAvailable = true
        micVolume = Double(audioGetVolume(id) * 100)
        micMuted = audioHasProperty(id, kAudioDevicePropertyMute) ? audioGetMute(id) : false
        FileHandle.standardError.write("mic: found OBSBOT audio device, volume=\(Int(micVolume.rounded()))% muted=\(micMuted)\n".data(using: .utf8)!)

        // The audio device ID is ephemeral (re-plugs get a new one), so re-arm the keep-alive
        // listener against the fresh ID whenever the toggle is already on. Remove the OLD
        // listener first (using its stored block + device ID, which removeMicRunningSomewhereListener
        // already tracks) before installing against the new ID, so listeners don't accumulate
        // across replugs.
        if keepMicLiveDuringCalls {
            removeMicRunningSomewhereListener()
            installMicRunningSomewhereListener()
        }
    }

    func setMicVolume(_ v: Double) {
        guard audioDeviceID != 0 else { return }
        micVolume = v
        audioSetVolume(audioDeviceID, Float32(v / 100))
    }

    func setMicMuted(_ muted: Bool) {
        guard audioDeviceID != 0 else { return }
        micMuted = muted
        audioSetMute(audioDeviceID, muted)
    }

    func setZoom(_ v: Double) { controller?.setZoom(Int(v)) }

    // ponytail: dragging Exposure or White Balance drops only that control out of auto
    // (autoFocus stays on) but shows "Auto Off"; touching a slider means you're taking over.
    func setExposure(_ v: Double) {
        guard let c = controller else { return }
        // Manual exposure only sticks when AE mode is manual.
        if c.autoExposureMode() != UVC_AEMode_Manual { c.setAutoExposureMode(UVC_AEMode_Manual); autoMode = false }
        c.setExposureTime(Int(v))
    }

    func setWhiteBalance(_ v: Double) {
        guard let c = controller else { return }
        if c.autoWhiteBalance() { c.setAutoWhiteBalance(false); autoMode = false }
        c.setWhiteBalance(Int(v))
    }

    func setBrightness(_ v: Double) { controller?.setBright(Int(v)) }

    func setAuto(_ on: Bool) {
        guard let c = controller else { return }
        c.setAutoFocus(on)
        c.setAutoWhiteBalance(on)
        c.setAutoExposureMode(on ? UVC_AEMode_Auto : UVC_AEMode_Manual)
        autoMode = on
        // Snap sliders back to what the camera actually settled on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }

    func reset() {
        controller?.resetParamsToDefaults()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }
}

// MARK: - Aperture palette

enum Aperture {
    static let bgTop = Color(hex: 0x23201b)
    static let bgBottom = Color(hex: 0x191612)
    static let text = Color(hex: 0xece3d4)
    static let value = Color(hex: 0xf4ead8)
    static let label = Color(hex: 0xb3a488)
    static let fillStart = Color(hex: 0xb9762e)
    static let fillEnd = Color(hex: 0xe6b569)
    static let accent = Color(hex: 0xd99a4e)
    static let knob = Color(hex: 0xf6ecdb)
    static let hairline = Color(hex: 0x3a3226)
    static let resetText = Color(hex: 0x1c1610)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - Custom toggle (pill track, cream knob; amber when on to match the slider knob styling)

struct ApertureToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            AperturePillButton(isOn: configuration.isOn) { configuration.isOn.toggle() }
        }
        .contentShape(Rectangle())
        // Restores whole-row click-to-toggle (label text included), matching pre-PR behavior;
        // the AperturePillButton's own Button below still handles keyboard/Space activation.
        // Not a double-toggle risk: a click landing on the Capsule is consumed by the Button
        // itself (SwiftUI Button intercepts the tap before it reaches an ancestor's
        // onTapGesture), so only clicks on the label/row area outside the button reach this.
        .onTapGesture { configuration.isOn.toggle() }
        // The label Text and the pill button are siblings, not label-inside-button, so without
        // this VoiceOver would announce the button with no name. Combining reads them as one
        // accessible element: "<label>, toggle, on/off".
        .accessibilityElement(children: .combine)
    }
}

// Separate struct so it can hold @FocusState (ToggleStyle.makeBody can't).
private struct AperturePillButton: View {
    let isOn: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? Aperture.accent.opacity(0.85) : Color.black.opacity(0.35))
                .frame(width: 34, height: 19)
                .overlay(
                    Circle()
                        .fill(Aperture.knob)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                        .offset(x: isOn ? 7.5 : -7.5)
                )
                .overlay(
                    Capsule().stroke(Aperture.accent, lineWidth: focused ? 2 : 0)
                        .padding(-2)
                )
                .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .focused($focused)
        // Plain Button (not SwiftUI's Toggle) has no built-in on/off announcement, so state it
        // explicitly; combined with the sibling label via ApertureToggleStyle's
        // .accessibilityElement(children: .combine), VoiceOver reads "<label>, toggle, on/off".
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Custom slider (lens-ring feel: amber gradient fill, cream knob with amber ring)

struct ApertureSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    // Amount one tap of the −/+ buttons nudges the value. The slider is for coarse travel;
    // the steppers are for the finest meaningful adjustment (e.g. 50 K on white balance, where
    // a 1 K step would be imperceptible). No hold-to-repeat on the stepper buttons: the intent
    // there is precise single nudges. Arrow-key repeat via onMoveCommand on the slider track
    // (below) is exempt from this — standard OS key-repeat on a focused control is expected
    // behavior, not a bug, so it's left as-is rather than suppressed.
    var step: Double = 1
    let format: (Double) -> String
    let onChange: (Double) -> Void

    private let trackHeight: CGFloat = 5
    private let knobSize: CGFloat = 15
    @FocusState private var trackFocused: Bool

    // Move to the next grid multiple in the direction pressed: floor for increment so we
    // always land at least one step above; ceil for decrement so we land at least one step
    // below. This handles off-grid starting values (e.g. mic volume read back as 73%) without
    // skipping the nearest clean multiple. Then clamp so fast repeated taps can't drift past
    // the bounds. Route through onChange so a step behaves exactly like a drag — notably,
    // stepping EXPOSURE / WHITE BALANCE drops the camera out of auto via the same setter.
    private func nudge(_ direction: Double) {
        let snapped = direction > 0
            ? (floor(value / step) + 1) * step
            : (ceil(value / step) - 1) * step
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
        onChange(clamped)
    }

    private func stepButton(_ symbol: String, _ direction: Double, disabled: Bool) -> some View {
        Button(action: { nudge(direction) }) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Aperture.accent)
                .frame(width: 19, height: 19)
                .background(Aperture.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1) // dim at the extreme so the limit reads as a limit
        .help(direction < 0 ? "Decrease \(label.lowercased())" : "Increase \(label.lowercased())")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(Aperture.label)
                    .kerning(0.4)
                Spacer(minLength: 6)
                stepButton("minus", -1, disabled: value <= range.lowerBound)
                Text(format(value))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Aperture.value)
                    .frame(minWidth: 42, alignment: .trailing) // stable width so the +/− don't shift as digits change
                stepButton("plus", 1, disabled: value >= range.upperBound)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let span = max(range.upperBound - range.lowerBound, 1)
                let frac = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
                let x = frac * (width - knobSize) + knobSize / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(LinearGradient(colors: [Aperture.fillStart, Aperture.fillEnd],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(x, trackHeight), height: trackHeight)
                        .shadow(color: Aperture.accent.opacity(0.45), radius: 4, y: 0) // exposure-meter glow
                    Circle()
                        .fill(Aperture.knob)
                        .overlay(Circle().stroke(Aperture.accent, lineWidth: 2))
                        .overlay(Circle().stroke(Aperture.accent, lineWidth: trackFocused ? 2 : 0).padding(-3))
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .position(x: x, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(max((g.location.x - knobSize / 2) / (width - knobSize), 0), 1)
                    let v = range.lowerBound + Double(f) * span
                    value = v
                    onChange(v)
                })
                .focusable()
                .focused($trackFocused)
                .onMoveCommand { direction in
                    if direction == .left { nudge(-1) }
                    if direction == .right { nudge(1) }
                }
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
                .accessibilityAdjustableAction { direction in
                    nudge(direction == .increment ? 1 : -1)
                }
            }
            .frame(height: knobSize)
        }
    }
}

// MARK: - Mic level meter (thin horizontal bar; amber fill, hotter tone near clipping)

struct MicLevelMeter: View {
    let level: Double // 0...1
    let dimmed: Bool

    private let height: CGFloat = 5
    private let hotThreshold: Double = 0.85

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(level, 0), 1)
            let fillWidth = width * CGFloat(clamped)
            let hotWidth = width * CGFloat(max(0, clamped - hotThreshold))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Aperture.hairline)
                    .frame(height: height)
                Capsule()
                    .fill(LinearGradient(colors: [Aperture.fillStart, Aperture.fillEnd],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fillWidth, height), height: height)
                if hotWidth > 0 {
                    // Near-clipping cap in a hotter tone, pinned to the right edge of the fill.
                    Capsule()
                        .fill(Color(hex: 0xe66b3f))
                        .frame(width: max(hotWidth, height), height: height)
                        .offset(x: width * CGFloat(hotThreshold))
                }
            }
            .opacity(dimmed ? 0.4 : 1)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: - Live preview layer (NSViewRepresentable wrapping AVCaptureVideoPreviewLayer)

struct PreviewLayerView: NSViewRepresentable {
    let model: CameraModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        // Build the layer empty on main (CALayer geometry is main-thread), then hand it to the model
        // to assign `session` on sessionQueue — see attachPreviewLayer for why the session-graph
        // mutation must not happen here on the main thread.
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        model.attachPreviewLayer(layer)
        model.applyPreviewMirror(to: layer, hostView: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The preview layer's connection isn't guaranteed to exist yet at makeNSView time
        // (it's created lazily once the session is configured), so re-attempt on every update
        // pass until mirroring is confirmed; once previewMirrorApplied is set we stop dispatching
        // to sessionQueue so rapid redraws (e.g. zoom-slider drag) don't flood it.
        guard !model.previewMirrorApplied else { return }
        if let layer = nsView.layer as? AVCaptureVideoPreviewLayer {
            model.applyPreviewMirror(to: layer, hostView: nsView)
        }
    }
}

// MARK: - Window-drag handle (macOS 15+; no-op on the 13.0 deployment target's older OSes)

struct WindowDragIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: CameraModel
    // The pinned window manages its lifecycle manually (orderOut doesn't fire onDisappear).
    var countsAppearance = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.connected {
                connectedBody
            } else {
                emptyState
            }
            quitRow
        }
        .frame(width: 300)
        .background(
            LinearGradient(colors: [Aperture.bgTop, Aperture.bgBottom], startPoint: .top, endPoint: .bottom)
        )
        .onAppear {
            model.refresh()
            model.refreshLaunchAtLogin()
            if countsAppearance { model.panelAppeared() }
        }
        .onDisappear {
            if countsAppearance { model.panelDisappeared() }
        }
        // ponytail: MenuBarExtra's window supplies its own corner radius and shadow;
        // forcing an exact 16px transparent-corner popover isn't worth the NSWindow surgery.
    }

    // Preview area: 300x169 (16:9), warm placeholder states instead of a black slab.
    private var previewArea: some View {
        ZStack {
            LinearGradient(colors: [Aperture.bgTop, Aperture.bgBottom], startPoint: .top, endPoint: .bottom)
            switch model.previewState {
            case .running, .starting:
                PreviewLayerView(model: model)
            case .denied:
                previewMessage("Grant camera access in System Settings\nto see the live preview.")
            case .inUse:
                previewMessage("Camera in use by another app")
            case .unavailable, .idle:
                previewMessage("Preview unavailable")
            }
        }
        .frame(width: 300, height: 169)
        .clipped()
        // Drag handle: the preview area moves the (pinned) window; sliders below never get this gesture.
        // WindowDragGesture needs macOS 15+; deployment target is 13.0, so gate it and no-op below 15
        // (whole-surface dragging is already off, so worst case on old macOS is "drag by header only" missing).
        .modifier(WindowDragIfAvailable())
    }

    private func previewMessage(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(Aperture.label.opacity(0.8))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Aperture.label)
                .multilineTextAlignment(.center)
        }
    }

    private var connectedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            // Header: device name + status line + pin
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.deviceName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Aperture.text)
                    HStack(spacing: 6) {
                        Circle().fill(Aperture.accent).frame(width: 6, height: 6)
                            .shadow(color: Aperture.accent.opacity(0.8), radius: 3)
                        Text("Framing")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(Aperture.label)
                    }
                }
                Spacer()
                Button(action: { model.setPinned(!model.pinned) }) {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(model.pinned ? Aperture.accent : Aperture.label)
                        .padding(6)
                        .background(Aperture.accent.opacity(model.pinned ? 0.14 : 0))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(model.pinned ? "Unpin floating panel" : "Pin as floating panel")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            // Drag handle: header (device name + pin button) moves the window; the pin
            // Button's own tap gesture still wins over this for its own hit area.
            .modifier(WindowDragIfAvailable())

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            VStack(spacing: 16) {
                ApertureSlider(label: "ZOOM", value: $model.zoom, range: model.zoomRange,
                               step: 1, format: { "\(Int($0))" }, onChange: model.setZoom)
                ApertureSlider(label: "EXPOSURE", value: $model.exposure, range: model.exposureRange,
                               step: 1, format: { "\(Int($0))" }, onChange: model.setExposure)
                ApertureSlider(label: "WHITE BALANCE", value: $model.whiteBalance, range: model.whiteBalanceRange,
                               step: 50, format: { "\(Int($0)) K" }, onChange: model.setWhiteBalance)
                ApertureSlider(label: "BRIGHTNESS", value: $model.brightness, range: model.brightnessRange,
                               step: 1, format: { "\(Int($0))" }, onChange: model.setBrightness)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if model.micAvailable {
                Rectangle().fill(Aperture.hairline).frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ApertureSlider(label: "MIC", value: $model.micVolume, range: 0...100,
                                       step: 5, format: { "\(Int($0))%" }, onChange: model.setMicVolume)

                        Button(action: { model.setMicMuted(!model.micMuted) }) {
                            Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(model.micMuted ? Aperture.label.opacity(0.5) : Aperture.accent)
                                .padding(7)
                                .background(Aperture.accent.opacity(model.micMuted ? 0 : 0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .help(model.micMuted ? "Unmute microphone" : "Mute microphone")
                    }

                    // Live input level meter. Simpler-correct choice: mute silences the mic's output
                    // to other apps, not our own monitoring tap, so the meter keeps reading input
                    // level while muted (dimmed) rather than forcing it to 0 — that's more useful for
                    // confirming the mic still hears you before you unmute.
                    MicLevelMeter(level: model.micLevel, dimmed: model.micMuted)

                    Rectangle().fill(Aperture.hairline).frame(height: 1)
                        .padding(.top, 2)

                    Toggle(isOn: Binding(
                        get: { model.keepMicLiveDuringCalls },
                        set: { model.setKeepMicLiveDuringCalls($0) }
                    )) {
                        Text("Wake mic when apps need it")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundColor(Aperture.text)
                    }
                    .toggleStyle(ApertureToggleStyle())

                    if model.keepMicLiveDuringCalls {
                        Text("Turns the camera on only while an app uses the mic, so the mic works. The camera light comes on then.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(Aperture.label)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Text("Launch at login")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(Aperture.text)
            }
            .toggleStyle(ApertureToggleStyle())
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            HStack(spacing: 10) {
                Button(action: { model.setAuto(!model.autoMode) }) {
                    Text(model.autoMode ? "Auto  On" : "Auto  Off")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(Aperture.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Aperture.accent.opacity(model.autoMode ? 0.12 : 0.05))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Aperture.accent.opacity(0.35), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: model.reset) {
                    Text("Reset")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(Aperture.resetText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Aperture.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
    }

    // Always-present footer. This is an LSUIElement agent (no Dock icon, no app menu), so this
    // button is the only way to quit — it lives in the outer body, outside the connected/empty
    // branch, so it's reachable even when no camera is attached. Understated on purpose: quitting
    // is a rare utility action, not a primary control.
    private var quitRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Aperture.hairline).frame(height: 1)
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quit OBSBOT Control")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                }
                .foregroundColor(Aperture.label)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit OBSBOT Control")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Aperture.accent.opacity(0.7))
            Text("No OBSBOT connected")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Aperture.text)
            Text("Plug in the camera and reopen this panel.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(Aperture.label)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - App delegate (reopen handling)

// The whole reason this exists: a menu-bar / LSUIElement app has no ordinary window, so
// re-invoking it from a launcher (Spotlight/Raycast/`open -a`) while it's already running does
// nothing visible by default. AppKit still delivers a "reopen" to the running instance; we catch
// it here and show the control panel so the launcher behaves like it would for a normal app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        FileHandle.standardError.write("reopen: applicationShouldHandleReopen fired (hasVisibleWindows=\(flag))\n".data(using: .utf8)!)
        // An accessory app won't come forward on its own; without this the panel can appear behind
        // whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        CameraModel.current?.showPanel()
        return true
    }
}

// MARK: - App

@main
struct ObsbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: CameraModel

    init() {
        // LSUIElement in Info.plist keeps us out of the Dock; this backs it up when run bare.
        NSApplication.shared.setActivationPolicy(.accessory)
        let m = CameraModel()
        _model = StateObject(wrappedValue: m)
        // ponytail: headless verification hooks; harmless in normal use, but gated out of
        // release builds entirely via #if DEBUG so this test scaffolding never ships.
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["OBSBOT_PREVIEW_TEST"] == "1" {
            DispatchQueue.main.async { m.startPreview() }
        }
        if env["OBSBOT_PIN_TEST"] == "1" {
            DispatchQueue.main.async { m.setPinned(true) }
        }
        if env["OBSBOT_ESCAPE_TEST"] == "1" {
            // Headless verification: synthesize an Escape keyDown and post it through the same
            // NSEvent dispatch path a real keypress on the pinned window would take, to prove the
            // local monitor fires and drives the unpin path without a human at the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let escEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: 0, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    FileHandle.standardError.write("esc-test: posting synthetic Escape keyDown\n".data(using: .utf8)!)
                    NSApp.postEvent(escEvent, atStart: true)
                }
            }
        }
        if env["OBSBOT_KEEPALIVE_TEST"] == "1" {
            // Headless verification: force the toggle on to prove the CoreAudio listener installs
            // and reads the initial IsRunningSomewhere value, then manually exercise the keep-alive
            // session's start path directly (since no other app is capturing the mic in this test
            // environment, IsRunningSomewhere will likely stay false the whole time — that's
            // expected and doesn't indicate a bug), then flip the toggle off to prove listener
            // removal + session stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                m.setKeepMicLiveDuringCalls(true)
                m.startKeepAliveSessionForTest()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                m.setKeepMicLiveDuringCalls(false)
            }
        }
        if env["OBSBOT_KEEPALIVE_RAPID_TEST"] == "1" {
            // Headless verification: toggle keep-alive on/off/on/off in quick succession (each
            // start/stop dispatched to sessionQueue but requested from main in a tight burst) to
            // shake out any remaining ordering race between rapid session mutations.
            for i in 0..<4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.3) {
                    let on = i % 2 == 0
                    FileHandle.standardError.write("keepalive-rapid: toggling \(on)\n".data(using: .utf8)!)
                    m.setKeepMicLiveDuringCalls(on)
                    if on { m.startKeepAliveSessionForTest() }
                }
            }
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: "camera.aperture")
        }
        .menuBarExtraStyle(.window)
    }
}
