import Flutter
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

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
  /// Extra time to finish a sync if the person leaves the app mid-way (cozysafe/awake).
  private var awakeTask: UIBackgroundTaskIdentifier = .invalid
  /// "Block screenshots" (Settings, on by default). iOS has no switch for it; like banking
  /// and dating apps, the window's layer is moved inside a secure text field's, which the
  /// system leaves out of screenshots and recordings (they come out black). Undocumented:
  /// if it ever stops working, the capture cover and the screenshot warning still stand.
  private var secureOn = true
  private var secureFields: [ObjectIdentifier: UITextField] = [:]

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
    excludeLibraryFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The vaults live under Application Support (lib/main.dart). Sealed as they are, they
  /// stay out of iCloud and computer backups: a copy there would outlive a vault deleted
  /// here and be one more place to attack (docs/security.md, OS backups). Set on the
  /// folder at every start, before Dart creates anything in it; what is made inside later
  /// is excluded with it.
  private func excludeLibraryFromBackup() {
    let fm = FileManager.default
    guard var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CozyPrivacy") {
      registrar.register(TabBarFactory(messenger: registrar.messenger()), withId: "cozysafe/tabbar")
      let channel = FlutterMethodChannel(name: "cozysafe/privacy", binaryMessenger: registrar.messenger())
      privacyChannel = channel
      // While a sync runs (lib/sync/awake.dart): the screen stays on, and if the person
      // still leaves the app, iOS lends it some time to finish the item under way.
      let awake = FlutterMethodChannel(name: "cozysafe/awake", binaryMessenger: registrar.messenger())
      awake.setMethodCallHandler { [weak self] call, result in
        guard let self else { return result(nil) }
        // "progress" feeds Android's notification; iOS has no long background work to show.
        if call.method == "progress" { return result(nil) }
        guard call.method == "set" else { return result(FlutterMethodNotImplemented) }
        let on = (call.arguments as? Bool) ?? false
        UIApplication.shared.isIdleTimerDisabled = on
        if on, self.awakeTask == .invalid {
          self.awakeTask = UIApplication.shared.beginBackgroundTask(withName: "sync") { [weak self] in
            guard let self, self.awakeTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.awakeTask)
            self.awakeTask = .invalid
          }
        } else if !on, self.awakeTask != .invalid {
          UIApplication.shared.endBackgroundTask(self.awakeTask)
          self.awakeTask = .invalid
        }
        result(nil)
      }
      // Thumbnails for imported photos, made by ImageIO at the small size directly (it
      // reads only what it needs of a HEIC or JPEG), several at once off the main thread
      // (lib/screens/file_view.dart imageThumbnail). The JPEG goes back to Dart, sealed there.
      let media = FlutterMethodChannel(name: "cozysafe/media", binaryMessenger: registrar.messenger())
      media.setMethodCallHandler { call, result in
        guard call.method == "thumbnail", let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else { return result(FlutterMethodNotImplemented) }
        let side = args["shortSide"] as? Int ?? 320
        DispatchQueue.global(qos: .userInitiated).async {
          let data = Thumbnails.jpeg(path: path, shortSide: side)
          DispatchQueue.main.async { result(data.map { FlutterStandardTypedData(bytes: $0) }) }
        }
      }
      let originals = FlutterMethodChannel(name: "cozysafe/originals", binaryMessenger: registrar.messenger())
      originalsChannel = originals
      originals.setMethodCallHandler { [weak self] call, result in
        guard let self else { return result(nil) }
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "pickMedia": self.pickSession = args?["session"] as? Int ?? 0; self.pickMedia(result)
        case "pickFiles": self.pickSession = args?["session"] as? Int ?? 0; self.pickFiles(result)
        case "stopCopy": self.stopCopying(); result(nil)
        case "delete": self.deleteOriginals(args?["ids"] as? [String] ?? [], photos: args?["photos"] as? Bool ?? true, result)
        case "release": self.releaseFiles(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
      // The app's own language, the same value as Settings → Cozy Safe → Language
      // (lib/language.dart). iOS applies it from the next start.
      let language = FlutterMethodChannel(name: "cozysafe/language", binaryMessenger: registrar.messenger())
      language.setMethodCallHandler { call, result in
        let defaults = UserDefaults.standard
        let own = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        switch call.method {
        case "get": result(own?.first)
        case "set":
          let tag = (call.arguments as? [String: Any])?["tag"] as? String ?? ""
          if tag.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
          } else {
            defaults.set([tag], forKey: "AppleLanguages")
          }
          result(defaults.stringArray(forKey: "AppleLanguages")?.first)
        default: result(FlutterMethodNotImplemented)
        }
      }
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "suspendCover" {
          self?.coverSuspended = (call.arguments as? Bool) ?? false
          result(nil)
        } else if call.method == "openUrl" {
          // Our own pages only (lib/links.dart); the system opens the browser.
          guard let text = call.arguments as? String, let url = URL(string: text),
                url.scheme == "https", url.host == "safe.cozypi.com" else { return result(false) }
          UIApplication.shared.open(url) { ok in result(ok) }
        } else if call.method == "openExternal" {
          // A link tapped in a note, after the person confirmed its host (lib/links.dart,
          // docs/security.md): http or https with a host, nothing else (no file:,
          // javascript: or app schemes).
          guard let text = call.arguments as? String, let url = URL(string: text),
                let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                let host = url.host, !host.isEmpty else { return result(false) }
          UIApplication.shared.open(url) { ok in result(ok) }
        } else if call.method == "liquidGlass" {
          // The system's own bottom bar has Liquid Glass from iOS 26 (lib/widgets/native_bar.dart).
          if #available(iOS 26.0, *) { result(true) } else { result(false) }
        } else if call.method == "setSecure" {
          self?.secureOn = (call.arguments as? Bool) ?? true
          self?.captureChanged()
          self?.applySecure()
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
    applySecure() // the window exists by now
    captureChanged() // recording may have started while the app was away
  }

  /// Put each app window under a secure text field's layer once, then switch the field's
  /// secure entry on or off: off, screenshots work again (for a bug report).
  private func applySecure() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      guard let window = scene.windows.first(where: { $0.rootViewController is FlutterViewController }) ?? scene.windows.first
      else { continue }
      let key = ObjectIdentifier(window)
      if let field = secureFields[key] {
        field.isSecureTextEntry = secureOn
        continue
      }
      guard secureOn, let host = window.layer.superlayer else { continue }
      let field = UITextField()
      field.isSecureTextEntry = true
      field.isUserInteractionEnabled = false
      window.addSubview(field)
      host.addSublayer(field.layer)
      // The field's own content layer is the last sublayer on current iOS.
      guard let secure = field.layer.sublayers?.last else {
        field.removeFromSuperview()
        continue
      }
      secure.addSublayer(window.layer)
      secureFields[key] = field
    }
  }

  @objc private func captureChanged() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      let key = ObjectIdentifier(scene)
      // Covered only while screenshots are blocked: turned off (to record a bug report, or
      // a store video), recording shows the app like a screenshot does.
      if scene.screen.isCaptured && secureOn {
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

  // MARK: Originals (lib/originals.dart)
  //
  // Photos and files are picked keeping where each came from, so that once they are
  // encrypted into the vault the person can remove the originals. iOS itself asks before
  // anything in Photos is deleted; files are removed from where they were picked.

  private var pickResult: FlutterResult?
  private var originalsChannel: FlutterMethodChannel?
  /// Dart's number for the current pick: each copied file is sent back with it.
  private var pickSession = 0
  /// Copies still on their way, so a cancelled import can stop them.
  private var copying: [Progress] = []
  private var copyStopped = false
  /// Picked files, by the id given to Dart, still open for their security scope.
  private var pickedFiles: [String: URL] = [:]

  private var topController: UIViewController? {
    var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  /// Where picked copies go: the caches folder (Dart's temporary directory), deleted by
  /// Dart right after encrypting them.
  private func copyFolder() -> URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pick")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func pickMedia(_ result: @escaping FlutterResult) {
    var config = PHPickerConfiguration(photoLibrary: .shared()) // gives each photo's library id
    config.selectionLimit = 0
    config.filter = .any(of: [.images, .videos])
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    pickResult = result
    topController?.present(picker, animated: true)
  }

  private func pickFiles(_ result: @escaping FlutterResult) {
    // Opened in place (not copied by the system), so the original can be removed later.
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    pickResult = result
    topController?.present(picker, animated: true)
  }

  private func deleteOriginals(_ ids: [String], photos: Bool, _ result: @escaping FlutterResult) {
    if !photos {
      var deleted = 0, failed = 0
      for id in ids {
        guard let url = pickedFiles[id] else { failed += 1; continue }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { u in
          if (try? FileManager.default.removeItem(at: u)) != nil { deleted += 1 } else { failed += 1 }
        }
        if error != nil { failed += 1 }
      }
      releaseFiles()
      return result(["deleted": deleted, "failed": failed, "cancelled": false])
    }
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      guard status == .authorized || status == .limited else {
        return DispatchQueue.main.async { result(["deleted": 0, "failed": ids.count, "cancelled": false]) }
      }
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
      let found = assets.count
      guard found > 0 else {
        return DispatchQueue.main.async { result(["deleted": 0, "failed": ids.count, "cancelled": false]) }
      }
      // iOS shows its own "Allow Cozy Safe to delete …?"; the items go to Recently Deleted.
      PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(assets) }) { ok, _ in
        DispatchQueue.main.async {
          result(["deleted": ok ? found : 0, "failed": ids.count - found, "cancelled": !ok])
        }
      }
    }
  }

  private func stopCopying() {
    copyStopped = true
    for p in copying { p.cancel() }
    copying = []
  }

  private func releaseFiles() {
    for url in pickedFiles.values { url.stopAccessingSecurityScopedResource() }
    pickedFiles.removeAll()
  }
}

extension AppDelegate: PHPickerViewControllerDelegate {
  /// Tell Dart the count at once, then hand over each file as soon as iOS has it, so the
  /// vault encrypts while the rest are still being copied (owner 2026-10-23: 4 GB took
  /// 96 s to copy and the vault waited for all of it). Four at a time, in order: the
  /// first ones arrive early instead of all of them at the end.
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = pickResult else { return }
    pickResult = nil
    result(results.count)
    guard !results.isEmpty else { return }
    let dir = copyFolder()
    let session = pickSession
    copyStopped = false
    copying = []
    let slots = DispatchSemaphore(value: 4)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      for r in results {
        slots.wait()
        let provider = r.itemProvider
        let type = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie : UTType.image
        let started = Date()
        let id = r.assetIdentifier ?? ""
        let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
          defer { slots.signal() }
          var item: [String: Any] = ["session": session]
          if let url {
            let name = url.lastPathComponent
            let copy = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
            // iOS deletes its file when this returns: take it (a rename) or copy it.
            let fm = FileManager.default
            if (try? fm.moveItem(at: url, to: copy)) != nil || (try? fm.copyItem(at: url, to: copy)) != nil {
              // "mime" empty: Dart reads it from the extension (.heic, .mov, .mp4…).
              item.merge(["path": copy.path, "name": name, "mime": "", "id": id,
                          "ms": Int(Date().timeIntervalSince(started) * 1000)]) { $1 }
            }
          }
          let sent = item
          DispatchQueue.main.async { self?.originalsChannel?.invokeMethod("copied", arguments: sent) }
        }
        DispatchQueue.main.async {
          guard let self else { return }
          if self.copyStopped { progress.cancel() } else { self.copying.append(progress) }
        }
      }
    }
  }
}

extension AppDelegate: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pickResult else { return }
    pickResult = nil
    result(urls.count)
    let dir = copyFolder()
    let session = pickSession
    copyStopped = false
    // One after another off the main thread; each is sent to Dart as soon as it is copied.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      for url in urls {
        let stopped = DispatchQueue.main.sync { self?.copyStopped ?? true }
        let started = Date()
        let scoped = !stopped && url.startAccessingSecurityScopedResource()
        let copy = dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        var copied = false
        if !stopped {
          var error: NSError?
          NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
            copied = (try? FileManager.default.copyItem(at: u, to: copy)) != nil
          }
        }
        let done = copied
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        DispatchQueue.main.async {
          var item: [String: Any] = ["session": session]
          if done {
            let id = UUID().uuidString
            self?.pickedFiles[id] = url // kept open until deleted or released
            item.merge(["path": copy.path, "name": url.lastPathComponent, "mime": "", "id": id, "ms": ms]) { $1 }
          } else if scoped {
            url.stopAccessingSecurityScopedResource()
          }
          self?.originalsChannel?.invokeMethod("copied", arguments: item)
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickResult?(0)
    pickResult = nil
  }
}

/// The vault's bottom bar drawn by UIKit (lib/widgets/native_bar.dart): a glass lock
/// button and a tab bar, both Apple's own Liquid Glass on iOS 26. Dart sends the items,
/// the selected one and the theme ("update"); taps come back as "select" and "lock".
final class TabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    TabBarView(frame: frame, id: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
  }
}

private final class TabBarRoot: UIView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

final class TabBarView: NSObject, FlutterPlatformView, UITabBarDelegate, UIGestureRecognizerDelegate {
  private let root: TabBarRoot
  private let bar = UITabBar()
  private let lock = UIButton(type: .system)
  private let channel: FlutterMethodChannel
  private var showLock = true
  private var holdHome = false
  private var itemsKey = ""
  private var reportedHeight: CGFloat = 0
  /// Room around the bar: the glass bubble under a finger grows past the bar's edge, and
  /// a platform view clips to its frame (0.1.26: the bubble was cut).
  private let margin = UIEdgeInsets(top: 14, left: 10, bottom: 10, right: 10)

  init(frame: CGRect, id: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    root = TabBarRoot(frame: frame)
    channel = FlutterMethodChannel(name: "cozysafe/tabbar/\(id)", binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .clear
    bar.delegate = self
    bar.tintColor = .label
    // Icon above its word, as on every iPhone. A platform view does not always get the
    // phone's size classes, and the tab bar then laid icon and word side by side, the
    // word over the next icon (0.1.25 on a real iPhone).
    if #available(iOS 17.0, *) {
      root.traitOverrides.horizontalSizeClass = .compact
      root.traitOverrides.verticalSizeClass = .regular
    }
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
    hold.cancelsTouchesInView = false
    hold.delaysTouchesEnded = false
    // Alongside the bar's own gestures, never instead of them: taking a touch away left
    // the glass bubble stuck under a lifted finger (0.1.26 on a real iPhone).
    hold.delegate = self
    bar.addGestureRecognizer(hold)
    lock.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
    let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.image = UIImage(systemName: "lock.fill", withConfiguration: symbol)
      config.cornerStyle = .capsule
      config.baseForegroundColor = .label
      lock.configuration = config
    } else {
      lock.setImage(UIImage(systemName: "lock.fill", withConfiguration: symbol), for: .normal)
      lock.tintColor = .label
    }
    root.addSubview(lock)
    root.addSubview(bar)
    root.onLayout = { [weak self] in self?.layout() }
    apply(args)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update" { self?.apply(call.arguments as? [String: Any] ?? [:]) }
      result(nil)
    }
  }

  func view() -> UIView { root }

  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    true
  }

  private func layout() {
    let b = root.bounds.inset(by: margin)
    let side = showLock ? min(b.height, 56) : 0
    lock.isHidden = !showLock
    lock.frame = CGRect(x: b.minX, y: b.minY + (b.height - side) / 2, width: side, height: side)
    let x = b.minX + (showLock ? side + 6 : 0)
    let width = max(0, b.maxX - x)
    // As tall as the system wants it, plus the room around; Dart resizes the view.
    let need = ceil(bar.sizeThatFits(CGSize(width: width, height: 200)).height)
    bar.frame = CGRect(x: x, y: b.minY + max(0, (b.height - need) / 2), width: width, height: min(need, b.height))
    let total = need + margin.top + margin.bottom
    if need > 0, abs(total - reportedHeight) > 0.5 {
      reportedHeight = total
      channel.invokeMethod("height", arguments: Double(total))
    }
  }

  /// Holding the home tab (the first) locks, as the lock button would.
  @objc private func held(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began, holdHome, let count = bar.items?.count, count > 0 else { return }
    let x = g.location(in: bar).x
    if Int(x / (bar.bounds.width / CGFloat(count))) == 0 {
      channel.invokeMethod("holdHome", arguments: nil)
    }
  }

  private func apply(_ args: [String: Any]) {
    let items = args["items"] as? [[String: Any]] ?? []
    // Same items: keep them, so the selection moves with the system's own animation.
    let key = items.map { "\($0["title"] ?? "")|\($0["symbol"] ?? "")" }.joined(separator: ";")
    if key != itemsKey {
      itemsKey = key
      bar.items = items.enumerated().map { i, item in
        UITabBarItem(title: item["title"] as? String,
                     image: UIImage(systemName: item["symbol"] as? String ?? "circle"), tag: i)
      }
    }
    bar.isHidden = items.isEmpty
    let selected = args["selected"] as? Int ?? 0
    if let all = bar.items, selected >= 0, selected < all.count, bar.selectedItem !== all[selected] {
      bar.selectedItem = all[selected]
    }
    showLock = args["lock"] as? Bool ?? true
    holdHome = args["holdHome"] as? Bool ?? false
    lock.accessibilityLabel = args["lockLabel"] as? String
    root.overrideUserInterfaceStyle = (args["dark"] as? Bool ?? false) ? .dark : .light
    root.setNeedsLayout()
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("select", arguments: item.tag)
  }

  @objc private func lockTapped() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    channel.invokeMethod("lock", arguments: nil)
  }
}

/// A small JPEG of a picture file, its shorter side about `shortSide` pixels, upright.
enum Thumbnails {
  static func jpeg(path: String, shortSide: Int) -> Data? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      return nil
    }
    // ImageIO limits the longer side; work it out so the shorter one gets `shortSide`.
    var longSide = shortSide
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
       min(w, h) > 0 {
      longSide = Int((Double(shortSide) * Double(max(w, h)) / Double(min(w, h))).rounded(.up))
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: longSide,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
  }
}
