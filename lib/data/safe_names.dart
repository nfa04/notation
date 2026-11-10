import 'package:path/path.dart' as p;

/// Names that come out of a file or a message of somebody else (a note file, a peer's folder) must never decide where on the disk
/// something is written. These are the checks the code that builds a path from such a name goes through.

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
final _safeExtension = RegExp(r'^[a-z0-9]{1,5}$');

/// Whether [id] is a plain name: letters, digits, `-` and `_` (ids the app makes are such), so that it can be one part of a path.
bool isSafeId(String? id) => id != null && _safeId.hasMatch(id);

/// [id] made usable as a part of a file name: anything but letters, digits, `-` and `_` becomes `_`, and a long one is cut.
String safeFileId(String id) {
  final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  if (cleaned.isEmpty) return '_';
  return cleaned.length > 128 ? cleaned.substring(0, 128) : cleaned;
}

/// [extension] (without the dot, lower case) if it is one to five letters or digits, else [fallback].
String safeExtension(String? extension, {String fallback = 'png'}) {
  final e = (extension ?? '').toLowerCase();
  return _safeExtension.hasMatch(e) ? e : fallback;
}

/// The extension of a name inside an archive (`media/ab12.png` is `png`), made safe by [safeExtension]. Only the last part of the
/// name counts, so no separator or `..` can get through.
String extensionOfEntry(String? entryName, {String fallback = 'png'}) {
  if (entryName == null) return fallback;
  final base = entryName.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  return dot < 0 ? fallback : safeExtension(base.substring(dot + 1), fallback: fallback);
}

/// Whether [path] is below [root] once both are cleaned of `.` and `..`.
bool isInside(String root, String path) => p.isWithin(root, path);
