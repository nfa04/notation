// Packs the extensions of extensions/ for the gallery: one zip each in extensions/dist/ and extensions/index.json with the checksums.
//
//   dart run tool/build_extensions.dart
//
// Commit both; the app reads extensions/index.json from the repository (see lib/extensions/extension_gallery.dart). The packages hold
// the manifest, the main script, its modules and the templates it names, and nothing else (tests.json stays in the repository).
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const base = 'https://raw.githubusercontent.com/nfa04/notation/main/extensions/dist/';

void main() {
  final root = Directory('extensions');
  final dist = Directory('${root.path}/dist')..createSync(recursive: true);
  for (final old in dist.listSync()) {
    old.deleteSync(recursive: true);
  }
  final entries = <Map<String, Object?>>[];
  for (final dir in root.listSync().whereType<Directory>()) {
    final manifestFile = File('${dir.path}/manifest.json');
    if (!manifestFile.existsSync() || dir.path.endsWith('dist')) continue;
    final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final names = <String>[
      'manifest.json',
      manifest['main'] as String? ?? 'main.js',
      for (final m in (manifest['modules'] as List? ?? const [])) '$m',
      for (final t in (manifest['templates'] as List? ?? const [])) (t as Map)['file'] as String,
    ];
    final zip = Archive();
    for (final n in names) {
      final bytes = File('${dir.path}/$n').readAsBytesSync();
      zip.add(ArchiveFile.bytes(n, bytes)..lastModTime = 0);
    }
    final data = ZipEncoder().encodeBytes(zip);
    final file = '${manifest['id']}-${manifest['version']}.zip';
    File('${dist.path}/$file').writeAsBytesSync(data);
    entries.add({
      'id': manifest['id'],
      'name': manifest['name'],
      'version': manifest['version'],
      'description': manifest['description'] ?? '',
      'author': manifest['author'] ?? '',
      'permissions': manifest['permissions'] ?? const [],
      'url': '$base$file',
      'sha256': sha256.convert(data).toString(),
      'size': data.length,
    });
  }
  entries.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
  File('${root.path}/index.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({'extensions': entries})}\n');
  stdout.writeln('${entries.length} extensions packed.');
}
