import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// Disable stdout buffering so print() shows immediately in background
setbuf(stdout, nil)

// Writing to a dead pipe (e.g. crashed touch bridge) would otherwise kill us
// with SIGPIPE. We catch the resulting EPIPE explicitly at the write site.
signal(SIGPIPE, SIG_IGN)

// Disable simulator device bezels for a cleaner capture
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["write", "com.apple.iphonesimulator", "ShowDeviceBezels", "-bool", "false"]
    try p.run()
    p.waitUntilExit()
} catch {
    print("[App] Warning: could not disable simulator bezels: \(error)")
}

// Permission preflight — fail loudly with troubleshooting if anything is missing.
preflightPermissions()

// Initialize the AppKit/CoreGraphics subsystem required by ScreenCaptureKit
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let app = StreamingApp()
app.start()
RunLoop.main.run()


// MARK: - Permission preflight

private func preflightPermissions() {
    // 1. Screen Recording — REQUIRED. Without it capture is impossible.
    // CGRequestScreenCaptureAccess() triggers the system prompt the first time
    // an unsigned binary asks; it returns the current grant state synchronously.
    let screenGranted = CGRequestScreenCaptureAccess()
    if !screenGranted {
        printPermissionBox(
            level: "FATAL",
            title: "Screen Recording permission MISSING (required)",
            lines: [
                "ScreenCaptureKit cannot capture the Simulator window without it.",
                "",
                "Fix:",
                "  1. Open  System Settings → Privacy & Security → Screen Recording",
                "  2. Enable the toggle for Terminal (or whichever app launched this binary)",
                "  3. Fully quit Terminal (⌘Q on every window) and reopen it",
                "  4. Re-run ./start.sh",
                "",
                "VM/Tart hosts with SIP disabled: patch TCC.db to grant silently.",
            ]
        )
        exit(2)
    }

    // 2. Accessibility — REQUIRED. Without it we cannot measure the simulator
    // title bar, so touches end up offset and the capture isn't cropped.
    if !AXIsProcessTrusted() {
        printPermissionBox(
            level: "FATAL",
            title: "Accessibility permission MISSING (required)",
            lines: [
                "Without it:",
                "  • The captured video can't be cropped to the device screen.",
                "  • Touch coordinates will be misaligned (top bar offset uncorrected).",
                "",
                "Fix:",
                "  1. Open  System Settings → Privacy & Security → Accessibility",
                "  2. Enable the toggle for Terminal (or whichever app launched this binary)",
                "  3. Fully quit Terminal (⌘Q on every window) and reopen it",
                "  4. Re-run ./start.sh",
                "",
                "VM/Tart hosts with SIP disabled: patch TCC.db to grant silently.",
            ]
        )
        exit(5)
    }
}

private func printPermissionBox(level: String, title: String, lines: [String]) {
    let bar = String(repeating: "═", count: 72)
    print("")
    print(bar)
    print("[\(level)] \(title)")
    print(bar)
    for l in lines { print(l) }
    print(bar)
    print("")
}
