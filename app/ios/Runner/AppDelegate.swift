import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Covers the window while the app is not active, so the app switcher snapshot
  /// shows the dial on the page colour (white or black, as the phone is set) instead of
  /// what was on screen.
  private var covers: [ObjectIdentifier: UIView] = [:]
  /// Set by Dart while the Face ID prompt is up: the prompt makes the app inactive, and a
  /// cover then would hide the vault opening (lib/privacy.dart).
  private var coverSuspended = false
  /// Covers while the screen is recorded or mirrored (iOS cannot block that, but the app
  /// can see it and hide its content for as long as it lasts).
  private var captureCovers: [ObjectIdentifier: UIView] = [:]
  private var privacyChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                       name: UIScene.willDeactivateNotification, object: nil)
    center.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)),
                       name: UIScene.didEnterBackgroundNotification, object: nil)
    center.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                       name: UIScene.didActivateNotification, object: nil)
    center.addObserver(self, selector: #selector(captureChanged),
                       name: UIScreen.capturedDidChangeNotification, object: nil)
    // iOS cannot stop a screenshot; after one, Dart says where it went (Photos, unencrypted).
    center.addObserver(self, selector: #selector(screenshotTaken),
                       name: UIApplication.userDidTakeScreenshotNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CozyPrivacy") {
      let channel = FlutterMethodChannel(name: "cozysafe/privacy", binaryMessenger: registrar.messenger())
      privacyChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "suspendCover" {
          self?.coverSuspended = (call.arguments as? Bool) ?? false
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  @objc private func sceneWillDeactivate(_ note: Notification) {
    if !coverSuspended { cover(note) }
  }

  /// Leaving the app always covers, even if it left during the Face ID prompt.
  @objc private func sceneDidEnterBackground(_ note: Notification) {
    cover(note)
  }

  private func cover(_ note: Notification) {
    guard let scene = note.object as? UIWindowScene,
          let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
          covers[ObjectIdentifier(scene)] == nil else { return }
    let cover = UIView(frame: window.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = .systemBackground // white, or black in dark mode, like the app
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
    captureChanged() // recording may have started while the app was away
  }

  @objc private func captureChanged() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      let key = ObjectIdentifier(scene)
      if scene.screen.isCaptured {
        guard captureCovers[key] == nil,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { continue }
        let cover = makeCover(window.bounds)
        window.addSubview(cover)
        captureCovers[key] = cover
      } else {
        captureCovers.removeValue(forKey: key)?.removeFromSuperview()
      }
    }
  }

  @objc private func screenshotTaken() {
    privacyChannel?.invokeMethod("screenshot", arguments: nil)
  }

  /// The page colour with the dial: what the app switcher and screen recordings see.
  private func makeCover(_ bounds: CGRect) -> UIView {
    let cover = UIView(frame: bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = .systemBackground
    let dial = UIImageView(image: UIImage(named: "LaunchImage"))
    dial.center = CGPoint(x: cover.bounds.midX, y: cover.bounds.midY)
    dial.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
    cover.addSubview(dial)
    return cover
  }
}
