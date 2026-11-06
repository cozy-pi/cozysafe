import 'dart:math';

/// A strong password for a web site: random letters, digits and symbols from the
/// system's secure random source, at least one of each kind. 20 characters by default
/// (about 125 bits). docs/adr/0009-secure-items.md.
String generatePassword({int length = 20, Random? random}) {
  const lower = 'abcdefghijkmnopqrstuvwxyz'; // no l
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; // no I, O
  const digits = '23456789'; // no 0, 1
  const symbols = '-_.!@#%*+=?';
  const all = lower + upper + digits + symbols;
  final r = random ?? Random.secure();
  String pick(String from) => from[r.nextInt(from.length)];
  while (true) {
    final out = [for (var i = 0; i < length; i++) pick(all)].join();
    if ([lower, upper, digits, symbols].every((set) => out.split('').any(set.contains))) return out;
  }
}
