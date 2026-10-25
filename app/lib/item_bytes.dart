import 'dart:async';

import 'package:flutter/services.dart';

import 'lock_resume.dart';
import 'platform.dart';
import 'src/rust/api/vault.dart' as rust;

/// [read] again once the vault opens, when the vault locking cut it short (owner
/// 2026-10-25: a photo or a PDF still loading when the person left showed a read error
/// after unlock). Any other failure is the caller's to show.
Future<T> readThroughLock<T>(Future<T> Function() read) async {
  while (true) {
    try {
      return await read();
    } catch (_) {
      if (!vaultLock.locked) rethrow;
      await _opened();
    }
  }
}

Future<void> _opened() {
  if (!vaultLock.locked) return Future.value();
  final done = Completer<void>();
  void listen() {
    if (!vaultLock.locked && !done.isCompleted) {
      vaultLock.removeListener(listen);
      done.complete();
    }
  }

  vaultLock.addListener(listen);
  return done.future;
}

/// An item's decrypted content, read through a lock.
Future<Uint8List> itemBytes(String id) => readThroughLock(() => rust.itemContent(id: id));

const _media = MethodChannel('cozysafe/media');

/// A photo's bytes, ready for Flutter to draw. An iPhone's HEIC does not decode on every
/// Android (owner 2026-10-25), so there Android's own decoder turns it into a JPEG at
/// most [maxSide] px on its longer side; elsewhere the bytes are as stored.
Future<Uint8List> photoBytes(String id, {int maxSide = 4096}) async {
  final bytes = await itemBytes(id);
  if (!Device.android || !isHeif(bytes)) return bytes;
  try {
    final jpeg = await _media.invokeMethod<Uint8List>('decode', {'bytes': bytes, 'maxSide': maxSide});
    if (jpeg != null && jpeg.isNotEmpty) return jpeg;
  } catch (_) {}
  return bytes;
}

/// Whether [b] is a HEIF picture (HEIC and friends): an ISO box `ftyp` with one of
/// their brands.
bool isHeif(Uint8List b) {
  if (b.length < 12 || String.fromCharCodes(b.sublist(4, 8)) != 'ftyp') return false;
  const brands = {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1', 'avif'};
  return brands.contains(String.fromCharCodes(b.sublist(8, 12)));
}
