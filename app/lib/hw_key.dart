import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// A key inside the phone's secure hardware that never leaves it (owner 2026-10-26, B1):
/// the Secure Enclave on iPhone, the Android Keystore (StrongBox where there is one, else
/// the TEE). It wraps the PIN's device key, so a copy of the keystore taken off the phone
/// is useless: every PIN guess has to go through this phone's chip. Where there is none
/// (simulators, desktops), [wrap] gives null and the device key stays as it was.
abstract final class HwKey {
  static const _channel = MethodChannel('cozysafe/hwkey');

  /// For tests: stands in for the platform.
  @visibleForTesting
  static ({Future<Uint8List?> Function(Uint8List) wrap, Future<Uint8List?> Function(Uint8List) unwrap})? debug;

  static Future<Uint8List?> wrap(Uint8List data) async {
    if (debug case final d?) return d.wrap(data);
    if (!Device.iOS && !Device.android) return null; // the plugin lives on phones only
    try {
      return await _channel.invokeMethod<Uint8List>('wrap', {'bytes': data});
    } catch (_) {
      return null; // no such hardware, or no plugin on this platform
    }
  }

  static Future<Uint8List?> unwrap(Uint8List blob) async {
    if (debug case final d?) return d.unwrap(blob);
    if (!Device.iOS && !Device.android) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('unwrap', {'bytes': blob});
    } catch (_) {
      return null;
    }
  }
}
