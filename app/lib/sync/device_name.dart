import 'package:flutter/services.dart';

import '../platform.dart';

/// The name nearby sync gives this device on the other one ("iPhone 15 Pro Max",
/// "Google Pixel 8", "Mac"): the model, never the name the owner gave the device (that
/// often holds their own name, and on iPhone needs an entitlement). It crosses only
/// inside the sealed channel, after the other device proved it holds the vault.
Future<String> deviceName() async {
  if (Device.macOS) return 'Mac';
  if (Device.windows) return 'Windows PC';
  if (Device.linux) return 'Linux';
  try {
    if (Device.iOS) return appleModelName(await _channel.invokeMethod<String>('model') ?? '');
    if (Device.android) {
      final parts = await _channel.invokeListMethod<String>('model') ?? const [];
      return androidModelName(parts.isNotEmpty ? parts[0] : '', parts.length > 1 ? parts[1] : '');
    }
  } catch (_) {}
  return Device.iOS ? 'iPhone' : 'Android';
}

const _channel = MethodChannel('cozysafe/device');

/// "Samsung SM-S918B", "Google Pixel 8": the maker once, capitalised.
String androidModelName(String maker, String model) {
  maker = maker.trim();
  model = model.trim();
  if (maker.isEmpty) return model.isEmpty ? 'Android' : model;
  final m = maker[0].toUpperCase() + maker.substring(1);
  if (model.isEmpty) return m;
  return model.toLowerCase().startsWith(maker.toLowerCase()) ? model : '$m $model';
}

/// The marketing name of an Apple model id ("iPhone16,2" → "iPhone 15 Pro Max"); the
/// family for ids not listed (newer ones, iPads).
String appleModelName(String id) {
  final known = _apple[id];
  if (known != null) return known;
  if (id.startsWith('iPad')) return 'iPad';
  if (id.startsWith('iPod')) return 'iPod touch';
  return 'iPhone';
}

const _apple = {
  'iPhone10,1': 'iPhone 8',
  'iPhone10,4': 'iPhone 8',
  'iPhone10,2': 'iPhone 8 Plus',
  'iPhone10,5': 'iPhone 8 Plus',
  'iPhone10,3': 'iPhone X',
  'iPhone10,6': 'iPhone X',
  'iPhone11,2': 'iPhone XS',
  'iPhone11,4': 'iPhone XS Max',
  'iPhone11,6': 'iPhone XS Max',
  'iPhone11,8': 'iPhone XR',
  'iPhone12,1': 'iPhone 11',
  'iPhone12,3': 'iPhone 11 Pro',
  'iPhone12,5': 'iPhone 11 Pro Max',
  'iPhone12,8': 'iPhone SE',
  'iPhone13,1': 'iPhone 12 mini',
  'iPhone13,2': 'iPhone 12',
  'iPhone13,3': 'iPhone 12 Pro',
  'iPhone13,4': 'iPhone 12 Pro Max',
  'iPhone14,4': 'iPhone 13 mini',
  'iPhone14,5': 'iPhone 13',
  'iPhone14,2': 'iPhone 13 Pro',
  'iPhone14,3': 'iPhone 13 Pro Max',
  'iPhone14,6': 'iPhone SE',
  'iPhone14,7': 'iPhone 14',
  'iPhone14,8': 'iPhone 14 Plus',
  'iPhone15,2': 'iPhone 14 Pro',
  'iPhone15,3': 'iPhone 14 Pro Max',
  'iPhone15,4': 'iPhone 15',
  'iPhone15,5': 'iPhone 15 Plus',
  'iPhone16,1': 'iPhone 15 Pro',
  'iPhone16,2': 'iPhone 15 Pro Max',
  'iPhone17,1': 'iPhone 16 Pro',
  'iPhone17,2': 'iPhone 16 Pro Max',
  'iPhone17,3': 'iPhone 16',
  'iPhone17,4': 'iPhone 16 Plus',
  'iPhone17,5': 'iPhone 16e',
  'iPhone18,1': 'iPhone 17 Pro',
  'iPhone18,2': 'iPhone 17 Pro Max',
  'iPhone18,3': 'iPhone 17',
  'iPhone18,4': 'iPhone Air',
};
