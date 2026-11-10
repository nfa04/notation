import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/magic_extension.dart';
import 'package:notes/extensions/magic_prompt.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'magic_fakes.dart';

const checklist = "notation.tool('make-list', (ctx) => ctx.text.split('\\n').map((l) => '- [ ] ' + l).join('\\n'));";

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late Map<String, String> settings;
  late ExtensionService extensions;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('magic');
    settings = {};
    extensions = ExtensionService((k) async => settings[k], (k, v) async => settings[k] = v, directory: () async => Directory('${dir.path}/extensions'), engine: ({onConsole}) => ReadingEngine());
  });
  tearDown(() => dir.delete(recursive: true));

  MagicExtension magic(List<String> answers, {int attempts = 3}) => MagicExtension(AiService(providers: [Scripted(answers)]), extensions, attempts: attempts);
  Map<String, Object?> tool({String id = 'checklist', List<String> permissions = const [], List<Map<String, String>> actions = const []}) => {
        'id': id,
        'name': 'Checklist',
        'version': '1.0.0',
        'permissions': permissions,
        'tools': [
          {'id': 'make-list', 'title': 'Make a checklist'}
        ],
        'actions': actions,
      };

  group('reading an answer', () {
    test('the four parts are found by their headings, fences round code are taken off', () {
      final parts = MagicExtension.sections('Sure!\n### manifest.json\n```json\n{"a":1}\n```\n## main.js\ncode\n=== automations ===\nnone\n### Explanation:\nText');
      expect(parts.keys, containsAll(['manifest.json', 'main.js', 'automations', 'explanation']));
      expect(MagicExtension.unfenced(parts['manifest.json']!), '{"a":1}');
      expect(parts['explanation'], 'Text');
      expect(MagicExtension.unfenced('```js\nlet a = 1;\n```'), 'let a = 1;');
      expect(MagicExtension.unfenced('let a = 1;'), 'let a = 1;');
    });

    test('a good answer becomes a draft; a tool that needs nothing asks for nothing', () {
      final d = magic([]).check(answer(manifest: json(tool()), script: checklist));
      expect(d.manifest.id, 'checklist');
      expect(d.manifest.permissions, isEmpty);
      expect(d.manifest.tools.single.id, 'make-list');
      expect(d.automations, isEmpty);
      expect(d.explanation, 'It does a thing.');
    });

    test('small things are put right: the id, the version, a fence round the script, the file name', () {
      final d = magic([]).check(answer(manifest: json({'name': 'My Fancy Tool!', 'tools': [{'id': 'make-list', 'title': 'T'}], 'main': 'index.js'}), script: '```js\n$checklist\n```'));
      expect(d.manifest.id, 'my-fancy-tool');
      expect(d.manifest.version, '1.0.0');
      expect(d.manifest.main, 'main.js');
      expect(d.script, checklist);
    });

    test('a permission the script uses but the manifest forgot is added and told; one that is asked for and not used stays (it is shown)', () {
      const script = "notation.action('remind', async (ctx) => { const n = await notation.note.get(); await notation.tasks.add('x ' + n.title); await notation.clipboard.write('c'); });";
      final d = magic([]).check(answer(
        manifest: json({
          'id': 'remind',
          'name': 'Remind',
          'version': '1.0.0',
          'permissions': ['note.write'],
          'actions': [{'id': 'remind', 'title': 'Remind me'}],
        }),
        script: script,
      ));
      expect(d.manifest.permissions, {ExtensionPermission.noteWrite, ExtensionPermission.noteRead, ExtensionPermission.tasks, ExtensionPermission.clipboard});
      expect(d.added.toSet(), {ExtensionPermission.noteRead, ExtensionPermission.tasks, ExtensionPermission.clipboard});
    });

    test('the network needs hosts: they are taken from the addresses in the script, and without any it is a problem', () {
      const script = "notation.tool('make-list', async (ctx) => (await notation.network.fetch('https://api.example.com/x?q=' + ctx.text)).body);";
      final d = magic([]).check(answer(manifest: json(tool()), script: script));
      expect(d.manifest.permissions, {ExtensionPermission.network});
      expect(d.manifest.hosts, ['api.example.com']);
      expect(() => magic([]).check(answer(manifest: json(tool()), script: "notation.tool('make-list', async (c) => (await notation.network.fetch(url)).body);")), throwsA(isA<MagicProblem>().having((e) => e.message, 'm', contains('hosts'))));
    });

    test('what is wrong is said: parts missing, bad JSON, no handler, nothing to do, a script that does not read', () {
      void problem(String raw, String part) => expect(() => magic([]).check(raw), throwsA(isA<MagicProblem>().having((e) => e.message, 'm', contains(part))), reason: part);
      problem('nothing useful', '### manifest.json');
      problem('### manifest.json\n{"a":1}\n', '### main.js');
      problem(answer(manifest: '{not json', script: checklist), 'valid JSON');
      problem(answer(manifest: json(tool()), script: "notation.tool('other', () => 1);"), 'no handler for the tool "make-list"');
      problem(answer(manifest: json({'id': 'empty', 'name': 'E', 'version': '1'}), script: 'let a = 1;'), 'would do nothing');
      problem(answer(manifest: json(tool(actions: [{'id': 'go', 'title': 'Go'}])), script: checklist), 'no handler for the action "go"');
      problem(answer(manifest: json(tool()), script: '$checklist SYNTAX'), 'script has an error');
      problem(answer(manifest: json({...tool(), 'permissions': ['root']}), script: checklist), 'Unknown permission');
    });

    test('rules for the automations: the event and the action have to exist, weeks default and are checked', () {
      const script = "notation.action('remind', async (ctx) => 'ok');";
      Map<String, Object?> manifest() => {'id': 'remind', 'name': 'R', 'version': '1', 'actions': [{'id': 'remind', 'title': 'Remind'}]};
      final d = magic([]).check(answer(manifest: json(manifest()), script: script, automations: 'event=noteStale action=remind weeks=6 contains=exam,notes\n- event=noteCreated action=remind'));
      expect(d.automations.map((a) => (a.event, a.action, a.weeks, a.contains)), [
        (AutomationEvent.noteStale, 'remind', 6, 'exam,notes'),
        (AutomationEvent.noteCreated, 'remind', null, null),
      ]);
      expect(magic([]).check(answer(manifest: json(manifest()), script: script, automations: 'event=noteStale action=remind')).automations.single.weeks, 4);
      expect(() => magic([]).check(answer(manifest: json(manifest()), script: script, automations: 'event=nonsense action=remind')), throwsA(isA<MagicProblem>()));
      expect(() => magic([]).check(answer(manifest: json(manifest()), script: script, automations: 'event=noteOpened action=missing')), throwsA(isA<MagicProblem>().having((e) => e.message, 'm', contains('missing'))));
      expect(() => magic([]).check(answer(manifest: json(manifest()), script: script, automations: 'event=noteStale action=remind weeks=0')), throwsA(isA<MagicProblem>()));
    });
  });

  group('asking the model', () {
    test('the model is given the API and the request, and nothing else', () async {
      final provider = Scripted([answer(manifest: json(tool()), script: checklist)]);
      final m = MagicExtension(AiService(providers: [provider]), extensions);
      await m.draft('make the selected lines a checklist');
      final prompt = provider.prompts.single;
      expect(prompt.system, magicSystem);
      expect(prompt.user, 'Make this: make the selected lines a checklist');
      expect(prompt.history, isEmpty);
      expect(prompt.exact, isTrue);
    });

    test('a problem is told back and the model tries again; the third failure is an error', () async {
      final provider = Scripted([
        answer(manifest: '{broken', script: checklist),
        answer(manifest: json(tool()), script: "notation.tool('wrong', () => 1);"),
        answer(manifest: json(tool()), script: checklist),
      ]);
      final problems = <String>[];
      final d = await MagicExtension(AiService(providers: [provider]), extensions).draft('a checklist', onProblem: problems.add);
      expect(d.manifest.id, 'checklist');
      expect(problems.length, 2);
      expect(provider.prompts[1].user, contains('That did not work: The manifest is not valid JSON'));
      expect(provider.prompts[1].history.map((t) => t.fromUser), [true, false], reason: 'it is shown its own answer');
      expect(provider.prompts[2].user, contains('no handler for the tool "make-list"'));

      final bad = Scripted([for (var i = 0; i < 3; i++) 'no format at all']);
      await expectLater(MagicExtension(AiService(providers: [bad]), extensions).draft('x'), throwsA(isA<MagicProblem>().having((e) => e.message, 'm', contains('did not make a working extension'))));
      expect(bad.prompts.length, 3);
    });

    test('a change is asked for from the first answer', () async {
      final first = answer(manifest: json(tool()), script: checklist);
      final provider = Scripted([first, answer(manifest: json({...tool(), 'name': 'Checklist 2'}), script: checklist)]);
      final m = MagicExtension(AiService(providers: [provider]), extensions);
      final d1 = await m.draft('a checklist');
      final d2 = await m.draft('a checklist', previous: d1, change: 'call it Checklist 2');
      expect(d2.manifest.name, 'Checklist 2');
      final prompt = provider.prompts.last;
      expect(prompt.user, contains('call it Checklist 2'));
      expect(prompt.history.map((t) => t.text), ['Make this: a checklist', first]);
    });
  });

  group('installing', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService automations;

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'automations'");
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      automations = AutomationService(notes, tasks, extensions: extensions);
      await automations.load();
    });
    tearDown(() => automations.dispose());

    MagicDraft stale() => magic([]).check(answer(
          manifest: json({'id': 'stale', 'name': 'Stale', 'version': '1.0.0', 'actions': [{'id': 'remind', 'title': 'Remind'}]}),
          script: "notation.action('remind', async (ctx) => { await notation.tasks.add('Look at ' + ctx.note.title); return 'ok'; });",
          automations: 'event=noteStale action=remind weeks=6',
        ));

    test('by default it is off, with no permission, and its rule is off', () async {
      final made = await magic([]).install(stale(), automations: automations);
      expect(made, 1);
      final e = extensions.byId('stale')!;
      expect(e.enabled, isFalse);
      expect(e.granted, isEmpty);
      final rule = automations.all.single;
      expect(rule.enabled, isFalse);
      expect(rule.action, AutomationAction.extensionAction);
      expect(rule.params, {'extension': 'stale/remind', 'weeks': '6'});
      expect(rule.event, AutomationEvent.noteStale);
    });

    test('"install and allow" switches it on, gives the permissions that were shown, and its rules are on', () async {
      await magic([]).install(stale(), allow: true, automations: automations);
      final e = extensions.byId('stale')!;
      expect(e.enabled, isTrue);
      expect(e.granted, {ExtensionPermission.tasks});
      expect(automations.all.single.enabled, isTrue);
      expect(extensions.actions.map((a) => a.action.id), ['remind']);
    });

    test('installing again updates it (and adds no second extension)', () async {
      await magic([]).install(stale());
      await magic([]).install(stale());
      expect(extensions.installed.length, 1);
    });
  });

  test('the reference the model is given names every call of the API, and the documentation too', () {
    // what the script can reach is the object in the prelude: every call of it is in the reference for the model and in docs/extensions.md
    final docs = File('docs/extensions.md').readAsStringSync();
    for (final call in [
      'notation.tool',
      'notation.action',
      'notation.drawTool',
      'notation.note.get',
      'notation.note.insertText',
      'notation.note.setTitle',
      'notation.note.replaceText',
      'notation.note.format',
      'notation.note.inspect',
      'notation.pdf.read',
      'notation.pdf.search',
      'notation.note.resolveChanges',
      'notation.notes.favorite',
      'notation.note.addTags',
      'notation.note.moveToFolder',
      'notation.notes.search',
      'notation.notes.read',
      'notation.notes.create',
      'notation.notes.list',
      'notation.notes.move',
      'notation.notes.tag',
      'notation.notes.trash',
      'notation.notes.restore',
      'notation.folders.list',
      'notation.folders.create',
      'notation.folders.rename',
      'notation.selection.replace',
      'notation.tasks.add',
      'notation.tasks.list',
      'notation.reminders.add',
      'notation.reminders.list',
      'notation.reminders.remove',
      'notation.cards.add',
      'notation.calendar.events',
      'notation.calendar.addEvent',
      'notation.tasks.complete',
      'notation.tasks.update',
      'notation.tasks.remove',
      'notation.pages.list',
      'notation.pages.add',
      'notation.pages.delete',
      'notation.pages.move',
      'notation.pages.setup',
      'notation.textBoxes.list',
      'notation.textBoxes.add',
      'notation.textBoxes.move',
      'notation.textBoxes.delete',
      'notation.images.list',
      'notation.images.move',
      'notation.images.delete',
      'notation.draw.shape',
      'notation.draw.strokes',
      'notation.clipboard.write',
      'notation.network.fetch',
      'notation.events.emit',
      'notation.storage.get',
      'notation.storage.set',
      'notation.storage.remove',
      'notation.ui.message',
    ]) {
      expect(docs, contains(call), reason: 'docs: $call');
      expect(magicSystem, contains(call.replaceFirst('notation.storage.set', '.set').replaceFirst('notation.storage.remove', '.remove').replaceFirst('notation.storage.get', 'notation.storage.get')), reason: 'prompt: $call');
    }
    for (final p in ExtensionPermission.values) {
      expect(docs, contains('`${p.id}`'), reason: 'docs: ${p.id}');
      expect(magicSystem, contains(p.id), reason: 'prompt: ${p.id}');
    }
    for (final e in AutomationEvent.values) {
      expect(docs, contains('`${e.name}`'), reason: 'docs: ${e.name}');
      expect(magicSystem, contains(e.name), reason: 'prompt: ${e.name}');
    }
  });
}
