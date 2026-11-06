import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../src/rust/api/sync.dart' as rust;
import '../theme.dart';
import '../top_secret_mode.dart';
import 'totp.dart';

/// What a QR code held, for a two-factor setup (docs/adr/0009-secure-items.md, QR codes).
sealed class QrResult {
  const QrResult();
}

/// An `otpauth://totp/` link, read.
final class QrTotp extends QrResult {
  const QrTotp(this.totp);
  final Totp totp;
}

/// A QR code, but not a two-factor setup (a web link, a Wi-Fi code).
final class QrNotTotp extends QrResult {
  const QrNotTotp();
}

/// A picture with no QR code in it.
final class QrNone extends QrResult {
  const QrNone();
}

/// The camera could not be used (none, or no permission).
final class QrNoCamera extends QrResult {
  const QrNoCamera();
}

/// Reading a two-factor setup code from a QR code: on iOS a camera page of its own
/// (AVFoundation) and Vision for a photo, on a Mac Vision for an image file, on Android
/// the app's own Rust decoder (rqrr, [rust.qrReadText], as for pairing devices) on the
/// camera's frames and on a photo turned to grey. Everything stays in memory: no frame
/// or picture is written to a file, kept in the photo library or logged; only the code's
/// text comes back, and only an `otpauth://totp/` link is taken.
abstract final class QrCode {
  static const channel = MethodChannel('cozysafe/qr');

  /// Tests and mockups: what this device offers, in place of the platform's.
  static ({bool camera, bool photo})? debugAvailable;

  /// The camera can read one (phones).
  static bool get canScan => debugAvailable?.camera ?? (Device.iOS || Device.android);

  /// A picture can be read (phones: the photo picker; a Mac: an image file). Not in Top
  /// Secret Mode, where nothing is taken from the photo library or decoded from outside
  /// (ADR 0006): the camera and Paste stay.
  static bool get canReadPhoto =>
      !TopSecretMode.on && (debugAvailable?.photo ?? (Device.iOS || Device.android || Device.macOS));

  /// What a QR code's text is for a two-factor setup. Never throws.
  static QrResult read(String? text) {
    final t = text?.trim() ?? '';
    if (t.isEmpty) return const QrNone();
    if (!t.toLowerCase().startsWith('otpauth://')) return const QrNotTotp();
    final totp = Totp.parse(t);
    return totp == null ? const QrNotTotp() : QrTotp(totp);
  }

  /// Point the camera at a QR code. Null when closed without one.
  static Future<QrResult?> scan(BuildContext context) async {
    final String? text;
    if (Device.android) {
      final got = await Navigator.of(context).push<Object>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => const QrCameraScreen()));
      if (got is QrNoCamera) return got;
      text = got is String ? got : null;
    } else {
      final cancel = AppLocalizations.of(context).cancel;
      try {
        text = await channel.invokeMethod<String>('scan', {'cancel': cancel});
      } on PlatformException {
        return const QrNoCamera();
      }
    }
    return text == null ? null : read(text);
  }

  /// The vault is locking: the camera page closes (iOS draws it over the app).
  static Future<void> cancel() async {
    if (!Device.iOS) return;
    try {
      await channel.invokeMethod<void>('cancel');
    } catch (_) {}
  }

  /// Pick a screenshot or photo holding a QR code. Null when none was picked.
  static Future<QrResult?> readPhoto() async {
    // The picker is the system's: the vault does not lock while it is up.
    LockGuard.allowAway();
    try {
      final got = await channel.invokeMethod<Object>('pickImage');
      if (got == null) return null;
      // Android: the picture's brightness plane, read here by the Rust decoder.
      if (got is Map) {
        final luma = got['luma'];
        final width = got['width'] is int ? got['width'] as int : 0;
        final height = got['height'] is int ? got['height'] as int : 0;
        if (luma is! Uint8List || width <= 0 || height <= 0) return const QrNone();
        return read(await rust.qrReadText(luma: luma, width: width, height: height, stride: width));
      }
      return read(got is String ? got : null);
    } on PlatformException {
      return const QrNone();
    } finally {
      LockGuard.clear();
    }
  }
}

/// Android's QR camera: the `camera` plugin's preview, and a few frames a second read
/// by the Rust decoder ([rust.qrReadText], the luminance plane only, in memory). Pops the
/// code's text, or nothing.
class QrCameraScreen extends StatefulWidget {
  const QrCameraScreen({super.key});

  @override
  State<QrCameraScreen> createState() => _QrCameraScreenState();
}

class _QrCameraScreenState extends State<QrCameraScreen> with VaultLockAware {
  CameraController? _controller;
  bool _failed = false;
  bool _busy = false;
  /// Answered (a code, Cancel, the lock): nothing more pops.
  bool _done = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _start();
  }

  bool get _gone => !mounted || _done || vaultLock.locked;

  Future<void> _start() async {
    CameraController? c;
    try {
      final cameras = await availableCameras();
      if (_gone) return;
      final back = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      c = CameraController(cameras[back < 0 ? 0 : back], ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      // Held from here, so [_stop] lets it go whatever happens next.
      _controller = c;
      await c.initialize();
      if (_gone) return await _stop();
      await c.startImageStream(_onFrame);
      if (_gone) return await _stop();
      setState(() {});
    } catch (_) {
      await _stop();
      if (mounted) setState(() => _failed = true);
    }
  }

  /// About four frames a second, one at a time.
  Future<void> _onFrame(CameraImage image) async {
    final now = DateTime.now();
    if (_busy || _done || image.planes.isEmpty || now.difference(_last) < const Duration(milliseconds: 250)) return;
    _busy = true;
    _last = now;
    try {
      final y = image.planes.first;
      final text = await rust.qrReadText(luma: y.bytes, width: image.width, height: image.height, stride: y.bytesPerRow);
      if (text != null && text.isNotEmpty && !_gone) {
        HapticFeedback.mediumImpact();
        _finish(text);
      }
    } catch (_) {
      // A frame that could not be read: the next one is tried.
    } finally {
      _busy = false;
    }
  }

  /// Close with [value], once, and only this page (never the one under it).
  void _finish(Object? value) {
    if (_done) return;
    _done = true;
    _stop();
    if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop(value);
  }

  /// The camera lets go when the vault locks; the page closes.
  @override
  void vaultLocking() => _finish(null);

  Future<void> _stop() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _done = true;
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (c != null && c.value.isInitialized) Center(child: CameraPreview(c)),
          if (_failed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l.qrCameraFailed,
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: CsType.body)),
              ),
            ),
          // A square to aim with.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: .85), width: 3),
                borderRadius: BorderRadius.circular(Ui.radius),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: TextButton(
                      key: const ValueKey('qr-cancel'),
                      onPressed: () => _finish(null),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.black54,
                        shape: const StadiumBorder(),
                        minimumSize: const Size(0, Ui.tap),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: Text(l.cancel),
                    ),
                  ),
                  const Spacer(),
                  Text(l.qrAim,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: CsType.callout, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
