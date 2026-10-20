// The app in a browser, on pretend data, to try the interface without a phone:
//   tool/preview_web.sh   (then open http://localhost:8765, PIN 1234)
// No encryption, camera or Face ID here; nothing is saved. Not part of the app.
import 'dart:typed_data';

import 'package:flutter/material.dart';
// A dev dependency on purpose: this preview is never part of an app build.
// ignore: depend_on_referenced_packages
import 'package:http/http.dart' as http;

import 'main.dart';
import 'preview/fake_vault.dart';
import 'secret_key_store.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  RustLib.initMock(api: FakeVault(await _photos()));
  // The PIN pad needs this device's PIN key; the pretend vault accepts any.
  try {
    await PinStore.deviceKeyOrCreate(() => Uint8List.fromList(List.filled(16, 7)));
  } catch (_) {}
  runApp(const _Phone(child: CozySafeApp(libraryDir: '', hasSecretKey: true, locale: Locale('vi'))));
}

/// Sample photos served next to the page (web/preview/photo1.jpg …, copied there by
/// tool/preview_web.sh, not in git). None is fine: squares stay plain.
Future<List<Uint8List>> _photos() async {
  final out = <Uint8List>[];
  for (var i = 1; i <= 40; i++) {
    try {
      final r = await http.get(Uri.base.resolve('preview/photo$i.jpg'));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) break;
      out.add(r.bodyBytes);
    } catch (_) {
      break;
    }
  }
  return out;
}

/// An iPhone 15 Pro Max sized screen (430 × 932) with its notch and home bar areas.
class _Phone extends StatelessWidget {
  const _Phone({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final view = MediaQueryData.fromView(View.of(context));
    return ColoredBox(
      color: const Color(0xFF2A2F2E),
      // The whole phone scales down to fit the window.
      child: Center(
        child: FittedBox(
        child: Container(
          width: 430 + 20,
          height: 932 + 20,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(64)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(54),
            child: MediaQuery(
              data: view.copyWith(
                size: const Size(430, 932),
                padding: const EdgeInsets.only(top: 59, bottom: 34),
                viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
              ),
              child: child,
            ),
          ),
        ),
        ),
      ),
    );
  }
}
