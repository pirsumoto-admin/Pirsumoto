import Cocoa
import FlutterMacOS
import ApplicationServices
import Carbon
import WebKit

/// macOS-only native web automation service.
///
/// Implements pre-order accessibility tree traversal, Hebrew text normalization,
/// fuzzy similarity matching, pipe (`|`) alternative target splitting, and
/// hardware-level CGEvent input injection matching the Android automation architecture.
///
/// Targets the active WKWebView instance directly using AppKit NSAccessibility with
/// fallback to AXUIElement.
///
/// Channel: com.pirsumoto/mac_web
class MacWebAutomationService: NSObject {
    static let shared = MacWebAutomationService()
    private let channelName = "com.pirsumoto/mac_web"
    private var channel: FlutterMethodChannel?

    func register(with messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel?.setMethodCallHandler { [weak self] (call, result) in
            self?.handle(call, result: result)
        }
    }

    // MARK: - Channel Dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            switch call.method {

            case "findAndGetBounds":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let instance  = args["targetInstance"] as? Int ?? 1
                let threshold = args["threshold"] as? Double ?? 0.82
                let b = self.findWebElementBounds(target: target, threshold: threshold, instance: instance)
                DispatchQueue.main.async {
                    if let b = b {
                        result(["x": b.midX, "y": b.midY])
                    } else {
                        result(nil)
                    }
                }

            case "findAndTap":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(false) }
                    return
                }
                let instance  = args["targetInstance"] as? Int ?? 1
                let threshold = args["threshold"] as? Double ?? 0.82
                let deltaY    = args["deltaY"] as? Double ?? 0.0
                if let b = self.findWebElementBounds(target: target, threshold: threshold, instance: instance) {
                    let pt = CGPoint(x: b.midX, y: b.midY + deltaY)
                    self.postMouseClick(at: pt)
                    DispatchQueue.main.async { result(true) }
                } else {
                    DispatchQueue.main.async { result(false) }
                }

            case "isPresent":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(false) }
                    return
                }
                let instance = args["targetInstance"] as? Int ?? 1
                let found = self.findWebElementBounds(target: target, threshold: 0.82, instance: instance) != nil
                DispatchQueue.main.async { result(found) }

            case "findNodeAfterAndGetBounds":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let instance  = args["targetInstance"] as? Int ?? 1
                let threshold = args["threshold"] as? Double ?? 0.82
                let offset    = args["offset"] as? Int ?? 1
                let b = self.findNodeAfterTarget(target: target, targetInstance: instance, threshold: threshold, offset: offset)
                DispatchQueue.main.async {
                    if let b = b {
                        result(["x": b.midX, "y": b.midY])
                    } else {
                        result(nil)
                    }
                }

            case "findNodeBeforeAndGetBounds":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let instance  = args["targetInstance"] as? Int ?? 1
                let threshold = args["threshold"] as? Double ?? 0.82
                let b = self.findNodeBeforeTarget(target: target, targetInstance: instance, threshold: threshold)
                DispatchQueue.main.async {
                    if let b = b {
                        result(["x": b.midX, "y": b.midY])
                    } else {
                        result(nil)
                    }
                }

            case "findInputBeforeAndGetBounds":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let instance  = args["targetInstance"] as? Int ?? 1
                let threshold = args["threshold"] as? Double ?? 0.82
                let b = self.findInputBeforeTarget(target: target, targetInstance: instance, threshold: threshold)
                DispatchQueue.main.async {
                    if let b = b {
                        result(["x": b.midX, "y": b.midY])
                    } else {
                        result(nil)
                    }
                }

            case "findNodeTextAfterTarget":
                guard let args = call.arguments as? [String: Any],
                      let target = args["target"] as? String else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let instance  = args["targetInstance"] as? Int ?? 1
                let threshold = args["threshold"] as? Double ?? 0.82
                let offset    = args["offset"] as? Int ?? 1
                let text = self.findNodeTextAfterTarget(target: target, targetInstance: instance, threshold: threshold, offset: offset)
                DispatchQueue.main.async { result(text) }

            case "tapScreen":
                guard let args = call.arguments as? [String: Any] else {
                    DispatchQueue.main.async { result(false) }
                    return
                }
                let x = args["x"] as? Double ?? 0.0
                let y = args["y"] as? Double ?? 0.0
                
                DispatchQueue.main.async {
                    var globalPt = CGPoint(x: x, y: y)
                    if let window = NSApp.mainWindow ?? NSApp.windows.first,
                       let screen = window.screen ?? NSScreen.screens.first {
                        let contentRect = window.contentRect(forFrameRect: window.frame)
                        let cgTopY = screen.frame.height - (contentRect.origin.y + contentRect.height)
                        globalPt = CGPoint(x: contentRect.origin.x + x, y: cgTopY + y)
                    }
                    
                    // Post mouse click off the main thread so we don't block
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.postMouseClick(at: globalPt)
                        DispatchQueue.main.async { result(true) }
                    }
                }

            case "enterTextAtFocused", "injectTextNative":
                guard let args = call.arguments as? [String: Any],
                      let value = args["value"] as? String else {
                    DispatchQueue.main.async { result(false) }
                    return
                }
                self.injectText(value)
                DispatchQueue.main.async { result(true) }

            case "pressBack":
                self.postKeyboardShortcut(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), modifiers: .maskCommand)
                DispatchQueue.main.async { result(true) }

            case "scrollNode":
                guard let args = call.arguments as? [String: Any] else {
                    DispatchQueue.main.async { result(false) }
                    return
                }
                let percent   = args["percent"] as? Double ?? 0.3
                let direction = args["direction"] as? String ?? "down"
                let delta     = Int32(percent * 20.0)
                self.postScrollEvent(deltaY: direction == "down" ? -delta : delta)
                DispatchQueue.main.async { result(true) }

            case "logTree":
                let dump = self.dumpWebTree()
                print("[MacWeb] Tree dump:\n\(dump)")
                DispatchQueue.main.async { result(dump) }

            case "captureScreenshot":
                DispatchQueue.main.async {
                    if let wk = self.getAllWKWebViews().first {
                        let config = WKSnapshotConfiguration()
                        wk.takeSnapshot(with: config) { image, error in
                            if let image = image,
                               let tiffData = image.tiffRepresentation,
                               let bitmap = NSBitmapImageRep(data: tiffData),
                               let pngData = bitmap.representation(using: .png, properties: [:]) {
                                result(FlutterStandardTypedData(bytes: pngData))
                            } else {
                                self.captureWindowImage(result: result)
                            }
                        }
                    } else {
                        self.captureWindowImage(result: result)
                    }
                }

            default:
                DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
            }
        }
    }

    private func captureWindowImage(result: @escaping FlutterResult) {
        if let window = NSApp.mainWindow ?? NSApp.windows.first,
           let view = window.contentView {
            let bounds = view.bounds
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: bitmap)
                if let pngData = bitmap.representation(using: .png, properties: [:]) {
                    result(FlutterStandardTypedData(bytes: pngData))
                    return
                }
            }
        }
        result(nil)
    }

    // MARK: - WKWebView Discovery

    private func getAllWKWebViews() -> [WKWebView] {
        var list: [WKWebView] = []
        var visitedViews = Set<NSView>()
        var visitedWindows = Set<NSWindow>()

        var allWindows = NSApp.windows + NSApp.orderedWindows
        if let kw = NSApp.keyWindow { allWindows.append(kw) }
        if let mw = NSApp.mainWindow { allWindows.append(mw) }

        for window in allWindows {
            guard !visitedWindows.contains(window) else { continue }
            visitedWindows.insert(window)
            if let cv = window.contentView {
                list += findWKWebViews(in: cv, visited: &visitedViews)
            }
            if let children = window.childWindows {
                for cw in children {
                    guard !visitedWindows.contains(cw) else { continue }
                    visitedWindows.insert(cw)
                    if let cv = cw.contentView {
                        list += findWKWebViews(in: cv, visited: &visitedViews)
                    }
                }
            }
        }
        return list
    }

    private func findWKWebViews(in view: NSView, visited: inout Set<NSView>) -> [WKWebView] {
        guard !visited.contains(view) else { return [] }
        visited.insert(view)
        var list: [WKWebView] = []
        if let wv = view as? WKWebView {
            list.append(wv)
        }
        for sub in view.subviews {
            list += findWKWebViews(in: sub, visited: &visited)
        }
        return list
    }

    // MARK: - Tree Representation

    struct FlatNode {
        let role: String
        let text: String
        let bounds: CGRect
        let isEditable: Bool
        let isClickable: Bool
        let hasText: Bool
    }

    private func getAllNodes() -> [FlatNode] {
        let pid = NSRunningApplication.current.processIdentifier
        var allNodes: [FlatNode] = []
        
        if let app = AXUIElementCreateApplication(pid) as AXUIElement? {
            // Force WebKit to generate full accessibility tree
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        // Primary: Traverse AppKit WKWebViews on main thread (Native WebKit Accessibility)
        DispatchQueue.main.sync {
            let webViews = self.getAllWKWebViews()
            for wv in webViews {
                // Post layout changed to the actual WKWebView NSView to force it to wake up the web process accessibility bridge
                NSAccessibility.post(element: wv, notification: .layoutChanged)
                allNodes += self.collectAccessibilityNodes(from: wv)
            }
        }

        // Fallback: Traverse the whole app via AXUIElement (only if web views weren't found)
        // Note: Running this on a background thread against Flutter views can crash the app!
        if allNodes.isEmpty {
            DispatchQueue.main.sync {
                if let app = AXUIElementCreateApplication(pid) as AXUIElement? {
                    var windowsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                       let windows = windowsRef as? [AXUIElement] {
                        for win in windows {
                            allNodes += self.collectAllAXNodes(from: win)
                        }
                    }
                }
            }
        }

        return allNodes
    }

    // MARK: - AppKit Multi-Layer NSAccessibility Traversal

    private func collectAccessibilityNodes(from object: AnyObject, depth: Int = 0) -> [FlatNode] {
        guard depth < 100 else { return [] }
        
        if CFGetTypeID(object) == AXUIElementGetTypeID() {
            let axElement = object as! AXUIElement
            return collectAllAXNodes(from: axElement, depth: depth)
        }
        
        var list: [FlatNode] = []

        let role = getObjectRole(object)
        let text = getObjectText(object)
        let bounds = getObjectBounds(object)
        let isEditable = role.contains("TextField") || role.contains("TextArea") || role.contains("ComboBox") || role.contains("SearchField")
        let isClickable = role.contains("Button") || role.contains("Link") || role.contains("MenuItem") || role.contains("PopUpButton") || role.contains("CheckBox") || role.contains("RadioButton")
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        list.append(FlatNode(role: role, text: text, bounds: bounds, isEditable: isEditable, isClickable: isClickable, hasText: hasText))

        let children = getObjectChildren(object)
        for child in children {
            list += collectAccessibilityNodes(from: child, depth: depth + 1)
        }
        return list
    }

    private func safePerformSelector(_ object: AnyObject, _ selectorName: String) -> AnyObject? {
        let sel = NSSelectorFromString(selectorName)
        if object.responds(to: sel) {
            return object.perform(sel)?.takeUnretainedValue()
        }
        return nil
    }

    private func safeGetAttributeValue(_ object: AnyObject, _ attribute: String) -> AnyObject? {
        let sel = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel, with: attribute as NSString)?.takeUnretainedValue()
    }

    private func getObjectRole(_ object: AnyObject) -> String {
        var mainRole = ""
        var subRole = ""

        if let ax = object as? NSAccessibilityProtocol {
            if let r = ax.accessibilityRole() {
                mainRole = r.rawValue
            }
            if let sr = ax.accessibilitySubrole() {
                subRole = sr.rawValue
            }
        }
        if mainRole.isEmpty || mainRole == "AXUnknown", let r = safePerformSelector(object, "accessibilityRole") as? String {
            mainRole = r
        }
        if mainRole.isEmpty || mainRole == "AXUnknown", let r = safePerformSelector(object, "accessibilityRole") as? NSAccessibility.Role {
            mainRole = r.rawValue
        }
        if mainRole.isEmpty || mainRole == "AXUnknown", let r = safeGetAttributeValue(object, "AXRole") as? String {
            mainRole = r
        }
        if subRole.isEmpty, let sr = safePerformSelector(object, "accessibilitySubrole") as? String {
            subRole = sr
        }
        if subRole.isEmpty, let sr = safePerformSelector(object, "accessibilitySubrole") as? NSAccessibility.Subrole {
            subRole = sr.rawValue
        }
        if subRole.isEmpty, let sr = safeGetAttributeValue(object, "AXSubrole") as? String {
            subRole = sr
        }

        if !subRole.isEmpty && !mainRole.isEmpty {
            return "\(mainRole):\(subRole)"
        }
        return mainRole.isEmpty ? subRole : mainRole
    }

    private func getObjectBounds(_ object: AnyObject) -> CGRect {
        if let ax = object as? NSAccessibilityProtocol {
            let f = ax.accessibilityFrame()
            if f.width > 0 && f.height > 0 { return toQuartzRect(f) }
        }
        if let val = safePerformSelector(object, "accessibilityFrame") as? NSValue {
            let f = val.rectValue
            if f.width > 0 && f.height > 0 { return toQuartzRect(f) }
        }
        if let v = object as? NSView {
            let f = v.accessibilityFrame()
            if f.width > 0 && f.height > 0 { return toQuartzRect(f) }
        }
        if let posVal = safeGetAttributeValue(object, "AXPosition") as? NSValue,
           let sizeVal = safeGetAttributeValue(object, "AXSize") as? NSValue {
            let pt = posVal.pointValue
            let sz = sizeVal.sizeValue
            if sz.width > 0 && sz.height > 0 {
                return toQuartzRect(NSRect(origin: pt, size: sz))
            }
        }
        if let frameVal = safeGetAttributeValue(object, "AXFrame") as? NSValue {
            let f = frameVal.rectValue
            if f.width > 0 && f.height > 0 { return toQuartzRect(f) }
        }
        return .zero
    }

    private func getObjectText(_ object: AnyObject) -> String {
        // 1. accessibilityValue via NSAccessibilityProtocol
        if let ax = object as? NSAccessibilityProtocol {
            if let val = ax.accessibilityValue() as? String,
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
            if let val = ax.accessibilityValue() as? NSAttributedString,
               !val.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.string
            }
            if let title = ax.accessibilityTitle(),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            if let label = ax.accessibilityLabel(),
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return label
            }
            if let ph = ax.accessibilityPlaceholderValue(),
               !ph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ph
            }
            if let help = ax.accessibilityHelp(),
               !help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return help
            }
        }

        // 2. Safe selector dispatch (never throws NSUnknownKeyException)
        for key in ["accessibilityValue", "accessibilityTitle", "accessibilityLabel", "accessibilityPlaceholderValue", "accessibilityDescription", "accessibilityHelp", "title", "stringValue"] {
            if let val = safePerformSelector(object, key) as? String,
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
            if let val = safePerformSelector(object, key) as? NSAttributedString,
               !val.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.string
            }
        }

        // 3. Safe attribute value query for remote WebKit elements
        for attr in ["AXValue", "AXTitle", "AXDescription", "AXLabel", "AXPlaceholderValue", "AXHelp"] {
            if let val = safeGetAttributeValue(object, attr) as? String,
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
            if let val = safeGetAttributeValue(object, attr) as? NSAttributedString,
               !val.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.string
            }
            if let num = safeGetAttributeValue(object, attr) as? NSNumber {
                return num.stringValue
            }
        }

        return ""
    }

    private func getObjectChildren(_ object: AnyObject) -> [AnyObject] {
        var result: [AnyObject] = []
        var seen = Set<ObjectIdentifier>()

        func appendIfNew(_ obj: AnyObject) {
            let id = ObjectIdentifier(obj)
            if !seen.contains(id) {
                seen.insert(id)
                result.append(obj)
            }
        }

        if let ax = object as? NSAccessibilityProtocol, let ch = ax.accessibilityChildren() {
            for c in ch { appendIfNew(c as AnyObject) }
        }

        if let ch = safeGetAttributeValue(object, "AXChildren") as? [AnyObject] {
            for c in ch { appendIfNew(c) }
        }

        if let ch = safePerformSelector(object, "accessibilityChildren") as? [AnyObject] {
            for c in ch { appendIfNew(c) }
        }

        if let ch = safeGetAttributeValue(object, "AXVisibleChildren") as? [AnyObject] {
            for c in ch { appendIfNew(c) }
        }

        // If it's an NSView, also check subviews
        if let view = object as? NSView {
            for sub in view.subviews { appendIfNew(sub as AnyObject) }
        }

        return result
    }

    private func toQuartzRect(_ cocoaRect: NSRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return cocoaRect }
        let screenHeight = primaryScreen.frame.height
        let quartzY = screenHeight - (cocoaRect.origin.y + cocoaRect.height)
        return CGRect(x: cocoaRect.origin.x, y: quartzY, width: cocoaRect.width, height: cocoaRect.height)
    }

    // MARK: - AXUIElement Fallback Traversal

    private func collectAllAXNodes(from root: AXUIElement, depth: Int = 0) -> [FlatNode] {
        guard depth < 100 else { return [] }
        var list: [FlatNode] = []

        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? (roleRef as? String ?? "") : ""

        // Exclude system menus, menu bars, and OS window frame control buttons
        if role.contains("MenuBar") || role.contains("MenuItem") || role == "AXMenu" || role == "AXMenuBarItem" ||
           role.contains("CloseButton") || role.contains("MinimizeButton") || role.contains("FullScreenButton") {
            return []
        }

        var subRoleRef: CFTypeRef?
        let subRole = (AXUIElementCopyAttributeValue(root, kAXSubroleAttribute as CFString, &subRoleRef) == .success)
            ? (subRoleRef as? String ?? "") : ""

        let fullRole = (!subRole.isEmpty && !role.isEmpty) ? "\(role):\(subRole)" : (role.isEmpty ? subRole : role)

        let text = getAXElementText(root) ?? ""
        let bounds = getAXElementBounds(root) ?? .zero
        let isEditable = fullRole.contains("TextField") || fullRole.contains("TextArea") || fullRole.contains("ComboBox") || fullRole.contains("SearchField")
        let isClickable = fullRole.contains("Button") || fullRole.contains("Link") || fullRole.contains("MenuItem") || fullRole.contains("PopUpButton") || fullRole.contains("CheckBox") || fullRole.contains("RadioButton")
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        list.append(FlatNode(role: fullRole, text: text, bounds: bounds, isEditable: isEditable, isClickable: isClickable, hasText: hasText))

        let children = getAXChildren(root)
        for child in children {
            list += collectAllAXNodes(from: child, depth: depth + 1)
        }
        return list
    }

    private func getAXChildren(_ el: AXUIElement) -> [AXUIElement] {
        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? (roleRef as? String ?? "") : ""

        // If this is the WebArea proxy, forcefully wake it up
        if role == "AXUnknown" || role == "AXWebArea" || role == "AXGroup" {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
           let list = ref as? [AXUIElement] {
            return list
        }
        if AXUIElementCopyAttributeValue(el, "AXVisibleChildren" as CFString, &ref) == .success,
           let list = ref as? [AXUIElement] {
            return list
        }
        return []
    }

    private func getAXElementText(_ element: AXUIElement) -> String? {
        let attrs: [CFString] = [
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            kAXDescriptionAttribute as CFString,
            "AXDOMIdentifier" as CFString,
            "AXDOMClassList" as CFString,
            kAXRoleDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
        ]
        for attr in attrs {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr, &ref) == .success, let v = ref {
                if let str = v as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
                if let attrStr = v as? NSAttributedString, !attrStr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return attrStr.string }
                if let num = v as? NSNumber { return num.stringValue }
            }
        }
        return nil
    }

    private func getAXElementBounds(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var point = CGPoint.zero
        var size  = CGSize.zero

        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(pv as! AXValue, .cgPoint, &point)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }

        guard size.width > 0 && size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    // MARK: - Element Queries (Matching Android Architecture)

    private func findWebElementBounds(target: String, threshold: Double, instance: Int) -> CGRect? {
        let normalizedTargets = target.components(separatedBy: "|").map { normalizeHebrew($0) }.filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return nil }

        let allNodes = getAllNodes()

        struct Match {
            let bounds: CGRect
            let score: Double
        }
        var matches: [Match] = []

        for node in allNodes {
            if node.hasText && node.bounds.width > 0 && node.bounds.height > 0 {
                let norm = normalizeHebrew(node.text)
                var bestScore = 0.0
                for t in normalizedTargets {
                    let s = similarity(norm, t)
                    if s > bestScore { bestScore = s }
                }

                if bestScore >= threshold {
                    let isDup = matches.contains { m in
                        abs(m.bounds.midX - node.bounds.midX) < 25 &&
                        abs(m.bounds.midY - node.bounds.midY) < 25
                    }
                    if !isDup {
                        matches.append(Match(bounds: node.bounds, score: bestScore))
                    }
                }
            }
        }

        let sorted = matches.sorted { $0.score > $1.score }
        if sorted.count >= instance {
            return sorted[instance - 1].bounds
        }
        return nil
    }

    private func findInputBeforeTarget(target: String, targetInstance: Int, threshold: Double) -> CGRect? {
        let normalizedTargets = target.components(separatedBy: "|").map { normalizeHebrew($0) }.filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return nil }

        let allNodes = getAllNodes()

        struct TargetMatch {
            let node: FlatNode
            let score: Double
            let precedingInput: CGRect?
        }
        var allMatches: [TargetMatch] = []
        var lastInputBounds: CGRect?

        for node in allNodes {
            if node.isEditable && node.bounds.width > 0 && node.bounds.height > 0 {
                lastInputBounds = node.bounds
            }

            if node.hasText {
                let norm = normalizeHebrew(node.text)
                var bestScore = 0.0
                for t in normalizedTargets {
                    let s = similarity(norm, t)
                    if s > bestScore { bestScore = s }
                }

                if bestScore >= threshold {
                    let isDup = allMatches.contains { m in
                        abs(m.node.bounds.midX - node.bounds.midX) < 25 &&
                        abs(m.node.bounds.midY - node.bounds.midY) < 25
                    }
                    if !isDup {
                        allMatches.append(TargetMatch(node: node, score: bestScore, precedingInput: lastInputBounds))
                    }
                }
            }
        }

        let sorted = allMatches.sorted { $0.score > $1.score }
        if sorted.count >= targetInstance {
            return sorted[targetInstance - 1].precedingInput
        }
        return nil
    }

    private func findNodeBeforeTarget(target: String, targetInstance: Int, threshold: Double) -> CGRect? {
        let normalizedTargets = target.components(separatedBy: "|").map { normalizeHebrew($0) }.filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return nil }

        let allNodes = getAllNodes()

        struct TargetMatch {
            let node: FlatNode
            let score: Double
            let precedingNode: CGRect?
        }
        var allMatches: [TargetMatch] = []
        var lastMeaningfulBounds: CGRect?

        for node in allNodes {
            var isTarget = false
            if node.hasText {
                let norm = normalizeHebrew(node.text)
                var bestScore = 0.0
                for t in normalizedTargets {
                    let s = similarity(norm, t)
                    if s > bestScore { bestScore = s }
                }

                if bestScore >= threshold {
                    let isDup = allMatches.contains { m in
                        abs(m.node.bounds.midX - node.bounds.midX) < 25 &&
                        abs(m.node.bounds.midY - node.bounds.midY) < 25
                    }
                    if !isDup {
                        allMatches.append(TargetMatch(node: node, score: bestScore, precedingNode: lastMeaningfulBounds))
                    }
                    isTarget = true
                }
            }

            if !isTarget && (node.hasText || node.isClickable || node.isEditable) && node.bounds.width > 0 && node.bounds.height > 0 {
                lastMeaningfulBounds = node.bounds
            }
        }

        let sorted = allMatches.sorted { $0.score > $1.score }
        if sorted.count >= targetInstance {
            return sorted[targetInstance - 1].precedingNode
        }
        return nil
    }

    private func findNodeAfterTarget(target: String, targetInstance: Int, threshold: Double, offset: Int) -> CGRect? {
        let normalizedTargets = target.components(separatedBy: "|").map { normalizeHebrew($0) }.filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return nil }

        let allNodes = getAllNodes()

        struct TargetMatch {
            let nodeIndex: Int
            let score: Double
        }
        var allMatches: [TargetMatch] = []

        for (index, node) in allNodes.enumerated() {
            if node.hasText {
                let norm = normalizeHebrew(node.text)
                var bestScore = 0.0
                for t in normalizedTargets {
                    let s = similarity(norm, t)
                    if s > bestScore { bestScore = s }
                }

                if bestScore >= threshold {
                    let isDup = allMatches.contains { m in
                        abs(allNodes[m.nodeIndex].bounds.midX - node.bounds.midX) < 25 &&
                        abs(allNodes[m.nodeIndex].bounds.midY - node.bounds.midY) < 25
                    }
                    if !isDup {
                        allMatches.append(TargetMatch(nodeIndex: index, score: bestScore))
                    }
                }
            }
        }

        let sorted = allMatches.sorted { $0.score > $1.score }
        if sorted.count >= targetInstance {
            let targetMatch = sorted[targetInstance - 1]
            var currentOffset = 0
            for i in (targetMatch.nodeIndex + 1)..<allNodes.count {
                let n = allNodes[i]
                if (n.hasText || n.isClickable || n.isEditable) && n.bounds.width > 0 && n.bounds.height > 0 {
                    currentOffset += 1
                    if currentOffset == offset {
                        return n.bounds
                    }
                }
            }
        }
        return nil
    }

    private func findNodeTextAfterTarget(target: String, targetInstance: Int, threshold: Double, offset: Int) -> String? {
        let normalizedTargets = target.components(separatedBy: "|").map { normalizeHebrew($0) }.filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return nil }

        let allNodes = getAllNodes()

        struct TargetMatch {
            let nodeIndex: Int
            let score: Double
        }
        var allMatches: [TargetMatch] = []

        for (index, node) in allNodes.enumerated() {
            if node.hasText {
                let norm = normalizeHebrew(node.text)
                var bestScore = 0.0
                for t in normalizedTargets {
                    let s = similarity(norm, t)
                    if s > bestScore { bestScore = s }
                }

                if bestScore >= threshold {
                    let isDup = allMatches.contains { m in
                        abs(allNodes[m.nodeIndex].bounds.midX - node.bounds.midX) < 25 &&
                        abs(allNodes[m.nodeIndex].bounds.midY - node.bounds.midY) < 25
                    }
                    if !isDup {
                        allMatches.append(TargetMatch(nodeIndex: index, score: bestScore))
                    }
                }
            }
        }

        let sorted = allMatches.sorted { $0.score > $1.score }
        if sorted.count >= targetInstance {
            let targetMatch = sorted[targetInstance - 1]
            var currentOffset = 0
            for i in (targetMatch.nodeIndex + 1)..<allNodes.count {
                let n = allNodes[i]
                if n.hasText {
                    currentOffset += 1
                    if currentOffset == offset {
                        return n.text
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Hebrew Normalization & Fuzzy Similarity

    private func normalizeHebrew(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[\\u0591-\\u05C7]", options: []) else {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let noNiqqud = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
        let collapsed = noNiqqud.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func similarity(_ s1: String, _ s2: String) -> Double {
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        if s1 == s2 { return 1.0 }

        let clean1 = s1.replacingOccurrences(of: " ", with: "")
        let clean2 = s2.replacingOccurrences(of: " ", with: "")
        if !clean1.isEmpty && clean1 == clean2 { return 1.0 }

        if s1.contains(s2) || s2.contains(s1) { return 0.95 }

        let maxLen = max(s1.count, s2.count)
        let minLen = min(s1.count, s2.count)
        if Double(minLen) / Double(maxLen) < 0.5 { return 0.0 }

        let dist = levenshtein(s1, s2)
        return 1.0 - (Double(dist) / Double(maxLen))
    }

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dp[i][0] = i }
        for j in 0...b.count { dp[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
            }
        }
        return dp[a.count][b.count]
    }

    // MARK: - CGEvent Hardware Input Injection

    private func postMouseClick(at point: CGPoint) {
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
    }

    private func postScrollEvent(deltaY: Int32) {
        let src    = CGEventSource(stateID: .combinedSessionState)
        let scroll = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
        scroll?.post(tap: .cghidEventTap)
    }

    private func postKeyboardShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = modifiers; up?.flags = modifiers
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
    }

    private func keyCodeForChar(_ char: Character) -> CGKeyCode? {
        switch char {
        case "0": return CGKeyCode(kVK_ANSI_0)
        case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2)
        case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4)
        case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6)
        case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8)
        case "9": return CGKeyCode(kVK_ANSI_9)
        case "a", "A": return CGKeyCode(kVK_ANSI_A)
        case "b", "B": return CGKeyCode(kVK_ANSI_B)
        case "c", "C": return CGKeyCode(kVK_ANSI_C)
        case "d", "D": return CGKeyCode(kVK_ANSI_D)
        case "e", "E": return CGKeyCode(kVK_ANSI_E)
        case "f", "F": return CGKeyCode(kVK_ANSI_F)
        case "g", "G": return CGKeyCode(kVK_ANSI_G)
        case "h", "H": return CGKeyCode(kVK_ANSI_H)
        case "i", "I": return CGKeyCode(kVK_ANSI_I)
        case "j", "J": return CGKeyCode(kVK_ANSI_J)
        case "k", "K": return CGKeyCode(kVK_ANSI_K)
        case "l", "L": return CGKeyCode(kVK_ANSI_L)
        case "m", "M": return CGKeyCode(kVK_ANSI_M)
        case "n", "N": return CGKeyCode(kVK_ANSI_N)
        case "o", "O": return CGKeyCode(kVK_ANSI_O)
        case "p", "P": return CGKeyCode(kVK_ANSI_P)
        case "q", "Q": return CGKeyCode(kVK_ANSI_Q)
        case "r", "R": return CGKeyCode(kVK_ANSI_R)
        case "s", "S": return CGKeyCode(kVK_ANSI_S)
        case "t", "T": return CGKeyCode(kVK_ANSI_T)
        case "u", "U": return CGKeyCode(kVK_ANSI_U)
        case "v", "V": return CGKeyCode(kVK_ANSI_V)
        case "w", "W": return CGKeyCode(kVK_ANSI_W)
        case "x", "X": return CGKeyCode(kVK_ANSI_X)
        case "y", "Y": return CGKeyCode(kVK_ANSI_Y)
        case "z", "Z": return CGKeyCode(kVK_ANSI_Z)
        case " ": return CGKeyCode(kVK_Space)
        case "-": return CGKeyCode(kVK_ANSI_Minus)
        case "\n", "\r": return CGKeyCode(kVK_Return)
        case "\t": return CGKeyCode(kVK_Tab)
        default: return nil
        }
    }

    private func injectText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for char in text {
            let code = keyCodeForChar(char) ?? CGKeyCode(0)
            var utf16 = Array(String(char).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            usleep(15_000)
            up?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
    }

    func dumpWebTree() -> String {
        let nodes = getAllNodes()
        var out = "=== Accessibility Tree (\(nodes.count) nodes) ===\n"
        for node in nodes {
            let boundsStr = node.bounds.width > 0 ? "(\(Int(node.bounds.minX)),\(Int(node.bounds.minY)) \(Int(node.bounds.width))×\(Int(node.bounds.height)))" : ""
            var line = "[\(node.role)]"
            if !node.text.isEmpty {
                line += " \"\(node.text.replacingOccurrences(of: "\n", with: " "))\""
            }
            if !boundsStr.isEmpty {
                line += " \(boundsStr)"
            }
            out += "\(line)\n"
        }
        return out
    }

    private func dumpAccessibilityElement(_ object: AnyObject, depth: Int = 0) -> String {
        guard depth < 100 else { return "" }
        let pad = String(repeating: "  ", count: depth)

        let role = getObjectRole(object)
        let text = getObjectText(object)
        let bounds = getObjectBounds(object)
        let boundsStr = bounds.width > 0 ? "(\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))×\(Int(bounds.height)))" : ""

        var line = "\(pad)[\(role.isEmpty ? "?" : role)]"
        if !text.isEmpty {
            line += " \"\(text.replacingOccurrences(of: "\n", with: " "))\""
        }
        if !boundsStr.isEmpty {
            line += " \(boundsStr)"
        }
        line += "\n"

        var out = line
        let children = getObjectChildren(object)
        for child in children {
            out += dumpAccessibilityElement(child, depth: depth + 1)
        }
        return out
    }

    private func dumpAXElement(_ el: AXUIElement, depth: Int) -> String {
        guard depth < 100 else { return "" }
        let pad = String(repeating: "  ", count: depth)

        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? (roleRef as? String ?? "?") : "?"

        var subRoleRef: CFTypeRef?
        let subRole = (AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRoleRef) == .success)
            ? (subRoleRef as? String ?? "") : ""

        let fullRole = (!subRole.isEmpty && !role.isEmpty) ? "\(role):\(subRole)" : (role.isEmpty ? subRole : role)

        let text   = getAXElementText(el) ?? ""
        let bounds = getAXElementBounds(el).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? ""

        var line = "\(pad)[\(fullRole)]"
        if !text.isEmpty {
            line += " \"\(text.replacingOccurrences(of: "\n", with: " "))\""
        }
        if !bounds.isEmpty {
            line += " \(bounds)"
        }
        line += "\n"

        var out = line
        let children = getAXChildren(el)
        for child in children {
            out += dumpAXElement(child, depth: depth + 1)
        }
        return out
    }
}
