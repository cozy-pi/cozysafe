import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'platform.dart';
import 'screens/file_view.dart' show pickPhotos, pickFiles;

/// Picking photos, videos and files while remembering where each came from, so that once
/// they are encrypted into the vault the person can remove the originals (owner
/// 2026-10-21). The platforms do the deleting and ask first: iOS for Photos, Android for
/// its media and documents (AppDelegate.swift, MainActivity.kt, channel
/// "cozysafe/originals"). Elsewhere there is nothing to remove.
abstract final class Originals {
  static const _channel = MethodChannel('cozysafe/originals');

  /// Phones only: computers pick real files, and removing those is the person's business.
  static bool get supported => Device.iOS || Device.android;

  /// The picked files (copies in the temporary folder) and, for each, where it came from
  /// (null when unknown: then it cannot be removed from here).
  static Future<(List<XFile>, List<String?>)> pick({required bool photos}) async {
    if (!supported) {
      final files = photos ? await pickPhotos() : await pickFiles();
      return (files, List<String?>.filled(files.length, null));
    }
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(photos ? 'pickMedia' : 'pickFiles') ?? const [];
    final files = <XFile>[];
    final ids = <String?>[];
    for (final m in raw) {
      final mime = m['mime'] as String? ?? '';
      files.add(XFile(m['path'] as String, name: m['name'] as String?, mimeType: mime.isEmpty ? null : mime));
      final id = m['id'] as String? ?? '';
      ids.add(id.isEmpty ? null : id);
    }
    return (files, ids);
  }

  /// Remove the originals the platform can remove; the platform asks the person first.
  static Future<({int deleted, int failed, bool cancelled})> delete(List<String> ids, {required bool photos}) async {
    final r = await _channel.invokeMapMethod<String, Object?>('delete', {'ids': ids, 'photos': photos}) ?? const {};
    return (
      deleted: (r['deleted'] as int?) ?? 0,
      failed: (r['failed'] as int?) ?? ids.length,
      cancelled: (r['cancelled'] as bool?) ?? false,
    );
  }

  /// Keep the originals: let go of the picked files (iOS keeps them open until then).
  static Future<void> release() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}
