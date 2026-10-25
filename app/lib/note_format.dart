/// How a note's plain text is read (docs/security.md, links in notes): web addresses found
/// in it, the real host behind them, and checklist lines. Notes stay plain text on disk;
/// this only decides how they are drawn and what a tap may do. No network here.
library;

/// A web address found in a note: where it sits in the text, and the address to open.
class NoteLink {
  const NoteLink(this.start, this.end, this.url);

  /// The address as typed spans [start, end) of the text.
  final int start, end;

  /// What a tap opens: "www.…" gets "https://".
  final String url;

  @override
  bool operator ==(Object other) => other is NoteLink && other.start == start && other.end == end && other.url == url;

  @override
  int get hashCode => Object.hash(start, end, url);

  @override
  String toString() => 'NoteLink($start, $end, $url)';
}

/// http://, https:// or www., not in the middle of a word, an e-mail address or a longer
/// address (so "me@www.example.com" and "ftp://www.x" are not links).
final _linkStart = RegExp(r'(?<![\w@.\-/])(?:https?://|www\.)[^\s<>"`]+', caseSensitive: false);

/// Punctuation that ends a sentence rather than the address.
const _trailing = '.,;:!?\'"*_~';

/// Every web address in [text], in order.
List<NoteLink> findLinks(String text) {
  final out = <NoteLink>[];
  for (final m in _linkStart.allMatches(text)) {
    var s = m.group(0)!;
    // Drop what ends the sentence: "(see https://a.com/x)." keeps "https://a.com/x".
    while (s.isNotEmpty) {
      final last = s[s.length - 1];
      if (_trailing.contains(last)) {
        s = s.substring(0, s.length - 1);
      } else if ((last == ')' && _count(s, ')') > _count(s, '(')) || (last == ']' && _count(s, ']') > _count(s, '['))) {
        s = s.substring(0, s.length - 1);
      } else {
        break;
      }
    }
    final url = s.toLowerCase().startsWith('www.') ? 'https://$s' : s;
    if (safeLink(url) == null) continue; // "https://" alone, "www." alone
    out.add(NoteLink(m.start, m.start + s.length, url));
  }
  return out;
}

int _count(String s, String c) => c.allMatches(s).length;

/// A link that may be handed to the browser: its address in plain ASCII (an
/// international host in its xn-- form, everything else percent-encoded) and that host.
class SafeLink {
  const SafeLink(this.url, this.host);
  final String url, host;
}

/// [url] checked for opening: http or https with a host, nothing else ever (no
/// javascript:, file:, intent:, data: or an app's own scheme). Null when refused.
SafeLink? safeLink(String url) {
  final m = RegExp(r'^(https?)://([^/?#]*)(.*)$', caseSensitive: false, dotAll: true).firstMatch(url.trim());
  if (m == null) return null;
  final scheme = m.group(1)!.toLowerCase();
  var authority = m.group(2)!;
  final rest = m.group(3)!;
  final at = authority.lastIndexOf('@');
  final user = at < 0 ? '' : authority.substring(0, at + 1);
  authority = authority.substring(at + 1);
  var port = '';
  final p = RegExp(r':(\d*)$').firstMatch(authority);
  if (p != null && !authority.endsWith(']')) {
    port = authority.substring(p.start);
    authority = authority.substring(0, p.start);
  }
  if (authority.isEmpty || RegExp(r'[\s\\%]').hasMatch(authority)) return null;
  final String host;
  try {
    host = asciiHost(authority);
  } on FormatException {
    return null;
  }
  if (host.isEmpty || host.startsWith('.') || host.contains('..')) return null;
  final Uri uri;
  try {
    uri = Uri.parse('$scheme://$user$host$port$rest');
  } on FormatException {
    return null;
  }
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
  return SafeLink(uri.toString(), uri.host);
}

/// A host as the network sees it: lower case, and every label with letters outside
/// ASCII in its punycode form ("bücher.de" → "xn--bcher-kva.de"), so a look-alike
/// ("аpple.com" with a Cyrillic "а") shows as what it is. The full IDNA mapping is not
/// applied, only lower case; a host it would change is still shown in a form that
/// cannot pass for another.
String asciiHost(String host) {
  if (host.startsWith('[')) return host.toLowerCase(); // an IPv6 address
  final dots = host.replaceAll(RegExp('[。．｡]'), '.').toLowerCase();
  return dots.split('.').map((l) => l.runes.every((c) => c < 0x80) ? l : 'xn--${punycode(l)}').join('.');
}

const _base = 36, _tMin = 1, _tMax = 26, _skew = 38, _damp = 700;

/// RFC 3492 encoding of one label (without the "xn--").
String punycode(String label) {
  final cps = label.runes.toList();
  final out = StringBuffer();
  for (final c in cps) {
    if (c < 0x80) out.writeCharCode(c);
  }
  final b = out.length;
  var h = b;
  if (b > 0) out.write('-');
  var n = 0x80, delta = 0, bias = 72;
  while (h < cps.length) {
    var m = 0x10FFFF + 1;
    for (final c in cps) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (h + 1);
    n = m;
    for (final c in cps) {
      if (c < n) delta++;
      if (c == n) {
        var q = delta;
        for (var k = _base;; k += _base) {
          final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          out.writeCharCode(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        out.writeCharCode(_digit(q));
        bias = _adapt(delta, h + 1, h == b);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return out.toString();
}

int _digit(int d) => d < 26 ? 0x61 + d : 0x30 + d - 26;

int _adapt(int delta, int points, bool first) {
  delta = first ? delta ~/ _damp : delta ~/ 2;
  delta += delta ~/ points;
  var k = 0;
  while (delta > ((_base - _tMin) * _tMax) ~/ 2) {
    delta ~/= _base - _tMin;
    k += _base;
  }
  return k + (_base - _tMin + 1) * delta ~/ (delta + _skew);
}

/// "- [ ] task" or "- [x] done" (also * and +, indented or not).
final checklistLine = RegExp(r'^(\s*[-*+] \[)([ xX])(\] )');

/// [text] with the box on line [line] (0-based) ticked or cleared; null when that line
/// has no box. Nothing else changes, line endings included.
String? toggleChecklist(String text, int line) {
  var start = 0;
  for (var i = 0; i < line; i++) {
    final nl = text.indexOf('\n', start);
    if (nl < 0) return null;
    start = nl + 1;
  }
  final end = text.indexOf('\n', start);
  final row = text.substring(start, end < 0 ? text.length : end);
  final m = checklistLine.firstMatch(row);
  if (m == null) return null;
  final at = start + m.group(1)!.length;
  return text.replaceRange(at, at + 1, m.group(2) == ' ' ? 'x' : ' ');
}
