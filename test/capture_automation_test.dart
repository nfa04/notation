import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/capture/capture_service.dart';
import 'package:notes/citations/citation_repository.dart';
import 'package:notes/citations/citation_service.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/events/event_sources.dart';

import 'support/fake_model.dart';

const _page = '<html><head><title>Plants | Blog</title><meta property="og:site_name" content="Blog"></head><body><article><h1>Plants</h1>'
    '<p>Plants take in carbon dioxide through tiny pores called stomata, and give out oxygen while they do it, every day of their lives.</p>'
    '<p>The leaves are green because chlorophyll absorbs red and blue light and reflects the green light that is left over.</p></article></body></html>';

/// The event is announced without the capture waiting for its rules: they are given a moment.
Future<void> settle(AutomationService s) async {
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await s.assistantDone;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late TagRepository tags;
  late TaskRepository tasks;
  late CitationService citations;
  late CaptureService capture;
  late AutomationService service;
  late FakeModel model;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('capture_automation_');
    final db = await AppDatabase.open(path: '${dir.path}/notes.db');
    repo = NoteRepository(db);
    tags = TagRepository(db);
    tasks = TaskRepository(db);
    citations = CitationService(CitationRepository(SettingsRepository(db)));
    model = FakeModel('Plants breathe through stomata.');
    service = AutomationService(repo, tasks, ai: AiService(providers: [model]), tags: tags, citations: citations);
    await service.load();
    capture = CaptureService(repository: repo, supportDirectory: () async => dir, clock: () => DateTime(2026, 3, 4, 9, 5), fetch: (url) async => _page);
    capture.onCaptured = (c) async {
      final info = await repo.noteInfo(c.noteId);
      await service.bus.emit(AppEvent('captureReceived',
          noteId: c.noteId, title: c.title, folderId: info?.folderId, data: eventVars({'kind': c.kind, 'url': c.url, 'site': c.site})));
    };
  });
  tearDown(() async {
    service.dispose();
    await dir.delete(recursive: true);
  });

  test('what capturing makes says what it was, and where from', () async {
    final seen = <Captured>[];
    capture.onCaptured = seen.add;
    await capture.clipPage(Uri.parse('https://blog.example/plants'));
    await capture.quickNote('Buy flour tomorrow');
    await capture.clipSelection(url: Uri.parse('https://blog.example/x'), title: 'X', text: 'a quote');
    expect(seen.map((c) => c.kind), ['page', 'note', 'clip']);
    expect(seen.first.url, 'https://blog.example/plants');
    expect(seen.first.site, 'Blog');
    expect(seen[1].url, '');
  });

  test('a clipped page is tagged, summarized, and becomes a source, once', () async {
    await service.add(const Automation(id: 't', event: AutomationEvent.captureReceived, action: AutomationAction.addTag, params: {'tag': 'reading/{kind}'}));
    await service.add(const Automation(id: 's', event: AutomationEvent.captureReceived, action: AutomationAction.summarizeToBox));
    await service.add(const Automation(id: 'c', event: AutomationEvent.captureReceived, action: AutomationAction.addCitation));

    final got = await capture.clipPage(Uri.parse('https://blog.example/plants'));
    await settle(service);
    expect(await tags.tagsOf(got.noteId), ['reading/page']);

    final source = citations.sources.single;
    expect(source.type, SourceType.webpage);
    expect(source.title, 'Plants');
    expect(source.url, 'https://blog.example/plants');
    expect(source.container, 'Blog');
    expect(source.accessed, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(service.all.firstWhere((a) => a.id == 'c').lastResult, 'Added to the sources, cited as [@${source.id}]');

    final note = (await repo.loadNote(got.noteId))!;
    expect(note.textBoxes[0]!.single.controller.text, '**Summary**\nPlants breathe through stomata.');
    expect(model.prompts.single.user, contains('stomata'), reason: 'the text of the page is what is summarized');

    // the same page again is no second source
    await capture.clipPage(Uri.parse('https://blog.example/plants'));
    await settle(service);
    expect(citations.sources, hasLength(1));
    expect(service.all.firstWhere((a) => a.id == 'c').lastResult, 'That page is a source already');
  });

  test('a note typed in a moment has no address to cite, and is not tagged as a page', () async {
    await service.add(const Automation(id: 'c', event: AutomationEvent.captureReceived, action: AutomationAction.addCitation));
    await capture.quickNote('Buy flour tomorrow and also some yeast for the bread');
    await settle(service);
    expect(citations.sources, isEmpty);
    expect(service.all.single.lastResult, 'There is no address to cite');
  });

  test('a rule can be for the captured notes of one kind of name, and filing works on them', () {
    expect(AutomationAction.sortIntoFolder.worksAfter(AutomationEvent.captureReceived), isTrue);
    expect(AutomationAction.addCitation.worksAfter(AutomationEvent.captureReceived), isTrue);
    expect(AutomationAction.addCitation.worksAfter(AutomationEvent.noteClosed), isFalse);
    expect(AutomationEvent.captureReceived.hasNote, isTrue);
  });
}
