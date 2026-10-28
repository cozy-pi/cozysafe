import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Google sign-in for Drive (lib/sync/desktop_oauth.dart): open Google's sign-in page
    // in the default browser. Only https://accounts.google.com/ addresses, checked here
    // again; the app fetches nothing itself.
    let signIn = FlutterMethodChannel(
      name: "cozysafe/signin", binaryMessenger: flutterViewController.engine.binaryMessenger)
    signIn.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let text = call.arguments as? String,
        let url = URL(string: text),
        url.scheme == "https",
        url.host == "accounts.google.com",
        url.user == nil, url.password == nil, url.port == nil
      else {
        result(false)
        return
      }
      result(NSWorkspace.shared.open(url))
    }

    super.awakeFromNib()
  }
}
