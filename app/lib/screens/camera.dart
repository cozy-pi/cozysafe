import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import 'common.dart';

/// In-app camera. Shots never touch a file in the clear: we take the next frame of the
/// preview stream (memory), and Rust encodes the JPEG and encrypts it into the open
/// vault. `takePicture` is not used because it writes a cache file.
///
/// Pops with the number of photos saved.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _failed = false;
  bool _wantShot = false;
  bool _saving = false;
  bool _flash = false;
  int _saved = 0;
  Uint8List? _lastThumb;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final c = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );
      await c.initialize();
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await c.startImageStream(_onFrame);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    if (c != null) {
      // Stop the stream before disposing; both are best effort while leaving.
      (c.value.isStreamingImages ? c.stopImageStream() : Future<void>.value())
          .whenComplete(c.dispose);
    }
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  void _shoot() {
    if (_saving || _controller == null) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _wantShot = true;
      _saving = true;
      _flash = true;
    });
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  Future<void> _onFrame(CameraImage image) async {
    if (!_wantShot) return;
    _wantShot = false;
    final l = AppLocalizations.of(context);
    try {
      final frame = rust.CameraFrame(
        width: image.width,
        height: image.height,
        format: Platform.isIOS ? rust.FrameFormat.bgra8888 : rust.FrameFormat.yuv420,
        // Copy now: the plugin reuses these buffers for the next frame.
        planes: [
          for (final p in image.planes)
            rust.FramePlane(
              bytes: Uint8List.fromList(p.bytes),
              bytesPerRow: p.bytesPerRow,
              bytesPerPixel: p.bytesPerPixel ?? 1,
            ),
        ],
        rotation: _rotationFor(image),
      );
      final item = await rust.addPhoto(
        frame: frame,
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );
      final thumb = await rust.itemThumbnail(id: item.id);
      if (!mounted) return;
      setState(() {
        _saved++;
        _lastThumb = thumb;
      });
    } on rust.VaultError catch (e) {
      _snack(vaultErrorText(l, e));
    } catch (_) {
      _snack(l.photoSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The UI is held in portrait. A landscape frame is the sensor's native layout and
  /// needs turning: by the sensor's mounting angle on Android, a quarter turn on iOS.
  int _rotationFor(CameraImage image) {
    if (image.width <= image.height) return 0;
    if (Platform.isIOS) return 90;
    return _controller?.description.sensorOrientation ?? 90;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(_saved),
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: l.close,
              ),
            ),
            Expanded(
              child: Center(
                child: _failed
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          l.cameraUnavailable,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, height: 1.5),
                        ),
                      )
                    : c == null
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Stack(
                            alignment: Alignment.center,
                            children: [
                              CameraPreview(c),
                              IgnorePointer(
                                child: AnimatedOpacity(
                                  opacity: _flash ? 0.7 : 0,
                                  duration: const Duration(milliseconds: 90),
                                  child: Container(color: Colors.white),
                                ),
                              ),
                            ],
                          ),
              ),
            ),
            SizedBox(
              height: 112,
              child: Row(
                children: [
                  Expanded(
                    child: Center(
                      child: _lastThumb == null
                          ? const SizedBox.shrink()
                          : _LastShot(thumb: _lastThumb!, label: l.photosSaved(_saved)),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: l.shutter,
                    child: GestureDetector(
                      onTap: _failed ? null : _shoot,
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                        ),
                        padding: const EdgeInsets.all(5),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _saving ? Colors.white54 : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastShot extends StatelessWidget {
  const _LastShot({required this.thumb, required this.label});

  final Uint8List thumb;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(thumb, width: 48, height: 48, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
