import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/language.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bottom bar's words are never cut (owner 2026-10-21): in every language, on a
/// small Android phone and on the largest iPhone, each label is drawn whole — the tabs
/// scroll when they do not fit.
void main() {
  for (final width in [360.0, 430.0]) {
    for (final x in languages) {
      testWidgets('tabs fit: ${x.code} at $width', (t) async {
        t.view.physicalSize = Size(width, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          locale: localeOf(x.code),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: VaultBar(
                  section: VaultSection.note,
                  sections: VaultSection.values,
                  home: const SizedBox.square(dimension: 32),
                  onSection: (_) {},
                  lock: const SizedBox.square(dimension: 56),
                ),
              ),
            ),
          ),
        ));
        await t.pumpAndSettle();
        for (final p in t.renderObjectList<RenderParagraph>(find.descendant(of: find.byType(VaultBar), matching: find.byType(RichText)))) {
          final full = p.getMaxIntrinsicWidth(double.infinity);
          expect(p.size.width, greaterThanOrEqualTo(full - .5), reason: '"${p.text.toPlainText()}" is cut');
        }
      });
    }
  }
}
