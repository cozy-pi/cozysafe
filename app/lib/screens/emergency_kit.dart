import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../theme.dart';
import '../widgets/secret.dart';
import 'common.dart';
import '../widgets/toast.dart';

/// The Secret Key, written for people. Shown once after the first vault (and later from
/// the vault menu). With `confirm`, the user must type its last 4 characters to go on,
/// so it has really been written down somewhere.
class EmergencyKitScreen extends StatefulWidget {
  const EmergencyKitScreen({super.key, required this.keyText, required this.confirm, this.onDone});

  final String keyText;
  final bool confirm;
  final VoidCallback? onDone;

  @override
  State<EmergencyKitScreen> createState() => _EmergencyKitScreenState();
}

class _EmergencyKitScreenState extends State<EmergencyKitScreen> {
  final _last = TextEditingController();

  String get _tail => widget.keyText.replaceAll('-', '').substring(widget.keyText.replaceAll('-', '').length - 4);
  bool get _ok => !widget.confirm || _last.text.trim().toUpperCase() == _tail;

  @override
  void dispose() {
    _last.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final l = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: widget.keyText));
    LockGuard.copied(widget.keyText); // wiped from the clipboard after 60 s and on lock
    if (mounted) showToast(context, l.kitCopied, icon: Icons.check_rounded);
  }

  Future<void> _share(BuildContext buttonContext) async {
    final l = AppLocalizations.of(context);
    final box = buttonContext.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      subject: l.kitTitle,
      text: '${l.kitTitle}\n\n${widget.keyText}\n\n${l.kitShareNote}',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: widget.confirm ? null : AppBar(),
      body: FormColumn(
        children: [
          Text(l.kitTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(l.kitLead, style: TextStyle(color: c.muted, fontSize: 15, height: 1.5)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: c.soft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.border),
            ),
            child: SecretText(
              text: widget.keyText,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono'],
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(onPressed: _copy, icon: const Icon(Icons.copy_outlined, size: 18), label: Text(l.kitCopy)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Builder(
                  builder: (b) => OutlinedButton.icon(
                    onPressed: () => _share(b),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: Text(l.kitSave),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l.kitCopyNote, style: TextStyle(color: c.muted, fontSize: 13.5)),
          const SizedBox(height: 16),
          Material(
            color: c.warnBg,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(l.kitWarning, style: TextStyle(color: c.warnInk, fontSize: 14, height: 1.45)),
            ),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 20),
            TextField(
              controller: _last,
              maxLength: 4,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: l.kitConfirmLabel, counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _ok ? widget.onDone : null, child: Text(l.kitDone)),
          ],
        ],
      ),
    );
  }
}
