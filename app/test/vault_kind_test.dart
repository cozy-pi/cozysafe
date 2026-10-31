import 'dart:io';

import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/vault_kind.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what Dart hands to Rust at start.
class _Fake implements RustLibApi {
  final started = <(VaultKind, String)>[];

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName.toString().contains('StartRun')) {
      started.add((call.namedArguments[#kind] as VaultKind, call.namedArguments[#libraryDir] as String));
      return true;
    }
    return null;
  }
}

void main() {
  final fake = _Fake();
  setUpAll(() => RustLib.initMock(api: fake));

  late Directory support;
  setUp(() => support = Directory.systemTemp.createTempSync('kind'));
  tearDown(() => support.deleteSync(recursive: true));

  String sep(String a, String b) => '$a${Platform.pathSeparator}$b';

  test('no start file: Top secret, in the folders it always had', () {
    final dir = RunKind.start(support.path);
    expect(RunKind.current, VaultKind.topSecret);
    expect(dir, sep(support.path, 'library'));
    expect(RunKind.prefsDir(VaultKind.topSecret), support.path);
    expect(fake.started.last, (VaultKind.topSecret, dir));
    // Keystore names unchanged, so nothing on a device has to move.
    expect(RunKind.account('biometric'), 'cozysafe.biometric');
    expect(RunKind.namespace('biometric'), 'cozysafe_biometric');
    expect(RunKind.key('vault-unlock-key'), 'vault-unlock-key');
  });

  test('a start file naming Private: its own folders and keystore names', () {
    File(sep(support.path, RunKind.startFile)).writeAsStringSync('private\n');
    final dir = RunKind.start(support.path);
    expect(RunKind.current, VaultKind.private);
    expect(dir, sep(sep(support.path, 'private'), 'library'));
    expect(RunKind.prefsDir(VaultKind.private), sep(support.path, 'private'));
    expect(fake.started.last, (VaultKind.private, dir));
    expect(RunKind.account('biometric'), 'cozysafe.private.biometric');
    expect(RunKind.namespace('biometric'), 'cozysafe_private_biometric');
    expect(RunKind.key('vault-unlock-key'), 'private-vault-unlock-key');
  });

  test('anything else in the start file is Top secret', () {
    for (final v in ['', 'Private', 'top-secret', 'garbage']) {
      File(sep(support.path, RunKind.startFile)).writeAsStringSync(v);
      expect(RunKind.read(support.path), VaultKind.topSecret, reason: v);
    }
  });

  test('the two kinds share no folder', () {
    final top = RunKind.libraryDir(VaultKind.topSecret, support.path);
    final private = RunKind.libraryDir(VaultKind.private, support.path);
    expect(private.startsWith(top), isFalse);
    expect(top.startsWith(RunKind.prefsDir(VaultKind.private, support.path)), isFalse);
  });
}
