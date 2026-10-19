import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import 'common.dart';
import 'file_view.dart';

/// The camera, opened from the Library's + menu (docs/ui.md, vault bar): Photo | Video,
/// a shutter, the last shot, and flip. What it takes goes into the album open in the
/// Library ([folder]).
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.video, this.folder, required this.onOpenLast});
  final bool video;
  final String? folder;
  final void Function(rust.ItemInfo item) onOpenLast;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final _view = GlobalKey<CameraViewState>();
  late bool _video = widget.video;
  bool _recording = false;
  DateTime? _since;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _recordingChanged(bool on) {
    _tick?.cancel();
    if (!mounted) return;
    setState(() {
      _recording = on;
      _since = on ? DateTime.now() : null;
    });
    if (on) _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final since = _since;
    final d = since == null ? Duration.zero : DateTime.now().difference(since);
    return PopScope(
      canPop: !_recording,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!_recording)
                      Positioned(
                        left: 8,
                        child: IconButton(
                          tooltip: l.close,
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close, color: Colors.white),
                        ),
                      ),
                    if (_recording)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16,
                              fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: CameraView(
                  key: _view,
                  video: _video,
                  folder: widget.folder,
                  onSaved: (_) {},
                  onOpenLast: widget.onOpenLast,
                  onRecordingChanged: _recordingChanged,
                ),
              ),
              const SizedBox(height: 14),
              if (!_recording)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final v in [false, true])
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _video = v),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          child: Text(
                            (v ? l.cameraVideo : l.photo).toUpperCase(),
                            style: TextStyle(
                              color: v == _video ? const Color(0xFFFFD60A) : Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              letterSpacing: .8,
                            ),
                          ),
                        ),
                      ),
                  ],
                )
              else
                const SizedBox(height: 30),
              const SizedBox(height: 10),
              Semantics(
                button: true,
                label: _video ? (_recording ? l.stopRecording : l.recordVideo) : l.takePhoto,
                child: GestureDetector(
                  key: const ValueKey('shutter'),
                  onTap: () => _view.currentState?.shoot(),
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                    padding: const EdgeInsets.all(5),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: EdgeInsets.all(_recording ? 15 : 0),
                      decoration: BoxDecoration(
                        color: _video ? const Color(0xFFE5484D) : Colors.white,
                        borderRadius: BorderRadius.circular(_recording ? 6 : 40),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// The live preview and what it saves.
///
/// Photos never touch a file in the clear: we take the next frame of the preview stream
/// (memory), and Rust encodes the JPEG and encrypts it into the open vault.
/// `takePicture` is not used because it writes a cache file. Video has no such path: the
/// plugin records to a file in the app's private cache, which is encrypted into the vault
/// and deleted as soon as recording stops (and before the vault locks).
class CameraView extends StatefulWidget {
  const CameraView({
    super.key,
    required this.onSaved,
    required this.onOpenLast,
    this.video = false,
    this.folder,
    this.onRecordingChanged,
  });

  final bool video;
  final String? folder;
  final ValueChanged<bool>? onRecordingChanged;

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
  bool _recording = false;

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
        enableAudio: widget.video,
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

  @override
  void didUpdateWidget(CameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Video needs the microphone on the controller: start it again with audio.
    if (oldWidget.video != widget.video && !_recording) _restart();
  }

  Future<void> _restart() async {
    final old = _controller;
    setState(() => _controller = null);
    if (old != null) await _stop(old);
    await _start();
  }

  Future<void> _flip() async {
    if (_cameras.length < 2 || _saving || _recording) return;
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
    if (_recording && c != null) {
      unawaited(_finishVideo(c).whenComplete(() => _stop(c)));
    } else if (c != null) {
      _stop(c);
    }
    if (LockGuard.beforeLock == _saveBeforeLock) LockGuard.beforeLock = null;
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  /// The shutter: a photo, or start / stop a video.
  void shoot() {
    if (widget.video) {
      _recording ? _stopVideo() : _startVideo();
      return;
    }
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

  Future<void> _saveBeforeLock() async {
    final c = _controller;
    if (_recording && c != null) await _finishVideo(c);
  }

  Future<void> _startVideo() async {
    final c = _controller;
    if (c == null || _saving) return;
    final failed = AppLocalizations.of(context).videoSaveFailed;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.startVideoRecording();
      HapticFeedback.mediumImpact();
      LockGuard.beforeLock = _saveBeforeLock;
      setState(() => _recording = true);
      widget.onRecordingChanged?.call(true);
    } catch (_) {
      _snack(failed);
    }
  }

  Future<void> _stopVideo() async {
    final c = _controller;
    if (c == null || !_recording) return;
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    final item = await _finishVideo(c);
    if (!mounted) return;
    if (item != null) {
      final thumb = await rust.itemThumbnail(id: item.id).catchError((_) => Uint8List(0));
      if (!mounted) return;
      setState(() {
        _last = item;
        _lastThumb = thumb.isEmpty ? null : thumb;
      });
      widget.onSaved(item);
    } else {
      _snack(AppLocalizations.of(context).videoSaveFailed);
    }
    setState(() => _saving = false);
    try {
      await c.startImageStream(_onFrame);
    } catch (_) {}
  }

  /// Stop the recording, encrypt it into the vault, delete the plain file.
  Future<rust.ItemInfo?> _finishVideo(CameraController c) async {
    if (!_recording) return null;
    _recording = false;
    if (LockGuard.beforeLock == _saveBeforeLock) LockGuard.beforeLock = null;
    widget.onRecordingChanged?.call(false);
    XFile? file;
    try {
      file = await c.stopVideoRecording();
      final named = XFile(file.path, name: 'VID_${DateTime.now().millisecondsSinceEpoch}.mp4', mimeType: 'video/mp4');
      final added = await importFiles([named], photos: true);
      final item = added.firstOrNull;
      if (item != null && widget.folder != null) await rust.moveItems(ids: [item.id], folder: widget.folder);
      return item;
    } catch (_) {
      return null;
    } finally {
      if (file != null) {
        try {
          File(file.path).deleteSync();
        } catch (_) {}
      }
    }
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
      if (widget.folder != null) await rust.moveItems(ids: [item.id], folder: widget.folder);
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
                  onPressed: _saving || _recording ? null : _flip,
                  icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
