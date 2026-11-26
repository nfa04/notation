import 'package:archive/archive.dart';

/// A zip that is bigger than the limits it was read with.
class ArchiveTooBigException implements Exception {
  final String message;
  const ArchiveTooBigException(this.message);

  @override
  String toString() => message;
}

/// Reads the directory of a zip (what each file says it is) and refuses one that has too many files, a file that unpacks to more
/// than [maxEntryBytes], or files that together unpack to more than [maxTotalBytes]. Nothing is unpacked yet, so a "zip bomb"
/// is turned away before it takes the memory. (The sizes are what the zip declares; one that lies about them is not caught
/// by this, only the many files and the honestly huge ones are.)
///
/// Throws [ArchiveTooBigException]; whatever else is wrong with the bytes is thrown as the archive package throws it.
Archive decodeZipLimited(
  List<int> bytes, {
  int maxEntries = 10000,
  int maxEntryBytes = 512 << 20,
  int maxTotalBytes = 1 << 30,
  bool strict = false,
}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  if (archive.files.length > maxEntries) throw const ArchiveTooBigException('The archive has too many files.');
  var total = 0;
  for (final f in archive.files) {
    if (!f.isFile) continue;
    if (f.size < 0 || f.size > maxEntryBytes) throw const ArchiveTooBigException('A file in the archive is too big.');
    total += f.size;
    if (total > maxTotalBytes) throw const ArchiveTooBigException('The archive is too big.');
  }
  if (strict) _requireConsistent(bytes);
  return archive;
}

/// For zips whose content is going to be run (extensions): the file names of the zip's directory and of the headers in front of
/// each file must be the same, no name may be there twice, and every file must match its checksum. The decoder goes by the
/// headers in front of the files and drops a second file of the same name, so without this a zip could show a reviewer one file
/// and give the app another. Throws a [FormatException].
void _requireConsistent(List<int> bytes) {
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  final seen = <String>{};
  for (final h in directory.fileHeaders) {
    final f = h.file;
    if (f == null || f.filename != h.filename) throw const FormatException('A file name in the zip differs from its directory entry.');
    if (!seen.add(h.filename.toLowerCase())) throw const FormatException('The zip has the same file name twice.');
    if (!h.filename.endsWith('/') && !f.verifyCrc32()) throw const FormatException('A file in the zip does not match its checksum.');
  }
}
