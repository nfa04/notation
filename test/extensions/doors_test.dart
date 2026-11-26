import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/door_results.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:notes/import/import_source.dart';

Map<String, Object?> base([Map<String, Object?> more = const {}]) => {'id': 'doors-ext', 'name': 'Doors', 'version': '1', ...more};

String? refused(Map<String, Object?> json) {
  try {
    ExtensionManifest.fromJson(json);
    return null;
  } on ManifestException catch (e) {
    return e.message;
  }
}

class _Store extends ExtensionStorage {
  Map<String, Object?> data = {};
  @override
  Future<Map<String, Object?>> read() async => data;
  @override
  Future<void> write(Map<String, Object?> values) async => data = values;
}

class _Secrets extends ExtensionSecrets {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String? value) async => value == null ? map.remove(key) : map[key] = value;
}

class _Api extends InteractiveApi {
  _Api({super.onAsk, super.onProgress});
  @override
  Future<List<Map<String, Object?>>> noteBacklinks(String? id) async => [{'id': 'b', 'title': 'Back'}];
  @override
  Future<String> aiComplete(String prompt, {int maxTokens = 400}) async => 'ai:$prompt:$maxTokens';
  @override
  Future<List<Map<String, Object?>>> inkReadings({int? page}) async => [{'page': page, 'text': 'hi'}];
}

void main() {
  final skip = QuickJsEngine.available ? null : 'the script engine is not here';

  group('the manifest', () {
    test('an importer needs its permission, and the permission needs an importer', () {
      expect(refused(base({'importers': [{'id': 'enex', 'title': 'Evernote', 'accepts': ['.enex']}]})), contains('notes.import'));
      expect(refused(base({'permissions': ['notes.import']})), contains('needs "importers"'));
      final ok = ExtensionManifest.fromJson(base({
        'permissions': ['notes.import'],
        'importers': [{'id': 'enex', 'title': 'Evernote', 'accepts': ['.enex', 'zip'], 'description': 'ENEX files'}],
      }));
      expect(ok.importers.single.extensions, ['enex', 'zip']);
      expect(ExtensionManifest.fromJson(ok.toJson()).importers.single.accepts, ['.enex', 'zip']);
    });

    test('an importer of an account needs the network and takes no files', () {
      expect(refused(base({'permissions': ['notes.import'], 'importers': [{'id': 'a', 'title': 'A', 'accepts': ['account']}]})), contains('network'));
      expect(
          refused(base({
            'permissions': ['notes.import', 'network'],
            'hosts': ['api.example.com'],
            'importers': [{'id': 'a', 'title': 'A', 'accepts': ['account', '.json']}],
          })),
          contains('cannot be mixed'));
    });

    test('exporters need note.read; agent tools cannot have the network; the API version is checked', () {
      expect(refused(base({'exporters': [{'id': 'x', 'title': 'X', 'extension': 'tex'}]})), contains('note.read'));
      expect(refused(base({'permissions': ['note.read'], 'exporters': [{'id': 'x', 'title': 'X', 'extension': '.tex'}]})), contains('extension'));
      expect(
          refused(base({
            'permissions': ['network'],
            'hosts': ['a.example.com'],
            'agentTools': [{'id': 't', 'title': 'T', 'description': 'does a thing'}],
          })),
          contains('network'));
      expect(refused(base({'apiVersion': 99})), contains('version 99'));
      expect(ExtensionManifest.fromJson(base({'apiVersion': 2})).apiVersion, 2);
    });

    test('commands, settings, action fields, blocks, reactions', () {
      final m = ExtensionManifest.fromJson(base({
        'commands': [{'id': 'go', 'title': 'Go', 'where': ['dashboard']}, {'id': 'two', 'title': 'Two'}],
        'settings': [
          {'id': 'key', 'title': 'API key', 'type': 'secret'},
          {'id': 'mode', 'title': 'Mode', 'type': 'choice', 'choices': ['a', 'b'], 'default': 'b'},
          {'id': 'n', 'title': 'How many', 'type': 'number', 'default': 3},
        ],
        'actions': [
          {'id': 'tidy', 'title': 'Closed', 'fields': [{'id': 'tag', 'title': 'Tag'}]},
        ],
        'on': {'noteClosed': 'tidy'},
        'blocks': [{'id': 'chess', 'title': 'Chess', 'language': 'chess'}],
      }));
      expect(m.commands.first.where.single.id, 'dashboard');
      expect(m.settings.length, 3);
      expect(m.actions.single.fields.single.id, 'tag');
      expect(ExtensionManifest.fromJson(m.toJson()).blocks.single.language, 'chess');
      expect(refused(base({'commands': [{'id': 'go', 'title': 'Go', 'where': ['moon']}]})), contains('moon'));
      expect(refused(base({'settings': [{'id': 'm', 'title': 'M', 'type': 'choice'}]})), contains('choices'));
      expect(refused(base({'settings': [{'id': 'n', 'title': 'N', 'type': 'number', 'default': 'x'}]})), contains('default'));
      expect(refused(base({'on': {'noteClosed': 'tidy'}})), contains('does not list'));
      expect(refused(base({'on': {'nope': 'a'}, 'actions': [{'id': 'a', 'title': 'N'}]})), contains('not an event'));
      expect(refused(base({'actions': [{'id': 'a', 'title': 'A', 'fields': [{'id': 's', 'title': 'S', 'type': 'secret'}]}]})), contains('secret'));
      expect(refused(base({'blocks': [{'id': 'a', 'title': 'A', 'language': 'x'}, {'id': 'b', 'title': 'B', 'language': 'x'}]})), contains('same "language"'));
    });

    test('modules, templates and capture handlers', () {
      final m = ExtensionManifest.fromJson(base({
        'modules': ['lib/util.js'],
        'templates': [{'id': 'meet', 'title': 'Meeting', 'file': 'templates/meeting.md'}],
        'capture': [{'id': 'arx', 'title': 'arXiv', 'sites': ['arxiv.org']}],
      }));
      expect(m.modules, ['lib/util.js']);
      expect(m.capture.single.matches('export.arxiv.org'), isTrue);
      expect(m.capture.single.matches('notarxiv.org'), isFalse);
      expect(refused(base({'modules': ['../x.js']})), contains('modules'));
      expect(refused(base({'templates': [{'id': 'a', 'title': 'A', 'file': '../x.md'}]})), contains('file'));
    });
  });

  group('what the scripts get', () {
    ExtensionRuntime runtime(String script, Set<ExtensionPermission> perms, ExtensionApi api, {Map<String, Object?> settings = const {}, ExtensionSecrets? secrets, bool heavy = false}) =>
        ExtensionRuntime(
          manifest: ExtensionManifest(id: 'abc', name: 'x', version: '1', permissions: perms, hosts: perms.contains(ExtensionPermission.network) ? const ['a.example.com'] : const []),
          script: script,
          granted: perms,
          api: api,
          storage: _Store(),
          fetch: (u, {method = 'GET', headers = const {}, body}) async => {'status': 200, 'headers': {}, 'body': 'text'},
          fetchBytes: (u, {method = 'GET', headers = const {}, body, limit = 0}) async => {'status': 200, 'headers': {}, 'body': base64Encode([1, 2, 3]), 'limit': limit},
          settings: settings,
          secrets: secrets,
          heavy: heavy,
          limit: const Duration(seconds: 10),
        );

    test('an importer reads its files as it needs them and answers with notes', () async {
      final files = [
        SourceFile('export/a.enex', 5, () async => Uint8List.fromList(utf8.encode('alpha'))),
        SourceFile('export/b.bin', 3, () async => Uint8List.fromList([1, 2, 3])),
      ];
      final api = ImportApi(files);
      final rt = runtime('''
        notation.importer('enex', async (ctx) => {
          const text = await ctx.files[0].read();
          const raw = await ctx.files[1].readBytes();
          return { notes: [{ path: 'Evernote/Inbox/First', markdown: text + '!', tags: ['x'], sourceId: 's1',
                             attachments: [{ name: 'p.png', base64: raw }] }], notices: [ctx.files.length + ' files'] };
        });
      ''', {ExtensionPermission.notesImport}, api, heavy: true);
      final run = await rt.run('importer', 'enex', {
        'files': [for (final f in files) {'path': f.path, 'name': f.name, 'size': f.size}]
      });
      expect(run.error, isNull);
      final result = parseImporterResult(run.value);
      expect(result.notes.single.title, 'First');
      expect(result.notes.single.path, 'Evernote/Inbox/First');
      expect(result.notes.single.markdown, 'alpha!');
      expect(result.notes.single.attachments['p.png'], [1, 2, 3]);
      expect(result.notices, ['2 files']);
    }, skip: skip);

    test('importing needs the permission', () async {
      final rt = runtime("notation.importer('i', async (ctx) => ({ notes: [{ title: await ctx.files[0].read() }] }));", {}, ImportApi([SourceFile('a', 1, () async => Uint8List(1))]));
      final run = await rt.run('importer', 'i', {'files': [{'path': 'a', 'name': 'a', 'size': 1}]});
      expect(run.error, contains('notes.import'));
    }, skip: skip);

    test('an answer that is not right makes nothing', () {
      expect(() => parseImporterResult({'notes': [{'markdown': 'x'}]}), throwsA(isA<ExtensionError>()));
      expect(() => parseImporterResult({'notes': [{'title': 't', 'attachments': [{'name': 'a', 'base64': '!!'}]}]}), throwsA(isA<ExtensionError>()));
      expect(() => parseImporterResult({'notes': [{'title': 'a', 'sourceId': 's'}, {'title': 'b', 'sourceId': 's'}]}), throwsA(isA<ExtensionError>()));
      expect(() => parseImporterResult({'notes': [{'path': '../x', 'title': 't'}]}), throwsA(isA<ExtensionError>()));
    });

    test('exporters and blocks are checked', () {
      final f = parseExportedFile({'name': 'a/b:c', 'text': 'hello'}, 'tex');
      expect(f.name, 'a_b_c.tex');
      expect(utf8.decode(f.bytes), 'hello');
      expect(() => parseExportedFile({'name': 'x'}, 'tex'), throwsA(isA<ExtensionError>()));
      final b = parseBlockDrawing({
        'width': 100,
        'height': 50,
        'strokes': [{'points': [[0, 0], [10, 10]]}],
        'texts': [{'x': 1, 'y': 2, 'text': 'hi'}],
      });
      expect(b.strokes.length, 1);
      expect(b.texts.single['size'], 14);
      expect(() => parseBlockDrawing({'width': 1, 'height': 50}), throwsA(isA<ExtensionError>()));
    });

    test('secrets and settings', () async {
      final secrets = _Secrets();
      final rt = runtime('''
        notation.command('c', async () => {
          await notation.secrets.set('token', 'abc');
          const s = await notation.settings.get();
          return (await notation.secrets.get('token')) + ':' + s.mode;
        });
      ''', {}, InteractiveApi(), settings: {'mode': 'fast'}, secrets: secrets);
      final run = await rt.run('command', 'c', {});
      expect(run.value, 'abc:fast');
      expect(secrets.map['token'], 'abc');
    }, skip: skip);

    test('questions go to the person, and fail where there is nobody to ask', () async {
      final asked = <String>[];
      final api = _Api(onAsk: (kind, args) async {
        asked.add('$kind:${jsonEncode(args)}');
        return kind == 'confirm' ? true : {'name': 'Ann'};
      }, onProgress: (t, f) => asked.add('progress:$t:$f'));
      final rt = runtime('''
        notation.command('c', async () => {
          const ok = await notation.ui.confirm('Sure?');
          const v = await notation.ui.form('Who', [{ id: 'name', title: 'Name' }]);
          await notation.ui.progress('half', 0.5);
          return ok + ':' + v.name;
        });
      ''', {}, api);
      expect((await rt.run('command', 'c', {})).value, 'true:Ann');
      expect(asked.first, 'confirm:{"text":"Sure?"}');
      expect(asked.last, 'progress:half:0.5');
      final quiet = runtime("notation.command('c', async () => { try { await notation.ui.confirm('x'); } catch (e) { return e.message; } });", {}, InteractiveApi());
      expect((await quiet.run('command', 'c', {})).value, contains('background'));
      final bad = runtime("notation.command('c', async () => { try { await notation.ui.form('x', [{ id: 'A b', title: 'x' }]); } catch (e) { return e.message; } });", {}, api);
      expect((await bad.run('command', 'c', {})).value, contains('id'));
    }, skip: skip);

    test('binary answers come as base64, with a bigger limit for a heavy job', () async {
      const script = "notation.command('c', async () => { const r = await notation.network.fetch('https://a.example.com/x', { responseType: 'base64' }); return r.body + ':' + r.limit; });";
      expect((await runtime(script, {ExtensionPermission.network}, InteractiveApi()).run('command', 'c', {})).value, '${base64Encode([1, 2, 3])}:${4 * 1024 * 1024}');
      expect((await runtime(script, {ExtensionPermission.network}, InteractiveApi(), heavy: true).run('command', 'c', {})).value, '${base64Encode([1, 2, 3])}:${20 * 1024 * 1024}');
    }, skip: skip);

    test('links, ink, AI: each under its own permission, the AI at most five times a run', () async {
      final api = _Api();
      expect(
          (await runtime("notation.command('c', async () => JSON.stringify(await notation.notes.backlinks()));", {ExtensionPermission.notesReadAll}, api).run('command', 'c', {})).value,
          '[{"id":"b","title":"Back"}]');
      expect((await runtime("notation.command('c', async () => { try { await notation.notes.backlinks(); } catch (e) { return e.message; } });", {}, api).run('command', 'c', {})).value, contains('notes.readAll'));
      expect((await runtime("notation.command('c', async () => JSON.stringify(await notation.ink.read({ page: 2 })));", {ExtensionPermission.noteRead}, api).run('command', 'c', {})).value, '[{"page":2,"text":"hi"}]');
      expect((await runtime("notation.command('c', async () => await notation.ai.complete('hi', { maxTokens: 9 }));", {ExtensionPermission.aiUse}, api).run('command', 'c', {})).value, 'ai:hi:9');
      final many = runtime('''notation.command('c', async () => { let last; for (let i = 0; i < 7; i++) { try { await notation.ai.complete('x'); last = i; } catch (e) { return last + ':' + e.message; } } });''', {ExtensionPermission.aiUse}, api);
      expect((await many.run('command', 'c', {})).value, startsWith('4:'));
    }, skip: skip);
  });
}
