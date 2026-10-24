import 'dart:io';

import '../src/rust/api/sync.dart' as sync;

/// This device's address on the home or office network (Wi-Fi first), if it has one.
/// Reading the interfaces opens no connection.
Future<String?> localAddress() async {
  try {
    final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
    String? any;
    for (final i in all) {
      // Mobile data and VPN tunnels can carry private addresses too; never those.
      if (_notLocal.any(i.name.startsWith)) continue;
      for (final a in i.addresses) {
        if (a.isLoopback || !sync.p2PLocalAddress(ip: a.address)) continue;
        if (i.name == 'en0' || i.name.startsWith('wlan')) return a.address;
        any ??= a.address;
      }
    }
    return any;
  } catch (_) {
    return null;
  }
}

const _notLocal = ['pdp_ip', 'rmnet', 'ccmni', 'utun', 'ipsec', 'tun', 'ppp', 'bridge', 'awdl', 'llw'];
