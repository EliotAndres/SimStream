import Foundation
import AppKit

final class TouchInjector {
    private let queue = DispatchQueue(label: "com.simulatorstream.touch", qos: .userInteractive)
    private var bridgeProcess: Process?
    private var bridgeStdin: FileHandle?
    private var screenWidth: Double = 0
    private var screenHeight: Double = 0
    private var simulatorUDID: String?

    /// When false, the captured video is the full simulator window (top bar included)
    /// and touch coordinates must be adjusted. When true, the video is already cropped
    /// to the device screen and direct mapping is correct.
    private var videoIsCropped: Bool = true

    /// Top bar height in macOS window points (from Accessibility API).
    private var topBarOffsetMacOS: Double = 0
    /// Total simulator window height in macOS points.
    private var windowHeightMacOS: Double = 0
    /// Device content area height in macOS points.
    private var contentHeightMacOS: Double = 0

    // ─── Readiness state — touches are only valid once everything resolved.
    /// `true` once UDID + screen size + bridge process are all up.
    private var ready: Bool = false
    /// Human-readable reason captured by the last failure path.
    private var unreadyReason: String = "touch pipeline not initialised yet"
    /// Suppress repeat logging while the failure mode is unchanged.
    private var lastLoggedUnreadyReason: String?
    /// Resolve is expensive (idb shells out, retries) — avoid stacking concurrent passes.
    private var resolveInFlight: Bool = false

    func pressHome() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let udid = self.simulatorUDID else {
                self.logError("pressHome ignored — simulator not resolved yet. \(self.unreadyReason)")
                self.kickResolveIfNeeded()
                return
            }
            let output = self.shell("idb", "ui", "button", "HOME", "--udid", udid)
            print("[Touch] Home button: \(output.isEmpty ? "ok" : output)")
        }
    }

    func setVideoIsCropped(_ isCropped: Bool) {
        queue.async { self.videoIsCropped = isCropped }
        print("[Touch] Video is \(isCropped ? "cropped to device screen (direct mapping)" : "full window — applying top bar correction")")
    }

    func handleTouch(_ event: TouchEvent) {
        guard ready, screenWidth > 0, screenHeight > 0 else {
            logError("Dropping '\(event.type)' touch — \(unreadyReason)")
            kickResolveIfNeeded()
            return
        }

        let deviceX: Double
        let deviceY: Double

        if !videoIsCropped && windowHeightMacOS > 0 && contentHeightMacOS > 0 && topBarOffsetMacOS > 0 {
            // Video frame is the full simulator window (top bar included).
            // Map through the content rect to get device logical coordinates.
            let scaleY = screenHeight / contentHeightMacOS
            deviceX = event.x * screenWidth
            deviceY = max(0, (event.y * windowHeightMacOS - topBarOffsetMacOS) * scaleY)
        } else {
            deviceX = event.x * screenWidth
            deviceY = event.y * screenHeight
        }

        let point = CGPoint(x: deviceX, y: deviceY)

        switch event.type {
        case "down", "move", "up":
            sendBridge(["type": event.type, "x": point.x, "y": point.y])
        default:
            break
        }
    }

    func resolveSimulator() {
        queue.async { [weak self] in
            guard let self else { return }

            if self.ready, let proc = self.bridgeProcess, proc.isRunning {
                return
            }
            if self.resolveInFlight {
                return
            }
            self.resolveInFlight = true
            defer { self.resolveInFlight = false }

            print("[Touch] Resolving simulator...")
            guard let udid = self.findBootedUDID() else {
                self.markNotReady(
                    "No booted iOS Simulator found.",
                    troubleshoot: [
                        "Boot one in Xcode → Simulator, or:",
                        "    xcrun simctl boot <device-udid>",
                        "  Then trigger any touch in the browser to retry.",
                    ]
                )
                return
            }
            self.simulatorUDID = udid
            print("[Touch] Using simulator UDID: \(udid)")

            if let size = self.queryScreenSizeWithRetries(udid: udid) {
                self.screenWidth = size.width
                self.screenHeight = size.height
                print("[Touch] Screen size: \(size.width)x\(size.height) points")
            } else {
                self.markNotReady(
                    "'idb describe-all' never reported a non-zero device frame for UDID \(udid).",
                    troubleshoot: [
                        "  • Make sure idb_companion is installed: brew list facebook/fb/idb-companion",
                        "  • Make sure .venv/bin/idb works: ./.venv/bin/idb describe-all --udid \(udid) --json",
                        "  • Make sure SpringBoard has finished booting (open the Simulator and unlock).",
                    ]
                )
                return
            }

            if let metrics = self.detectWindowMetrics() {
                self.topBarOffsetMacOS = metrics.topBarOffset
                self.windowHeightMacOS = metrics.windowHeight
                self.contentHeightMacOS = metrics.contentHeight
                print("[Touch] Top bar offset: \(metrics.topBarOffset) pts, window: \(metrics.windowHeight) pts, content: \(metrics.contentHeight) pts")
            } else {
                print("[Touch] WARN: could not detect window metrics via Accessibility — touches will use direct mapping (may be offset if video isn't cropped). Grant Accessibility permission to fix.")
            }

            let socketPath = "/tmp/idb/\(udid)_companion.sock"
            guard FileManager.default.fileExists(atPath: socketPath) else {
                self.markNotReady(
                    "idb_companion socket not found at \(socketPath).",
                    troubleshoot: [
                        "  • idb_companion should auto-start when fb-idb is invoked.",
                        "  • Confirm it's running:    pgrep -fl idb_companion",
                        "  • Start it manually:       idb_companion --udid \(udid) &",
                    ]
                )
                return
            }

            self.startBridge(socketPath: socketPath)
        }
    }

    // MARK: - Bridge process

    private func startBridge(socketPath: String) {
        if let existing = bridgeProcess, existing.isRunning {
            print("[Touch] HID bridge already running (pid \(existing.processIdentifier))")
            markReady()
            return
        }

        let scriptPath = self.bridgeScriptPath()
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            markNotReady(
                "Bridge script not found at \(scriptPath).",
                troubleshoot: [
                    "  • Re-clone the repo; idb_touch_events_bridge.py must sit at the project root.",
                    "  • Make sure ./start.sh is run from the project root directory.",
                ]
            )
            return
        }

        guard let pythonPath = resolvePython() else {
            markNotReady(
                "Python interpreter not found under .venv/bin/python.",
                troubleshoot: [
                    "  • Run ./install_idb.sh from the repo root to create the venv.",
                    "  • Confirm: test -x ./.venv/bin/python && ./.venv/bin/python --version",
                ]
            )
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        print("[Touch] Starting bridge: \(pythonPath) \(scriptPath)")
        print("[Touch] IDB_COMPANION_SOCKET=\(socketPath)")
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["IDB_COMPANION_SOCKET": socketPath]
        ) { _, new in new }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // When the bridge dies unexpectedly, mark the pipeline not-ready so the
        // next touch surfaces a clear error instead of silently disappearing.
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                self.bridgeProcess = nil
                self.bridgeStdin = nil
                self.markNotReady(
                    "Touch bridge process exited unexpectedly (code \(proc.terminationStatus), reason \(proc.terminationReason.rawValue)).",
                    troubleshoot: [
                        "  • Check the [Touch] Bridge stderr lines above for a Python traceback.",
                        "  • Verify the venv still has grpclib + fb-idb installed:",
                        "      ./.venv/bin/python -c 'import grpclib, idb'",
                        "  • Next touch will trigger an automatic retry of the resolve step.",
                    ]
                )
            }
        }

        do {
            try process.run()
        } catch {
            markNotReady(
                "Failed to launch touch bridge subprocess: \(error)",
                troubleshoot: [
                    "  • Confirm the python interpreter is executable: ls -l \(pythonPath)",
                    "  • Try running it by hand: \(pythonPath) \(scriptPath)",
                ]
            )
            return
        }

        self.bridgeProcess = process
        self.bridgeStdin = stdinPipe.fileHandleForWriting

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading

        // Stream stdout
        DispatchQueue.global(qos: .utility).async {
            while let line = self.readLine(from: outHandle) {
                print("[Touch] Bridge stdout: \(line)")
            }
        }

        // Stream stderr
        DispatchQueue.global(qos: .utility).async {
            while let line = self.readLine(from: errHandle) {
                print("[Touch] Bridge stderr: \(line)")
            }
        }

        print("[Touch] Bridge started (pid \(process.processIdentifier))")
        markReady()
    }

    private func sendBridge(_ dict: [String: Any]) {
        guard let stdin = bridgeStdin,
              let proc = bridgeProcess, proc.isRunning,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8) else {
            // Either pipeline isn't up or JSON-encoding failed (shouldn't happen for our payloads).
            logError("sendBridge dropped a touch — bridge not running or payload invalid.")
            kickResolveIfNeeded()
            return
        }
        json += "\n"
        let payload = Data(json.utf8)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try stdin.write(contentsOf: payload)
            } catch {
                // EPIPE / broken pipe — bridge died between the isRunning check and write.
                self.logError("Touch write to bridge failed: \(error). Touch dropped.")
                self.markNotReady(
                    "Touch bridge pipe write failed (\(error)).",
                    troubleshoot: [
                        "  • The bridge likely just crashed; check stderr above for a Python traceback.",
                        "  • Next touch will trigger an automatic retry.",
                    ]
                )
            }
        }
    }

    private func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8) }
            if byte.first == UInt8(ascii: "\n") {
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(byte)
        }
    }

    private func bridgeScriptPath() -> String {
        // Locate idb_touch_events_bridge.py relative to the built binary or the source tree
        let fm = FileManager.default
        // When running from the source tree with `swift run`
        let candidates = [
            // Relative to working directory
            "idb_touch_events_bridge.py",
            // Relative to executable
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("../../../idb_touch_events_bridge.py")
                .standardized.path
        ]
        for path in candidates {
            if fm.fileExists(atPath: path) { return path }
        }
        return candidates[0]
    }

    // MARK: - Simulator discovery (one-time, via CLI)

    private func findBootedUDID() -> String? {
        let output = shell("xcrun", "simctl", "list", "devices", "booted", "-j")
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }
        for (_, devices) in devicesByRuntime {
            for device in devices {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String {
                    return udid
                }
            }
        }
        return nil
    }

    /// SpringBoard often reports 0×0 in `describe-all` briefly after boot; retry before giving up (VM/template races).
    private func queryScreenSizeWithRetries(udid: String) -> CGSize? {
        let maxAttempts = 30
        let delaySeconds: TimeInterval = 1.5
        for attempt in 1...maxAttempts {
            let logDetail = attempt == 1 || attempt % 10 == 0
            if let size = queryScreenSizeOnce(udid: udid, logFailures: logDetail), size.width > 0, size.height > 0 {
                if attempt > 1 {
                    print("[Touch] describe-all returned valid frame on attempt \(attempt)/\(maxAttempts)")
                }
                return size
            }
            if attempt < maxAttempts {
                print("[Touch] describe-all not ready (attempt \(attempt)/\(maxAttempts)), retrying in \(delaySeconds)s…")
                Thread.sleep(forTimeInterval: delaySeconds)
            }
        }
        return nil
    }

    private func queryScreenSizeOnce(udid: String, logFailures: Bool = true) -> CGSize? {
        let output = shell("idb", "ui", "describe-all", "--udid", udid, "--json")
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let frame = first["frame"] as? [String: Any] else {
            if logFailures {
                let snippet = output.count > 400 ? String(output.prefix(400)) + "…" : output
                print("[Touch] describe-all returned unparseable output:\n\(snippet)")
            }
            return nil
        }
        let width = (frame["width"] as? Double) ?? Double(frame["width"] as? Int ?? 0)
        let height = (frame["height"] as? Double) ?? Double(frame["height"] as? Int ?? 0)
        guard width > 0, height > 0 else {
            if logFailures {
                print("[Touch] describe-all returned frame without dimensions: \(frame)")
            }
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Uses macOS Accessibility to find the simulator top bar height and total window height.
    /// Returns values in macOS window points (same coordinate space as SCStream sourceRect).
    private func detectWindowMetrics() -> (topBarOffset: Double, windowHeight: Double, contentHeight: Double)? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard let windows = windowsRef as? [AXUIElement] else { return nil }

        for win in windows {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
            guard (subroleRef as? String) == "AXStandardWindow" else { continue }

            var winPos = CGPoint.zero
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
            if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &winPos) }

            var winSize = CGSize.zero
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
            if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &winSize) }
            guard winSize.height > 0 else { continue }

            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &childrenRef)
            guard let children = childrenRef as? [AXUIElement] else { continue }

            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                guard (roleRef as? String) == "AXGroup" else { continue }

                var childPos = CGPoint.zero
                var cPosRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &cPosRef)
                if let cPosRef { AXValueGetValue(cPosRef as! AXValue, .cgPoint, &childPos) }

                var childSize = CGSize.zero
                var cSizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &cSizeRef)
                if let cSizeRef { AXValueGetValue(cSizeRef as! AXValue, .cgSize, &childSize) }
                guard childSize.height > 0 else { continue }

                let topBarOffset = Double(childPos.y - winPos.y)
                return (topBarOffset: topBarOffset, windowHeight: Double(winSize.height), contentHeight: Double(childSize.height))
            }
        }
        return nil
    }

    /// Returns the python interpreter from the uv-managed venv created by install.sh.
    private func resolvePython() -> String? { resolveVenvBinary("python") }

    /// idb lives in the venv created by install.sh. PATH may not include that
    /// venv when launched from outside a terminal (e.g. start.sh, launchd),
    /// so we locate it explicitly rather than relying on `env idb`.
    private func resolveIDB() -> String? { resolveVenvBinary("idb") }

    /// Always returns an **absolute** path. Relative paths (e.g. `.venv/bin/idb`)
    /// break `Process.executableURL` when cwd is not the repo root (Xcode, Finder, etc.).
    private func resolveVenvBinary(_ name: String) -> String? {
        let fm = FileManager.default
        let suffix = ".venv/bin/\(name)"

        func ok(_ path: String) -> Bool {
            fm.fileExists(atPath: path) && fm.isExecutableFile(atPath: path)
        }

        var roots: [String] = []
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL.path
        roots.append(cwd)

        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        var dir = URL(fileURLWithPath: exe).deletingLastPathComponent().path
        for _ in 0..<12 {
            if !roots.contains(dir) { roots.append(dir) }
            let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
            if parent == dir { break }
            dir = parent
        }

        for root in roots {
            let path = URL(fileURLWithPath: root).appendingPathComponent(suffix).standardizedFileURL.path
            if ok(path) { return path }
        }
        return nil
    }

    private func shell(_ command: String, _ args: String...) -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        // Prefer the venv copy of idb so we don't depend on PATH configuration.
        if command == "idb", let idbPath = resolveIDB() {
            process.executableURL = URL(fileURLWithPath: idbPath)
            process.arguments = args
        } else if command == "idb" {
            print("[ERROR][Touch] idb not found under .venv/bin — run ./install_idb.sh from the repo root (needs fb-idb). Falling back to PATH.")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        process.standardOutput = outPipe
        process.standardError = errPipe
        let label = "\(command) \(args.joined(separator: " "))"
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[Shell] launch failed: \(label) error=\(error)")
            return ""
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let code = process.terminationStatus
        let outTrim = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let errTrim = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || (outTrim.isEmpty && !errTrim.isEmpty) {
            print("[Shell] \(label) exit=\(code) stdoutBytes=\(stdout.utf8.count) stderr=\(snippet(errTrim))")
        } else if !errTrim.isEmpty {
            print("[Shell] \(label) exit=\(code) stderr=\(snippet(errTrim))")
        }
        return outTrim
    }

    private func snippet(_ s: String, max: Int = 400) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    // MARK: - Readiness / diagnostics

    /// Mark the pipeline up; loud-log the transition and reset error-suppression.
    private func markReady() {
        if !ready { print("[Touch] ✓ Touch pipeline ready — touches will now reach the simulator.") }
        ready = true
        lastLoggedUnreadyReason = nil
    }

    /// Mark the pipeline broken with a human-readable cause + actionable hints.
    /// Logs at most once per distinct reason so we don't flood the console.
    private func markNotReady(_ reason: String, troubleshoot: [String] = []) {
        ready = false
        unreadyReason = reason
        if lastLoggedUnreadyReason != reason {
            lastLoggedUnreadyReason = reason
            print("")
            print("[ERROR][Touch] \(reason)")
            if !troubleshoot.isEmpty {
                print("[Touch] Troubleshooting:")
                for line in troubleshoot { print("[Touch] \(line)") }
            }
            print("")
        }
    }

    /// Loud one-line error (no troubleshooting payload).
    private func logError(_ message: String) {
        print("[ERROR][Touch] \(message)")
    }

    /// If the pipeline isn't ready and no resolve is in flight, schedule one.
    /// Called from touch paths to auto-recover after transient failures.
    private func kickResolveIfNeeded() {
        if !ready && !resolveInFlight {
            resolveSimulator()
        }
    }
}
