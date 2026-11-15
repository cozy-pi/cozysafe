/// File names for items sent out together (the share sheet gets decrypted copies in one
/// temporary folder): safe as file names, a note ends in ".txt", and no two are the same,
/// since two items may carry one name ("IMG_0001.jpg" from two phones). A repeat gets a
/// number before its extension: "IMG_0001 (2).jpg". Compared without case, as the file
/// systems of iPhone, Mac and Windows do.
List<String> sendNames(List<({String name, bool note})> items) {
  final taken = <String>{};
  final names = <String>[];
  for (final (n, it) in items.indexed) {
    var name = it.name.isEmpty ? 'item-$n' : it.name.replaceAll(RegExp(r'[/\\:]'), '-');
    if (it.note && !name.endsWith('.txt')) name = '$name.txt';
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var unique = name;
    for (var copy = 2; !taken.add(unique.toLowerCase()); copy++) {
      unique = '$base ($copy)$extension';
    }
    names.add(unique);
  }
  return names;
}
