import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';

/// What the app was asked to do on behalf of the script: it has to stay empty wherever a permission is missing.
class _Api extends ExtensionApi {
  final calls = <String>[];
  @override
  Future<Map<String, Object?>> note() async {
    calls.add('note');
    return {'id': 'n', 'title': 'T', 'text': 'secret'};
  }

  @override
  Future<void> insertText(String text) async => calls.add('insert');
  @override
  Future<void> replaceSelection(String text) async => calls.add('replace');
  @override
  Future<void> setTitle(String title) async => calls.add('title');
  @override
  Future<void> addTask(String title, {String? due}) async => calls.add('task');
  @override
  Future<void> copy(String text) async => calls.add('copy');
}

class _Storage extends ExtensionStorage {
  Map<String, Object?> data = {};
  @override
  Future<Map<String, Object?>> read() async => Map.of(data);
  @override
  Future<void> write(Map<String, Object?> values) async => data = Map.of(values);
}

/// Every call that needs a permission, with arguments that are otherwise fine.
const _gated = <(String, Object?, ExtensionPermission)>[
  ('note.get', null, ExtensionPermission.noteRead),
  ('note.insertText', {'text': 'x'}, ExtensionPermission.noteWrite),
  ('selection.replace', {'text': 'x'}, ExtensionPermission.noteWrite),
  ('note.setTitle', {'title': 'x'}, ExtensionPermission.noteWrite),
  ('tasks.add', {'title': 'x'}, ExtensionPermission.tasks),
  ('clipboard.write', {'text': 'x'}, ExtensionPermission.clipboard),
  ('network.fetch', {'url': 'https://api.example.com/'}, ExtensionPermission.network),
  ('events.emit', {'event': 'ping', 'data': {}}, ExtensionPermission.eventsEmit),
];

void main() {
  final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here (LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib)';

  late _Api api;
  late _Storage storage;
  final fetched = <Uri>[];
  final emitted = <String>[];

  /// A run the way the app does it: the script in QuickJS on an isolate of its own, every call back through the checks of the app.
  ExtensionRuntime runtime(String script, {Set<ExtensionPermission> asked = const {}, Set<ExtensionPermission>? granted}) => ExtensionRuntime(
        manifest: ExtensionManifest(
          id: 'sandboxed',
          name: 'S',
          version: '1',
          permissions: asked,
          hosts: asked.contains(ExtensionPermission.network) ? const ['api.example.com'] : const [],
          events: asked.contains(ExtensionPermission.eventsEmit) ? const [ExtensionEventDef('ping', 'Ping')] : const [],
        ),
        script: script,
        granted: granted ?? asked,
        api: api,
        storage: storage,
        fetch: (url, {method = 'GET', headers = const {}, body}) async {
          fetched.add(url);
          return {'status': 200, 'headers': {}, 'body': 'ok'};
        },
        emit: (name, data) => emitted.add(name),
        limit: const Duration(seconds: 5),
      );

  setUp(() {
    api = _Api();
    storage = _Storage();
    fetched.clear();
    emitted.clear();
  });

  void nothingHappened() {
    expect(api.calls, isEmpty);
    expect(fetched, isEmpty);
    expect(emitted, isEmpty);
  }

  /// Calls [calls] straight on `__host` (no `notation` wrapper in between) and gives back the replies.
  Future<Map<String, Object?>> byHand(ExtensionRuntime rt, List<(String, Object?, ExtensionPermission)> calls) async {
    final list = jsonEncode([for (final c in calls) [c.$1, c.$2]]);
    final r = await rt.run('tool', 'a', {'calls': jsonDecode(list)}).timeout(const Duration(seconds: 20));
    // (the script's result is JSON; a failure of the run itself is not what is tested)
    expect(r.ok, isTrue, reason: r.error);
    return (jsonDecode(r.value as String) as Map).cast<String, Object?>();
  }

  const handScript = '''
    notation.tool('a', async (ctx) => {
      const out = {};
      for (const [name, args] of ctx.calls) out[name] = JSON.parse(await __host(name, JSON.stringify(args)));
      return JSON.stringify(out);
    });
  ''';

  group('a call that needs a permission, made by hand on the host', () {
    test('fails when the extension did not ask for it', () async {
      final out = await byHand(runtime(handScript), _gated);
      for (final c in _gated) {
        expect((out[c.$1]! as Map)['error'], contains('did not ask for the permission "${c.$3.id}"'), reason: c.$1);
      }
      nothingHappened();
    }, skip: skip);

    test('fails when it asked and the person did not give it', () async {
      final out = await byHand(runtime(handScript, asked: ExtensionPermission.values.toSet(), granted: {}), _gated);
      for (final c in _gated) {
        expect((out[c.$1]! as Map)['error'], contains('was not given'), reason: c.$1);
      }
      nothingHappened();
    }, skip: skip);

    test('one permission given opens its own calls and no other', () async {
      for (final given in ExtensionPermission.values) {
        api.calls.clear();
        fetched.clear();
        emitted.clear();
        final out = await byHand(runtime(handScript, asked: ExtensionPermission.values.toSet(), granted: {given}), _gated);
        for (final c in _gated) {
          final reply = out[c.$1]! as Map;
          if (c.$3 == given) {
            expect(reply['error'], isNull, reason: '${c.$1} with ${given.id}');
          } else {
            expect(reply['error'], contains('was not given'), reason: '${c.$1} with ${given.id}');
          }
        }
      }
    }, skip: skip);

    test('a name the app does not have is refused, and so is a malformed payload', () async {
      final out = await byHand(runtime(handScript), [
        ('storage.__proto__', null, ExtensionPermission.tasks),
        ('fs.read', {'path': '/etc/passwd'}, ExtensionPermission.tasks),
        ('', null, ExtensionPermission.tasks),
      ]);
      for (final reply in out.values) {
        expect((reply as Map)['error'], contains('Unknown call'));
      }
      final r = await runtime("notation.tool('a', async () => await __host('tasks.add', 'not json {'))", asked: {ExtensionPermission.tasks}).run('tool', 'a', {});
      expect(jsonDecode(r.value as String), containsPair('error', anything));
      nothingHappened();
    }, skip: skip);
  });

  group('what a script can do to get round that', () {
    test('forging the host or notation changes only what the script itself sees', () async {
      final r = await runtime('''
        const api = notation;
        try { globalThis.__host = async () => JSON.stringify({ value: 'forged' }); } catch (e) {}
        try { api.note.get = async () => 'forged'; } catch (e) {}
        try { api.note = { get: async () => 'forged' }; } catch (e) {}
        try { Object.defineProperty(globalThis, 'notation', { value: { tool: api.tool } }); } catch (e) {}
        api.tool('a', async () => { try { return JSON.stringify(await api.note.get()); } catch (e) { return 'error: ' + e.message; } });
      ''').run('tool', 'a', {});
      expect(r.value, allOf(startsWith('error: '), contains('did not ask')), reason: 'error=\${r.error}');
      nothingHappened();
    }, skip: skip);

    test('the way out through the language is closed: Function, eval, import, constructors', () async {
      final r = await runtime('''
        notation.tool('a', async () => {
          const seen = [];
          const probe = (label, fn) => { try { seen.push(label + '=' + String(fn())); } catch (e) { seen.push(label + '=threw'); } };
          const g = (0, eval)('this');
          probe('eval-require', () => typeof g.require);
          probe('eval-process', () => typeof g.process);
          probe('eval-std', () => typeof g.std);
          probe('eval-os', () => typeof g.os);
          probe('Function-fetch', () => new Function('return typeof fetch')());
          probe('Function-module', () => new Function('return typeof module')());
          probe('ctor-process', () => typeof (function () {}).constructor('return this')().process);
          probe('globalThis-keys', () => Object.getOwnPropertyNames(globalThis).filter((k) => /^(std|os|fs|http|net|socket|Deno|Bun|Dart|dart|flutter)/i.test(k)).join('|'));
          try { await import('os'); seen.push('import-os=loaded'); } catch (e) { seen.push('import-os=refused'); }
          try { await import('std'); seen.push('import-std=loaded'); } catch (e) { seen.push('import-std=refused'); }
          try { await import('file:///etc/passwd'); seen.push('import-file=loaded'); } catch (e) { seen.push('import-file=refused'); }
          return seen.join(',');
        });
      ''').run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      final seen = '${r.value}';
      expect(seen, isNot(contains('loaded')));
      for (final k in ['eval-require', 'eval-process', 'eval-std', 'eval-os']) {
        expect(seen, contains('$k=undefined'));
      }
      expect(seen, contains('Function-fetch=undefined'));
      expect(seen, contains('Function-module=undefined'));
      expect(seen, contains('ctor-process=undefined'));
      expect(seen, contains('globalThis-keys='), reason: seen);
      expect(RegExp(r'globalThis-keys=([^,]+)').firstMatch(seen)?.group(1) ?? '', isEmpty, reason: seen);
      nothingHappened();
    }, skip: skip);

    test('the network: only the listed website, however the address is written', () async {
      const mustFail = [
        'https://api.example.com@evil.org/',
        'https://api.example.com:443@evil.org/',
        'https://evil.org/?x=api.example.com',
        'https://evil.org/#@api.example.com',
        'https://api.example.com./',
        'https://api.example.com.evil.org/',
        'https://evil.org\\@api.example.com/',
        'https://api.example.com%2eevil.org/',
        'https://127.0.0.1/',
        'https://[::1]/',
        'https://localhost:8080/',
        'http://api.example.com/',
        'ftp://api.example.com/',
        'file:///etc/passwd',
        '//api.example.com/',
        'api.example.com',
        ' https://evil.org/',
      ];
      for (final url in mustFail) {
        final r = await runtime(
          "notation.tool('a', async () => { try { await notation.network.fetch(${jsonEncode(url)}); return 'sent'; } catch (e) { return 'refused'; } });",
          asked: {ExtensionPermission.network},
        ).run('tool', 'a', {});
        expect(r.value, 'refused', reason: url);
      }
      expect(fetched, isEmpty);
      for (final url in ['https://API.Example.COM/x', 'https://api.example.com:8443/x']) {
        final r = await runtime("notation.tool('a', async () => (await notation.network.fetch(${jsonEncode(url)})).body);", asked: {ExtensionPermission.network}).run('tool', 'a', {});
        expect(r.value, 'ok', reason: url);
      }
      expect(fetched.map((u) => u.host), everyElement('api.example.com'));
    }, skip: skip);

    test('an event it did not list, and data that is not an object, are refused', () async {
      final r = await runtime('''
        notation.tool('a', async () => {
          const out = [];
          for (const [name, data] of [['other', {}], ['ext:other/ping', {}], ['ping', 'text'], ['ping', [1]], ['ping', null]]) {
            try { await notation.events.emit(name, data); out.push('sent'); } catch (e) { out.push('refused'); }
          }
          return out.join(',');
        });
      ''', asked: {ExtensionPermission.eventsEmit}).run('tool', 'a', {});
      expect(r.value, 'refused,refused,refused,refused,refused');
      expect(emitted, isEmpty);
    }, skip: skip);
  });

  group('in the app', () {
    late Directory dir;
    late EventBus bus;
    late ExtensionService service;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sandbox');
      bus = EventBus();
      service = ExtensionService((k) async => null, (k, v) async {}, directory: () async => Directory('${dir.path}/ext'), bus: bus, addTask: (t, d) async => api.calls.add('task'));
    });
    tearDown(() => dir.delete(recursive: true));

    Future<InstalledExtension> install(String id, String script, {List<String> permissions = const [], bool on = true, bool grant = true}) async {
      final events = permissions.contains('events.emit') ? ', "events": [{"id": "ping", "title": "Ping"}]' : '';
      await service.installSource(
          '{"id": "$id", "name": "$id", "version": "1", "permissions": ${jsonEncode(permissions)}, "actions": [{"id": "go", "title": "Go"}]$events}', script);
      if (on) await service.setEnabled(id, true);
      if (grant) {
        for (final p in permissions) {
          await service.setGranted(id, ExtensionPermission.byId(p)!, true);
        }
      }
      return service.byId(id)!;
    }

    Future<String> go(InstalledExtension e, {_Api? place}) => service.runAction(e, e.manifest.actions.single, event: const {}, api: place ?? api);

    test('a permission taken back stops working at the next run', () async {
      final e = await install('revoke', "notation.action('go', async () => { await notation.tasks.add('x'); return 'added'; });", permissions: ['tasks.add']);
      expect(await go(e), 'added');
      expect(api.calls, ['task']);
      await service.setGranted('revoke', ExtensionPermission.tasks, false);
      expect(await go(e), allOf(startsWith('Failed:'), contains('was not given')));
      expect(api.calls, ['task'], reason: 'nothing more');
    }, skip: skip);

    test('one that is switched off does not run, even when something asks it to', () async {
      final e = await install('off', "notation.action('go', async () => { await notation.tasks.add('x'); return 'ran'; });", permissions: ['tasks.add'], on: false);
      expect(await go(e), allOf(startsWith('Failed:'), contains('switched off')));
      expect(api.calls, isEmpty);
      await service.setEnabled('off', true);
      expect(await go(e), 'ran');
    }, skip: skip);

    test('what one extension keeps, another cannot read', () async {
      final a = await install('keeper', "notation.action('go', async () => { await notation.storage.set('secret', 'mine'); return 'kept'; });");
      final b = await install('snoop', "notation.action('go', async () => JSON.stringify([await notation.storage.get('secret'), await notation.storage.get('../keeper/secret'), await notation.storage.get('keeper')]));");
      expect(await go(a), 'kept');
      expect(await go(b), '[null,null,null]');
    }, skip: skip);

    test('announcing an event needs the permission in JavaScript too, and works with it', () async {
      final heard = <String>[];
      bus.listen((e) => heard.add(e.type));
      const script = "notation.action('go', async () => { try { await notation.events.emit('ping', {n: 1}); return 'sent'; } catch (e) { return 'refused: ' + e.message; } });";
      final without = await install('quiet', script, permissions: ['events.emit'], grant: false);
      expect(await go(without), allOf(startsWith('refused'), contains('was not given')));
      await Future<void>.delayed(Duration.zero);
      expect(heard, isEmpty);
      final allowed = await install('loud', script, permissions: ['events.emit']);
      expect(await go(allowed), 'sent');
      await Future<void>.delayed(Duration.zero);
      expect(heard, ['ext:loud/ping']);
    }, skip: skip);
  });
}
