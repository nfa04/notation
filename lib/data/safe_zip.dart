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
  return archive;
}
