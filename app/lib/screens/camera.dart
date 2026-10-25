import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture_name.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../widgets/vault_bar.dart';
import '../src/rust/api/vault.dart' as rust;
import 'common.dart';
import 'file_view.dart';
import '../widgets/toast.dart';
import '../theme.dart';

/// The camera, opened from the Library's + menu (docs/ui.md, vault bar): Photo | Video,
/// a shutter, the last shot, and flip. What it takes carries the tag open in the vault
/// ([tagId]), if any.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.video, this.tagId, required this.onOpenLast});
  final bool video;
  final String? tagId;
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
    final ink = Theme.of(context).colorScheme.onSurface;
    final view = _view.currentState;
    final last = view?.lastShot;
    final lastThumbnail = view?.lastThumbnail;
    return PopScope(
      canPop: !_recording,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // A grabber (swipe down closes), the title, and the timer while recording.
              // Close itself is in the bottom row, in thumb reach (docs/ui.md, camera).
              Container(
                width: 38,
                height: 5,
                margin: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(color: ink.withValues(alpha: .22), borderRadius: BorderRadius.circular(3)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _video ? l.recordVideo : l.takePhoto,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -.5),
                      ),
                    ),
                    if (_recording)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: recordRed(context), borderRadius: BorderRadius.circular(10)),
                        child: Text(
                          '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15,
                              fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                  ],
                ),
              ),
              // The viewfinder, a rounded card inside the page; swipe down on it closes.
              // The last shot sits in its corner, small, until tapped.
              Expanded(
                child: GestureDetector(
                  onVerticalDragEnd: (e) {
                    if (!_recording && (e.primaryVelocity ?? 0) > 600) Navigator.of(context).maybePop();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: CameraView(
                            key: _view,
                            video: _video,
                            tagId: widget.tagId,
                            onSaved: (_) {},
                            onChanged: () {
                              if (mounted) setState(() {});
                            },
                            onRecordingChanged: _recordingChanged,
                          ),
                        ),
                        if (last != null && lastThumbnail != null && !_recording)
                          Positioned(
                            left: 14,
                            bottom: 14,
                            child: Semantics(
                              button: true,
                              label: l.openLastShot,
                              child: GestureDetector(
                                onTap: () => widget.onOpenLast(last),
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: Colors.white, width: 2),
                                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 10)],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.memory(lastThumbnail, fit: BoxFit.cover),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // Photo | Video, in the same glass capsule as the vault's sections.
              AnimatedOpacity(
                opacity: _recording ? 0 : 1,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: _recording,
                  child: SizedBox(
                    width: 240,
                    child: Glass(
                      radius: Ui.chip / 2 + 4,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            for (final v in [false, true])
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  selected: v == _video,
                                  child: GestureDetector(
                                    key: ValueKey(v ? 'camera-video' : 'camera-photo'),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => setState(() => _video = v),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 160),
                                      height: Ui.chip,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: v == _video
                                            ? Theme.of(context).colorScheme.primary.withValues(alpha: .14)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(Ui.chip / 2),
                                      ),
                                      child: Text(
                                        v ? l.cameraVideo : l.photo,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: v == _video ? FontWeight.w700 : FontWeight.w600,
                                          color: v == _video
                                              ? Theme.of(context).colorScheme.primary
                                              : ink.withValues(alpha: .75),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // Close · shutter · flip, all in thumb reach.
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: Ui.bar,
                      child: _recording
                          ? null
                          : GlassButton(
                              key: const ValueKey('camera-close'),
                              icon: Icons.close,
                              tooltip: l.close,
                              size: Ui.bar,
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                    ),
                    const Spacer(),
                    Semantics(
                      button: true,
                      label: _video ? (_recording ? l.stopRecording : l.recordVideo) : l.takePhoto,
                      child: GestureDetector(
                        key: const ValueKey('shutter'),
                        onTap: () => _view.currentState?.shoot(),
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ink, width: 4)),
                          padding: const EdgeInsets.all(5),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            // Photo: a full disc. Video: a smaller disc. Recording: a square.
                            margin: EdgeInsets.all(_recording ? 16 : (_video ? 9 : 0)),
                            decoration: BoxDecoration(
                              // Video (and recording) red, photo ink — as in the phone's camera.
                              color: _video ? recordRed(context) : ink,
                              borderRadius: BorderRadius.circular(_recording ? 6 : 40),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    SizedBox.square(
                      dimension: Ui.bar,
                      child: (view?.canFlip ?? false) && !_recording
                          ? Center(
                              child: GlassButton(
                                icon: Icons.cameraswitch_outlined,
                                tooltip: l.flipCamera,
                                size: Ui.bar,
                                onTap: () => _view.currentState?.flip(),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
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
    this.video = false,
    this.tagId,
    this.onRecordingChanged,
    this.onChanged,
  });

  /// For the mockup renders (tool/mockup.sh): a still image instead of the camera.
  static Widget? debugPreview;
  /// For the mockup renders: a last shot to show in the corner.
  static (rust.ItemInfo, Uint8List)? debugLast;

  final bool video;
  final String? tagId;
  final ValueChanged<bool>? onRecordingChanged;
  /// The last shot or the cameras changed: the screen redraws its controls.
  final VoidCallback? onChanged;

  /// A photo was encrypted into the vault.
  final void Function(rust.ItemInfo item) onSaved;
  @override
  State<CameraView> createState() => CameraViewState();
}

class CameraViewState extends State<CameraView> with VaultLockAware {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _camera = 0;
  bool _failed = false;
  bool _wantShot = false;
  bool _saving = false;
  bool _flash = false;
  rust.ItemInfo? _last;
  Uint8List? _lastThumbnail;
  bool _recording = false;
  /// Set when recording starts (the context may be gone when it is saved on lock).
  String? _videoName;

  bool get ready => _controller != null && !_saving;
  rust.ItemInfo? get lastShot => _last;
  Uint8List? get lastThumbnail => _lastThumbnail;
  bool get canFlip => _cameras.length > 1 || CameraView.debugPreview != null;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _start();
    // The screen draws flip / last shot from this state: tell it once it exists.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onChanged?.call());
  }

  Future<void> _start() async {
    if (CameraView.debugPreview != null) {
      _last = CameraView.debugLast?.$1;
      _lastThumbnail = CameraView.debugLast?.$2;
      return;
    }
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
      if (!mounted || vaultLock.locked) {
        await _stop(c);
        return;
      }
      setState(() => _controller = c);
      widget.onChanged?.call();
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

  /// Switch between the back and front camera.
  Future<void> flip() async {
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
    if (vaultLock.locked) _release();
  }

  /// The screen stays under the lock; the camera itself lets go (a recording is saved
  /// first, by [_saveBeforeLock]) and starts again when the vault opens.
  @override
  void vaultLocking() {
    if (_wantShot) {
      _wantShot = false;
      _saving = false;
    }
    if (!_recording) _release();
  }

  @override
  void vaultUnlocked() {
    if (_controller == null && !_failed && CameraView.debugPreview == null) _start();
  }

  void _release() {
    final c = _controller;
    if (c == null) return;
    setState(() => _controller = null);
    widget.onChanged?.call();
    _stop(c);
  }

  Future<void> _startVideo() async {
    final c = _controller;
    if (c == null || _saving) return;
    final l = AppLocalizations.of(context);
    final failed = l.videoSaveFailed;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.startVideoRecording();
      _videoName = captureName(l, ItemKind.video, DateTime.now(), '.mp4');
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
      final thumbnail = await rust.itemThumbnail(id: item.id).catchError((_) => Uint8List(0));
      if (!mounted) return;
      setState(() {
        _last = item;
        _lastThumbnail = thumbnail.isEmpty ? null : thumbnail;
      });
      widget.onChanged?.call();
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
      final named = XFile(file.path, name: _videoName ?? 'Video.mp4', mimeType: 'video/mp4');
      final added = await importFiles([named], photos: true);
      final item = added.firstOrNull;
      final tagId = widget.tagId;
      if (item != null && tagId != null) await rust.setTag(itemIds: [item.id], tagId: tagId, tagged: true);
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
      final item = await rust.addPhoto(
          frame: frame, name: captureName(l, ItemKind.photo, DateTime.now(), '.jpg'), createdMs: nowMs());
      final tagId = widget.tagId;
      if (tagId != null) await rust.setTag(itemIds: [item.id], tagId: tagId, tagged: true);
      final thumbnail = await rust.itemThumbnail(id: item.id);
      if (!mounted) return;
      setState(() {
        _last = item;
        _lastThumbnail = thumbnail;
      });
      widget.onChanged?.call();
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
    showToast(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    final still = CameraView.debugPreview;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (still != null)
            still
          else
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
        ],
      ),
    );
  }
}
