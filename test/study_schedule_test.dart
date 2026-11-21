import 'package:flutter_test/flutter_test.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_schedule.dart';

void main() {
  group('the material in parts', () {
    test('a PDF with a table of contents: one part per chapter, from its page to the page before the next', () {
      final outline = <PageHeading>[
        (title: 'Cells', level: 1, page: 4),
        (title: 'Membranes', level: 2, page: 6),
        (title: 'Genetics', level: 1, page: 20),
        (title: 'Evolution', level: 1, page: 41),
      ];
      final units = unitsFromOutline('n', outline, 60)!;
      expect([for (final u in units) u.title], ['Pages 1-4', 'Cells', 'Genetics', 'Evolution'], reason: 'four pages before the first chapter are a part');
      expect([for (final u in units) (u.fromPage, u.toPage)], [(0, 3), (4, 19), (20, 40), (41, 59)]);
      expect(units[1].minutes, (16 * minutesPerPdfPage).round());
      expect(units.map((u) => u.id).toSet(), hasLength(4));
    });

    test('a book whose only top heading is its title is cut by the chapters under it; headings on one page are one part', () {
      final outline = <PageHeading>[
        (title: 'Biology', level: 1, page: 0),
        (title: 'One', level: 2, page: 1),
        (title: 'Two', level: 2, page: 5),
        (title: 'Two b', level: 2, page: 5),
        (title: 'Three', level: 2, page: 9),
      ];
      final units = unitsFromOutline('n', outline, 12)!;
      expect([for (final u in units) u.title], ['Biology', 'One', 'Two, Two b', 'Three']);
      expect([for (final u in units) (u.fromPage, u.toPage)], [(0, 0), (1, 4), (5, 8), (9, 11)]);
    });

    test('no table of contents (or one heading): even runs of about half an hour', () {
      expect(unitsFromOutline('n', const [(title: 'Only', level: 1, page: 0)], 30), isNull);
      final units = unitsFromPages('n', 30);
      expect(units.first.title, 'Pages 1-8');
      expect(units.last.toPage, 29);
      expect(units.fold<int>(0, (n, u) => n + u.pageCount), 30);
      expect(unitsFromPages('n', 0), isEmpty);
      expect(unitsFromPages('n', 1).single.title, 'Page 1');
    });

    test('a written document: a part per heading, its words give the minutes; text before the first heading counts once it is long', () {
      final words = List.filled(400, 'word').join(' ');
      final text = '${List.filled(60, 'intro').join(' ')}\n# Heat\n$words\n## Detail\nmore words here\n# Work\n$words\n# Empty\n';
      final units = unitsFromText('n', text, lead: 'Physics');
      expect([for (final u in units) u.title], ['Physics', 'Heat', 'Work'], reason: 'a heading with nothing under it is no part; ## stays in its # part');
      expect(units[1].minutes, 4);
      expect(units[1].hasPages, isFalse);
      expect(unitsFromText('n', 'too short'), isEmpty);
      final long = List.filled(9000, 'word').join(' ');
      expect([for (final u in unitsFromText('n', long, lead: 'Notes')) u.title], ['Notes (1/3)', 'Notes (2/3)', 'Notes (3/3)']);
      expect(unitsFromText('n', '```\n# not a heading\n```\n$words', lead: 'Notes').single.title, 'Notes');
    });

    test('a note: its PDF, its document and its handwritten pages; a locked note gives nothing', () {
      final words = List.filled(300, 'word').join(' ');
      final units = unitsOfNote(NoteShape(noteId: 'n', title: 'Lecture', pdfPages: 8, documentText: words, notebookPages: 14));
      expect([for (final u in units) u.title], ['Pages 1-8', 'Lecture', 'Pages 9-14']);
      expect(units.map((u) => u.id).toSet(), hasLength(3));
      expect(unitsOfNote(const NoteShape(noteId: 'n', pdfPages: 8, locked: true)), isEmpty);
    });

    test('how hard a part is sets its time; a part is read back as it was kept', () {
      const u = StudyUnit(id: 'n#0', noteId: 'n', title: 'Cells', fromPage: 2, toPage: 9, minutes: 40);
      expect(u.learnMinutes, 40);
      expect(u.copyWith(difficulty: Difficulty.hard).learnMinutes, 60);
      expect(u.copyWith(difficulty: Difficulty.easy).learnMinutes, 28);
      expect(u.reviewMinutes, 14);
      final back = StudyUnit.fromJson(u.copyWith(difficulty: Difficulty.hard, included: false).toJson())!;
      expect((back.title, back.fromPage, back.toPage, back.minutes, back.difficulty, back.included), ('Cells', 2, 9, 40, Difficulty.hard, false));
      expect(StudyUnit.fromJson({'id': 1}), isNull);
    });
  });

  group('the sessions', () {
    // Monday 1 June 2026, 8 o'clock
    final now = DateTime(2026, 6, 1, 8);
    const evenings = StudyWindow(16 * 60, 20 * 60);
    List<StudyUnit> chapters(int n, {int minutes = 60, int pages = 10}) =>
        [for (var i = 0; i < n; i++) StudyUnit(id: 'u$i', noteId: 'n', title: 'Chapter ${i + 1}', fromPage: i * pages, toPage: i * pages + pages - 1, minutes: minutes)];
    int total(StudySchedule s, WorkKind kind) => s.sessions.expand((x) => x.items).where((i) => i.kind == kind).fold(0, (n, i) => n + i.minutes);

    test('free time is the window without the events and a buffer around them, from the next quarter hour today', () {
      final day = DateTime(2026, 6, 1);
      final busy = <Busy>[(start: DateTime(2026, 6, 1, 17), end: DateTime(2026, 6, 1, 18))];
      expect(freeStretches(day, evenings, busy), [(960, 1010), (1090, 1200)]);
      expect(freeStretches(day, evenings, busy, notBefore: DateTime(2026, 6, 1, 16, 5), buffer: 0), [(975, 1020), (1080, 1200)]);
      expect(freeStretches(day, evenings, const [], notBefore: DateTime(2026, 6, 1, 21)), isEmpty);
      final slots = sessionSlots(day, StudyTime.daily(evenings, maxPerDay: 120, sessionLength: 45), busy);
      expect([for (final (s, m) in slots) (s.hour, s.minute, m)], [(16, 0, 45), (18, 10, 45), (19, 10, 30)], reason: 'a break after each, at most 120 minutes');
    });

    test('everything is learnt, then gone over, spread over the time rather than crammed into the first days', () {
      final units = chapters(4); // 4 x 60 learning + 4 x 21 going over
      final s = scheduleStudy(now: now, exam: DateTime(2026, 6, 15), units: units, time: StudyTime.daily(evenings));
      expect(s.fits, isTrue);
      expect(total(s, WorkKind.learn), 240);
      expect(total(s, WorkKind.review), 84);
      final days = s.sessions.where((x) => x.items.every((i) => i.kind != WorkKind.lastLook)).map((x) => DateTime(x.start.year, x.start.month, x.start.day)).toSet();
      expect(days.length, greaterThan(7), reason: 'about 324 minutes over 14 days: not all in the first three');
      expect(days.last.isAfter(DateTime(2026, 6, 10)), isTrue);
      // learning comes before going over
      final kinds = [for (final x in s.sessions) for (final i in x.items) if (i.kind == WorkKind.learn || i.kind == WorkKind.review) i.kind];
      expect(kinds.indexOf(WorkKind.review), greaterThan(kinds.lastIndexOf(WorkKind.learn)));
      // each unit is covered once whole, in pages
      for (final u in units) {
        final shares = [for (final x in s.sessions) for (final i in x.items) if (i.kind == WorkKind.learn && i.unitId == u.id) i];
        expect(shares.first.from, 0);
        expect(shares.last.to, closeTo(1, 1e-6));
        for (var k = 1; k < shares.length; k++) {
          expect(shares[k].from, closeTo(shares[k - 1].to, 1e-6));
        }
        for (final i in shares) {
          expect((i.to * 10 - (i.to * 10).round()).abs(), lessThan(1e-6), reason: 'whole pages');
        }
      }
      // the last look on the exam day
      final last = s.sessions.last;
      expect((last.start, last.items.single.kind), (DateTime(2026, 6, 15, 16), WorkKind.lastLook));
      // no session is longer than set, none outside the window, none overlap
      for (final x in s.sessions) {
        expect(x.minutes, lessThanOrEqualTo(45));
        expect(x.start.hour, greaterThanOrEqualTo(16));
        expect(x.end.isAfter(DateTime(x.start.year, x.start.month, x.start.day, 20)), isFalse);
      }
      expect(s.sessions.map((x) => x.key).toSet(), hasLength(s.sessions.length));
    });

    test('events, days off and the minutes a day are kept to', () {
      final busy = <Busy>[for (var d = 1; d <= 14; d++) (start: DateTime(2026, 6, d, 16), end: DateTime(2026, 6, d, 18))];
      final s = scheduleStudy(
        now: now,
        exam: DateTime(2026, 6, 15),
        units: chapters(8),
        time: StudyTime.daily(evenings, daysOff: {6, 7}, maxPerDay: 60),
        busy: busy,
      );
      for (final x in s.sessions.where((x) => x.items.first.kind != WorkKind.lastLook)) {
        expect(x.start.weekday, lessThan(6), reason: 'no session at the weekend');
        expect(x.start.isBefore(DateTime(x.start.year, x.start.month, x.start.day, 18, 10)), isFalse, reason: 'after the event and its buffer');
      }
      final perDay = <DateTime, int>{};
      for (final x in s.sessions) {
        final d = DateTime(x.start.year, x.start.month, x.start.day);
        perDay[d] = (perDay[d] ?? 0) + x.minutes;
      }
      expect(perDay.values.every((m) => m <= 60), isTrue);
    });

    test('too little time: the going over is given up first, then what cannot be learnt is said', () {
      // (5 minutes a page: the sessions hold whole pages without a minute left over)
      final short = scheduleStudy(now: now, exam: DateTime(2026, 6, 3), units: chapters(2, pages: 12), time: StudyTime.daily(evenings, maxPerDay: 60));
      expect(short.available, 120);
      expect(short.learnLeftOver, 0);
      expect(short.reviewLeftOver, 42, reason: '120 minutes hold the 120 of learning, none of the going over');
      final shorter = scheduleStudy(now: now, exam: DateTime(2026, 6, 3), units: chapters(4, pages: 12), time: StudyTime.daily(evenings, maxPerDay: 60));
      expect(shorter.fits, isFalse);
      expect(shorter.learnLeftOver, 120);
      expect(shorter.unitsLeftOver, ['u2', 'u3']);
      expect(shorter.needed, 4 * 60 + 4 * 21);
    });

    test('what is done already is not planned again; cards come first in a day; the exam time leaves the last look early', () {
      final units = chapters(2);
      final s = scheduleStudy(
        now: now,
        exam: DateTime(2026, 6, 4),
        examTime: 18 * 60,
        units: units,
        progress: {'u0': (learned: 1.0, reviewed: 0.0), 'u1': (learned: 0.5, reviewed: 0.0)},
        time: StudyTime.daily(evenings),
        cardMinutes: {DateTime(2026, 6, 1): 10, DateTime(2026, 6, 2): 10},
      );
      final learn = [for (final x in s.sessions) for (final i in x.items) if (i.kind == WorkKind.learn) i];
      expect(learn.every((i) => i.unitId == 'u1'), isTrue);
      expect(learn.first.from, 0.5);
      expect(total(s, WorkKind.learn), 30);
      final monday = s.sessions.firstWhere((x) => x.start.day == 1);
      expect(monday.items.first.kind, WorkKind.cards);
      expect(s.sessions.last.items.single.kind, WorkKind.lastLook);
      expect(s.sessions.last.start, DateTime(2026, 6, 4, 16), reason: 'the window opens at 16:00; the exam at 18:00 leaves the hour before it free');
      expect(scheduleStudy(now: now, exam: DateTime(2026, 6, 4), examTime: 16 * 60 + 30, units: units, time: StudyTime.daily(evenings)).sessions.where((x) => x.items.first.kind == WorkKind.lastLook), isEmpty,
          reason: 'no time left before the exam');
      expect(scheduleStudy(now: now, exam: DateTime(2026, 5, 30), units: units, time: StudyTime.daily(evenings)).sessions, isEmpty);
    });

    test('what a session says', () {
      final units = {for (final u in chapters(3)) u.id: u};
      final s = PlannedSession(DateTime(2026, 6, 1, 16), 45, [
        const SessionItem(WorkKind.cards, minutes: 10),
        const SessionItem(WorkKind.learn, unitId: 'u0', from: 0.5, to: 1, minutes: 30),
        const SessionItem(WorkKind.review, unitId: 'u1', minutes: 5),
      ]);
      expect(sessionTitleOf('Biology', s, (id) => units[id]), 'Biology: Chapter 1 and 1 more');
      expect(itemText(s.items[1], units['u0']), 'Learn: Chapter 1 (Pages 6-10)');
      expect(itemText(s.items[2], units['u1']), 'Go over: Chapter 2');
      expect(itemText(s.items[0], null), 'Flashcards that are due (about 10 min)');
      expect(s.key, '2026-06-01T1600');
      expect(SessionItem.fromJson(s.items[1].toJson()), s.items[1]);
    });
  });
}
