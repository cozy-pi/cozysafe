import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Cozy Safe never uses the network. Installed first thing in `main`, this makes
/// every Dart-side attempt fail: `HttpClient()` (and so `package:http`, image loading
/// from URLs, …) throws, `Socket.connect` / `Socket.startConnect` /
/// `ServerSocket.bind` fail with a [SocketException].
///
/// One layer of several (docs/supply-chain.md): it covers Dart code only. Native code
/// in plugins is held back by the OS where it can be (Android without the INTERNET
/// permission, the macOS sandbox without a network entitlement) and by CI checks.
/// `RawSocket` / `RawDatagramSocket` have no override hook in `dart:io`; the
/// dependency source scan (tools/check-deps) looks for them instead.
///
/// Not installed in the browser preview (`lib/preview_main.dart`), which fetches its
/// sample photos over HTTP and has no `dart:io` at all.
void installNetworkGuard() {
  if (kIsWeb) return;
  HttpOverrides.global = NoNetworkHttpOverrides();
  IOOverrides.global = NoNetworkIOOverrides();
}

const _message = 'Cozy Safe works offline: network access is disabled';

final class NoNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw UnsupportedError(_message);
}

final class NoNetworkIOOverrides extends IOOverrides {
  @override
  Future<Socket> socketConnect(host, int port, {sourceAddress, int sourcePort = 0, Duration? timeout}) =>
      Future.error(const SocketException(_message));

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(host, int port, {sourceAddress, int sourcePort = 0}) =>
      Future.error(const SocketException(_message));

  @override
  Future<ServerSocket> serverSocketBind(address, int port,
          {int backlog = 0, bool v6Only = false, bool shared = false}) =>
      Future.error(const SocketException(_message));
}
