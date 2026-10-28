import Cocoa
import CryptoKit
import FlutterMacOS
import LocalAuthentication
import Security

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

    // Touch ID unlock (lib/biometric.dart, docs/security.md "Touch ID on a Mac").
    let biokey = FlutterMethodChannel(
      name: "cozysafe/biokey", binaryMessenger: flutterViewController.engine.binaryMessenger)
    biokey.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "available":
        result(BioKey.available())
      case "wrap":
        guard let bytes = (args?["bytes"] as? FlutterStandardTypedData)?.data else {
          result(FlutterError(code: "args", message: nil, details: nil))
          return
        }
        if let blob = BioKey.wrap(bytes) {
          result(FlutterStandardTypedData(bytes: blob))
        } else {
          result(FlutterError(code: "wrap", message: nil, details: nil))
        }
      case "unwrap":
        guard let blob = (args?["bytes"] as? FlutterStandardTypedData)?.data else {
          result(FlutterError(code: "args", message: nil, details: nil))
          return
        }
        BioKey.unwrap(blob, reason: args?["reason"] as? String ?? "Unlock") { outcome in
          DispatchQueue.main.async {
            switch outcome {
            case .key(let key): result(FlutterStandardTypedData(bytes: key))
            case .gone: result(nil)
            case .cancelled: result(FlutterError(code: "cancelled", message: nil, details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}

/// The biometric half of biometric unlock on a Mac. A P-256 key made inside the Secure
/// Enclave with `biometryCurrentSet`: only this Mac's enclave can use it, only after a
/// Touch ID check, and enrolling or removing a finger makes it unusable for good. It is
/// not stored in the keychain (on macOS that needs the data-protection keychain, hence a
/// provisioning profile): CryptoKit hands out an opaque blob that only this enclave can
/// turn back into the key, and Dart keeps that blob in the legacy keychain with the rest.
///
/// The secret is wrapped by ECDH with a one-off key, HKDF-SHA256 and AES-GCM. Blob:
/// version 1 | key blob length (2 bytes, big-endian) | key blob | one-off public key
/// (65 bytes, X9.63) | AES-GCM nonce, ciphertext and tag.
enum BioKey {
  enum Outcome {
    case key(Data)
    /// The key cannot be used any more (fingers changed, no fingers, another Mac).
    case gone
    /// Cancelled, not recognised, Touch ID locked out or unavailable right now.
    case cancelled
  }

  private static let version: UInt8 = 1
  private static let info = Data("cozysafe biometric unlock v1".utf8)

  /// Touch ID set up with at least one finger, and a Secure Enclave to hold the key.
  static func available() -> Bool {
    guard SecureEnclave.isAvailable else { return false }
    var error: NSError?
    let context = LAContext()
    return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
      && context.biometryType == .touchID
  }

  private static func symmetricKey(_ secret: SharedSecret, _ one: P256.KeyAgreement.PublicKey,
                                   _ enclave: P256.KeyAgreement.PublicKey) -> SymmetricKey {
    secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: one.x963Representation + enclave.x963Representation,
      sharedInfo: info, outputByteCount: 32)
  }

  /// A new enclave key wrapping `data`. Asks for nothing: only the public key is used.
  static func wrap(_ data: Data) -> Data? {
    guard available(),
          let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], nil)
    else { return nil }
    do {
      let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
      let one = P256.KeyAgreement.PrivateKey()
      let secret = try one.sharedSecretFromKeyAgreement(with: enclave.publicKey)
      let key = symmetricKey(secret, one.publicKey, enclave.publicKey)
      guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Data([version])).combined
      else { return nil }
      let keyBlob = enclave.dataRepresentation
      guard keyBlob.count <= 0xFFFF else { return nil }
      var out = Data([version, UInt8(keyBlob.count >> 8), UInt8(keyBlob.count & 0xFF)])
      out += keyBlob
      out += one.publicKey.x963Representation
      out += sealed
      return out
    } catch {
      return nil
    }
  }

  /// Shows the Touch ID prompt, then unwraps.
  static func unwrap(_ blob: Data, reason: String, done: @escaping (Outcome) -> Void) {
    let bytes = [UInt8](blob)
    guard bytes.count > 3, bytes[0] == version else { return done(.gone) }
    let keyLength = Int(bytes[1]) << 8 | Int(bytes[2])
    let pubStart = 3 + keyLength
    guard bytes.count > pubStart + 65 + 28 else { return done(.gone) }
    let keyBlob = Data(bytes[3..<pubStart])
    let pubBytes = Data(bytes[pubStart..<(pubStart + 65)])
    let sealedBytes = Data(bytes[(pubStart + 65)...])

    let context = LAContext()
    var canError: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canError) else {
      // No finger enrolled any more: biometryCurrentSet has made the key useless. Anything
      // else (no Touch ID reachable, e.g. a closed laptop; locked out) may pass.
      let code = (canError as? LAError)?.code
      return done(code == .biometryNotEnrolled ? .gone : .cancelled)
    }
    context.localizedFallbackTitle = "" // no "Use password…": the app has its own PIN and password
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
      guard ok else { return done(.cancelled) }
      // The owner was recognised: from here, any failure means the key itself is unusable.
      do {
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(
          dataRepresentation: keyBlob, authenticationContext: context)
        let one = try P256.KeyAgreement.PublicKey(x963Representation: pubBytes)
        let secret = try enclave.sharedSecretFromKeyAgreement(with: one)
        let key = symmetricKey(secret, one, enclave.publicKey)
        let box = try AES.GCM.SealedBox(combined: sealedBytes)
        done(.key(try AES.GCM.open(box, using: key, authenticating: Data([version]))))
      } catch {
        done(.gone)
      }
    }
  }
}
