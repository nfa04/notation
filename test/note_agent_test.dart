import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/assistant_chat.dart';
import 'package:notes/ai/document_index.dart';
import 'package:notes/ai/note_agent.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/note_format.dart';
import 'package:notes/markdown/markdown_formatting.dart' show decideChanges;
import 'package:notes/models/rich_text.dart';

import 'support/fake_model.dart';

RichInlineTextController text(String t) => RichInlineTextController()..text = t;

NoteFormat fmt(Map<String, Object?> json) => NoteFormat.fromJson(json);

/// A note in memory: the API an assistant works on in these tests.
class _Note extends ExtensionApi {
  final RichInlineTextController body;
  String title = 'Biology';
  final tasks = <String>[];
  _Note(String t) : body = text(t);

  @override
  Future<Map<String, Object?>> note() async => {'id': 'n', 'title': title, 'text': body.text};
  @override
  Future<void> insertText(String t) async => body.text = '${body.text}\n$t';
  @override
  Future<int> replaceText(String find, String replacement, {bool all = false}) async => replaceNoteText([body], find, replacement, all: all);
  @override
  Future<String> formatText(Map<String, Object?> options) async => formatNoteText([body], NoteFormat.fromJson(options));
  @override
  Future<void> setTitle(String t) async => title = t;
  @override
  Future<void> addTask(String t, {String? due}) async => tasks.add('$t|$due');

  @override
  Future<int> resolveChanges({required bool accept}) async {
    final edits = decideChanges(body.text, accept: accept);
    body.replaceRanges(edits);
    return edits.length;
  }

  final pageNames = ['one', 'two', 'three'];
  final taskRows = <Map<String, Object?>>[
    {'id': 't1', 'title': 'Buy milk', 'due': '2026-12-24', 'done': false},
    {'id': 't2', 'title': 'Call Sam', 'due': null, 'done': true},
  ];
  @override
  Future<List<Map<String, Object?>>> pages() async => [
        for (var i = 0; i < pageNames.length; i++) {'page': i + 1, 'kind': 'notebook', 'strokes': i, 'textBoxes': 0, 'images': 0},
      ];
  @override
  Future<int> addPage({int? at}) async {
    pageNames.insert((at ?? pageNames.length + 1) - 1, 'new');
    return at ?? pageNames.length;
  }

  @override
  Future<void> deletePage(int page) async => pageNames.removeAt(page - 1);
  @override
  Future<void> movePage(int page, int to) async => pageNames.insert(to - 1, pageNames.removeAt(page - 1));
  @override
  Future<List<Map<String, Object?>>> listTasks({bool? done}) async => [for (final t in taskRows) if (done == null || t['done'] == done) t];
  @override
  Future<void> completeTask(String id, {bool done = true}) async => taskRows.firstWhere((t) => t['id'] == id)['done'] = done;
  @override
  Future<void> updateTask(String id, {String? title, String? due, bool setDue = false}) async {
    final t = taskRows.firstWhere((t) => t['id'] == id);
    if (title != null) t['title'] = title;
    if (setDue) t['due'] = due;
  }

  @override
  Future<void> removeTask(String id) async => taskRows.removeWhere((t) => t['id'] == id);
}

void main() {
  group('formatting', () {
    test('a quoted phrase gets bold marks, and asking again changes nothing', () {
      final c = text('One\nSome important words here\nThree');
      expect(formatNoteText([c], fmt({'target': 'important words', 'bold': true})), startsWith('Done'));
      expect(c.text, 'One\nSome **important words** here\nThree');
      expect(formatNoteText([c], fmt({'target': 'important words', 'bold': true})), startsWith('Nothing changed'));
      expect(c.text, 'One\nSome **important words** here\nThree');
      formatNoteText([c], fmt({'target': 'important words', 'bold': false}));
      expect(c.text, 'One\nSome important words here\nThree');
    });

    test('a line becomes a heading, a list, a quote; a paragraph takes it away again', () {
      final c = text('Intro\n\nfirst\nsecond');
      formatNoteText([c], fmt({'target': 'Intro', 'block': 'heading2'}));
      formatNoteText([c], fmt({'target': 'second', 'block': 'bullet'}));
      formatNoteText([c], fmt({'target': 'first', 'block': 'bullet'}));
      expect(c.text, '## Intro\n\n- first\n- second');
      formatNoteText([c], fmt({'target': 'Intro', 'block': 'paragraph'}));
      expect(c.text, 'Intro\n\n- first\n- second');
    });

    test('everything: blank lines, tables and code are left alone, numbering restarts after a gap', () {
      final c = text('a\nb\n\n| x | y |\n|---|---|\n\n```\ncode\n```\nc');
      formatNoteText([c], fmt({'target': 'all', 'block': 'numbered', 'bold': true}));
      expect(c.text, '1. **a**\n2. **b**\n\n| x | y |\n|---|---|\n\n```\ncode\n```\n1. **c**');
    });

    test('bold goes inside a heading mark, and a quote is found through the marks', () {
      final c = text('## Cell **membrane** and wall');
      formatNoteText([c], fmt({'target': 'Cell membrane and wall', 'italic': true}));
      expect(c.text, startsWith('## *Cell'));
      expect(formatNoteText([c], fmt({'target': 'MEMBRANE', 'underline': true})), startsWith('Done'));
      expect(c.attributes.single.type, AttributeType.underline);
    });

    test('colour, size, font and the layout of the paragraph', () {
      final c = text('Title line\nbody');
      formatNoteText([c], fmt({'target': 'Title line', 'color': 'red', 'size': 20, 'font': 'serif', 'align': 'center', 'spacing': 1.5}));
      expect(c.text, startsWith('{align=center spacing=1.5}Title line'));
      expect(c.attributes.map((a) => (a.start, a.end)).toSet(), {(26, 36)});
      expect(c.attributes.map((a) => (a.type, a.value)), containsAll([(AttributeType.color, '#D32F2F'), (AttributeType.size, '20'), (AttributeType.font, 'Serif')]));
      formatNoteText([c], fmt({'target': 'Title line', 'color': 'none'}));
      expect(c.attributes.any((a) => a.type == AttributeType.color), isFalse);
    });

    test('the formatting stays on the text when words around it are replaced', () {
      final c = text('keep this and change that');
      formatNoteText([c], fmt({'target': 'keep this', 'underline': true}));
      replaceNoteText([c], 'change that', 'swap it');
      expect(c.text, 'keep this and swap it');
      expect(c.attributes.single.end, 9);
    });

    test('raised text, lowered text and the yellow highlight are Markdown, as the bar writes them', () {
      final c = text('H2O is a big molecule');
      formatNoteText([c], fmt({'target': '2', 'subscript': true}));
      expect(c.text, 'H~2~O is a big molecule');
      formatNoteText([c], fmt({'target': '2', 'superscript': true}));
      expect(c.text, 'H^2^O is a big molecule');
      formatNoteText([c], fmt({'target': 'big molecule', 'superscript': true}));
      expect(c.text, 'H^2^O is a big molecule');
      expect(c.attributes.single.type, AttributeType.superscript);
      formatNoteText([c], fmt({'target': 'is a', 'highlight': 'yellow'}));
      expect(c.text, 'H^2^O ==is a== big molecule');
      formatNoteText([c], fmt({'target': 'is a', 'highlight': 'none'}));
      expect(c.text, 'H^2^O is a big molecule');
    });

    test('"like" copies the formatting of other text: the kind of line, the looks, the marks, the layout of the paragraph', () {
      final c = text('## Cell **membrane**\n{align=center}Wall of plants\nlast line');
      formatNoteText([c], fmt({'target': 'Cell', 'color': 'red', 'size': 20, 'font': 'serif', 'underline': true}));
      formatNoteText([c], fmt({'target': 'Wall of plants', 'align': 'center'}));
      // the last line becomes what the heading is: the same kind of line, colour, size, font, underline; and bold only where the reference is
      formatNoteText([c], fmt({'target': 'last line', 'like': 'Cell'}));
      expect(c.text, endsWith('\n## last line'));
      final looks = c.attributes.where((a) => c.text.substring(a.start, a.end).contains('last line')).map((a) => '${a.type.name}=${a.value}').toSet();
      expect(looks, {'color=#D32F2F', 'size=20', 'font=Serif', 'underline=null'});
      // like a centred plain line: no heading mark, centred, and the looks of the reference taken off
      formatNoteText([c], fmt({'target': 'Cell', 'like': 'Wall of plants'}));
      expect(c.text, startsWith('{align=center}Cell **membrane**'));
      expect(c.attributes.where((a) => c.text.substring(a.start, a.end).contains('Cell')).map((a) => a.type), isNot(contains(AttributeType.color)));
      // what else is asked for changes what was copied
      formatNoteText([c], fmt({'target': 'last line', 'like': 'Wall of plants', 'bold': true, 'align': 'right'}));
      expect(c.text, endsWith('{align=right}**last line**'));
      expect(() => formatNoteText([c], fmt({'target': 'last line', 'like': 'not there'})), throwsA(isA<ExtensionError>().having((e) => e.message, 'm', contains('copy the formatting from'))));
    });

    test('the formatting can be looked at: lines as written, and the looks Markdown cannot say', () {
      final c = text('# Title\nplain **bold** words\n{align=center}Centred');
      formatNoteText([c], fmt({'target': 'Title', 'color': '#112233', 'font': 'mono'}));
      formatNoteText([c], fmt({'target': 'words', 'size': 16, 'underline': true}));
      final all = describeNoteFormatting([c], ['The written document']);
      expect(all, contains('== The written document =='));
      expect(all, contains('1| # Title'));
      expect(all, contains('2| plain **bold** words'));
      expect(all, contains('3| {align=center}Centred'));
      expect(all, contains('"Title": color=#112233'));
      expect(all, contains('"Title": font=Mono'));
      expect(all, contains('"words": size=16'));
      expect(all, contains('"words": underline'));
      final one = describeNoteFormatting([c], ['d'], target: 'words');
      expect(one, contains('2| plain **bold** words'));
      expect(one, isNot(contains('1| # Title')));
      expect(one, isNot(contains('Centred')));
      expect(() => describeNoteFormatting([c], ['d'], target: 'missing'), throwsA(isA<ExtensionError>()));
      expect(() => describeNoteFormatting([text('')], ['d']), throwsA(isA<ExtensionError>()));
    });

    test('text goes after or before a line, or at the start', () {
      final c = text('Intro\nBody line\nEnd');
      insertNoteText([c], 'New one', after: 'Body');
      expect(c.text, 'Intro\nBody line\nNew one\nEnd');
      insertNoteText([c], 'First', before: 'Intro');
      insertNoteText([c], 'Last', after: 'End');
      expect(c.text, 'First\nIntro\nBody line\nNew one\nEnd\nLast');
      insertNoteText([c], 'Zero', atStart: true);
      expect(c.text, startsWith('Zero\nFirst\n'));
      expect(() => insertNoteText([c], 'x', after: 'nowhere'), throwsA(isA<ExtensionError>()));
    });

    test('selection and clear', () {
      final c = text('a **b** c');
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
      formatNoteText([c], fmt({'target': 'selection', 'clear': true}));
      expect(c.text, 'a b c');
      c.selection = const TextSelection.collapsed(offset: 1);
      expect(() => formatNoteText([c], fmt({'target': 'selection', 'bold': true})), throwsA(isA<ExtensionError>()));
    });

    test('what cannot be done is said', () {
      final c = text('hello');
      expect(() => formatNoteText([c], fmt({'target': 'missing', 'bold': true})), throwsA(isA<ExtensionError>().having((e) => e.message, 'm', contains('not in the note'))));
      expect(() => formatNoteText([text('  ')], fmt({'target': 'all', 'bold': true})), throwsA(isA<ExtensionError>()));
      expect(() => fmt({'target': 'all'}), throwsA(isA<ExtensionError>()));
      expect(() => fmt({'target': 'all', 'glow': true}), throwsA(isA<ExtensionError>().having((e) => e.message, 'm', contains('Unknown formatting'))));
      expect(() => fmt({'target': 'all', 'bold': 'yes'}), throwsA(isA<ExtensionError>()));
      expect(() => fmt({'target': 'all', 'block': 'heading9'}), throwsA(isA<ExtensionError>()));
      expect(() => fmt({'target': 'all', 'size': 400}), throwsA(isA<ExtensionError>()));
    });

    test('replace: first, everywhere, and not there', () {
      final c = text('cat dog cat');
      expect(replaceNoteText([c], 'cat', 'fox'), 1);
      expect(c.text, 'fox dog cat');
      expect(replaceNoteText([c], 'o', '0', all: true), 2);
      expect(c.text, 'f0x d0g cat');
      expect(() => replaceNoteText([c], 'zebra', 'x'), throwsA(isA<ExtensionError>()));
    });
  });

  group('reading the calls', () {
    test('tags, trailing text, braces inside strings, several calls', () {
      final calls = parseToolCalls('Sure.\n<tool>{"name":"note.replaceText","args":{"find":"a}b","replacement":"c"}}</tool> and <tool_call>{"name":"note.get","args":{}}</tool_call>');
      expect(calls.map((c) => c.name), ['note.replaceText', 'note.get']);
      expect(calls.first.args['find'], 'a}b');
    });

    test('a bare or fenced call counts, prose and broken calls do not', () {
      expect(parseToolCalls('```json\n{"name":"note.get","args":{}}\n```').single.name, 'note.get');
      expect(parseToolCalls('{"name":"note.get"}').single.name, 'note.get');
      expect(parseToolCalls('The answer is {"x": 1}.'), isEmpty);
      expect(parseToolCalls('<tool>{"name":"note.get", "args": {</tool>').single.error, isNotNull);
    });

    test('a long text with real line breaks in it is read', () {
      final call = parseToolCalls('<tool>{"name":"note.insertText","args":{"text":"# ARMv8\n\n- one\n\t- two \\"quoted\\""}}</tool>');
      expect(call.single.error, isNull);
      expect(call.single.args['text'], '# ARMv8\n\n- one\n\t- two "quoted"');
    });

    test('small slips in a call are taken as meant, and a call that cannot be says what it had', () async {
      final note = _Note('x');
      Future<String> run(String reply, {bool describe = true}) async {
        final call = parseToolCalls(reply).single;
        final tool = agentTools.firstWhere((t) => t.name == call.name);
        tool.describe(call.args);
        return tool.run(note, call.args);
      }

      await run('<tool>{"name":"note.insertText","text":"flat"}</tool>');
      await run('<tool>{"name":"note.insertText","args":{"content":"renamed"}}</tool>');
      await run('<tool>{"name":"note.insertText","args":{"text":["one","two"]}}</tool>');
      expect(note.body.text, 'x\nflat\nrenamed\none\ntwo');
      final tool = agentTools.firstWhere((t) => t.name == 'note.insertText');
      expect(() => tool.describe({'text': 3, 'other': 'a'}), throwsA(isA<ExtensionError>().having((e) => e.message, 'm', allOf(contains('text (int)'), contains('other (text)')))));
    });

    test('the person does not see the calls being written', () {
      expect(visibleAnswer('Let me format that.<tool>{"name":'), 'Let me format that.');
    });
  });

  group('the assistant acting', () {
    late FakeModel model;
    late _Note note;
    late AssistantChat chat;
    late List<String> replies;

    String call(String name, Map<String, Object?> args) => '<tool>{"name":"$name","args":${_json(args)}}</tool>';

    setUp(() {
      note = _Note('Intro\nThe mitochondria is the powerhouse.');
      replies = [];
      model = FakeModel()..respond = (_) => replies.removeAt(0);
      chat = AssistantChat(
        ai: AiService(providers: [model]),
        index: () async => DocumentIndex(chunkText('Page 1', 0, note.body.text)),
        agent: NoteAgent(api: note, copies: () => [scratchCopy(note.body)]),
      )..acting = true;
    });

    test('what a change would do is shown while the person is asked, and nothing is changed by it', () async {
      replies = [call('note.replaceText', {'find': 'powerhouse', 'replacement': 'engine'}), call('note.format', {'target': 'Intro', 'block': 'heading1'}), 'Done.'];
      final done = chat.ask('Reword and head');
      await pumpEventQueue();
      final first = chat.messages.last.steps.single;
      expect(first.state, AgentStepState.asking);
      expect(first.preview!.lines.join('|'), '  Intro|- The mitochondria is the powerhouse.|+ The mitochondria is the engine.');
      expect(note.body.text, contains('powerhouse'), reason: 'looking is not doing');
      chat.decide(AgentChoice.once);
      await pumpEventQueue();
      final second = chat.messages.last.steps.last;
      expect(second.preview!.lines.join('|'), '- Intro|+ # Intro|  The mitochondria is the engine.');
      chat.decide(AgentChoice.deny);
      await done;
      expect(note.body.text, 'Intro\nThe mitochondria is the engine.');
    });

    test('a version is kept before and after each change of the note, and for nothing else', () async {
      final log = <String>[];
      chat = AssistantChat(
        ai: AiService(providers: [model]),
        index: () async => DocumentIndex(chunkText('Page 1', 0, note.body.text)),
        agent: NoteAgent(
          api: note,
          copies: () => [scratchCopy(note.body)],
          beforeChange: (what) async => log.add('before: $what | ${note.body.text.contains('powerhouse') ? 'old' : 'new'}'),
          afterChange: (what) async => log.add('after: $what | ${note.body.text.contains('powerhouse') ? 'old' : 'new'}'),
        ),
      )..acting = true;
      replies = [
        call('note.get', {}),
        call('note.replaceText', {'find': 'powerhouse', 'replacement': 'engine'}),
        call('tasks.add', {'title': 'Read chapter 2'}),
        call('note.setTitle', {'title': ''}),
        'Done.',
      ];
      final done = chat.ask('Do it');
      for (var i = 0; i < 4; i++) {
        await pumpEventQueue();
        chat.decide(AgentChoice.always);
      }
      await done;
      expect(log, [
        'before: Replace "powerhouse" | old',
        'after: Replace "powerhouse" | new',
      ], reason: 'not for reading, tasks, or a call that failed before it began');
    });

    test('pages are looked at freely, changed after asking and with versions; tasks are asked about, even to look at', () async {
      final log = <String>[];
      chat = AssistantChat(
        ai: AiService(providers: [model]),
        index: () async => DocumentIndex(chunkText('Page 1', 0, note.body.text)),
        agent: NoteAgent(api: note, beforeChange: (what) async => log.add('before: $what'), afterChange: (what) async => log.add('after: $what')),
      )..acting = true;
      replies = [
        call('pages.list', {}),
        call('pages.move', {'page': '3', 'to': 1.0}),
        call('pages.delete', {'page': 2}),
        call('pages.add', {'at': 2}),
        call('pages.delete', {'page': 'x'}),
        call('tasks.list', {'done': false}),
        call('tasks.complete', {'id': 't1'}),
        call('tasks.update', {'id': 't2', 'title': 'Call Sam back', 'due': ''}),
        'Done.',
      ];
      final done = chat.ask('Tidy up');
      await pumpEventQueue();
      expect(chat.messages.last.steps.map((s) => s.state), [AgentStepState.done, AgentStepState.asking], reason: 'listing pages is only reading: the first to ask about is the move');
      final seen = <String>[];
      for (var i = 0; i < 6; i++) {
        seen.add(chat.messages.last.steps.last.action.summary);
        chat.decide(AgentChoice.once);
        await pumpEventQueue();
      }
      await done;
      expect(seen, [
        'Move page 3 to page 1',
        'Delete page 2 with everything on it',
        'Add a blank page as page 2',
        'Look at your tasks',
        'Tick off the task t1',
        'Change the task t2',
      ]);
      expect(note.pageNames, ['three', 'new', 'two']);
      expect(note.taskRows, [
        {'id': 't1', 'title': 'Buy milk', 'due': '2026-12-24', 'done': true},
        {'id': 't2', 'title': 'Call Sam back', 'due': null, 'done': true},
      ]);
      expect(log, [
        'before: Move page 3 to page 1',
        'after: Move page 3 to page 1',
        'before: Delete page 2 with everything on it',
        'after: Delete page 2 with everything on it',
        'before: Add a blank page as page 2',
        'after: Add a blank page as page 2',
      ], reason: 'a version for each change of the pages, none for tasks, and none for the page number that was not one');
      expect(chat.messages.last.steps.where((s) => s.state == AgentStepState.failed).length, 1);
    });

    test('tracked changes are settled after the person has seen what would be left', () async {
      note = _Note('Intro\nThe {--old--}{++new++} word and {++an addition++}.');
      chat = AssistantChat(
        ai: AiService(providers: [model]),
        index: () async => DocumentIndex(chunkText('Page 1', 0, note.body.text)),
        agent: NoteAgent(api: note, copies: () => [scratchCopy(note.body)]),
      )..acting = true;
      replies = [call('note.resolveChanges', {'accept': false}), call('note.resolveChanges', {'accept': true}), 'Done.'];
      final done = chat.ask('Reject the suggestions, then accept them');
      await pumpEventQueue();
      final first = chat.messages.last.steps.last;
      expect(first.action.summary, 'Reject all tracked changes');
      expect(first.preview!.lines.join('|'), '  Intro|- The {--old--}{++new++} word and {++an addition++}.|+ The old word and .');
      chat.decide(AgentChoice.once);
      await pumpEventQueue();
      expect(note.body.text, 'Intro\nThe old word and .');
      // (nothing is left to settle the second time)
      expect(chat.messages.last.steps.last.state, AgentStepState.failed);
      await done;
    });

    test('a change that cannot be done is not asked about', () async {
      replies = [call('note.replaceText', {'find': 'not in the note', 'replacement': 'x'}), 'Could not.'];
      await chat.ask('Reword');
      expect(chat.messages.last.steps.single.state, AgentStepState.failed);
      expect(chat.messages.last.steps.single.result, contains('not in the note'));
    });

    test('it asks first; allowing lets it work, and it is told what came of it', () async {
      replies = [call('note.format', {'target': 'Intro', 'block': 'heading1'}), 'Made it a heading.'];
      final done = chat.ask('Make Intro a heading');
      await pumpEventQueue();
      final step = chat.messages.last.steps.single;
      expect(step.state, AgentStepState.asking);
      expect(step.action.summary, contains('Intro'));
      expect(note.body.text, startsWith('Intro'), reason: 'nothing happens before the answer');
      chat.decide(AgentChoice.once);
      await done;
      expect(note.body.text, startsWith('# Intro'));
      expect(step.state, AgentStepState.done);
      expect(chat.messages.last.text, 'Made it a heading.');
      expect(model.prompts.first.system, contains('note.format'));
      expect(model.prompts.first.user, contains('Request: Make Intro a heading'));
      expect(model.prompts.last.user, contains('Done: formatted'));
      expect(model.prompts.last.history.first.text, contains('Request:'));
    });

    test('"allow for this chat" is asked only once; a new conversation asks again', () async {
      replies = [
        call('note.setTitle', {'title': 'Cells'}),
        call('note.replaceText', {'find': 'powerhouse', 'replacement': 'engine'}),
        'Both done.',
      ];
      final done = chat.ask('Retitle and reword');
      await pumpEventQueue();
      chat.decide(AgentChoice.always);
      await done;
      expect(note.title, 'Cells');
      expect(note.body.text, contains('engine'));
      expect(chat.messages.last.steps.map((s) => s.state), [AgentStepState.done, AgentStepState.done]);
      chat.clear();
      replies = [call('note.setTitle', {'title': 'Again'}), 'ok'];
      final again = chat.ask('Retitle');
      await pumpEventQueue();
      expect(chat.messages.last.steps.single.state, AgentStepState.asking);
      chat.decide(AgentChoice.deny);
      await again;
      expect(note.title, 'Cells');
    });

    test('a refusal changes nothing and the model is told not to go on', () async {
      replies = [call('note.replaceText', {'find': 'mitochondria', 'replacement': 'ribosome'}), 'I did not change it.'];
      final done = chat.ask('Reword');
      await pumpEventQueue();
      chat.decide(AgentChoice.deny);
      await done;
      expect(note.body.text, contains('mitochondria'));
      expect(chat.messages.last.steps.single.state, AgentStepState.refused);
      expect(model.prompts.last.user, contains('did not allow'));
    });

    test('reading needs no asking; a failed call is reported to the model, which may try again', () async {
      replies = [
        call('note.get', {}),
        call('note.format', {'target': 'nonsense text', 'bold': true}),
        call('note.format', {'target': 'powerhouse', 'bold': true}),
        'Bolded.',
      ];
      final done = chat.ask('Bold the powerhouse');
      await pumpEventQueue();
      expect(chat.messages.last.steps.map((s) => s.state), [AgentStepState.done, AgentStepState.failed, AgentStepState.asking], reason: 'the doomed change was not asked about');
      chat.decide(AgentChoice.always);
      await done;
      final steps = chat.messages.last.steps;
      expect(steps.map((s) => s.state), [AgentStepState.done, AgentStepState.failed, AgentStepState.done]);
      expect(steps[1].result, contains('not in the note'));
      expect(note.body.text, contains('**powerhouse**'));
    });

    test('a bad call, an unknown tool and a repeated call are answered without asking', () async {
      replies = [
        '<tool>{"name":"note.format","args":{"target":"Intro"}}</tool>',
        call('network.fetch', {'url': 'https://example.com'}),
        'Could not.',
      ];
      await chat.ask('Do things');
      expect(chat.messages.last.steps.map((s) => s.state), [AgentStepState.failed, AgentStepState.failed], reason: 'what went wrong is shown');
      expect(chat.messages.last.steps.first.result, contains('Say what to change'));
      expect(model.prompts.last.user, contains('there is no tool "network.fetch"'));
      expect(model.prompts[1].user, contains('Say what to change'));
    });

    test('a model that never stops is stopped, and stop() answers a question that is open with no', () async {
      model.respond = (_) => call('note.get', {'again': DateTime.now().microsecondsSinceEpoch});
      await chat.ask('Loop');
      expect(chat.messages.last.text, contains('stopped after'));

      replies = [call('note.setTitle', {'title': 'X'}), 'unreachable'];
      model.respond = (_) => replies.removeAt(0);
      final done = chat.ask('Retitle');
      await pumpEventQueue();
      chat.stop();
      await done;
      expect(note.title, 'Biology');
      expect(chat.busy, isFalse);
    });

    group('with a service that takes tools', () {
      late _ToolModel tools;

      setUp(() {
        tools = _ToolModel();
        chat = AssistantChat(
          ai: AiService(providers: [tools]),
          index: () async => DocumentIndex(chunkText('Page 1', 0, note.body.text)),
          agent: NoteAgent(api: note),
        )..acting = true;
      });

      test('the tools go with the request, the answers to the calls come back under their ids, no text protocol is used', () async {
        tools.replies = [
          const AiToolReply('', [AiToolCall('id1', 'note_insertText', {'text': '# Greek\n\nhistory'}), AiToolCall('id2', 'note_setTitle', {'title': 'Greece'})]),
          const AiToolReply('Added it and renamed the note.'),
        ];
        final done = chat.ask('Add a summary of Greek history');
        await pumpEventQueue();
        chat.decide(AgentChoice.always);
        await done;
        expect(note.body.text, endsWith('# Greek\n\nhistory'));
        expect(note.title, 'Greece');
        expect(chat.messages.last.text, 'Added it and renamed the note.');
        expect(chat.messages.last.steps.map((s) => s.state), [AgentStepState.done, AgentStepState.done]);
        final first = tools.prompts.first;
        expect(first.system, isNot(contains('<tool>')));
        expect(tools.specs.first.map((t) => t.name), containsAll(['note_get', 'note_insertText', 'note_replaceText', 'note_format', 'note_setTitle', 'tasks_add', 'clipboard_write']));
        expect(tools.specs.first.firstWhere((t) => t.name == 'note_format').parameters!['required'], ['target']);
        final second = tools.prompts.last;
        expect(second.user, isEmpty);
        expect(second.history.where((t) => t.calls.isNotEmpty).single.calls.map((c) => c.id), ['id1', 'id2']);
        expect(second.history.where((t) => t.resultOf != null).map((t) => t.resultOf), ['id1', 'id2']);
      });

      test('a call that is broken or has no such tool is answered under its id too', () async {
        tools.replies = [
          const AiToolReply('', [AiToolCall('a', 'note_insertText', {}, error: 'The arguments were not a JSON object.'), AiToolCall('b', 'web_search', {'q': 'x'})]),
          const AiToolReply('Could not.'),
        ];
        await chat.ask('Do things');
        expect(chat.messages.last.steps.map((s) => s.state), [AgentStepState.failed, AgentStepState.failed]);
        final answers = tools.prompts.last.history.where((t) => t.resultOf != null).toList();
        expect(answers.map((t) => t.resultOf), ['a', 'b']);
        expect(answers.first.text, contains('not a JSON object'));
        expect(answers.last.text, contains('no tool'));
      });

      test('a service that takes no tools gets the calls as text instead, and is not asked with tools again', () async {
        tools.refuse = true;
        tools.replies = [AiToolReply('<tool>{"name":"note.setTitle","args":{"title":"Text"}}</tool>'), const AiToolReply('Retitled.')];
        final done = chat.ask('Retitle');
        await pumpEventQueue();
        chat.decide(AgentChoice.once);
        await done;
        expect(note.title, 'Text');
        expect(tools.prompts.first.system, contains('<tool>'));
        expect(tools.specs.length, 1, reason: 'only the one refused request had tools');
      });
    });

    test('only answering: the model gets no tools and nothing is asked', () async {
      chat.acting = false;
      replies = ['It is the powerhouse.'];
      await chat.ask('What is it?');
      expect(model.prompts.single.system, isNot(contains('note.format')));
      expect(chat.messages.last.steps, isEmpty);
    });
  });
}

String _json(Map<String, Object?> m) => '{${m.entries.map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}').join(',')}}';

/// A model that takes tools with the request: answers with [replies], one for each request.
class _ToolModel extends FakeModel implements ToolCalling {
  List<AiToolReply> replies = [];
  final specs = <List<AiToolSpec>>[];
  bool refuse = false;

  @override
  Future<AiToolReply> completeWithTools(AiPrompt prompt, List<AiToolSpec> tools, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    specs.add(tools);
    if (refuse) throw ToolsNotSupported('this model does not support tools');
    prompts.add(prompt);
    return replies.removeAt(0);
  }

  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    return replies.removeAt(0).text;
  }
}
