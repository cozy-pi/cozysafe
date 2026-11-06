# Material Symbols Rounded (subset)

`MaterialSymbolsRounded.ttf` is a small cut of Google's Material Symbols Rounded, the
icons new pieces use through `Sym` (`lib/widgets/symbols.dart`, docs/design-language.md).
Licence: Apache-2.0 (`LICENSE` here, as published with the font).

| | |
|---|---|
| Source | https://github.com/google/material-design-icons, `variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf` and `.codepoints` |
| Commit | `10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7` (2026-10-23) |
| SHA-256 of the original `.ttf` | `7e74e36533ccee12c2b81e75bfcf3ccf123d3bb7e7e46d65d94445f23db0c97c` (15 235 612 bytes) |
| SHA-256 of the `.codepoints` | `a7404d9e5a1b63f496cf05ace45d386075886b5a7f123fba9f29527cb6006fde` |
| SHA-256 of `LICENSE` | `58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd` |
| Axes | a static instance: FILL 1, GRAD 0, opsz 24, wght 500 |
| Tool | fontTools 4.60.1 (`varLib.instancer`, `pyftsubset`), run on a computer, not in the build |
| SHA-256 of the subset | `82905b1bdc279fae4d55d1c4b39b2d306311c6740c67ba30699be76c3bc1543e` (7 204 bytes, 26 glyphs) |

Made with `tools/symbols-font <work dir> <names…>`, which downloads the two files at that
commit, checks their SHA-256 and runs:

    SOURCE_DATE_EPOCH=1792721923 fonttools varLib.instancer rounded.ttf FILL=1 GRAD=0 opsz=24 wght=500 -o static.ttf -q
    pyftsubset static.ttf --unicodes=<the glyphs' code points> --layout-features='' \
      --no-hinting --desubroutinize --name-IDs='*' --output-file=MaterialSymbolsRounded.ttf

The same input gives the same bytes. Glyphs, in this order: key shield_lock pin
qr_code_scanner image content_paste link search edit autorenew keyboard alternate_email
chevron_right visibility visibility_off check_circle language close person photo_camera
perm_media edit_note photo_library folder notes mic.

A new glyph: add it to `Sym`, run the tool with the whole list again, update the list
and the subset's hash here. `test/symbols_test.dart` fails when `Sym` names a glyph the
font lacks.
