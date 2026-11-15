import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'vault_bar.dart' show showCard;

/// One answer to a question ([askCard], [askSheet]). The first look is the default: an
/// outlined button the width of the card.
class AskAction<T> {
  /// A second way to go: outlined.
  const AskAction(this.label, this.value, {this.key, this.danger = false})
      : main = false,
        quiet = false;

  /// What the question is for: filled, red when [danger].
  const AskAction.main(this.label, this.value, {this.key, this.danger = false})
      : main = true,
        quiet = false;

  /// Leaving it (Cancel, Not now): plain text.
  const AskAction.quiet(this.label, this.value, {this.key})
      : main = false,
        quiet = true,
        danger = false;

  final String label;
  final T? value;
  final Key? key;
  final bool main;
  final bool quiet;
  /// Red: it deletes or throws something away.
  final bool danger;
}

/// The text of a button in a card or a sheet: on the [Text] itself, never in the button's
/// style (docs/design-language.md, Buttons).
const _buttonText = TextStyle(fontSize: CsType.callout, fontWeight: FontWeight.w700);

Widget _button<T>(BuildContext context, AskAction<T> a) {
  void go() => Navigator.of(context).pop(a.value);
  final ink = Theme.of(context).colorScheme.onSurface;
  final label = Text(a.label, textAlign: TextAlign.center, style: a.main ? _buttonText : _buttonText.copyWith(fontWeight: FontWeight.w600));
  if (a.main) {
    return FilledButton(
      key: a.key,
      onPressed: go,
      style: a.danger ? FilledButton.styleFrom(backgroundColor: recordRed(context), foregroundColor: Colors.white) : null,
      child: label,
    );
  }
  if (a.quiet) {
    return TextButton(
      key: a.key,
      onPressed: go,
      style: TextButton.styleFrom(foregroundColor: ink, minimumSize: const Size(0, Ui.tap), shape: const StadiumBorder()),
      child: label,
    );
  }
  return OutlinedButton(
    key: a.key,
    onPressed: go,
    style: a.danger ? OutlinedButton.styleFrom(foregroundColor: recordRed(context)) : null,
    child: label,
  );
}

/// The answers, one under the other in the order given: each the width of the card, so a
/// long translation never squeezes its neighbour.
List<Widget> _stacked<T>(BuildContext context, List<AskAction<T>> actions) => [
      for (final (i, a) in actions.indexed) ...[
        if (i > 0) SizedBox(height: a.quiet ? 4 : 8),
        _button(context, a),
      ],
    ];

/// The lines of a question, in grey under its title.
class _AskText extends StatelessWidget {
  const _AskText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: CsColors.of(context).muted, fontSize: CsType.subhead, height: 1.4));
}

/// A short question in a card ([showCard]), in place of a system dialog: the title, a few
/// grey lines, something of its own ([content]: a number counting down), then the answers.
/// Null when closed without one. [boxKey] marks the card's content for tests.
Future<T?> askCard<T>(
  BuildContext context, {
  required String title,
  String? body,
  Widget? content,
  required List<AskAction<T>> actions,
  Key? boxKey,
  bool dismissible = true,
}) =>
    showCard<T>(
      context,
      title: title,
      dismissible: dismissible,
      builder: (context) => SingleChildScrollView(
        key: boxKey,
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (body != null) _AskText(body),
            if (content != null) ...[if (body != null) const SizedBox(height: 12), content],
            const SizedBox(height: 18),
            ..._stacked(context, actions),
          ],
        ),
      ),
    );

/// A name asked in a card: one field, [cancel] (Cancel unless given) and [save] (Save).
/// The text, trimmed; null when left. [allowEmpty] false: Save waits for a letter.
Future<String?> promptCard(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String? cancel,
  String? save,
  Key? fieldKey,
  Key? saveKey,
  bool allowEmpty = true,
  bool dismissible = true,
}) =>
    showCard<String>(
      context,
      title: title,
      dismissible: dismissible,
      builder: (context) => _Prompt(
        initial: initial,
        hint: hint,
        cancel: cancel,
        save: save,
        fieldKey: fieldKey,
        saveKey: saveKey,
        allowEmpty: allowEmpty,
      ),
    );

class _Prompt extends StatefulWidget {
  const _Prompt({required this.initial, this.hint, this.cancel, this.save, this.fieldKey, this.saveKey, required this.allowEmpty});
  final String initial;
  final String? hint;
  final String? cancel;
  final String? save;
  final Key? fieldKey;
  final Key? saveKey;
  final bool allowEmpty;

  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  // Opens with the whole name selected, so typing replaces it.
  late final _text = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    final name = _text.text.trim();
    if (name.isEmpty && !widget.allowEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: widget.fieldKey,
            controller: _text,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => _done(),
          ),
          const SizedBox(height: 18),
          // Two short words (Cancel, Save): side by side, so the card stays low over the keyboard.
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(widget.cancel ?? l.cancel, style: _buttonText.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(key: widget.saveKey, onPressed: _done, child: Text(widget.save ?? l.save, style: _buttonText)),
            ),
          ]),
        ],
      ),
    );
  }
}

/// A question at the bottom, where the thumb is, before something is sent out or saved
/// (one body for every such sheet): the title, grey lines, something of its own
/// ([content]: a "don't ask again" switch), then the answers the width of the sheet.
Future<T?> askSheet<T>(
  BuildContext context, {
  required String title,
  List<String> body = const [],
  Widget? content,
  required List<AskAction<T>> actions,
  Key? boxKey,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AskSheetBody<T>(key: boxKey, title: title, body: body, content: content, actions: actions),
    );

/// What [askSheet] shows; on its own for a sheet opened another way.
class AskSheetBody<T> extends StatelessWidget {
  const AskSheetBody({super.key, required this.title, this.body = const [], this.content, required this.actions});
  final String title;
  final List<String> body;
  final Widget? content;
  final List<AskAction<T>> actions;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Ui.side, 20, Ui.side, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w800, letterSpacing: -.2)),
              for (final line in body) ...[const SizedBox(height: 8), _AskText(line)],
              if (content != null) ...[const SizedBox(height: 8), content!],
              const SizedBox(height: 18),
              ..._stacked(context, actions),
            ],
          ),
        ),
      );
}
