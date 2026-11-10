import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/note_ai.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Answering extends ChangeNotifier implements TextModelProvider {
  _Answering(this.answer);
  String answer;
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => '';
  @override
  ProviderState get state => ProviderState.ready;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    calls++;
    onPartial?.call(answer);
    return answer;
  }
}

const _slides = '''# Cells
## What a cell is
- The smallest unit of life
- Has a membrane
> Start with the basics.
## Mitochondria
- Make ATP
## Summary
- Cells are the base of biology
''';

const _quiz = '''Q: Which organelle makes ATP?
A) Nucleus
B) Mitochondrion
C) Ribosome
D) Vacuole
Answer: B
Why: Mitochondria produce the energy.

Q: Where is the DNA?
A) In the nucleus
B) In the membrane
Answer: A
''';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('slides, questions and tasks are read from what a model wrote', () {
    final p = parseSlides(_slides);
    expect(p.title, 'Cells');
    expect(p.slides.map((s) => s.title), ['What a cell is', 'Mitochondria', 'Summary']);
    expect(p.slides.first.bullets, ['The smallest unit of life', 'Has a membrane']);
    expect(p.slides.first.notes, 'Start with the basics.');

    final q = parseQuiz(_quiz);
    expect(q, hasLength(2));
    expect(q.first.choices[q.first.answer], 'Mitochondrion');
    expect(q.first.why, contains('energy'));
    expect(q.last.answer, 0);

    final a = parseActions('- Hand in the report (due: 2026-11-05)\n- [ ] Read chapter 3\nNone\nSome intro text');
    expect(a.map((x) => x.title), ['Hand in the report', 'Read chapter 3']);
    expect(a.first.due, DateTime(2026, 11, 5));
    expect(a.last.due, isNull);
    expect(parseActions('None'), isEmpty);
  });

  test('what the AI made is kept: made once, again on request, and it travels in the note file', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote(title: 'Cells');
    final note = (await repo.loadNote(id))!;
    note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(10, 10), initialText: 'Mitochondria make ATP. The nucleus holds the DNA.')];
    await repo.saveNote(note);

    final provider = _Answering(_slides);
    final noteAi = NoteAi(repo, AiService(providers: [provider]));
    final first = await noteAi.get(id, NoteAiKind.presentation);
    expect(first.content, _slides.trim());
    expect(provider.calls, 1);

    await noteAi.get(id, NoteAiKind.presentation); // from the note, not from the model
    expect(provider.calls, 1);

    expect(await noteAi.isStale(first), isFalse);
    final changed = (await repo.loadNote(id))!;
    changed.textBoxes[0]!.first.controller.text = 'Something else entirely.';
    await repo.saveNote(changed);
    expect(await noteAi.isStale((await noteAi.saved(id, NoteAiKind.presentation))!), isTrue);

    provider.answer = '# Again\n## One\n- a\n## Two\n- b';
    await noteAi.get(id, NoteAiKind.presentation, again: true);
    expect(provider.calls, 2);
    expect(parseSlides((await noteAi.saved(id, NoteAiKind.presentation))!.content).title, 'Again');

    provider.answer = 'not a quiz';
    expect(() => noteAi.get(id, NoteAiKind.quiz), throwsStateError);
    expect(await noteAi.saved(id, NoteAiKind.quiz), isNull);

    // the file carries it
    final dir = await Directory.systemTemp.createTemp('note_ai_');
    addTearDown(() => dir.delete(recursive: true));
    final files = NoteFileService(repo, supportDirectory: () async => dir);
    final bytes = (await files.exportBytes(id))!;
    final copy = await files.importBytes(bytes);
    final carried = await repo.ai.get(copy.noteId, 'presentation');
    expect(carried, isNotNull);
    expect(parseSlides(carried!.content).title, 'Again');
    expect(carried.sourceHash, (await noteAi.saved(id, NoteAiKind.presentation))!.sourceHash);
  });
}
