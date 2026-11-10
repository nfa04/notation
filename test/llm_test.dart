import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/llm/causal_lm.dart';
import 'package:notes/llm/llm_service.dart';
import 'package:notes/llm/qwen_tokenizer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A tiny tokenizer.json: the letters of "hello world" and one merge, plus Qwen's special tokens.
String tinyTokenizer() {
  const letters = ['h', 'e', 'l', 'o', 'Ġ', 'w', 'r', 'd', 'H', 'i'];
  final vocab = {for (var i = 0; i < letters.length; i++) letters[i]: i, 'he': 10, 'll': 11, 'hell': 12, 'hello': 13};
  return jsonEncode({
    'model': {
      'type': 'BPE',
      'vocab': vocab,
      'merges': [
        ['h', 'e'],
        ['l', 'l'],
        ['he', 'll'],
        ['hell', 'o'],
      ],
    },
    'added_tokens': [
      {'id': 100, 'content': '<|endoftext|>', 'special': true},
      {'id': 101, 'content': '<|im_start|>', 'special': true},
      {'id': 102, 'content': '<|im_end|>', 'special': true},
      {'id': 103, 'content': '<think>', 'special': false},
    ],
  });
}

class _FakeLm implements CausalLm {
  final List<List<int>> prompts = [];
  final List<int> prefixes = [];
  final List<int> answer;
  bool closed = false;
  _FakeLm(this.answer);
  @override
  Future<List<int>> generate(
    List<int> prompt, {
    required int maxNewTokens,
    required Set<int> stop,
    int sharedPrefix = 0,
    void Function(List<int> generated)? onProgress,
    bool Function()? shouldStop,
    double repetitionPenalty = 1,
  }) async {
    prompts.add(prompt);
    prefixes.add(sharedPrefix);
    return answer;
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the tokenizer', () {
    final tok = QwenTokenizer.parse(tinyTokenizer());

    test('words are merged as far as the merges go', () {
      expect(tok.encode('hello'), [13]);
      expect(tok.encode('hell'), [12]);
      expect(tok.encode('he'), [10]);
    });

    test('a space is part of the next word', () {
      expect(tok.encode('hello hello'), [13, 4, 13]); // "hello", "Ġ" (the space, a letter of its own here), "hello"
    });

    test('special tokens in the text are one token', () {
      expect(tok.encode('<|im_start|>hello<|im_end|>'), [101, 13, 102]);
      expect(tok.encode('<think>'), [103]);
      expect(tok.idOf('<|im_end|>'), 102);
      expect(tok.idOf('<|nope|>'), isNull);
    });

    test('ids come back as the text, specials left out', () {
      expect(tok.decode([13, 4, 13]), 'hello hello');
      expect(tok.decode([101, 13, 102]), 'hello');
      expect(tok.decode([103, 13]), '<think>hello');
      expect(tok.decode([-1, 9999, 13]), 'hello');
    });
  });

  group('accepting an answer', () {
    test('a tidy title is kept, capitalised', () {
      expect(acceptTitle('office hours.', 'Office hours, Prof. Müller'), 'Office hours');
      expect(acceptTitle('"Midterm exam (room B12)"\nsome more', 'Midterm exam, room B12'), 'Midterm exam (room B12)');
    });

    test('it must be about the input', () {
      expect(acceptTitle('Projektbericht via Moodle', 'Project proposal due via Moodle'), isNull);
      expect(acceptTitle('Library closed for renovation', 'Please note that the library will be closed for renovation'),
          'Library closed for renovation');
      expect(acceptTitle('Register for the exam session', 'Registration deadline for the exam session'), isNotNull);
    });

    test('no dates, nothing empty, nothing long', () {
      expect(acceptTitle('Exam 7.3.2026', 'Exam'), isNull);
      expect(acceptTitle('Exam 2026-03-07', 'Exam'), isNull);
      expect(acceptTitle('  ', 'Exam'), isNull);
      expect(acceptTitle('exam ' * 30, 'exam'), isNull);
    });
  });

  group('the service', () {
    late Directory dir;
    late Map<String, String> downloaded;

    LlmService make({_FakeLm? lm, Duration keep = const Duration(seconds: 30)}) => LlmService(
          open: (path) async => lm ?? _FakeLm([]),
          modelDirectory: () async => dir,
          download: (url, path, progress) async {
            downloaded[url] = path;
            progress(0.5);
            await File(path).writeAsString(url.endsWith('tokenizer.json') ? tinyTokenizer() : 'model');
            progress(1);
          },
          keepLoaded: keep,
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('llm_');
      downloaded = {};
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('it is not installed until both files are there', () async {
      final s = make();
      await s.load();
      expect(s.status, HandwritingStatus.notInstalled);
      expect(await s.shortTitle('Final exam'), isNull); // no model, no answer
      await File('${dir.path}/model_int8.onnx').writeAsString('x');
      await s.load();
      expect(s.status, HandwritingStatus.notInstalled); // the tokenizer is missing
    });

    test('install downloads both files, with progress, and keeps no half files', () async {
      final s = make();
      final seen = <double>[];
      s.addListener(() => seen.add(s.progress));
      await s.load();
      await s.install();
      expect(s.status, HandwritingStatus.installed);
      expect(downloaded.keys.map((u) => u.split('/').last), containsAll(['model_int8.onnx', 'tokenizer.json']));
      expect(seen.any((p) => p > 0 && p < 1), isTrue);
      expect(dir.listSync().map((f) => f.path.split('/').last).toSet(), {'model_int8.onnx', 'tokenizer.json'});
    });

    test('a failing download is reported and leaves nothing behind', () async {
      final s = LlmService(
        modelDirectory: () async => dir,
        download: (url, path, progress) async {
          await File(path).writeAsString('half');
          throw Exception('offline');
        },
      );
      await s.install();
      expect(s.status, HandwritingStatus.notInstalled);
      expect(s.error, contains('offline'));
      expect(dir.listSync(), isEmpty);
    });

    test('the title comes from what the model wrote, and the prompt is the chat format', () async {
      final tok = QwenTokenizer.parse(tinyTokenizer());
      final lm = _FakeLm(tok.encode('hello'));
      final s = make(lm: lm);
      await s.install();
      // the tiny tokenizer only knows a few letters: the answer "hello" is not about the input
      expect(await s.shortTitle('hello hello hello hello'), 'Hello');
      expect(lm.prompts.length, 1);
      expect(await s.shortTitle('Final exam'), isNull); // short enough as it is
      expect(lm.prompts.length, 1);
      expect(lm.prompts.single, isNotEmpty);
      final prompt = LlmService.promptFor('Final exam');
      expect(prompt, startsWith('<|im_start|>system\n'));
      expect(prompt, endsWith('<|im_start|>user\nFinal exam<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'));
      expect('<|im_start|>assistant'.allMatches(prompt).length, 6); // five examples and the question
      // the examples come first and are the same for every question
      final (a, q) = LlmService.promptParts('Final exam');
      expect(LlmService.promptParts('Another line').$1, a);
      expect(a + q, prompt);
      expect(lm.prefixes.single, greaterThan(0));
      expect(lm.prefixes.single, lessThan(lm.prompts.single.length + 1));
    });

    test('requests run one after the other, and the model is freed after a while', () async {
      final lm = _FakeLm(QwenTokenizer.parse(tinyTokenizer()).encode('hello'));
      final s = make(lm: lm, keep: const Duration(milliseconds: 50));
      await s.install();
      await Future.wait([s.shortTitle('hello hello hello hello'), s.shortTitle('hello hello hello hello hello')]);
      expect(lm.prompts.length, 2);
      expect(lm.closed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(lm.closed, isTrue);
    });

    test('removing deletes the files and frees the model', () async {
      final lm = _FakeLm([]);
      final s = make(lm: lm);
      await s.install();
      await s.shortTitle('hello hello hello hello');
      await s.remove();
      expect(s.status, HandwritingStatus.notInstalled);
      expect(dir.existsSync(), isFalse);
      expect(lm.closed, isTrue);
    });

    test('a model that fails gives no title, and is tried again from scratch', () async {
      var opened = 0;
      final s = LlmService(
        open: (_) async {
          opened++;
          throw StateError('out of memory');
        },
        modelDirectory: () async => dir,
        download: (url, path, progress) async =>
            File(path).writeAsString(url.endsWith('tokenizer.json') ? tinyTokenizer() : 'model'),
      );
      await s.install();
      expect(await s.shortTitle('hello hello hello hello'), isNull);
      expect(await s.shortTitle('hello hello hello hello'), isNull);
      expect(opened, 2);
    });
  });

  group('in an automation', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    final today = DateTime(2026, 3, 1);

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key LIKE 'automations%'");
      await db.delete('tasks');
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
    });

    Future<AutomationService> service(Future<String?> Function(String) smart, {bool on = true}) async {
      final s = AutomationService(notes, tasks, now: () => today, smartTitle: smart);
      await s.load();
      await s.add(Automation(
        id: 'd',
        event: AutomationEvent.dateFound,
        action: AutomationAction.addTask,
        params: {'title': '{time} {summary}', if (on) 'smart': '1'},
      ));
      return s;
    }

    _Editor editor() => _Editor(['Final exam: 20 June 2026']);

    test('the model\'s title replaces the summary, and it is given the cleaned line', () async {
      String? asked;
      final s = await service((text) async {
        asked = text;
        return 'Sit the final exam';
      });
      final r = await s.scanForDates(editor(), noteId: 'n');
      expect(r.error, isNull);
      expect(r.results.single, startsWith('Added the task'));
      s.dispose();
      expect(asked, 'Final exam');
      expect((await tasks.listTasks()).single.title, 'Sit the final exam');
    });

    test('without an answer the cleaned line stays', () async {
      final s = await service((_) async => null);
      await s.scanForDates(editor(), noteId: 'n');
      s.dispose();
      expect((await tasks.listTasks()).single.title, 'Final exam');
    });

    test('the model is not asked unless the automation says so', () async {
      var asked = false;
      final s = await service((_) async {
        asked = true;
        return 'x';
      }, on: false);
      await s.scanForDates(editor(), noteId: 'n');
      s.dispose();
      expect(asked, isFalse);
      expect((await tasks.listTasks()).single.title, 'Final exam');
    });
  });
}

class _Editor implements NoteEditorHandle {
  final List<String> lines;
  _Editor(this.lines);
  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async {}
  @override
  String get noteTitle => 'Course';
  @override
  Future<List<String>> pdfTextLines() async => lines;
  @override
  Future<String?> exportPdfTo(String path) async => null;
}
