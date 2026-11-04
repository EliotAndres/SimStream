import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

final class CaptureManager: NSObject, @unchecked Sendable {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?
    private let streamQueue = DispatchQueue(label: "com.simulatorstream.capture")
    private var lastPixelBuffer: CVPixelBuffer?
    /// First N SCStream frames get extra logging (dimensions / format / pts).
    private var debugFrameLogRemaining = 5
    /// One-shot JPEG on disk when `SIMULATOR_STREAM_DEBUG_JPEG=1`.
    private var savedDebugJPEG = false

    private(set) var deviceScreenRect: CGRect?
    private(set) var windowTarget: SimulatorWindow.Target?

    /// Source dimensions in points (either the cropped content rect or the whole window).
    /// Used by `updateConfig` to recompute output pixel size when maxHeight changes.
    private var sourcePointsSize: CGSize?
    private var hostScaleFactor: CGFloat = 2.0
    private var currentFPS: Int = 60
    /// 0 = uncapped (use host scale factor).
    private var maxOutputHeight: Int = 0

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("[Capture] Failed to get shareable content. Make sure Screen Recording permission is granted.")
            print("[Capture] Error: \(error)")
            throw error
        }

        let (contentFilter, windowSize) = try await makeFilter(from: content)
        let config = makeConfiguration(windowSize: windowSize)
        self.filter = contentFilter
        self.streamConfig = config

        let captureStream = SCStream(filter: contentFilter, configuration: config, delegate: nil)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        try await captureStream.startCapture()
        self.stream = captureStream
        print("[Capture] Capture started successfully")
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }

    /// Push one frame now — cached if available, else capture a screenshot.
    /// Called when a viewer connects so they see content immediately even if
    /// SCStream hasn't delivered anything yet (e.g. a static simulator screen).
    func pushCurrentFrame() {
        streamQueue.async { self.pushOneFrame() }
    }

    private func pushOneFrame() {
        if let buf = lastPixelBuffer {
            let ts = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
            onFrame?(buf, ts)
            return
        }

        guard let filter, let config = streamConfig else { return }
        Task {
            do {
                let image = try await SCScreenshotManager.captureSampleBuffer(
                    contentFilter: filter,
                    configuration: config
                )
                guard let pixelBuffer = image.imageBuffer else { return }
                self.lastPixelBuffer = pixelBuffer
                let ts = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
                self.onFrame?(pixelBuffer, ts)
                print("[Capture] Sent screenshot as initial frame")
            } catch {
                print("[Capture] Failed to capture screenshot: \(error)")
            }
        }
    }

    private func makeFilter(from content: SCShareableContent) async throws -> (SCContentFilter, CGSize?) {
        let candidates = content.windows.filter {
            SimulatorWindow.bundleIDs.contains($0.owningApplication?.bundleIdentifier ?? "")
        }.sorted { lhs, rhs in
            let leftPriority = SimulatorWindow.titlePriority(lhs.title ?? "")
            let rightPriority = SimulatorWindow.titlePriority(rhs.title ?? "")
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            let leftHub = lhs.owningApplication?.bundleIdentifier == SimulatorWindow.deviceHubBundleID
            let rightHub = rhs.owningApplication?.bundleIdentifier == SimulatorWindow.deviceHubBundleID
            if leftHub != rightHub { return leftHub }
            return lhs.windowID < rhs.windowID
        }
        if var window = candidates.first, let app = window.owningApplication {
            var target = SimulatorWindow.Target(processID: app.processID, bundleID: app.bundleIdentifier,
                                               title: window.title ?? "", frame: window.frame)
            let isDeviceHub = app.bundleIdentifier == SimulatorWindow.deviceHubBundleID
            if isDeviceHub {
                let compact = try await SimulatorWindow.prepareDeviceHub(target)
                // SCWindow frames are snapshots: refresh after the AX resize before
                // configuring output dimensions or creating the content filter.
                let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let updated = refreshed.windows.first(where: { $0.windowID == window.windowID }) else {
                    throw CaptureError.windowUnavailable
                }
                window = updated
                target = SimulatorWindow.Target(processID: app.processID, bundleID: app.bundleIdentifier,
                                                title: window.title ?? "", frame: window.frame,
                                                compactConfirmed: compact)
            }
            windowTarget = target
            let name = isDeviceHub ? "Device Hub" : "Simulator"
            print("[Capture] Found \(name) window: \(window.title ?? "untitled") (\(window.frame.width)x\(window.frame.height))")
            return (SCContentFilter(desktopIndependentWindow: window), window.frame.size)
        }

        for bundleID in SimulatorWindow.bundleIDs {
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }),
               let display = content.displays.first {
                let name = bundleID == SimulatorWindow.deviceHubBundleID ? "Device Hub" : "Simulator"
                print("[Capture] Found \(name) app, capturing all its windows")
                return (SCContentFilter(display: display, including: [app], exceptingWindows: []), nil)
            }
        }

        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        print("[Capture] Warning: Device Hub / Simulator not found, capturing entire display")
        return (SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), nil)
    }

    private func makeConfiguration(windowSize: CGSize?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(currentFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        if let size = windowSize {
            hostScaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

            if let contentRect = detectSimulatorContentRect() {
                self.deviceScreenRect = contentRect
                config.sourceRect = contentRect
                sourcePointsSize = contentRect.size
                print("[Capture] Cropping to content area: \(contentRect)")
            } else {
                sourcePointsSize = size
            }
            applyOutputSize(to: config)
        }

        return config
    }

    /// Compute output pixel dimensions from stored source points + scale/cap.
    private func applyOutputSize(to config: SCStreamConfiguration) {
        guard let srcPoints = sourcePointsSize, srcPoints.height > 0 else { return }
        let scale: CGFloat
        if maxOutputHeight > 0 {
            scale = min(hostScaleFactor, CGFloat(maxOutputHeight) / srcPoints.height)
        } else {
            scale = hostScaleFactor
        }
        config.width = Int(srcPoints.width * scale)
        config.height = Int(srcPoints.height * scale)
        print("[Capture] Output size: \(config.width)x\(config.height) (scale \(scale), cap \(maxOutputHeight))")
    }

    /// Live-tune frame rate and/or max output height. Safe to call while streaming.
    /// `fps` clamps to 1…60. `maxHeight` of 0 removes the cap.
    func updateConfig(fps: Int?, maxHeight: Int?) async {
        guard let config = streamConfig, let stream = stream else { return }
        let dimsChanged: Bool
        if let fps = fps {
            currentFPS = max(1, min(60, fps))
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(currentFPS))
        }
        if let maxHeight = maxHeight {
            let prevW = config.width, prevH = config.height
            maxOutputHeight = max(0, maxHeight)
            applyOutputSize(to: config)
            dimsChanged = (config.width != prevW || config.height != prevH)
        } else {
            dimsChanged = false
        }
        do {
            try await stream.updateConfiguration(config)
        } catch {
            print("[Capture] updateConfiguration failed: \(error)")
            return
        }
        // SCStream only delivers on content change — on a static screen there'd be
        // no frame at the new dims. Drop the cached buffer (it's at the old dims)
        // and kick a fresh screenshot so the viewer sees something immediately.
        if dimsChanged {
            streamQueue.async {
                self.lastPixelBuffer = nil
                self.pushOneFrame()
            }
        }
    }

    /// Uses macOS Accessibility to find the device screen content area inside
    /// the Simulator window. Returns a rect in window-local points suitable
    /// for SCStreamConfiguration.sourceRect, or nil on failure.
    private func detectSimulatorContentRect() -> CGRect? {
        guard let target = windowTarget, let metrics = SimulatorWindow.metrics(for: target) else {
            print("[Capture] Could not find content rect via Accessibility; capturing whole window")
            return nil
        }
        let rect = metrics.contentRect
        print("[Capture] AX content rect in window: \(rect)  (window \(metrics.windowFrame.width)x\(metrics.windowFrame.height))")
        return rect
    }
}

enum CaptureError: Error {
    case noDisplay
    case windowUnavailable
}

extension CaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        let timestamp = sampleBuffer.presentationTimeStamp

        if let pixelBuffer = sampleBuffer.imageBuffer {
            if debugFrameLogRemaining > 0 {
                debugFrameLogRemaining -= 1
                let idx = 5 - debugFrameLogRemaining
                CaptureDebug.logPixelBuffer(pixelBuffer, label: "SCStream frame #\(idx)", pts: timestamp)
            }

            maybeSaveDebugJPEG(pixelBuffer: pixelBuffer)

            lastPixelBuffer = pixelBuffer
            onFrame?(pixelBuffer, timestamp)
        }
    }

    /// Set `SIMULATOR_STREAM_DEBUG_JPEG=1` to write the first frame to disk as JPEG (default path below).
    /// Copy to your Mac, e.g. `scp admin@<tart-ip>:/tmp/simulator-stream-capture-debug.jpg .`
    private func maybeSaveDebugJPEG(pixelBuffer: CVPixelBuffer) {
        guard !savedDebugJPEG else { return }
        guard ProcessInfo.processInfo.environment["SIMULATOR_STREAM_DEBUG_JPEG"] == "1" else { return }

        let path = ProcessInfo.processInfo.environment["SIMULATOR_STREAM_DEBUG_JPEG_PATH"]
            ?? "/tmp/simulator-stream-capture-debug.jpg"
        savedDebugJPEG = true
        do {
            try CaptureDebug.saveJPEG(from: pixelBuffer, to: path)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            print("[Capture] DEBUG JPEG saved (\(w)×\(h)) → \(path)")
        } catch {
            print("[Capture] DEBUG JPEG save failed: \(error)")
        }
    }
}
