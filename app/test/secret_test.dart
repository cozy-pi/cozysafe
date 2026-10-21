import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/secret.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Secrets are never on screen until asked for (docs/security.md, secrets on screen).
void main() {
  Widget app(Widget child) => MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      );
  const key = 'CS1-AB12-CD34-EF56';

  testWidgets('the Secret Key is hidden until Show, and hides again after 30 s', (t) async {
    await t.pumpWidget(app(const SecretText(text: key, style: TextStyle())));
    expect(find.text(key), findsNothing);
    expect(find.text('••••-••••-••••-••••'), findsOneWidget); // fixed: the mask never tells the length
    await t.tap(find.byKey(const ValueKey('secret-show')));
    await t.pump();
    expect(find.text(key), findsOneWidget);
    await t.pump(const Duration(seconds: 31));
    expect(find.text(key), findsNothing);
  });

  testWidgets('it hides when the app goes to the background', (t) async {
    await t.pumpWidget(app(const SecretText(text: key, style: TextStyle())));
    await t.tap(find.byKey(const ValueKey('secret-show')));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(find.text(key), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('password and key fields are hidden while typed', (t) async {
    final c = TextEditingController(text: 'orange kettle');
    await t.pumpWidget(app(SecretField(controller: c, label: 'Password')));
    expect(t.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    await t.tap(find.byType(IconButton));
    await t.pump();
    expect(t.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
  });
}
