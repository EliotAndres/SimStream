import AppKit

/// Shared AX window selection and geometry for capture and touch mapping.
enum SimulatorWindow {
    static let deviceHubBundleID = "com.apple.dt.Devices"
    static let bundleIDs = [deviceHubBundleID, "com.apple.iphonesimulator"]

    struct Target {
        let processID: pid_t
        let bundleID: String
        let title: String
        let frame: CGRect
        var compactConfirmed = false
    }

    struct Metrics {
        let windowFrame: CGRect
        let contentRect: CGRect
    }

    static func titlePriority(_ title: String) -> Int {
        title.localizedCaseInsensitiveContains("iOS") ? 1 : 0
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // Timeouts are per AX object; setting one on the app does not cover children.
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func window(for target: Target) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.processID)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            attribute($0, kAXSubroleAttribute) as? String == "AXStandardWindow"
        }
        // Match the captured window, never a different device's first AX window.
        // ScreenCaptureKit reports "iPhone 17 Pro" where AX reports
        // "iPhone 17 Pro – iOS 27.2", so match on a shared prefix, not equality.
        let titled = windows.filter { window in
            guard let title = attribute(window, kAXTitleAttribute) as? String else { return false }
            if title == target.title { return true }
            guard !target.title.isEmpty, !title.isEmpty else { return false }
            return title.hasPrefix(target.title) || target.title.hasPrefix(title)
        }
        // With no title match, fall back to the AX window nearest the captured frame.
        return (titled.isEmpty ? windows : titled).min { lhs, rhs in
            func distance(_ element: AXUIElement) -> CGFloat {
                guard let rect = frame(element) else { return .greatestFiniteMagnitude }
                return abs(rect.minX - target.frame.minX) + abs(rect.minY - target.frame.minY)
            }
            return distance(lhs) < distance(rhs)
        }
    }

    /// The switch lives in the toolbar, possibly beneath AX groups.
    static func compactButton(in window: AXUIElement, deadline: Date) -> AXUIElement? {
        var pending = [(window, 0)]
        var visited = 0
        while let (element, depth) = pending.popLast(), Date() < deadline, visited < 128 {
            visited += 1
            if attribute(element, kAXRoleAttribute) as? String == "AXButton",
               attribute(element, kAXDescriptionAttribute) as? String == "Switch to compact window" {
                return element
            }
            if depth < 6 { pending += children(element).map { ($0, depth + 1) } }
        }
        return nil
    }

    /// Compact Device Hub has a full-window group and a separate thin, full-width
    /// toolbar/top group. The full-window group is NOT the device screen.
    static func topBarHeight(in window: AXUIElement, frame windowFrame: CGRect) -> CGFloat? {
        let directChildren = children(window)
        let candidates = directChildren + directChildren.flatMap { children($0) }
        return candidates.compactMap { child -> CGFloat? in
            let role = attribute(child, kAXRoleAttribute) as? String
            guard role == "AXToolbar" || role == "AXGroup",
                  let rect = frame(child),
                  abs(rect.minY - windowFrame.minY) <= 2,
                  abs(rect.minX - windowFrame.minX) <= 2,
                  abs(rect.width - windowFrame.width) <= 2,
                  rect.height < windowFrame.height / 4 else { return nil }
            return rect.maxY - windowFrame.minY
        }.max()
    }

    /// Compact Device Hub draws the phone screen as an AXGroup inset inside the
    /// window (e.g. 188x410 at local (21,61) in a 230x532 window) with a button
    /// strip underneath, so "everything below the top bar" is NOT the device.
    /// Pick the largest AXGroup that sits below the bar and is narrower than the window.
    static func deviceScreenFrame(in window: AXUIElement, frame windowFrame: CGRect, top: CGFloat) -> CGRect? {
        var best: CGRect?
        var pending = children(window).map { ($0, 1) }
        var visited = 0
        while let (element, depth) = pending.popLast(), visited < 64 {
            visited += 1
            guard attribute(element, kAXRoleAttribute) as? String == "AXGroup",
                  let rect = frame(element) else { continue }
            let inset = rect.width < windowFrame.width - 2
                && rect.minY >= windowFrame.minY + top - 1
                && windowFrame.insetBy(dx: -1, dy: -1).contains(rect)
            if inset, rect.width * rect.height > (best.map { $0.width * $0.height } ?? 0) { best = rect }
            if depth < 2 { pending += children(element).map { ($0, depth + 1) } }
        }
        return best
    }

    /// Called once before capture, never from the touch pipeline.
    /// Returns true only when compact geometry is established.
    static func prepareDeviceHub(_ target: Target) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        guard let window = window(for: target), let originalFrame = frame(window) else {
            print("[Capture] Device Hub AX window unavailable; capturing whole window")
            return false
        }
        guard let button = compactButton(in: window, deadline: deadline) else {
            // No compact switch means the window is already compact. Confirm by the
            // inset device element rather than by width: a compact window can be
            // dragged larger than any fixed threshold.
            if Date() < deadline, let top = topBarHeight(in: window, frame: originalFrame),
               originalFrame.width <= 400 || deviceScreenFrame(in: window, frame: originalFrame, top: top) != nil {
                return true
            }
            print("[Capture] Device Hub compact switch not found; capturing whole window")
            return false
        }
        print("[Capture] Switching Device Hub to compact mode")
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            print("[Capture] Device Hub compact switch failed; capturing whole window")
            return false
        }
        var previousFrame: CGRect?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let current = self.window(for: target), let rect = frame(current) else { continue }
            // Wait for the resize to settle, including compact windows zoomed above 400 pt.
            if rect.size != originalFrame.size, rect == previousFrame,
               compactButton(in: current, deadline: deadline) == nil,
               Date() < deadline, topBarHeight(in: current, frame: rect) != nil {
                print("[Capture] Device Hub compact mode ready")
                return true
            }
            previousFrame = rect
        }
        print("[Capture] Device Hub compact switch timed out; capturing whole window")
        return false
    }

    static func metrics(for target: Target) -> Metrics? {
        guard let window = window(for: target), let windowFrame = frame(window) else { return nil }
        if target.bundleID == deviceHubBundleID {
            guard target.compactConfirmed,
                  let top = topBarHeight(in: window, frame: windowFrame) else { return nil }
            if let screen = deviceScreenFrame(in: window, frame: windowFrame, top: top) {
                return Metrics(windowFrame: windowFrame,
                               contentRect: screen.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
            }
            // No inset device element found: fall back to everything below the top bar.
            return Metrics(windowFrame: windowFrame,
                           contentRect: CGRect(x: 0, y: top, width: windowFrame.width,
                                               height: windowFrame.height - top))
        }
        // Legacy Simulator exposes the actual device screen as an AXGroup.
        for child in children(window) {
            guard attribute(child, kAXRoleAttribute) as? String == "AXGroup",
                  let rect = frame(child) else { continue }
            return Metrics(windowFrame: windowFrame,
                           contentRect: rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
        }
        return nil
    }
}
