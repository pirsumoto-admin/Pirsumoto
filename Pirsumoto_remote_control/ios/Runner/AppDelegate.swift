import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PublicationMedia")!
    let channel = FlutterMethodChannel(name: "com.pirsumoto.controller/media", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "normalizeImage" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: String],
            let source = args["source"], let destination = args["destination"],
            let original = UIImage(contentsOfFile: source) else {
        result(FlutterError(code: "invalid_image", message: "Cannot open photo", details: nil)); return
      }
      let scale = min(1.0, 1920.0 / max(original.size.width, original.size.height))
      let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        original.draw(in: CGRect(origin: .zero, size: size))
      }
      do {
        guard let jpeg = normalized.jpegData(compressionQuality: 0.85) else {
          result(FlutterError(code: "invalid_image", message: "Cannot encode photo", details: nil)); return
        }
        try jpeg.write(to: URL(fileURLWithPath: destination), options: .atomic)
        result(nil)
      } catch {
        result(FlutterError(code: "image_save", message: error.localizedDescription, details: nil))
      }
    }
  }
}
