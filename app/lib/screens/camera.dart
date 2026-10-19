import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import 'common.dart';

/// The camera inside the vault: it takes the content area while the dock's mode is
/// "Take photo", and the dock's round button shoots (docs/ui.md, vault content).
///
/// Shots never touch a file in the clear: we take the next frame of the preview stream
/// (memory), and Rust encodes the JPEG and encrypts it into the open vault.
/// `takePicture` is not used because it writes a cache file.
class CameraView extends StatefulWidget {
  const CameraView({super.key, required this.onSaved, required this.onOpenLast});

  /// A photo was encrypted into the vault.
  final void Function(rust.ItemInfo item) onSaved;
  /// The last shot's thumbnail was tapped.
  final void Function(rust.ItemInfo item) onOpenLast;

  @override
  State<CameraView> createState() => CameraViewState();
}

class CameraViewState extends State<CameraView> {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _camera = 0;
  bool _failed = false;
  bool _wantShot = false;
  bool _saving = false;
  bool _flash = false;
  rust.ItemInfo? _last;
  Uint8List? _lastThumb;

  bool get ready => _controller != null && !_saving;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _start();
  }

  Future<void> _start() async {
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
        final back = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
        _camera = back < 0 ? 0 : back;
      }
      final c = CameraController(
        _cameras[_camera],
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: Device.iOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );
      await c.initialize();
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await c.startImageStream(_onFrame);
      if (!mounted) {
        await _stop(c);
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  static Future<void> _stop(CameraController c) async {
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    await c.dispose();
  }

  Future<void> _flip() async {
    if (_cameras.length < 2 || _saving) return;
    final old = _controller;
    setState(() {
      _controller = null;
      _camera = (_camera + 1) % _cameras.length;
    });
    if (old != null) await _stop(old);
    await _start();
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    if (c != null) _stop(c);
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  /// Called by the dock's shutter button.
  void shoot() {
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
        format: Device.iOS ? rust.FrameFormat.bgra8888 : rust.FrameFormat.yuv420,
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
      final item = await rust.addPhoto(frame: frame, createdMs: nowMs());
      final thumb = await rust.itemThumbnail(id: item.id);
      if (!mounted) return;
      setState(() {
        _last = item;
        _lastThumb = thumb;
      });
      widget.onSaved(item);
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
    if (Device.iOS) return 90;
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
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
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
                    : ClipRect(
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: c.value.previewSize?.height ?? 1080,
                            height: c.value.previewSize?.width ?? 1920,
                            child: CameraPreview(c),
                          ),
                        ),
                      ),
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _flash ? 0.7 : 0,
              duration: const Duration(milliseconds: 90),
              child: const ColoredBox(color: Colors.white),
            ),
          ),
          if (_lastThumb != null && _last != null)
            Positioned(
              left: 14,
              bottom: 14,
              child: Semantics(
                button: true,
                label: l.openLastShot,
                child: GestureDetector(
                  onTap: () => widget.onOpenLast(_last!),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: Colors.white, width: 2),
                      image: DecorationImage(image: MemoryImage(_lastThumb!), fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
            ),
          if (_cameras.length > 1)
            Positioned(
              right: 14,
              bottom: 14,
              child: Material(
                color: const Color(0x73000000),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: l.flipCamera,
                  onPressed: _saving ? null : _flip,
                  icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
