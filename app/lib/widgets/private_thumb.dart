import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'vault_bar.dart' show blurThumbnails;
import '../vault_kind.dart';

/// Width a blurred thumbnail is made at: blurred, so drawing it larger loses nothing.
const _blurSide = 48;

/// The blur on that small picture: about the old 12 px blur on a library square.
const _blurSigma = 4.5;

/// Blurred thumbnails made so far, by their bytes (gone with them).
final _blurred = Expando<ui.Image>();
final _making = Expando<Future<ui.Image?>>();

Future<ui.Image?> _blur(Uint8List bytes) => _making[bytes] ??= () async {
      try {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: _blurSide);
        final small = (await codec.getNextFrame()).image;
        codec.dispose();
        final rec = ui.PictureRecorder();
        Canvas(rec).drawImage(
            small,
            Offset.zero,
            Paint()
              ..imageFilter = ui.ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma, tileMode: TileMode.clamp));
        final out = await rec.endRecording().toImage(small.width, small.height);
        small.dispose();
        return _blurred[bytes] = out;
      } catch (_) {
        return null;
      }
    }();

/// A thumbnail filling its box, blurred when [blurThumbnails] is on.
///
/// Smooth scrolling (owner 2026-10-28: the library did not scroll like Photos): the blur
/// used to be a filter on every square, redone on every frame of a scroll for each of the
/// dozens on screen. Now each thumbnail is blurred once, small, and kept.
class PrivateThumb extends StatelessWidget {
  const PrivateThumb(this.bytes, {super.key});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    // A Top secret run decodes no picture (ADR 0005): the last guard, whatever asked.
    if (RunKind.topSecret) return const SizedBox.expand();
    if (!blurThumbnails()) return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    final ready = _blurred[bytes];
    if (ready != null) return _image(ready);
    // Never the clear picture, not even for a frame: nothing until the blurred one is made.
    return FutureBuilder<ui.Image?>(
      future: _blur(bytes),
      builder: (context, snap) => snap.data == null ? const SizedBox.expand() : _image(snap.data!),
    );
  }

  static Widget _image(ui.Image image) => SizedBox.expand(
        child: RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
      );
}
