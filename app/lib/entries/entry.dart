import 'dart:convert';

import '../item_kind.dart';
import 'totp.dart';

/// A secure item's document (docs/adr/0009-secure-items.md): a JSON object with a
/// version `v`. Fields the app does not know (from a newer version) are kept as they
/// are, so editing never drops them.
class Entry {
  Entry(this.kind, [Map<String, Object?>? doc]) : doc = {...?doc, 'v': doc?['v'] ?? version};

  static const version = 1;

  final String kind;
  final Map<String, Object?> doc;

  static Entry decode(String kind, String json) {
    final d = jsonDecode(json);
    return Entry(kind, d is Map<String, Object?> ? d : null);
  }

  String encode() => jsonEncode(doc);

  /// Made by a newer version of the app: shown, never written back (it could drop what
  /// that version added).
  bool get newer => (doc['v'] is int ? doc['v'] as int : version) > version;

  String _s(String key) => doc[key] is String ? doc[key] as String : '';
  void _set(String key, String value) => value.trim().isEmpty ? doc.remove(key) : doc[key] = value;

  /// Login: user name or email. One-time code and recovery codes: the account.
  String get account => _s(kind == ItemKind.login ? 'username' : 'account');
  set account(String v) => _set(kind == ItemKind.login ? 'username' : 'account', v.trim());

  String get password => _s('password');
  set password(String v) => _set('password', v);

  String get notes => _s('notes');
  set notes(String v) => _set('notes', v);

  String get issuer => _s('issuer');
  set issuer(String v) => _set('issuer', v.trim());

  List<String> get urls => [for (final u in (doc['urls'] is List ? doc['urls'] as List : const [])) if (u is String) u];
  /// Entries that are not plain strings (a newer version's web site with options) are
  /// kept after the ones edited here.
  set urls(List<String> v) {
    final others = [for (final u in (doc['urls'] is List ? doc['urls'] as List : const [])) if (u is! String) u];
    final clean = [for (final u in v) if (u.trim().isNotEmpty) u.trim()];
    clean.isEmpty && others.isEmpty ? doc.remove('urls') : doc['urls'] = [...clean, ...others];
  }

  /// The one-time code: a login's `otp`, or a one-time code item's own fields.
  Totp? get totp => kind == ItemKind.otp ? Totp.fromJson(doc) : Totp.fromJson(doc['otp']);
  set totp(Totp? t) {
    if (kind == ItemKind.otp) {
      for (final k in const ['secret', 'algo', 'digits', 'period']) {
        doc.remove(k);
      }
      if (t != null) {
        doc.addAll({'secret': t.secret, 'algo': t.algo, 'digits': t.digits, 'period': t.period});
        if (issuer.isEmpty) issuer = t.issuer;
        if (account.isEmpty) account = t.account;
      }
    } else if (t == null) {
      doc.remove('otp');
    } else {
      // Over the one there: what this version does not know about it stays.
      final old = doc['otp'] is Map ? Map<String, Object?>.from(doc['otp'] as Map) : <String, Object?>{};
      doc['otp'] = {...old, ...t.toJson()};
    }
  }

  /// Recovery codes, each with whether it has been used.
  List<({String code, bool used})> get codes => [
        for (final c in (doc['codes'] is List ? doc['codes'] as List : const []))
          if (c is Map && c['code'] is String) (code: c['code'] as String, used: c['used'] == true),
      ];
  /// Each code keeps what else its entry held (matched by its code, else by position).
  set codes(List<({String code, bool used})> v) {
    final old = [for (final c in (doc['codes'] is List ? doc['codes'] as List : const [])) if (c is Map) Map<String, Object?>.from(c)];
    final taken = <int>{};
    Map<String, Object?> before(int i, String code) {
      var at = -1;
      for (var j = 0; j < old.length && at < 0; j++) {
        if (!taken.contains(j) && old[j]['code'] == code) at = j;
      }
      // An edited code: the one that stood in its place.
      if (at < 0 && i < old.length && !taken.contains(i) && !v.any((c) => c.code == old[i]['code'])) at = i;
      if (at < 0) return {};
      taken.add(at);
      return old[at];
    }

    if (v.isEmpty) {
      doc.remove('codes');
      return;
    }
    doc['codes'] = [
      for (final (i, c) in v.indexed) {...before(i, c.code)..remove('used'), 'code': c.code, if (c.used) 'used': true},
    ];
  }

  /// Recovery codes from pasted text: one per line, or separated by commas. Not by
  /// spaces: some services write a code as two halves ("1234 5678").
  static List<String> splitCodes(String text) =>
      [for (final c in text.split(RegExp(r'[\n\r,;]+'))) if (c.trim().isNotEmpty) c.trim()];
}
