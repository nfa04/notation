import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../data/safe_zip.dart';

/// One file of something that is imported (a vault, an export): where it lies, relative to the root, with `/` between the parts, and
/// a way to read it when it is needed (a vault is not held in memory).
class SourceFile {
  final String path;
  final int size;
  final Future<Uint8List> Function() read;
  const SourceFile(this.path, this.size, this.read);

  String get name => path.substring(path.lastIndexOf('/') + 1);

  /// The ending of the name in lower case, without the dot ('' if it has none).
  String get ext {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  String get directory => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

/// The files of a vault or an export, and the name it goes by.
class ImportSource {
  final String name;
  final List<SourceFile> files;
  const ImportSource(this.name, this.files);
}

/// A path that belongs to the tools of the other app or the system, not to the notes: a part that starts with a dot (`.obsidian`,
/// `.trash`, `.git`, `.DS_Store`) or the `__MACOSX` folder a Mac puts into a zip.
bool isHiddenPath(String path) => path.split('/').any((s) => s.startsWith('.') || s == '__MACOSX');

/// The files of a zip. A zip inside it (Notion splits a big export into several) is opened too. When everything lies in one folder,
/// that folder is the root and gives the name. Throws a [FormatException] for something that is no zip, and [ArchiveTooBigException]
/// for one that is too big.
ImportSource sourceFromZip(Uint8List bytes, {required String name}) {
  final files = <SourceFile>[];
  void collect(Archive zip, int depth) {
    for (final f in zip.files) {
      if (!f.isFile) continue;
      final path = f.name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
      if (path.isEmpty || path.split('/').contains('..') || isHiddenPath(path)) continue;
      if (depth < 2 && path.toLowerCase().endsWith('.zip')) {
        try {
          collect(decodeZipLimited(f.content as List<int>), depth + 1);
          continue;
        } on ArchiveTooBigException {
          rethrow;
        } catch (_) {
          // not a zip after all: it is an ordinary file then
        }
      }
      files.add(SourceFile(path, f.size, () async => Uint8List.fromList(f.content as List<int>)));
    }
  }

  final Archive zip;
  try {
    zip = decodeZipLimited(bytes);
  } on ArchiveTooBigException {
    rethrow;
  } catch (_) {
    throw const FormatException('This is not a zip file.');
  }
  if (zip.files.isEmpty) throw const FormatException('This is not a zip file.');
  collect(zip, 0);
  return _withoutSingleRoot(name, files);
}

/// The files below [directory] (a vault that was picked as a folder). Not for the web, where a folder cannot be picked.
Future<ImportSource> sourceFromDirectory(Directory directory) async {
  final files = <SourceFile>[];
  final root = directory.path;
  await for (final entity in directory.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = p.relative(entity.path, from: root).replaceAll('\\', '/');
    if (isHiddenPath(path)) continue;
    files.add(SourceFile(path, await entity.length(), entity.readAsBytes));
  }
  return ImportSource(p.basename(root), files);
}

ImportSource _withoutSingleRoot(String name, List<SourceFile> files) {
  if (files.isEmpty) return ImportSource(name, files);
  final first = files.first.path.split('/');
  if (first.length < 2) return ImportSource(name, files);
  final root = first.first;
  if (!files.every((f) => f.path.startsWith('$root/'))) return ImportSource(name, files);
  return ImportSource(root, [for (final f in files) SourceFile(f.path.substring(root.length + 1), f.size, f.read)]);
}
