import 'package:flutter/widgets.dart';

/// Material Symbols Rounded (Google, Apache-2.0), the newer set beside the app's
/// Material Icons Rounded. New pieces use these (docs/design-language.md); the rest of
/// the app moves later (docs/backlog.md).
///
/// The font is a static instance, FILL 1, wght 500, GRAD 0, opsz 24: filled and
/// rounded like the `Icons.*_rounded` beside them, a touch heavier so the strokes match
/// at 28. Only the glyphs below are in it (assets/fonts/README.md says how it was cut):
/// a new one needs the font cut again, or it shows as a blank box.
abstract final class Sym {
  static const _family = 'MaterialSymbolsRounded';

  // Kinds of secure item (ADR 0009).
  static const key = IconData(0xe73c, fontFamily: _family);
  static const shieldLock = IconData(0xf686, fontFamily: _family);
  static const pin = IconData(0xf045, fontFamily: _family);

  // Adding step by step.
  static const qrCodeScanner = IconData(0xf206, fontFamily: _family);
  static const image = IconData(0xe3f4, fontFamily: _family);
  static const contentPaste = IconData(0xe14f, fontFamily: _family);
  static const link = IconData(0xe250, fontFamily: _family);
  static const search = IconData(0xef7a, fontFamily: _family);
  static const edit = IconData(0xf097, fontFamily: _family);
  static const autorenew = IconData(0xe863, fontFamily: _family);
  static const keyboard = IconData(0xe312, fontFamily: _family);
  static const alternateEmail = IconData(0xe0e6, fontFamily: _family);
  static const person = IconData(0xf0d3, fontFamily: _family);
  static const chevronRight = IconData(0xe5cc, fontFamily: _family);
  static const visibility = IconData(0xe8f4, fontFamily: _family);
  static const visibilityOff = IconData(0xe8f5, fontFamily: _family);
  static const checkCircle = IconData(0xf0be, fontFamily: _family);
  static const language = IconData(0xea07, fontFamily: _family);
  static const close = IconData(0xe5cd, fontFamily: _family);

  // The four ways to add, and their second choices.
  static const photoCamera = IconData(0xe412, fontFamily: _family);
  static const permMedia = IconData(0xe8a7, fontFamily: _family);
  static const editNote = IconData(0xe745, fontFamily: _family);
  static const photoLibrary = IconData(0xe413, fontFamily: _family);
  static const folder = IconData(0xe2c7, fontFamily: _family);
  static const notes = IconData(0xe26c, fontFamily: _family);
  static const mic = IconData(0xe31d, fontFamily: _family);

  /// Every glyph, for the test that checks each is in the font.
  static const all = [
    key, shieldLock, pin, qrCodeScanner, image, contentPaste, link, search, edit, autorenew, keyboard,
    alternateEmail, person, chevronRight, visibility, visibilityOff, checkCircle, language, close,
    photoCamera, permMedia, editNote, photoLibrary, folder, notes, mic,
  ];
}
