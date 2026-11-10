import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

/// Where the file the person picked can be read as a [File]. A browser gives no path, only the bytes: they are put in the
/// files of the web (lib/web/web_files_web.dart) under the name the file had, and that path is returned.
Future<String?> pickedPath(PlatformFile? picked) async {
  if (picked == null) return null;
  if (!kIsWeb) return picked.path;
  final dir = Directory('/tmp/picked/${DateTime.now().microsecondsSinceEpoch}');
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, picked.name));
  await file.writeAsBytes(await picked.readAsBytes());
  return file.path;
}
