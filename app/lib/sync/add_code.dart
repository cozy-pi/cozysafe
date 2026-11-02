import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'progress.dart' show SyncLink;

/// Adding a device by a code (ADR 0003, point 11, 2026-11-01): the two devices find each
/// other on the Wi-Fi and make a key together (X25519, the new device committing to its
/// half first); the old device shows 8 digits drawn from that key and the new device's
/// person types them. Someone in the middle holds two different keys, so the digits the
/// old device shows are not the ones the new device works out, however often they are
/// typed: the new device compares them itself and never sends them, so retyping after a
/// typo gives no one in the middle anything. A wrong code ends the
/// try; three wrong codes, or three wrong passwords, end the session (owner 2026-11-01:
/// a typo should not mean starting again).

/// How many digits the code has, and how it is shown: "1234 - 5678".
const addCodeDigits = 8;

String addCodeText(String digits) =>
    digits.length == addCodeDigits ? '${digits.substring(0, 4)} - ${digits.substring(4)}' : digits;

/// The old device before the new one connected: what to do on the new one, and the time
/// left.
class AddCodeWaiting extends StatelessWidget {
  const AddCodeWaiting({super.key, required this.left});
  final String left;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Column(
      key: const ValueKey('add-code-waiting'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The two devices on every page of adding one (owner 2026-11-01: less bare).
        const SyncLink(),
        const SizedBox(height: 22),
        Text(l.addCodeWaitTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 8),
        Text(l.addCodeWaitLead, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
        const SizedBox(height: 14),
        Text(l.syncWaitLeft(left),
            textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 22),
        _OneTry(text: l.addCodeTries),
      ],
    );
  }
}

/// The new device while it knocks on the Wi-Fi for the old one.
class AddCodeSearching extends StatelessWidget {
  const AddCodeSearching({super.key});

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('add-code-searching'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SyncLink(),
          const SizedBox(height: 22),
          Text(AppLocalizations.of(context).addCodeSearching,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        ],
      );
}

/// The old device once the new one connected: the code to type there.
class AddCodeShown extends StatelessWidget {
  const AddCodeShown({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Column(
      key: const ValueKey('add-code-shown'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SyncLink(moving: false),
        const SizedBox(height: 22),
        Text(l.addCodeShowTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 18),
        Center(
          child: Container(
            key: const ValueKey('add-code-digits'),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
            child: Text(addCodeText(code),
                style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 2, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ),
        const SizedBox(height: 12),
        Text(l.addCodeShowHint, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
        const SizedBox(height: 22),
        _OneTry(text: l.addCodeTries),
      ],
    );
  }
}

/// The new device: the 8 digits the old one shows, typed. [onCode] gets the digits alone.
class AddCodeEntry extends StatefulWidget {
  const AddCodeEntry({super.key, required this.onCode, this.left});
  final ValueChanged<String> onCode;
  /// After a wrong code: how many tries are left.
  final int? left;

  @override
  State<AddCodeEntry> createState() => _AddCodeEntryState();
}

class _AddCodeEntryState extends State<AddCodeEntry> {
  final _text = TextEditingController();
  /// Sent once; a wrong code comes back as a new entry (keyed by the try).
  bool _sent = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _digits => _text.text.replaceAll(RegExp(r'\D'), '');
  bool get _ready => _digits.length == addCodeDigits;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      key: const ValueKey('add-code-entry'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SyncLink(moving: false),
        const SizedBox(height: 22),
        Text(l.addCodeEnterTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 18),
        TextField(
          key: const ValueKey('add-code-field'),
          controller: _text,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [_CodeFormatter()],
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: 2, fontFeatures: [FontFeature.tabularFigures()]),
          decoration: InputDecoration(
            hintText: '0000 - 0000',
            errorText: widget.left == null ? null : l.addCodeWrongLeft(widget.left!),
          ),
          // The 8th digit connects; no Next to tap (owner 2026-11-02).
          onChanged: (_) {
            if (_ready && !_sent) {
              _sent = true;
              widget.onCode(_digits);
            }
          },
        ),
      ],
    );
  }
}

/// Digits only, at most [addCodeDigits], shown as "1234 - 5678".
class _CodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue value) {
    var d = value.text.replaceAll(RegExp(r'\D'), '');
    if (d.length > addCodeDigits) d = d.substring(0, addCodeDigits);
    final text = d.length > 4 ? '${d.substring(0, 4)} - ${d.substring(4)}' : d;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// How adding a device ended when it did not: on either device, one message and nothing
/// to try again here (after three wrong codes or three wrong passwords).
enum AddCodeEnd { wrongCode, wrongPassword, closed }

class AddCodeEnded extends StatelessWidget {
  const AddCodeEnded({super.key, required this.end});
  final AddCodeEnd end;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final (title, lead) = switch (end) {
      AddCodeEnd.wrongCode => (l.addCodeWrong, l.addCodeWrongLead),
      AddCodeEnd.wrongPassword => (l.addPasswordWrong, l.addPasswordWrongLead),
      AddCodeEnd.closed => (l.addCodeClosed, l.addCodeClosedLead),
    };
    return Column(
      key: ValueKey('add-code-ended-${end.name}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.gpp_bad_rounded, size: 64, color: Color(0xFFFF9500)),
        const SizedBox(height: 18),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 8),
        Text(lead, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
      ],
    );
  }
}

class _OneTry extends StatelessWidget {
  const _OneTry({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.lock_rounded, size: 18, color: c.muted),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.35))),
    ]);
  }
}
