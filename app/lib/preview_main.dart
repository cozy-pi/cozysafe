// The app in a browser, on pretend data, to try the interface without a phone:
//   tool/preview_web.sh   (then open http://localhost:8765, PIN 1234)
// No encryption, camera or Face ID here; nothing is saved. Not part of the app.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'main.dart';
import 'preview/fake_vault.dart';
import 'preview/photos.g.dart';
import 'secret_key_store.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  RustLib.initMock(api: FakeVault(previewPhotos()));
  // The PIN pad needs this device's PIN key; the pretend vault accepts any.
  try {
    await PinStore.deviceKeyOrCreate(() => Uint8List.fromList(List.filled(16, 7)));
  } catch (_) {}
  runApp(const _Phone(child: CozySafeApp(libraryDir: '', hasSecretKey: true, locale: Locale('vi'))));
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
