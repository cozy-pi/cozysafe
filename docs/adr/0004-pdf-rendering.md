# ADR 0004: Rendering PDFs without PDFium in the app's process

Status: **Proposed** (2026-10-28, owner asked to isolate risky third-party code)

## Context

A person can add any PDF to the vault. The app shows it twice: the viewer
(`screens/file_view.dart`, `PdfViewer.data` / `PdfViewer.file`) and the first page in
Quick Look (`screens/quick_look.dart`, `PdfDocument.openData`). Both go through `pdfrx`,
which runs PDFium, Chrome's PDF engine, written in C++, in the app's own process.

Why this is the riskiest code in the app:

- A PDF is a complex format, and PDFium's history is full of memory-safety bugs. Chrome
  runs it in a sandboxed renderer for that reason; we run it with every right the app
  has: decrypted items in memory, the vault keys while unlocked, the network for sync.
- A crafted PDF needs no help from the person beyond adding it (a download, an email
  attachment, a file someone sends to "store safely").
- We ship our own PDFium binary (`pdfium_dart` / `pdfium_flutter`, pinned by SHA-256).
  When PDFium is fixed, the fix reaches people only when we update the pin and release;
  nothing else patches it.
- `pdfrx` brings 15 packages of its own (`docs/dependencies.md`, tier 1), from one
  publisher.

Platforms: iOS, Android, macOS, Windows, Linux.

## Options

**A. PDFium in its own process.** Render pages in a helper with no rights and hand
bitmaps back.

- Android: a `Service` with `android:isolatedProcess="true"` gets no permissions, no
  network, no app files; it reads the PDF from a file descriptor it is passed.
- macOS: an XPC service with its own sandbox (no network, no files).
- Windows / Linux: a helper executable started with a restricted token / seccomp;
  more of our own platform code.
- **iOS allows neither** (no child processes, no app-defined XPC). The iPhone, the main
  platform, keeps PDFium in-process.
- We still ship and patch PDFium ourselves.

**B. The system's PDF renderer.** iOS and macOS: PDFKit. Android:
`android.graphics.pdf.PdfRenderer`. Windows: `Windows.Data.Pdf`. Linux has none.

- Bugs are fixed by Apple, Google and Microsoft through system updates, which reach
  people without a Cozy Safe release, and those renderers get far more scrutiny than
  our pinned copy.
- Still in the app's process (as with any system library), but the third-party code and
  our duty to patch it are gone: `pdfrx` and its 15 packages leave the app.
- Linux: no system renderer. Either keep PDFium there only, or show the PDF's name and
  size with "Export" (no in-app preview on Linux).
- Rendering becomes ours: a page list with zoom and scrolling over page bitmaps, one
  small platform channel per OS. Text selection and search are not offered today and
  would not be.

**C. No preview.** Show an icon; the person exports the PDF to open it elsewhere.
Rejected: export writes the decrypted file outside the vault, which is what the vault
is for.

## Proposal

**B, plus A on Android**: Android's `PdfRenderer` takes a file descriptor, so it can run
in an `isolatedProcess` service at little extra cost. Linux keeps the PDF's name, size and
Export only. Nothing in the vault format changes; only the two screens above.

| | iOS | Android | macOS | Windows | Linux |
|---|---|---|---|---|---|
| Renderer | PDFKit | PdfRenderer in an isolated process | PDFKit | Windows.Data.Pdf | none (Export) |
| Patched by | iOS updates | Android updates | macOS updates | Windows updates | — |

Open for the owner: Linux without a PDF preview, or PDFium kept for Linux only.
