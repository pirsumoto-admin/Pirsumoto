import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    
    self.contentViewController = flutterViewController
    RegisterGeneratedPlugins(registry: flutterViewController)
    
    // Register custom native services
    MacWebAutomationService.shared.register(with: flutterViewController.engine.binaryMessenger)
    MacAccessibilityService.shared.register(with: flutterViewController.engine.binaryMessenger)
    
    super.awakeFromNib()
    
    if let screenFrame = NSScreen.main?.visibleFrame {
        let width = screenFrame.width * 0.3
        let height = screenFrame.height
        let windowFrame = NSRect(x: screenFrame.minX, y: screenFrame.minY, width: width, height: height)
        
        self.setFrameAutosaveName("")
        self.setFrame(windowFrame, display: true)
        self.minSize = NSSize(width: width, height: height)
    }
  }
}
