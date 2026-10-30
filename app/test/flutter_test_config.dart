import 'dart:async';
import 'dart:io';

import 'package:cozysafe/widgets/words_input.dart';

/// The core is not loaded in widget tests: the Recovery Key word list is read from the
/// core's own copy of it, so the grid checks words as it does in the app.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  RecoveryWords.load = () => File('../core/cs-crypto/src/bip39_english.txt').readAsLinesSync().where((w) => w.isNotEmpty).toList();
  await testMain();
}
