import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Covers the window while the app is not active, so the app switcher snapshot
  /// shows the dial on vault green instead of what was on screen.
  private var covers: [ObjectIdentifier: UIView] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                       name: UIScene.willDeactivateNotification, object: nil)
    center.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                       name: UIScene.didActivateNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  @objc private func sceneWillDeactivate(_ note: Notification) {
    guard let scene = note.object as? UIWindowScene,
          let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
          covers[ObjectIdentifier(scene)] == nil else { return }
    let cover = UIView(frame: window.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = UIColor(red: 0x0F / 255, green: 0x3D / 255, blue: 0x33 / 255, alpha: 1)
    let dial = UIImageView(image: UIImage(named: "LaunchImage"))
    dial.center = CGPoint(x: cover.bounds.midX, y: cover.bounds.midY)
    dial.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
    cover.addSubview(dial)
    window.addSubview(cover)
    covers[ObjectIdentifier(scene)] = cover
  }

  @objc private func sceneDidActivate(_ note: Notification) {
    guard let scene = note.object as? UIWindowScene else { return }
    covers.removeValue(forKey: ObjectIdentifier(scene))?.removeFromSuperview()
  }
}
