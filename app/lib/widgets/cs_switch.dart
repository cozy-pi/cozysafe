import 'package:flutter/material.dart';

import '../theme.dart';

/// The one switch of the app (docs/design-language.md, shared pieces): on is the
/// iPhone's green with a white knob (settings may use colour; a black or white track was
/// too strong, owner 2026-10-21).
class CsSwitch extends StatelessWidget {
  const CsSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  /// Null: shown greyed, it cannot be changed here.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeTrackColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF30D158) : const Color(0xFF34C759),
        activeThumbColor: Colors.white,
      );
}

/// A line with a switch at its end, in a card or a sheet ("Don't ask again"): a tap
/// anywhere on the line flips it.
class CsSwitchLine extends StatelessWidget {
  const CsSwitchLine({super.key, required this.title, required this.value, required this.onChanged});
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Ui.tap + 8),
          child: Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: CsType.callout))),
            const SizedBox(width: 12),
            CsSwitch(value: value, onChanged: onChanged),
          ]),
        ),
      );
}
