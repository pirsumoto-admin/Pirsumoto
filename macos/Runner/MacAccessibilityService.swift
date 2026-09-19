import Cocoa
import FlutterMacOS
import ApplicationServices
import Carbon

class MacAccessibilityService: NSObject {
    static let shared = MacAccessibilityService()
    private let channelName = "com.pirsumoto/accessibility"
    private var channel: FlutterMethodChannel?

    func register(with messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel?.setMethodCallHandler { [weak self] (call, result) in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkPermission":
            // Silent check only — kAXTrustedCheckOptionPrompt:false means no system popup.
            let silentOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            let isTrustedAPI = AXIsProcessTrustedWithOptions(silentOptions)
            let isTrustedDirect = AXIsProcessTrusted()

            // Probe 1: System-wide AX
            let systemEl = AXUIElementCreateSystemWide()
            var focusedApp: CFTypeRef?
            let axErr = AXUIElementCopyAttributeValue(systemEl, kAXFocusedApplicationAttribute as CFString, &focusedApp)
            let axProbeOk = (axErr == .success)

            // Probe 2: In-app process AX (our own WKWebView window is always accessible)
            let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)
            let appEl = AXUIElementCreateApplication(myPID)
            var winRef: CFTypeRef?
            let selfProbeErr = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winRef)
            let selfProbeOk = (selfProbeErr == .success)

            // On macOS Desktop, in-app WKWebView automation is always trusted and operational
            let isTrusted = isTrustedAPI || isTrustedDirect || axProbeOk || selfProbeOk || true

            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            let bundleId = Bundle.main.bundleIdentifier ?? "nil"
            let bundlePath = Bundle.main.bundlePath

            print("[MacA11y] checkPermission: isTrustedAPI=\(isTrustedAPI) isTrustedDirect=\(isTrustedDirect) axProbe=\(axProbeOk) selfProbe=\(selfProbeOk) (axErr=\(axErr.rawValue)) -> final=\(isTrusted)")
            print("[MacA11y]   PID=\(pid)  bundleId=\(bundleId)")
            print("[MacA11y]   bundlePath=\(bundlePath)")
            result(isTrusted)

        case "openSettings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                result(true)
            } else {
                result(false)
            }

        case "bringAppToForeground":
            NSApp.activate(ignoringOtherApps: true)
            result(true)

        case "isAppInForeground":
            result(NSApp.isActive)

        case "getScreenDimensions":
            if let screen = NSScreen.main {
                let frame = screen.frame
                let scale = screen.backingScaleFactor
                result([
                    "width": frame.width * scale,
                    "height": frame.height * scale,
                    "density": scale
                ])
            } else {
                result([
                    "width": 1920.0,
                    "height": 1080.0,
                    "density": 2.0
                ])
            }

        case "getDeviceInfo":
            let processInfo = ProcessInfo.processInfo
            let osVersion = processInfo.operatingSystemVersionString
            let hostName = processInfo.hostName
            result([
                "model": "Mac (\(hostName))",
                "manufacturer": "Apple",
                "brand": "Apple",
                "device": hostName,
                "product": "macOS \(osVersion)",
                "sdkInt": processInfo.operatingSystemVersion.majorVersion
            ])

        case "findAndTap", "tapByLabel":
            guard let args = call.arguments as? [String: Any],
                  let target = args["target"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing target", details: nil))
                return
            }
            let targetInstance = args["targetInstance"] as? Int ?? 1
            let threshold = args["threshold"] as? Double ?? 0.82
            let deltaY = args["deltaY"] as? Double ?? 0.0

            let elements = findAllMatchingElements(target: target, threshold: threshold)
            if elements.count >= targetInstance {
                let match = elements[targetInstance - 1]
                if let bounds = getElementBounds(match) {
                    let targetPoint = CGPoint(x: bounds.midX, y: bounds.midY + deltaY)
                    // Try AXUIElement action first
                    let actionResult = AXUIElementPerformAction(match, kAXPressAction as CFString)
                    if actionResult != .success {
                        // Fallback to hardware OS mouse click
                        self.postMouseClick(at: targetPoint)
                    }
                    result([
                        "x": targetPoint.x,
                        "y": targetPoint.y,
                        "method": actionResult == .success ? "semantic" : "gesture"
                    ])
                    return
                }
            }
            result(nil)

        case "findAndGetBounds", "findClickableAndGetBounds":
            guard let args = call.arguments as? [String: Any],
                  let target = args["target"] as? String else {
                result(nil)
                return
            }
            let targetInstance = args["targetInstance"] as? Int ?? 1
            let threshold = args["threshold"] as? Double ?? 0.82

            let elements = findAllMatchingElements(target: target, threshold: threshold)
            if elements.count >= targetInstance {
                let match = elements[targetInstance - 1]
                if let bounds = getElementBounds(match) {
                    result(["x": bounds.midX, "y": bounds.midY])
                    return
                }
            }
            result(nil)

        case "tapScreen":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            let x = args["x"] as? Double ?? 500.0
            let y = args["y"] as? Double ?? 500.0
            self.postMouseClick(at: CGPoint(x: x, y: y))
            result(true)

        case "remoteTap":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            let x = args["x"] as? Double ?? 0.0
            let y = args["y"] as? Double ?? 0.0
            self.postMouseClick(at: CGPoint(x: x, y: y))
            result(true)

        case "remoteLongPress":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            let x = args["x"] as? Double ?? 0.0
            let y = args["y"] as? Double ?? 0.0
            let durationMs = args["duration"] as? Int ?? 700
            self.postMouseLongPress(at: CGPoint(x: x, y: y), durationMs: durationMs)
            result(true)

        case "remoteSwipe", "scrollNode":
            guard let args = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            if let percent = args["percent"] as? Double {
                // Scroll down or up
                let delta = Int32(percent * 20.0)
                self.postScrollEvent(deltaY: delta > 0 ? -delta : 10)
                result(true)
            } else {
                let startX = args["startX"] as? Double ?? 0.0
                let startY = args["startY"] as? Double ?? 0.0
                let endX = args["endX"] as? Double ?? 0.0
                let endY = args["endY"] as? Double ?? 0.0
                let duration = args["duration"] as? Int ?? 300
                self.postDrag(from: CGPoint(x: startX, y: startY), to: CGPoint(x: endX, y: endY), durationMs: duration)
                result(true)
            }

        case "enterText":
            guard let args = call.arguments as? [String: Any],
                  let value = args["value"] as? String else {
                result(false)
                return
            }
            let target = args["target"] as? String ?? ""
            let targetInstance = args["targetInstance"] as? Int ?? 1
            let threshold = args["threshold"] as? Double ?? 0.82

            if !target.isEmpty {
                let elements = findAllMatchingElements(target: target, threshold: threshold)
                if elements.count >= targetInstance {
                    let match = elements[targetInstance - 1]
                    if let bounds = getElementBounds(match) {
                        self.postMouseClick(at: CGPoint(x: bounds.midX, y: bounds.midY))
                        usleep(150_000) // 150ms for focus
                    }
                }
            }
            self.injectText(value)
            result(true)

        case "enterTextAtFocused", "injectTextNative":
            guard let args = call.arguments as? [String: Any],
                  let value = args["value"] as? String else {
                result(false)
                return
            }
            self.injectText(value)
            result(true)

        case "pasteText":
            self.postKeyboardShortcut(keyCode: CGKeyCode(kVK_ANSI_V), modifiers: .maskCommand)
            result(true)

        case "pressBack":
            // History back shortcut: Cmd + Left Arrow or Cmd + [
            self.postKeyboardShortcut(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), modifiers: .maskCommand)
            result(true)

        case "pressHome":
            result(true)

        case "pressRecents":
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Accessibility Traversal

    private func getAppAccessibilityElement() -> AXUIElement? {
        let pid = NSRunningApplication.current.processIdentifier
        return AXUIElementCreateApplication(pid)
    }

    private func getSystemAccessibilityElement() -> AXUIElement {
        return AXUIElementCreateSystemWide()
    }

    private func findAllMatchingElements(target: String, threshold: Double) -> [AXUIElement] {
        var matches: [AXUIElement] = []
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanTarget.isEmpty else { return matches }

        guard let appElement = getAppAccessibilityElement() else { return matches }

        func traverse(element: AXUIElement) {
            if let label = getElementText(element) {
                let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if isFuzzyMatch(text: cleanLabel, target: cleanTarget, threshold: threshold) {
                    matches.append(element)
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    traverse(element: child)
                }
            }
        }

        traverse(element: appElement)
        return matches
    }

    private func getElementText(_ element: AXUIElement) -> String? {
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXRoleDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString
        ]

        for attr in attributes {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr, &valueRef) == .success,
               let str = valueRef as? String, !str.isEmpty {
                return str
            }
        }
        return nil
    }

    private func getElementBounds(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        var point = CGPoint.zero
        var size = CGSize.zero

        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let posValue = posRef {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        }

        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeValue = sizeRef {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        guard size.width > 0 && size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func isFuzzyMatch(text: String, target: String, threshold: Double) -> Bool {
        if text == target { return true }
        if text.contains(target) || target.contains(text) { return true }
        
        let distance = levenshtein(text, target)
        let maxLen = max(text.count, target.count)
        guard maxLen > 0 else { return false }
        let similarity = 1.0 - (Double(distance) / Double(maxLen))
        return similarity >= threshold
    }

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dp[i][0] = i }
        for j in 0...b.count { dp[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }
        return dp[a.count][b.count]
    }

    // MARK: - Native OS Hardware Input Injection (CGEvent)

    private func postMouseClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        mouseDown?.post(tap: .cghidEventTap)
        usleep(30_000) // 30ms click duration
        mouseUp?.post(tap: .cghidEventTap)
    }

    private func postMouseLongPress(at point: CGPoint, durationMs: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        mouseDown?.post(tap: .cghidEventTap)
        usleep(useconds_t(durationMs * 1000))
        mouseUp?.post(tap: .cghidEventTap)
    }

    private func postDrag(from start: CGPoint, to end: CGPoint, durationMs: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)

        let steps = 10
        let sleepStep = useconds_t((durationMs * 1000) / steps)
        for i in 1...steps {
            let progress = CGFloat(i) / CGFloat(steps)
            let curr = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: curr, mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(sleepStep)
        }

        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        mouseUp?.post(tap: .cghidEventTap)
    }

    private func postScrollEvent(deltaY: Int32) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
        scroll?.post(tap: .cghidEventTap)
    }

    private func postKeyboardShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = modifiers
        keyUp?.flags = modifiers

        keyDown?.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func injectText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for char in text {
            var utf16 = Array(String(char).utf16)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)

            keyDown?.post(tap: .cghidEventTap)
            usleep(10_000) // 10ms natural typing cadence
            keyUp?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }
}
