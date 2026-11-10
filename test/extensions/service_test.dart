import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';

class _Api extends ExtensionApi {
  final calls = <String>[];
  @override
  Future<Map<String, Object?>> note() async => {'id': 'n', 'title': 'T', 'text': 'body'};
  @override
  Future<void> addTask(String title, {String? due}) async => calls.add('task:$title');
}

String manifest({String id = 'word-count', String version = '1.0.0', List<String> permissions = const [], List<String> hosts = const []}) => jsonEncode({
      'id': id,
      'name': 'Word count',
      'version': version,
      'permissions': permissions,
      if (hosts.isNotEmpty) 'hosts': hosts,
      'tools': [
        {'id': 'count', 'title': 'Count'},
        {'id': 'shout', 'title': 'Shout'},
      ],
      'actions': [
        {'id': 'daily', 'title': 'Daily'}
      ],
    });

const script = '''
  notation.tool('count', (ctx) => ({ message: ctx.text.split(' ').length + ' words' }));
  notation.tool('shout', (ctx) => ctx.text.toUpperCase() + '!');
  notation.action('daily', async (ctx) => { await notation.tasks.add('Count for ' + ctx.note.title); return 'added'; });
''';

List<int> zipOf(Map<String, String> files, {String folder = ''}) {
  final a = Archive();
  files.forEach((name, text) => a.addFile(ArchiveFile('$folder$name', text.length, utf8.encode(text))));
  return ZipEncoder().encode(a);
}

void main() {
  final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here (run with LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib after a Linux build)';
  late Directory dir;
  late Map<String, String> settings;

  ExtensionService make() => ExtensionService((k) async => settings[k], (k, v) async => settings[k] = v, directory: () async => Directory('${dir.path}/extensions'));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ext');
    settings = {};
  });
  tearDown(() => dir.delete(recursive: true));

  group('installing', () {
    test('from text: it is off, with no permission, until the person says so', () async {
      final s = make();
      final e = await s.installSource(manifest(permissions: ['note.read']), script);
      expect(e.enabled, isFalse);
      expect(e.granted, isEmpty);
      expect(s.tools, isEmpty, reason: 'off: nothing of it is offered');
      await s.setEnabled('word-count', true);
      expect(s.tools.map((t) => t.tool.id), ['count', 'shout']);
      expect(s.actions.map((a) => a.action.id), ['daily']);
    });

    test('from a zip, at the top or in a folder', () async {
      for (final folder in ['', 'word-count/']) {
        final s = make();
        final e = await s.installZip(zipOf({'manifest.json': manifest(), 'main.js': script}, folder: folder));
        expect(e.id, 'word-count', reason: 'folder "$folder"');
        await s.remove('word-count');
      }
    });

    test('what is wrong with a zip is said', () async {
      final s = make();
      await expectLater(s.installZip([1, 2, 3]), throwsA(isA<ManifestException>().having((e) => e.message, 'm', contains('not a zip'))));
      await expectLater(s.installZip(zipOf({'main.js': script})), throwsA(isA<ManifestException>().having((e) => e.message, 'm', contains('no manifest.json'))));
      await expectLater(s.installZip(zipOf({'manifest.json': manifest()})), throwsA(isA<ManifestException>().having((e) => e.message, 'm', contains('no main.js'))));
      await expectLater(s.installZip(zipOf({'manifest.json': '{not json', 'main.js': script})), throwsA(isA<ManifestException>().having((e) => e.message, 'm', contains('JSON'))));
      await expectLater(s.installSource(manifest(), '   '), throwsA(isA<ManifestException>()));
      await expectLater(s.installSource(manifest(), 'x' * 300000), throwsA(isA<ManifestException>().having((e) => e.message, 'm', contains('too big'))));
      expect(s.installed, isEmpty);
    });

    test('a zip cannot write outside of its folder', () async {
      final s = make();
      await s.installZip(zipOf({'manifest.json': manifest(), 'main.js': script, '../../evil.txt': 'x'}));
      expect(File('${dir.path}/evil.txt').existsSync(), isFalse);
      expect(Directory('${dir.path}/extensions/word-count').listSync().map((f) => f.path.split('/').last).toSet(), {'manifest.json', 'main.js'});
    });
  });

  group('what the person decided', () {
    test('stays after a restart', () async {
      var s = make();
      await s.installSource(manifest(permissions: ['note.read', 'tasks.add']), script);
      await s.setEnabled('word-count', true);
      await s.setGranted('word-count', ExtensionPermission.noteRead, true);
      s = make();
      await s.load();
      final e = s.byId('word-count')!;
      expect(e.enabled, isTrue);
      expect(e.granted, {ExtensionPermission.noteRead});
      expect(e.script, script);
    });

    test('a permission that was not asked for cannot be given', () async {
      final s = make();
      await s.installSource(manifest(), script);
      await s.setGranted('word-count', ExtensionPermission.noteWrite, true);
      expect(s.byId('word-count')!.granted, isEmpty);
    });

    test('a newer version keeps what was decided, and what it asks for more is not given', () async {
      final s = make();
      await s.installSource(manifest(permissions: ['note.read']), script);
      await s.setEnabled('word-count', true);
      await s.setGranted('word-count', ExtensionPermission.noteRead, true);
      final v2 = await s.installSource(manifest(version: '2.0.0', permissions: ['note.read', 'tasks.add']), script);
      expect(v2.manifest.version, '2.0.0');
      expect(v2.enabled, isTrue);
      expect(v2.granted, {ExtensionPermission.noteRead});
      // one that asks for less loses what it does not ask for
      final v3 = await s.installSource(manifest(version: '3.0.0'), script);
      expect(v3.granted, isEmpty);
    });

    test('a permission given in the settings file but not asked for in the manifest is ignored', () async {
      var s = make();
      await s.installSource(manifest(), script);
      settings[ExtensionService.stateKey] = jsonEncode({
        'word-count': {'enabled': true, 'granted': ['note.read', 'network', 'nonsense']}
      });
      s = make();
      await s.load();
      expect(s.byId('word-count')!.granted, isEmpty);
    });

    test('removing deletes it and what it kept', () async {
      final s = make();
      await s.installSource(manifest(), script);
      File('${dir.path}/extensions/word-count/storage.json').writeAsStringSync('{}');
      await s.remove('word-count');
      expect(Directory('${dir.path}/extensions/word-count').existsSync(), isFalse);
      final again = make();
      await again.load();
      expect(again.installed, isEmpty);
    });

    test('a folder that is not an extension is passed over', () async {
      Directory('${dir.path}/extensions/junk').createSync(recursive: true);
      File('${dir.path}/extensions/junk/manifest.json').writeAsStringSync('{"id": "other-name", "name": "x", "version": "1"}');
      File('${dir.path}/extensions/junk/main.js').writeAsStringSync('1');
      final s = make();
      await s.load();
      expect(s.installed, isEmpty, reason: 'the folder is not named as the id says');
    });
  });

  group('running', () {
    test('a tool: a message, a replacement, nothing', () async {
      final s = make();
      await s.installSource(manifest(), script);
      await s.setEnabled('word-count', true); // (one that is off does not run)
      final e = s.byId('word-count')!;
      final count = await s.runTool(e, e.manifest.tools[0], text: 'a b c', api: _Api());
      expect((count.ok, count.message, count.replace), (true, '3 words', null));
      final shout = await s.runTool(e, e.manifest.tools[1], text: 'hey', api: _Api());
      expect(shout.replace, 'HEY!');
    }, skip: skip);

    test('an action, with what the person allowed', () async {
      final s = make();
      var e = await s.installSource(manifest(permissions: ['tasks.add']), script);
      await s.setEnabled('word-count', true);
      e = s.byId('word-count')!;
      final api = _Api();
      expect(await s.runAction(e, e.manifest.actions.single, event: {'note': {'title': 'Physics'}}, api: api), startsWith('Failed:'), reason: 'not given yet');
      expect(api.calls, isEmpty);
      await s.setGranted('word-count', ExtensionPermission.tasks, true);
      e = s.byId('word-count')!;
      expect(await s.runAction(e, e.manifest.actions.single, event: {'note': {'title': 'Physics'}}, api: api), 'added');
      expect(api.calls, ['task:Count for Physics']);
    }, skip: skip);

    test('a failing tool says why and the app goes on', () async {
      final s = make();
      await s.installSource(manifest(), "notation.tool('count', () => { throw new Error('boom'); });");
      await s.setEnabled('word-count', true);
      final e = s.byId('word-count')!;
      final r = await s.runTool(e, e.manifest.tools[0], text: 'x', api: _Api());
      expect((r.ok, r.error), (false, 'boom'));
    }, skip: skip);

    test('runs go one after the other', () async {
      final s = make();
      await s.installSource(manifest(), "notation.tool('count', async () => { const n = ((await notation.storage.get('n')) || 0) + 1; await notation.storage.set('n', n); return String(n); });");
      await s.setEnabled('word-count', true);
      final e = s.byId('word-count')!;
      final results = await Future.wait([for (var i = 0; i < 5; i++) s.runTool(e, e.manifest.tools[0], text: '', api: _Api())]);
      expect(results.map((r) => r.replace).toList(), ['1', '2', '3', '4', '5']);
    }, skip: skip);

    test('without the engine, it says so', () async {
      final s = ExtensionService((k) async => null, (k, v) async {}, directory: () async => Directory('${dir.path}/extensions'), engine: ({onConsole}) => throw StateError('no engine'));
      final e = await s.installSource(manifest(), script);
      final r = await s.runTool(e, e.manifest.tools[0], text: 'x', api: _Api());
      expect(r.ok, isFalse);
    });
  });
}
