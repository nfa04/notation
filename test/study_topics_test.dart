import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_topics.dart';

import 'support/fake_model.dart';

void main() {
  group('the answer of the model', () {
    test('parts that follow each other are read as they are (pages count from 1 in the answer)', () {
      const reply = '1-4 | Cell structure\n5-9 | The membrane\n10-12 | Transport';
      expect(parseTopicSplit(reply, 0, 11, maxPages: 24), [
        (from: 0, to: 3, name: 'Cell structure'),
        (from: 4, to: 8, name: 'The membrane'),
        (from: 9, to: 11, name: 'Transport'),
      ]);
    });

    test('gaps go to the part before, overlaps to the part that came first, the ends are the run\'s; other lines are left out', () {
      const reply = 'Here are the parts:\n'
          '- Pages 2–5: "Osmosis"\n'
          '4-8 | Diffusion.\n'
          '11 | A single page\n'
          '9-9 | \n'
          '30-40 | Not in the run\n';
      expect(parseTopicSplit(reply, 0, 13, maxPages: 24), [
        (from: 0, to: 4, name: 'Osmosis'),
        (from: 5, to: 9, name: 'Diffusion'),
        (from: 10, to: 13, name: 'A single page'),
      ]);
      expect(parseTopicSplit('I cannot do that.', 0, 9, maxPages: 24), isNull);
    });

    test('a run that does not start at the first page is read in its own page numbers, and a part too long is cut evenly', () {
      expect(parseTopicSplit('21-50 | Genetics', 20, 49, maxPages: 12), [
        (from: 20, to: 29, name: 'Genetics (1)'),
        (from: 30, to: 39, name: 'Genetics (2)'),
        (from: 40, to: 49, name: 'Genetics (3)'),
      ]);
    });

    test('the request shows each page with the start of its text, and says the longest a part may be', () {
      final p = topicSplitPrompt([(page: 4, text: 'Mitosis'), (page: 5, text: '')], maxPages: 9);
      expect(p.user, 'Page 5: Mitosis\nPage 6: (no text)');
      expect(p.system, contains('between 1 and 9 pages'));
      expect(p.exact, isTrue);
    });
  });

  group('cutting the pages', () {
    // a note of 24 pages without a table of contents: three runs of 8 pages, the middle one hard and half learned
    final units = [
      for (final u in unitsFromPages('n', 24)) u.id == 'n#1' ? u.copyWith(difficulty: Difficulty.hard) : u,
      const StudyUnit(id: 'n#3', noteId: 'n', title: 'Summary', minutes: 10),
    ];
    final progress = {'n#1': (learned: 0.5, reviewed: 0.0), 'n#3': (learned: 1.0, reviewed: 0.0)};
    Map<int, String> pages({int upTo = 24}) => {for (var p = 0; p < upTo; p++) p: 'Text of page ${p + 1} about something long enough'};

    test('the runs of pages are cut where the model says; time, difficulty and progress go with the pages', () async {
      expect(units.where((u) => u.plain).length, 3);
      final model = FakeModel('1-6 | Cells\n7-14 | Membranes\n15-24 | Transport');
      final splitter = StudyTopicSplitter(pageTexts: (_) async => pages(), model: () => model, enabled: () => true);
      expect(StudyTopicSplitter.canSplit(units, 'n'), isTrue);
      final r = await splitter.split(units, progress, 'n');
      expect([for (final u in r.units) u.title], ['Cells', 'Membranes', 'Transport', 'Summary']);
      expect([for (final u in r.units.take(3)) (u.fromPage, u.toPage)], [(0, 5), (6, 13), (14, 23)]);
      expect(r.units.take(3).every((u) => !u.plain), isTrue);
      expect([for (final u in r.units.take(3)) u.minutes], [24, 32, 40], reason: '4 minutes a page, as before');
      expect(r.units[1].difficulty, Difficulty.hard, reason: 'most of its pages were hard');
      expect(r.units[0].difficulty, Difficulty.medium);
      // pages 9-16 were half learned: Membranes has 6 of its 8 pages in there, Transport 2 of 10
      expect(r.progress['n#p6']!.learned, closeTo(6 * 0.5 / 8, 1e-9));
      expect(r.progress['n#p14']!.learned, closeTo(2 * 0.5 / 10, 1e-9));
      expect(r.progress.containsKey('n#p0'), isFalse);
      expect(r.progress.containsKey('n#1'), isFalse);
      expect(r.progress['n#3'], (learned: 1.0, reviewed: 0.0), reason: 'what is not a run of pages is not touched');
      expect(StudyTopicSplitter.canSplit(r.units, 'n'), isFalse);
      expect(model.prompts.single.user, startsWith('Page 1: Text of page 1'));
    });

    test('long runs are asked about in pieces; a topic going on into the next piece stays one part', () async {
      final many = unitsFromPages('n', 60);
      final model = FakeModel()
        ..respond = (p) => p.user.startsWith('Page 1:') ? '1-24 | Basics\n25-34 | Cells\n35-40 | Proteins' : '41-48 | Proteins\n49-60 | Enzymes';
      final splitter = StudyTopicSplitter(pageTexts: (_) async => pages(upTo: 60), model: () => model, enabled: () => true);
      final r = await splitter.split(many, const {}, 'n');
      expect(model.prompts.length, 2);
      expect([for (final u in r.units) (u.title, u.fromPage, u.toPage)], [('Basics', 0, 23), ('Cells', 24, 33), ('Proteins', 34, 47), ('Enzymes', 48, 59)]);
    });

    test('without a model, without text on the pages, or with an answer that cannot be read, nothing changes and it is said why', () async {
      final model = FakeModel('nonsense');
      final off = StudyTopicSplitter(pageTexts: (_) async => pages(), model: () => model, enabled: () => false);
      expect(off.ready, isFalse);
      await expectLater(off.split(units, progress, 'n'), throwsA(isA<StateError>()));
      model.current = ProviderStateForTest.notReady;
      final unready = StudyTopicSplitter(pageTexts: (_) async => pages(), model: () => model, enabled: () => true);
      await expectLater(unready.split(units, progress, 'n'), throwsA(isA<StateError>()));
      model.current = ProviderState.ready;
      final unread = StudyTopicSplitter(pageTexts: (_) async => {0: 'A page'}, model: () => model, enabled: () => true);
      await expectLater(unread.split(units, progress, 'n'), throwsA(predicate((e) => '$e'.contains('too little text'))));
      expect(model.prompts, isEmpty, reason: 'nothing is asked about pages that were not read');
      final garbled = StudyTopicSplitter(pageTexts: (_) async => pages(), model: () => model, enabled: () => true);
      await expectLater(garbled.split(units, progress, 'n'), throwsA(predicate((e) => '$e'.contains('could not be read'))));
    });

    test('stopped part of the way, the runs not cut yet stay as they were', () async {
      final cancel = AiCancel();
      // (two runs: pages 1-8 and 11-18)
      const two = [
        StudyUnit(id: 'a', noteId: 'n', title: 'Pages 1-8', fromPage: 0, toPage: 7, minutes: 32, plain: true),
        StudyUnit(id: 'b', noteId: 'n', title: 'Pages 11-18', fromPage: 10, toPage: 17, minutes: 32, plain: true),
      ];
      expect(plainRuns(two, 'n').length, 2);
      final model = FakeModel()
        ..respond = (p) {
          cancel.cancel();
          return '1-8 | Start';
        };
      final splitter = StudyTopicSplitter(pageTexts: (_) async => pages(), model: () => model, enabled: () => true);
      final r = await splitter.split(two, const {}, 'n', cancel: cancel);
      expect(r.units, two, reason: 'cancelled while the first answer came: kept as it was');
    });
  });
}
