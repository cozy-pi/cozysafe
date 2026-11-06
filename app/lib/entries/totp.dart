import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A one-time code (TOTP, RFC 6238) as services hand it out: a secret in base 32, most
/// often in an `otpauth://totp/…` link inside a QR code. docs/adr/0009-secure-items.md.
class Totp {
  const Totp({
    required this.secret,
    this.algo = 'SHA1',
    this.digits = 6,
    this.period = 30,
    this.issuer = '',
    this.account = '',
  });

  /// Base 32, upper case, no spaces or padding.
  final String secret;
  /// SHA1, SHA256 or SHA512.
  final String algo;
  final int digits;
  final int period;
  final String issuer;
  final String account;

  static const algos = ['SHA1', 'SHA256', 'SHA512'];

  /// From what a person pastes or a QR code holds: an `otpauth://totp/` link or the
  /// secret alone. Null when it is neither, or the secret is not base 32.
  static Totp? parse(String text) {
    final t = text.trim();
    if (t.toLowerCase().startsWith('otpauth://')) return _fromUri(t);
    final secret = normalize(t);
    return secret != null ? Totp(secret: secret) : null;
  }

  /// Never throws: a malformed link (bad percent-encoding in the label or a parameter)
  /// is null, like any other text that is not a setup code.
  static Totp? _fromUri(String text) {
    try {
      return _fromUriOrThrow(text);
    } catch (_) {
      return null;
    }
  }

  static Totp? _fromUriOrThrow(String text) {
    final uri = Uri.parse(text);
    // HOTP (counter-based) codes are not kept: almost no service uses them.
    if (uri.host.toLowerCase() != 'totp') return null;
    final q = uri.queryParameters;
    final secret = normalize(q['secret'] ?? '');
    if (secret == null) return null;
    var label = uri.pathSegments.isEmpty ? '' : uri.pathSegments.join('/');
    var issuer = q['issuer']?.trim() ?? '';
    var account = label.trim();
    final colon = label.indexOf(':');
    if (colon >= 0) {
      if (issuer.isEmpty) issuer = label.substring(0, colon).trim();
      account = label.substring(colon + 1).trim();
    }
    // "SHA-256" and "sha256" alike.
    final algo = (q['algorithm'] ?? 'SHA1').toUpperCase().replaceAll('-', '');
    final digits = int.tryParse(q['digits'] ?? '') ?? 6;
    final period = int.tryParse(q['period'] ?? '') ?? 30;
    if (!algos.contains(algo) || digits < 6 || digits > 8 || period < 1 || period > 300) return null;
    return Totp(secret: secret, algo: algo, digits: digits, period: period, issuer: issuer, account: account);
  }

  /// The secret as stored: upper case, without spaces, dashes or `=` padding; null
  /// unless it is base 32 and long enough (at least 80 bits, RFC 4226 asks 128).
  static String? normalize(String text) {
    final s = text.replaceAll(RegExp(r'[\s\-=]'), '').toUpperCase();
    if (s.length < 16 || !RegExp(r'^[A-Z2-7]+$').hasMatch(s)) return null;
    return s;
  }

  static Uint8List base32(String s) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final out = BytesBuilder();
    var buffer = 0, bits = 0;
    for (final c in s.codeUnits) {
      buffer = (buffer << 5) | alphabet.indexOf(String.fromCharCode(c));
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((buffer >> bits) & 0xff);
      }
    }
    return out.toBytes();
  }

  /// The code at `now`, as digits (leading zeros kept).
  String code(DateTime now) => codeAt(now.millisecondsSinceEpoch ~/ 1000 ~/ period);

  /// The code for a time step: HOTP (RFC 4226) over the step.
  String codeAt(int step) {
    final msg = ByteData(8)..setInt64(0, step);
    final hash = switch (algo) { 'SHA256' => sha256, 'SHA512' => sha512, _ => sha1 };
    final mac = Hmac(hash, base32(secret)).convert(msg.buffer.asUint8List()).bytes;
    final o = mac.last & 0x0f;
    final bin = ((mac[o] & 0x7f) << 24) | (mac[o + 1] << 16) | (mac[o + 2] << 8) | mac[o + 3];
    var mod = 1;
    for (var i = 0; i < digits; i++) {
      mod *= 10;
    }
    return (bin % mod).toString().padLeft(digits, '0');
  }

  /// Seconds until the next code.
  int secondsLeft(DateTime now) => period - (now.millisecondsSinceEpoch ~/ 1000) % period;

  /// As kept in an item's document.
  Map<String, Object> toJson() => {
        'secret': secret,
        'algo': algo,
        'digits': digits,
        'period': period,
        if (issuer.isNotEmpty) 'issuer': issuer,
        if (account.isNotEmpty) 'account': account,
      };

  static Totp? fromJson(Object? j) {
    if (j is! Map) return null;
    final secret = normalize('${j['secret'] ?? ''}');
    if (secret == null) return null;
    final algo = '${j['algo'] ?? 'SHA1'}'.toUpperCase().replaceAll('-', '');
    final digits = j['digits'] is int ? j['digits'] as int : 6;
    final period = j['period'] is int ? j['period'] as int : 30;
    return Totp(
      secret: secret,
      algo: algos.contains(algo) ? algo : 'SHA1',
      digits: digits >= 6 && digits <= 8 ? digits : 6,
      period: period >= 1 && period <= 300 ? period : 30,
      issuer: '${j['issuer'] ?? ''}',
      account: '${j['account'] ?? ''}',
    );
  }
}
