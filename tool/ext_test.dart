// Runs the cases of an extension you are writing (see tool/ext_runner.dart for the form of tests.json):
//
//   EXT_DIR=extensions/my-extension LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test tool/ext_test.dart
//
// (the script engine needs the native libraries of a debug build of the app; with no EXT_DIR every folder of extensions/ is run)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/script_engine.dart';

import 'ext_runner.dart';

void main() {
  final one = Platform.environment['EXT_DIR'];
  final folders = one != null
      ? [Directory(one)]
      : [for (final d in Directory('extensions').listSync().whereType<Directory>()) if (File('${d.path}/tests.json').existsSync()) d];
  for (final folder in folders) {
    test(folder.path, () async {
      final problems = await runExtensionCases(folder);
      expect(problems, isEmpty, reason: problems.join('\n'));
    }, skip: QuickJsEngine.available ? null : 'the script engine is not here');
  }
}
