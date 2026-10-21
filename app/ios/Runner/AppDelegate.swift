import Flutter
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
      let originals = FlutterMethodChannel(name: "cozysafe/originals", binaryMessenger: registrar.messenger())
      originals.setMethodCallHandler { [weak self] call, result in
        guard let self else { return result(nil) }
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "pickMedia": self.pickMedia(result)
        case "pickFiles": self.pickFiles(result)
        case "delete": self.deleteOriginals(args?["ids"] as? [String] ?? [], photos: args?["photos"] as? Bool ?? true, result)
        case "release": self.releaseFiles(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
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

  // MARK: Originals (lib/originals.dart)
  //
  // Photos and files are picked keeping where each came from, so that once they are
  // encrypted into the vault the person can remove the originals. iOS itself asks before
  // anything in Photos is deleted; files are removed from where they were picked.

  private var pickResult: FlutterResult?
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

  private func releaseFiles() {
    for url in pickedFiles.values { url.stopAccessingSecurityScopedResource() }
    pickedFiles.removeAll()
  }
}

extension AppDelegate: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = pickResult else { return }
    pickResult = nil
    let dir = copyFolder()
    let group = DispatchGroup()
    let lock = NSLock()
    var out: [Int: [String: String]] = [:]
    for (i, r) in results.enumerated() {
      let provider = r.itemProvider
      let type = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie : UTType.image
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        defer { group.leave() }
        guard let url else { return }
        let name = url.lastPathComponent
        let copy = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
        lock.lock()
        // "mime" empty: Dart reads it from the extension (.heic, .mov, .mp4…).
        out[i] = ["path": copy.path, "name": name, "mime": "", "id": r.assetIdentifier ?? ""]
        lock.unlock()
      }
    }
    group.notify(queue: .main) { result((0..<results.count).compactMap { out[$0] }) }
  }
}

extension AppDelegate: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pickResult else { return }
    pickResult = nil
    let dir = copyFolder()
    var out: [[String: String]] = []
    for url in urls {
      let scoped = url.startAccessingSecurityScopedResource()
      let copy = dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
      var error: NSError?
      var copied = false
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
        copied = (try? FileManager.default.copyItem(at: u, to: copy)) != nil
      }
      guard copied else {
        if scoped { url.stopAccessingSecurityScopedResource() }
        continue
      }
      let id = UUID().uuidString
      pickedFiles[id] = url // kept open until deleted or released
      out.append(["path": copy.path, "name": url.lastPathComponent, "mime": "", "id": id])
    }
    result(out)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickResult?([])
    pickResult = nil
  }
}
