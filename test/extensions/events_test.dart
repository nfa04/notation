import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An engine whose "script" announces events: each call of [calls] goes to the app like `notation.events.emit` would.
class _EmitEngine implements ScriptEngine {
  static List<(String, Object?)> calls = [];
  late FutureOr<Object?> Function(List<Object?>) _host;

  @override
  void register(String name, FutureOr<Object?> Function(List<Object?> args) fn) => _host = fn;
  @override
  void eval(String code, {String filename = 'script'}) {}
  @override
  Future<Object?> evalAsync(String code, {String filename = 'script', Duration? timeout}) async {
    Object? last = jsonEncode({'value': null});
    for (final c in calls) {
      last = await _host(['events.emit', jsonEncode({'event': c.$1, 'data': c.$2})]);
    }
    return last;
  }

  @override
  void dispose() {}
}

class _Api extends ExtensionApi {}

const _manifest = '''{
  "id": "pinger", "name": "Pinger", "version": "1",
  "permissions": ["events.emit"],
  "events": [{ "id": "ping", "title": "A ping" }],
  "actions": [{ "id": "go", "title": "Go" }]
}''';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the manifest', () {
    Map<String, Object?> base({Object? events, Object? permissions}) => {
          'id': 'pinger', 'name': 'P', 'version': '1',
          'permissions': permissions ?? ['events.emit'],
          'events': events ?? [{'id': 'ping', 'title': 'A ping'}],
        };

    test('lists events, which need the permission, and the permission needs events', () {
      final m = ExtensionManifest.fromJson(base());
      expect(m.events.single.id, 'ping');
      expect(ExtensionManifest.fromJson(ExtensionManifest.fromJson(base()).toJson()).events.single.title, 'A ping');
      expect(() => ExtensionManifest.fromJson(base(permissions: [])), throwsA(isA<ManifestException>()));
      expect(() => ExtensionManifest.fromJson(base(events: [])), throwsA(isA<ManifestException>()));
      expect(() => ExtensionManifest.fromJson(base(events: [{'id': 'a', 'title': 'A'}, {'id': 'a', 'title': 'B'}])), throwsA(isA<ManifestException>()));
      expect(() => ExtensionManifest.fromJson(base(events: [{'id': 'No Spaces', 'title': 'A'}])), throwsA(isA<ManifestException>()));
    });
  });

  group('announcing', () {
    late Directory dir;
    late EventBus bus;
    late ExtensionService extensions;
    late List<AppEvent> heard;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('extevents');
      bus = EventBus();
      heard = [];
      bus.listen(heard.add);
      _EmitEngine.calls = [];
      extensions = ExtensionService((k) async => null, (k, v) async {},
          directory: () async => Directory('${dir.path}/ext'), engine: ({onConsole}) => _EmitEngine(), bus: bus);
      await extensions.installSource(_manifest, 'notation.action("go", () => 1);');
    });
    tearDown(() => dir.delete(recursive: true));

    Future<String> go([Map<String, Object?> context = const {}]) {
      final e = extensions.byId('pinger')!;
      return extensions.runAction(e, e.manifest.actions.single, event: context, api: _Api());
    }

    test('its events are known only while it is on and may announce them', () async {
      expect(bus.type('ext:pinger/ping'), isNull);
      await extensions.setEnabled('pinger', true);
      expect(bus.type('ext:pinger/ping'), isNull); // (not given the permission yet)
      await extensions.setGranted('pinger', ExtensionPermission.eventsEmit, true);
      expect(bus.type('ext:pinger/ping')!.label, 'Pinger: A ping');
      await extensions.setEnabled('pinger', false);
      expect(bus.type('ext:pinger/ping'), isNull);
      await extensions.setEnabled('pinger', true);
      await extensions.remove('pinger');
      expect(bus.type('ext:pinger/ping'), isNull);
    });

    test('an event it announces is namespaced and carries its data', () async {
      await extensions.setEnabled('pinger', true);
      await extensions.setGranted('pinger', ExtensionPermission.eventsEmit, true);
      _EmitEngine.calls = [('ping', {'n': 3})];
      expect(await go(), 'Done');
      await Future<void>.delayed(Duration.zero);
      expect(heard.single.type, 'ext:pinger/ping');
      expect(heard.single.data, {'n': 3});
    });

    test('what it did not list, did not get permission for, or makes too big is refused', () async {
      await extensions.setEnabled('pinger', true);
      _EmitEngine.calls = [('ping', {})];
      expect(await go(), allOf(startsWith('Failed:'), contains('events.emit'))); // not given
      await extensions.setGranted('pinger', ExtensionPermission.eventsEmit, true);
      _EmitEngine.calls = [('other', {})];
      expect(await go(), allOf(startsWith('Failed:'), contains('did not list')));
      _EmitEngine.calls = [('ping', {'big': 'x' * 9000})];
      expect(await go(), allOf(startsWith('Failed:'), contains('too big')));
      await Future<void>.delayed(Duration.zero);
      expect(heard, isEmpty);
    });

    test('it cannot announce the event it is reacting to, nor flood', () async {
      await extensions.setEnabled('pinger', true);
      await extensions.setGranted('pinger', ExtensionPermission.eventsEmit, true);
      _EmitEngine.calls = [('ping', {})];
      expect(await go({'event': 'ext:pinger/ping'}), allOf(startsWith('Failed:'), contains('reacting')));
      expect(heard, isEmpty);
      _EmitEngine.calls = [for (var i = 0; i < 21; i++) ('ping', {'i': i})];
      expect(await go(), allOf(startsWith('Failed:'), contains('Too many')));
      await Future<void>.delayed(Duration.zero);
      expect(heard, hasLength(20));
    });
  });

  test('an automation reacts to an event that an extension announces', () async {
    final dir = await Directory.systemTemp.createTemp('extevents2');
    addTearDown(() => dir.delete(recursive: true));
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('tasks');
    final tasks = TaskRepository(db);
    final bus = EventBus();
    final extensions = ExtensionService((k) async => null, (k, v) async {},
        directory: () async => Directory('${dir.path}/ext'), engine: ({onConsole}) => _EmitEngine(), bus: bus);
    final service = AutomationService(NoteRepository(db), tasks, extensions: extensions, bus: bus);
    await service.load();
    addTearDown(service.dispose);
    await extensions.installSource(_manifest, 'notation.action("go", () => 1);');
    await extensions.setEnabled('pinger', true);
    await extensions.setGranted('pinger', ExtensionPermission.eventsEmit, true);

    expect(service.events.map((e) => e.id), contains('ext:pinger/ping'));
    await service.add(Automation(id: 'r', event: service.events.firstWhere((e) => e.id == 'ext:pinger/ping'), action: AutomationAction.addTask, params: const {'title': 'Pinged'}));

    _EmitEngine.calls = [('ping', {})];
    final e = extensions.byId('pinger')!;
    await extensions.runAction(e, e.manifest.actions.single, event: {}, api: _Api());
    for (var i = 0; i < 40 && (await tasks.listTasks()).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect((await tasks.listTasks()).single.title, 'Pinged');
  });
}
