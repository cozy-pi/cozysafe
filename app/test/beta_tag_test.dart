// Cozy Safe Beta says which app it is with a small tag; Cozy Safe itself shows nothing.

import 'package:cozysafe/build_info.dart';
import 'package:cozysafe/widgets/beta_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugBeta = null);

  testWidgets('no tag in Cozy Safe', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: BetaTag())));
    expect(find.text('beta'), findsNothing);
  });

  testWidgets('the tag in Cozy Safe Beta', (t) async {
    debugBeta = true;
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: BetaTag())));
    expect(find.text('beta'), findsOneWidget);
  });
}
