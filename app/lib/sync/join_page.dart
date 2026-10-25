import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import 'consent.dart';
import 'progress.dart';

/// A code read or typed: name the address it points at, ask, then connect.
/// [ask] false: the person already allowed it (looking for their device on this Wi-Fi).
Future<void> joinWithCode(BuildContext context, String code, {required VoidCallback onSynced, bool ask = true}) async {
  final l = AppLocalizations.of(context);
  final address = sync.p2PCodeAddress(code: code);
  if (address == null) return;
  if (ask && !await allowConnection(context, l.syncAllowJoin(address))) return;
  if (!context.mounted) return;
  final route = MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text(l.syncRow)),
      body: SafeArea(
        top: false,
        child: SyncProgress(
          events: sync.p2PJoin(code: code),
          onSynced: onSynced,
          waiting: Builder(builder: (context) => _Connecting(address: address)),
        ),
      ),
    ),
  );
  // From the QR page it takes that page's place; from the digits it stacks, so Back
  // after the sync comes back to the sync screen either way.
  await (ask ? Navigator.of(context).pushReplacement(route) : Navigator.of(context).push(route));
}

/// What to do with a code read or typed (sync by default; a restore passes its own).
typedef OnCode = Future<void> Function(BuildContext context, String code);

/// Read the code with the camera; only Cozy Safe pairing codes are taken.
class ScanCodePage extends StatefulWidget {
  const ScanCodePage({super.key, required this.onSynced, this.onCode});
  final VoidCallback onSynced;
  final OnCode? onCode;

  /// For the mockup renders: a still image instead of the camera.
  static Widget? debugPreview;

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage> with VaultLockAware {
  CameraController? _camera;
  bool _none = false;
  bool _reading = false;
  bool _found = false;

  @override
  void initState() {
    super.initState();
    if (ScanCodePage.debugPreview == null) _open();
  }

  Future<void> _open() async {
    try {
      final all = await availableCameras();
      final back = all.where((c) => c.lensDirection == CameraLensDirection.back).firstOrNull ?? all.firstOrNull;
      if (back == null) throw StateError('no camera');
      // High: a code on another phone's screen is small and needs the detail (reading a
      // 720p frame takes ~10 ms).
      final c = CameraController(back, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      if (!mounted || vaultLock.locked) {
        await c.dispose();
        return;
      }
      setState(() => _camera = c);
      await c.startImageStream(_onFrame);
    } catch (_) {
      if (mounted) setState(() => _none = true);
    }
  }

  // One frame at a time, in Rust off the UI thread; the brightness plane is enough.
  Future<void> _onFrame(CameraImage image) async {
    if (_reading || _found || image.planes.isEmpty) return;
    _reading = true;
    try {
      final y = image.planes.first;
      final code = await sync.qrRead(luma: y.bytes, width: image.width, height: image.height, stride: y.bytesPerRow);
      if (code != null && mounted && !_found) {
        _found = true;
        HapticFeedback.mediumImpact();
        // Ask at once; the camera stops meanwhile (waiting for it first felt slow).
        unawaited(_camera?.stopImageStream());
        final onCode = widget.onCode;
        if (onCode != null) {
          await onCode(context, code);
        } else {
          await joinWithCode(context, code, onSynced: widget.onSynced);
        }
        // Asked and refused: keep looking.
        if (mounted) {
          _found = false;
          await _camera?.startImageStream(_onFrame);
        }
      }
    } catch (_) {
      // A bad frame: try the next.
    } finally {
      _reading = false;
    }
  }

  /// The page stays under the lock; the camera lets go meanwhile and starts again after.
  @override
  void vaultLocking() {
    final c = _camera;
    setState(() => _camera = null);
    c?.dispose();
  }

  @override
  void vaultUnlocked() {
    if (_camera == null && !_none && ScanCodePage.debugPreview == null) _open();
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final cam = _camera;
    final preview = ScanCodePage.debugPreview ??
        (cam != null && cam.value.isInitialized ? CameraPreview(cam) : const ColoredBox(color: Colors.black));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: _none
                      ? ColoredBox(
                          color: Theme.of(context).cardColor,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(l.syncNoCamera, textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
                            ),
                          ),
                        )
                      : Stack(fit: StackFit.expand, children: [
                          FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox(width: 300, height: 400, child: preview)),
                          // The frame to aim with.
                          Padding(
                            padding: const EdgeInsets.all(36),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white, width: 3),
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                          ),
                        ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(l.syncPointCamera, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15, height: 1.35)),
        ],
      ),
    );
  }
}

/// Right after Allow, until the other device has proved the vault.
class _Connecting extends StatelessWidget {
  const _Connecting({required this.address});
  final String address;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text(AppLocalizations.of(context).syncConnectingTo(address),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ],
      );
}
