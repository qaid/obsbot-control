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

    private var controller: VVUVCController?

    // MARK: Preview (one AVCaptureSession owned by the model, shared by popover and pinned window)
    @Published var previewState: PreviewState = .idle
    let session = AVCaptureSession()
    private var sessionConfigured = false
    private var loggedFirstFrame = false
    private var frameTimeoutWork: DispatchWorkItem?
    private let videoQueue = DispatchQueue(label: "obsbot.preview")

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

    override init() {
        super.init()
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
        if !sessionConfigured {
            guard let device = findCaptureDevice() else {
                previewState = .unavailable
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw NSError(domain: "obsbot", code: 1) }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                previewState = .inUse // couldn't attach the input: someone else holds the device
                return
            }
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            sessionConfigured = true
        }
        previewState = .starting
        loggedFirstFrame = false
        videoQueue.async { self.session.startRunning() }

        // No frames within 2.5s -> treat as "in use by another app".
        frameTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewState == .starting else { return }
            self.previewState = .inUse
        }
        frameTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func stopPreview() {
        frameTimeoutWork?.cancel()
        videoQueue.async { self.session.stopRunning() }
        previewState = .idle
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
        if !audioSessionConfigured {
            guard let device = findAudioCaptureDevice() else { return }
            audioSession.beginConfiguration()
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard audioSession.canAddInput(input) else { throw NSError(domain: "obsbot", code: 2) }
                audioSession.addInput(input)
            } catch {
                audioSession.commitConfiguration()
                return
            }
            let output = AVCaptureAudioDataOutput()
            if audioSession.canAddOutput(output) { audioSession.addOutput(output) }
            audioSession.commitConfiguration()
            audioChannel = output.connection(with: .audio)?.audioChannels.first
            audioSessionConfigured = true
        }
        videoQueue.async { self.audioSession.startRunning() }

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
            videoQueue.async { self.audioSession.stopRunning() }
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
            if self.previewState == .starting { self.previewState = .running }
            if !self.loggedFirstFrame {
                self.loggedFirstFrame = true
                FileHandle.standardError.write("preview: first frame received\n".data(using: .utf8)!)
            }
        }
    }

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

// MARK: - Custom slider (lens-ring feel: amber gradient fill, cream knob with amber ring)

struct ApertureSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onChange: (Double) -> Void

    private let trackHeight: CGFloat = 5
    private let knobSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(Aperture.label)
                    .kerning(0.4)
                Spacer()
                Text(format(value))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Aperture.value)
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
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        applyMirror(to: layer, hostView: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The preview layer's connection isn't guaranteed to exist yet at makeNSView time
        // (it's created lazily once the session is configured), so re-attempt on every update
        // pass; applyMirror no-ops once it has already mirrored successfully.
        if let layer = nsView.layer as? AVCaptureVideoPreviewLayer {
            applyMirror(to: layer, hostView: nsView)
        }
    }

    // Mirror the DISPLAYED preview only (selfie-view); capture output to other apps must be untouched.
    // AVCaptureVideoPreviewLayer manages its own `transform` internally and overrides/ignores a
    // manually-set layer transform, so that route silently does nothing (confirmed: preview stayed
    // unmirrored). Instead we mirror via the preview layer's AVCaptureConnection
    // (`isVideoMirrored`), which only affects what's displayed, not the session's captured/output
    // frames. If the connection isn't available yet or doesn't support mirroring, we fall back to
    // flipping the HOST NSView's layer (not the preview layer) via `sublayerTransform`, which the
    // preview layer can't override since it's the parent's transform, not its own.
    private func applyMirror(to layer: AVCaptureVideoPreviewLayer, hostView: NSView) {
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            if connection.isVideoMirrored { return } // already applied; connection route confirmed working
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            FileHandle.standardError.write("mirror: connection.isVideoMirrored=\(connection.isVideoMirrored)\n".data(using: .utf8)!)
        } else if hostView.layer?.sublayerTransform.m11 != -1 {
            hostView.layer?.sublayerTransform = CATransform3DMakeScale(-1, 1, 1)
            FileHandle.standardError.write("mirror: applied container transform (connection unavailable or unsupported)\n".data(using: .utf8)!)
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
        }
        .frame(width: 300)
        .background(
            LinearGradient(colors: [Aperture.bgTop, Aperture.bgBottom], startPoint: .top, endPoint: .bottom)
        )
        .onAppear {
            model.refresh()
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
                PreviewLayerView(session: model.session)
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
                               format: { "\(Int($0))" }, onChange: model.setZoom)
                ApertureSlider(label: "EXPOSURE", value: $model.exposure, range: model.exposureRange,
                               format: { "\(Int($0))" }, onChange: model.setExposure)
                ApertureSlider(label: "WHITE BALANCE", value: $model.whiteBalance, range: model.whiteBalanceRange,
                               format: { "\(Int($0)) K" }, onChange: model.setWhiteBalance)
                ApertureSlider(label: "BRIGHTNESS", value: $model.brightness, range: model.brightnessRange,
                               format: { "\(Int($0))" }, onChange: model.setBrightness)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if model.micAvailable {
                Rectangle().fill(Aperture.hairline).frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ApertureSlider(label: "MIC", value: $model.micVolume, range: 0...100,
                                       format: { "\(Int($0))%" }, onChange: model.setMicVolume)

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
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

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

// MARK: - App

@main
struct ObsbotApp: App {
    @StateObject private var model: CameraModel

    init() {
        // LSUIElement in Info.plist keeps us out of the Dock; this backs it up when run bare.
        NSApplication.shared.setActivationPolicy(.accessory)
        let m = CameraModel()
        _model = StateObject(wrappedValue: m)
        // ponytail: headless verification hooks; harmless in normal use.
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
