// The Dart network guard installed at the top of main() (lib/offline.dart).
import 'dart:io';

import 'package:cozysafe/offline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpOverrides? http;
  late IOOverrides? io;

  setUp(() {
    http = HttpOverrides.current;
    io = IOOverrides.current;
    installNetworkGuard();
  });

  tearDown(() {
    HttpOverrides.global = http;
    IOOverrides.global = io;
  });

  test('HttpClient cannot be created', () {
    expect(() => HttpClient().getUrl(Uri.parse('https://example.com/')), throwsUnsupportedError);
  });

  test('Socket.connect fails', () async {
    await expectLater(Socket.connect('127.0.0.1', 9), throwsA(isA<SocketException>()));
    await expectLater(Socket.startConnect('127.0.0.1', 9), throwsA(isA<SocketException>()));
  });

  test('ServerSocket.bind fails', () async {
    await expectLater(ServerSocket.bind(InternetAddress.loopbackIPv4, 0), throwsA(isA<SocketException>()));
  });

  test('files still work', () async {
    final dir = await Directory.systemTemp.createTemp('cs-offline');
    final f = File('${dir.path}/a.txt');
    await f.writeAsString('ok');
    expect(await f.readAsString(), 'ok');
    await dir.delete(recursive: true);
  });
}
