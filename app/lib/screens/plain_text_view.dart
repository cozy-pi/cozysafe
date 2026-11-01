import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/vault_bar.dart' show pushPage;
import 'file_view.dart' show textExtensions, textNames;


/// The largest file read as text (the Rust core's `plain_text::MAX`).
const plainTextMax = 1 << 20;

/// Whether [item] may open as plain text in Top Secret Mode: a file with a listed
/// extension, at most 1 MB. The core checks again, and checks the bytes.
bool opensAsPlainText(rust.ItemInfo item) {
  if (item.kind != 'file' || item.sizeBytes > BigInt.from(plainTextMax)) return false;
  // The same names as the everyday mode reads as text (file_view.dart).
  final name = item.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot < 0 ? textNames.contains(name) : textExtensions.contains(name.substring(dot + 1));
}

/// A plain text file in Top Secret Mode (owner 2026-11-01): its characters as they are,
/// in a fixed-width face; no Markdown, no colours, no links. When the core refuses (not
/// text after all), [onRefused] runs instead, for the sealed card.
Future<void> showPlainText(BuildContext context, rust.ItemInfo item, {required VoidCallback onRefused}) async {
  String text;
  try {
    text = await rust.itemPlainText(id: item.id);
  } catch (_) {
    onRefused();
    return;
  }
  if (!context.mounted) return;
  await pushPage<void>(
    context,
    title: item.name,
    builder: (context) => _PlainText(text: text),
  );
}

class _PlainText extends StatelessWidget {
  const _PlainText({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    return Scrollbar(
      child: SingleChildScrollView(
        key: const ValueKey('plain-text'),
        padding: const EdgeInsets.fromLTRB(Ui.side, 12, Ui.side, 40),
        child: text.isEmpty
            ? Text(l.plainTextEmpty, style: TextStyle(color: ink.withValues(alpha: .6)))
            : SelectableText(
                text,
                style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Courier'], fontSize: CsType.footnote, height: 1.45, color: ink),
              ),
      ),
    );
  }
}
