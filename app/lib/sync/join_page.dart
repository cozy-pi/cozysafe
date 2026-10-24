import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import '../widgets/vault_bar.dart' show pushPage;
import 'consent.dart';
import 'progress.dart';

/// A code read or typed: name the address it points at, ask, then connect.
Future<void> joinWithCode(BuildContext context, String code, {required VoidCallback onSynced}) async {
  final l = AppLocalizations.of(context);
  final address = sync.p2PCodeAddress(code: code);
  if (address == null) return;
  if (!await allowConnection(context, l.syncAllowJoin(address))) return;
  if (!context.mounted) return;
  await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text(l.syncTitle)),
      body: SafeArea(top: false, child: SyncProgress(events: sync.p2PJoin(code: code), onSynced: onSynced)),
    ),
  ));
}

/// Type the code the other device shows.
class TypeCodePage extends StatefulWidget {
  const TypeCodePage({super.key, required this.onSynced});
  final VoidCallback onSynced;

  @override
  State<TypeCodePage> createState() => _TypeCodePageState();
}

class _TypeCodePageState extends State<TypeCodePage> {
  final _text = TextEditingController();
  bool _bad = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _go() {
    final code = _text.text.trim();
    if (sync.p2PCodeAddress(code: code) == null) {
      setState(() => _bad = true);
      return;
    }
    joinWithCode(context, code, onSynced: widget.onSynced);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        TextField(
          key: const ValueKey('sync-code-field'),
          controller: _text,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z\- ]')), LengthLimitingTextInputFormatter(24)],
          style: const TextStyle(fontSize: 20, letterSpacing: 2, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: l.syncCodeHint,
            hintStyle: const TextStyle(fontSize: 16, letterSpacing: 0, fontFamily: null),
            errorText: _bad ? l.syncCodeBad : null,
          ),
          onChanged: (_) {
            if (_bad) setState(() => _bad = false);
          },
          onSubmitted: (_) => _go(),
        ),
        const SizedBox(height: 18),
        FilledButton(key: const ValueKey('sync-connect'), onPressed: _go, child: Text(l.syncConnect)),
      ],
    );
  }
}

/// Read the code with the camera; only Cozy Safe pairing codes are taken.
class ScanCodePage extends StatefulWidget {
  const ScanCodePage({super.key, required this.onSynced});
  final VoidCallback onSynced;

  /// For the mockup renders: a still image instead of the camera.
  static Widget? debugPreview;

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage> {
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
      final c = CameraController(back, ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      if (!mounted) {
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
        await _camera?.stopImageStream();
        if (!mounted) return;
        await joinWithCode(context, code, onSynced: widget.onSynced);
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
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('sync-type-instead'),
              icon: const Icon(Icons.keyboard_outlined),
              label: Text(l.syncTypeCode),
              onPressed: () => pushPage<void>(context, title: l.syncTypeCode, builder: (_) => TypeCodePage(onSynced: widget.onSynced)),
            ),
          ),
        ],
      ),
    );
  }
}
