import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/llm/onnx_runtime_packs.dart';
import 'package:notes/screens/acceleration_settings.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a pack is a folder with a libonnxruntime.so, plain or versioned; other folders and files are left out', () async {
    final root = await Directory.systemTemp.createTemp('packs');
    addTearDown(() => root.delete(recursive: true));
    for (final f in ['cuda-12/libonnxruntime.so', 'migraphx/libonnxruntime.so.1.23.1', 'migraphx/libonnxruntime.so.1', 'empty/readme.txt']) {
      await File(p.join(root.path, f)).create(recursive: true);
    }
    await File(p.join(root.path, 'loose.so')).create();
    final found = await findOnnxRuntimePacks(root);
    expect([for (final k in found) k.name], ['cuda-12', 'migraphx']);
    expect(found.last.library, p.join(root.path, 'migraphx', 'libonnxruntime.so.1.23.1'), reason: 'the full version, not the short link');
    expect(await findOnnxRuntimePacks(Directory(p.join(root.path, 'none'))), isEmpty);
  });

  testWidgets('the settings list the packs, show what runs, and save the pick', (tester) async {
    late NoteRepository repo;
    await tester.runAsync(() async => repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath)));
    OnnxRuntimePack? saved;
    var saves = 0;
    const pack = OnnxRuntimePack('migraphx-rocm-7.1', '/x/migraphx-rocm-7.1/libonnxruntime.so.1.23.1');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AccelerationSettings(
            repository: repo,
            runtimeInfo: () async => (version: '1.28.3', path: '', error: 'could not open /y/libonnxruntime.so', chosen: ''),
            findPacks: () async => [pack],
            packFolder: () async => '/x',
            suggested: () async => ['migraphx'],
            choosePack: (k) async {
              saved = k;
              saves++;
            },
          ),
        ),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.textContaining('the one in the app (processor only) (ONNX Runtime 1.28.3)'), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime-error')), findsOneWidget, reason: 'a chosen pack that did not open is said');
    expect(find.byKey(const ValueKey('runtime-migraphx-rocm-7.1')), findsOneWidget);
    expect(find.textContaining('Folder of the runtimes: /x'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('runtime-migraphx-rocm-7.1')));
    await tester.pump();
    expect(saves, 1);
    expect(saved, same(pack));

    await tester.tap(find.byKey(const ValueKey('runtime-app')));
    await tester.pump();
    expect(saves, 2);
    expect(saved, isNull, reason: 'back to the runtime in the app');
  });

  test('a pack is downloaded to a temporary folder, checked, and only then put in place; a bad manifest leaves nothing', () async {
    final root = await Directory.systemTemp.createTemp('packdl');
    addTearDown(() => root.delete(recursive: true));
    const lib = 'LIB';
    final sum = sha256.convert(utf8.encode(lib)).toString();
    Future<void> Function(String, String, void Function(double)) host(Map<String, dynamic> manifest, {String content = lib}) => (url, path, progress) async {
          await File(path).writeAsString(url.endsWith('manifest.json') ? jsonEncode(manifest) : content);
          progress(1);
        };
    final good = {
      'name': 'cuda12-ort-1.28.3',
      'files': [
        {'path': 'libonnxruntime.so.1.28.3', 'bytes': 3, 'sha256': sum},
        {'path': 'libonnxruntime.so', 'link': 'libonnxruntime.so.1.28.3'},
      ],
    };
    final seen = <double>[];
    final pack = await downloadOnnxRuntimePack(onnxRuntimeDownloads.first, folder: root, download: host(good), progress: seen.add);
    expect(pack.name, 'cuda12-ort-1.28.3');
    expect(await File(pack.library).readAsString(), 'LIB');
    expect(seen.last, 1);
    expect([for (final e in root.listSync()) p.basename(e.path)], ['cuda12-ort-1.28.3'], reason: 'no temporary folder left');

    // a file that arrives damaged, and a manifest that points out of the folder
    await expectLater(downloadOnnxRuntimePack(onnxRuntimeDownloads.first, folder: root, download: host(good, content: 'XXX')), throwsFormatException);
    final evil = {'name': 'x', 'files': [{'path': '../outside.so', 'bytes': 1}]};
    await expectLater(downloadOnnxRuntimePack(onnxRuntimeDownloads.first, folder: root, download: host(evil)), throwsFormatException);
    expect([for (final e in root.listSync()) p.basename(e.path)], ['cuda12-ort-1.28.3']);
  });

  test('what the machine has decides which pack is suggested', () async {
    final sys = await Directory.systemTemp.createTemp('sys');
    addTearDown(() => sys.delete(recursive: true));
    expect(await suggestedRuntimeDownloads(sys: sys.path), isEmpty);
    await File(p.join(sys.path, 'proc/driver/nvidia/version')).create(recursive: true);
    await File(p.join(sys.path, 'proc/driver/nvidia/version')).writeAsString('NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.95.05  Mon Sep  1 2025\n');
    await File(p.join(sys.path, 'dev/kfd')).create(recursive: true);
    await File(p.join(sys.path, 'sys/class/drm/card1/device/vendor')).create(recursive: true);
    await File(p.join(sys.path, 'sys/class/drm/card1/device/vendor')).writeAsString('0x8086\n');
    expect(await suggestedRuntimeDownloads(sys: sys.path), ['cuda13', 'migraphx', 'openvino']);
    await File(p.join(sys.path, 'proc/driver/nvidia/version')).writeAsString('NVRM version: NVIDIA UNIX x86_64 Kernel Module  535.54.03  Tue\n');
    expect((await suggestedRuntimeDownloads(sys: sys.path)).first, 'cuda12');
  });
}
