import 'dart:async';
import 'dart:io';

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

  static int _session = 0;
  static StreamController<PickedCopy>? _arriving;
  static int _left = 0;
  static bool _listening = false;

  /// Pick, then hand over each file as soon as the platform has copied it (owner
  /// 2026-10-23: 4 GB took 96 s to copy and the vault waited for all of it). The count
  /// comes first, then one file per arrival; a file that could not be read is left out.
  /// Desktops pick in place, so everything is there at once.
  static Future<PickedBatch> pick({required bool photos}) async {
    if (!supported) {
      final files = photos ? await pickPhotos() : await pickFiles();
      return PickedBatch(files.length, Stream.fromIterable([for (final f in files) PickedCopy(f, null, 0)]));
    }
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onCall);
    }
    await _close();
    final session = ++_session;
    final arriving = StreamController<PickedCopy>();
    _arriving = arriving;
    final count = await _channel.invokeMethod<int>(photos ? 'pickMedia' : 'pickFiles', {'session': session}) ?? 0;
    _left = count;
    if (count == 0) await _close();
    return PickedBatch(count, arriving.stream);
  }

  /// Stop copying what is still on its way; what arrives anyway is deleted.
  static Future<void> stopCopying() async {
    await _close();
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('stopCopy');
    } catch (_) {}
  }

  static Future<void> _close() async {
    final c = _arriving;
    _arriving = null;
    _left = 0;
    if (c != null && !c.isClosed) await c.close();
  }

  static Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'copied') return null;
    final m = call.arguments as Map<Object?, Object?>;
    final path = m['path'] as String?;
    final c = _arriving;
    if (c == null || m['session'] != _session) {
      // Left over from a pick that was cancelled: nobody wants it.
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      return null;
    }
    if (path != null) {
      final mime = m['mime'] as String? ?? '';
      final id = m['id'] as String? ?? '';
      c.add(PickedCopy(
        XFile(path, name: m['name'] as String?, mimeType: mime.isEmpty ? null : mime),
        id.isEmpty ? null : id,
        (m['ms'] as int?) ?? 0,
      ));
    }
    if (--_left <= 0) await _close();
    return null;
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

/// What a pick gives: how many were chosen, then the files as they arrive.
class PickedBatch {
  const PickedBatch(this.count, this.files);
  final int count;
  final Stream<PickedCopy> files;
}

/// One picked file: the copy to encrypt, where it came from (null when it cannot be
/// removed from here), and how long the platform took to hand it over.
class PickedCopy {
  const PickedCopy(this.file, this.origin, this.copyMs);
  final XFile file;
  final String? origin;
  final int copyMs;
}
