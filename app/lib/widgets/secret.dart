import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../theme.dart';

/// A secret shown for people (the Secret Key): hidden until "Show" is tapped, hidden again
/// after 30 seconds or when the app goes to the background, so a person or a camera
/// nearby does not catch it by chance (docs/security.md, secrets on screen).
class SecretText extends StatefulWidget {
  const SecretText({super.key, required this.text, required this.style, this.builder});
  final String text;
  final TextStyle style;
  /// Draws the secret itself, shown or masked (the Recovery Key's numbered words);
  /// without it, the text or a fixed row of dots.
  final Widget Function(BuildContext context, bool shown)? builder;

  @override
  State<SecretText> createState() => _SecretTextState();
}

class _SecretTextState extends State<SecretText> with WidgetsBindingObserver, VaultLockAware {
  static const _showFor = Duration(seconds: 30);
  bool _shown = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _hide?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _shown) _set(false);
  }

  /// Shown when the vault locked: hidden again behind the lock (the page stays).
  @override
  void vaultLocking() {
    if (_shown) _set(false);
  }

  void _set(bool shown) {
    _hide?.cancel();
    if (shown) _hide = Timer(_showFor, () => _set(false));
    if (mounted) setState(() => _shown = shown);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    // Same length and dashes, so the layout does not jump; every other character hidden.
    // Always the same dots, so the mask does not tell the key's length.
    const masked = '••••-••••-••••-••••';
    return Column(
      children: [
        if (widget.builder != null)
          widget.builder!(context, _shown)
        else if (_shown)
          SelectableText(widget.text, textAlign: TextAlign.center, style: widget.style)
        else
          Text(masked, textAlign: TextAlign.center, style: widget.style.copyWith(color: c.muted)),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const ValueKey('secret-show'),
          onPressed: () => _set(!_shown),
          icon: Icon(_shown ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
          label: Text(_shown ? l.secretHide : l.secretShow),
        ),
      ],
    );
  }
}

/// A text field for a password or a key: hidden while typed, with an eye to show it.
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.enabled = true,
    this.capitalization = TextCapitalization.none,
    this.onChanged,
    this.onSubmitted,
    this.multiline = false,
    this.paste = false,
  });

  /// A Paste button (the 24 words come from a password manager or a note). The
  /// clipboard is emptied after, so the words do not linger there.
  final bool paste;

  /// Long secrets (24 words): once shown, the field grows to several lines.
  final bool multiline;

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final bool enabled;
  final TextCapitalization capitalization;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _obscure = true;

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    widget.controller.text = text;
    widget.controller.selection = TextSelection.collapsed(offset: text.length);
    await Clipboard.setData(const ClipboardData(text: ''));
    widget.onChanged?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscure,
      minLines: 1,
      maxLines: _obscure || !widget.multiline ? 1 : 5,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      textCapitalization: widget.capitalization,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        errorText: widget.errorText,
        suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
          if (widget.paste)
            IconButton(
              key: const ValueKey('secret-paste'),
              tooltip: l.modePaste,
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: widget.enabled ? _paste : null,
            ),
          IconButton(
            tooltip: _obscure ? l.showPassword : l.hidePassword,
            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ]),
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    );
  }
}
