import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../screens/common.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'vault_bar.dart';

/// A finished recording or video that could not be encrypted into the vault (no space
/// left, most often). It used to be deleted with the error, whatever went wrong: the take
/// was gone. Now the plain file at [path] stays in the app's private temporary folder
/// while a card says what failed, with Try Again ([save] runs again) and Discard; it is
/// deleted once saved or discarded. It never outlives the session: the vault locking
/// empties that folder (`clearTemp`), and the card says so. True when it was saved.
///
/// A tap beside the card does not close it for good: only the two buttons decide.
Future<bool> retryOrDiscardTake(
  BuildContext context, {
  required String path,
  required Object error,
  /// The plain sentence for a failure that is not the vault's own.
  required String sentence,
  required Future<void> Function() save,
}) async {
  var failure = error;
  while (true) {
    // The vault locked or the page is gone: nobody is left to choose, and a plain file
    // does not wait for the next time.
    if (!context.mounted || vaultLock.locked) {
      _delete(path);
      return false;
    }
    final l = AppLocalizations.of(context);
    final what = failure is rust.VaultError ? vaultErrorText(l, failure) : withCode(l, sentence, failure);
    final again = await showCard<bool>(context, title: l.takeKeptTitle, builder: (context) => _TakeKept(error: what));
    if (again == null) continue;
    if (!again) {
      _delete(path);
      return false;
    }
    try {
      await save();
      _delete(path);
      return true;
    } catch (e) {
      failure = e;
    }
  }
}

void _delete(String path) {
  try {
    File(path).deleteSync();
  } catch (_) {}
}

class _TakeKept extends StatelessWidget {
  const _TakeKept({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(error, key: const ValueKey('take-kept-error'), style: const TextStyle(fontSize: CsType.subhead, height: 1.4)),
          const SizedBox(height: 10),
          Text(l.takeKeptBody, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('take-kept-retry'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50), shape: const StadiumBorder()),
            child: Text(l.tryAgain),
          ),
          const SizedBox(height: 6),
          TextButton(
            key: const ValueKey('take-kept-discard'),
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: recordRed(context),
              minimumSize: const Size(0, 50),
              shape: const StadiumBorder(),
            ),
            child: Text(l.takeDiscard),
          ),
        ],
      ),
    );
  }
}
