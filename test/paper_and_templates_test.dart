import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/database_schema.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/templates/templates.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  const page = Size(800, 1131);

  group('the paper', () {
    test(
      'music paper has staves of five lines, evenly spaced, inside the margins, with a bar line at each end',
      () {
        final lines = paperLines(PageBackground.staff, page);
        final horizontal = [
          for (final (a, b) in lines)
            if (a.dy == b.dy) (a, b),
        ];
        final bars = [
          for (final (a, b) in lines)
            if (a.dx == b.dx) (a, b),
        ];
        expect(horizontal.length % 5, 0);
        expect(
          horizontal.length ~/ 5,
          greaterThanOrEqualTo(8),
          reason: 'a page holds a good number of staves',
        );
        for (final (a, b) in horizontal) {
          expect(a.dx, staffMargin);
          expect(b.dx, page.width - staffMargin);
          expect(b.dy, lessThanOrEqualTo(page.height - staffMargin + 1e-9));
        }
        for (var s = 0; s < horizontal.length; s += 5) {
          for (var i = 1; i < 5; i++) {
            expect(
              horizontal[s + i].$1.dy - horizontal[s + i - 1].$1.dy,
              staffGap,
            );
          }
          if (s > 0) {
            expect(horizontal[s].$1.dy - horizontal[s - 5].$1.dy, staffPitch);
          }
        }
        expect(
          bars.length,
          2 * (horizontal.length ~/ 5),
          reason: 'two bar lines for each stave',
        );
        for (final (a, b) in bars) {
          expect(b.dy - a.dy, staffGap * 4);
        }
      },
    );

    test('guitar tab has staves of six lines', () {
      final horizontal = [
        for (final (a, b) in paperLines(PageBackground.tab, page))
          if (a.dy == b.dy) a.dy,
      ];
      expect(horizontal.length % 6, 0);
      expect(horizontal[1] - horizontal[0], tabGap);
      expect(horizontal[6] - horizontal[0], tabPitch);
    });

    test(
      'a page too small for a stave has none, and a very narrow one does not break',
      () {
        expect(paperLines(PageBackground.staff, const Size(800, 60)), isEmpty);
        expect(paperLines(PageBackground.staff, const Size(50, 500)), isEmpty);
      },
    );

    test(
      'a dot grid has dots where graph paper has crossings, and no lines',
      () {
        final dots = paperDots(PageBackground.dots, page);
        expect(paperLines(PageBackground.dots, page), isEmpty);
        expect(dots, isNotEmpty);
        final xs = {for (final d in dots) d.dx};
        expect(xs.first, paperSpacing);
        final crossings = {
          for (final (a, b) in paperLines(PageBackground.grid, page))
            if (a.dx == b.dx) a.dx,
        };
        expect(xs, crossings);
        for (final b in PageBackground.values.where(
          (b) => b != PageBackground.dots,
        )) {
          expect(paperDots(b, page), isEmpty, reason: b.name);
        }
      },
    );

    test(
      'isometric paper stays on the page and has three directions that meet in points',
      () {
        final lines = paperLines(PageBackground.isometric, page);
        for (final (a, b) in lines) {
          for (final p in [a, b]) {
            expect(p.dx, inInclusiveRange(-1e-6, page.width + 1e-6));
            expect(p.dy, inInclusiveRange(-1e-6, page.height + 1e-6));
          }
        }
        double angle((Offset, Offset) l) =>
            math.atan2(l.$2.dy - l.$1.dy, l.$2.dx - l.$1.dx) * 180 / math.pi;
        final directions = {for (final l in lines) angle(l).round()};
        expect(directions, {
          90,
          30,
          -30,
        }, reason: 'vertical, and 30 degrees down and up');
        // the lines of both slopes go through the same points on every vertical line
        final dx = paperSpacing * math.sqrt(3) / 2;
        final x = 5 * dx;
        final modulo = <Set<int>>[{}, {}];
        for (final l in lines) {
          final (a, b) = l;
          if (a.dx == b.dx || x < a.dx || x > b.dx) continue;
          final y = a.dy + (b.dy - a.dy) * (x - a.dx) / (b.dx - a.dx);
          modulo[b.dy > a.dy ? 0 : 1].add(
            ((y % paperSpacing) * 10).round() % (paperSpacing * 10).round(),
          );
        }
        expect(modulo[0].length, 1);
        expect(modulo[0], modulo[1]);
      },
    );

    test('grid and lines are as they were', () {
      final lines = paperLines(PageBackground.lines, page);
      expect(lines.first.$1.dy, paperSpacing * 2);
      expect(paperLines(PageBackground.blank, page), isEmpty);
      expect(
        paperLines(PageBackground.grid, page).length,
        greaterThan(lines.length),
      );
    });

    test('a canvas takes the paper that goes on for ever, not staves', () {
      expect(
        {
          for (final b in PageBackground.values)
            if (b.fitsCanvas) b,
        },
        {
          PageBackground.blank,
          PageBackground.grid,
          PageBackground.lines,
          PageBackground.dots,
        },
      );
      expect(
        {for (final b in PageBackground.values) b.label}.length,
        PageBackground.values.length,
      );
    });
  });

  group('the templates for creative work', () {
    late NoteRepository repo;
    late TemplateService service;
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('templates');
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      service = TemplateService(
        repo,
        NoteFileService(repo, supportDirectory: () async => dir),
        now: () => DateTime(2026, 3, 9),
      );
    });
    tearDown(() => dir.delete(recursive: true));

    Future<dynamic> made(String id) async => (await repo.loadNote(
      await service.createFrom(service.builtIn.firstWhere((t) => t.id == id)),
    ))!;

    test(
      'every template has a name, a line about it and an icon of its own, and an id that is used once',
      () {
        final all = service.builtIn;
        expect({for (final t in all) t.id}.length, all.length);
        expect({for (final t in all) t.name}.length, all.length);
        for (final t in all) {
          expect(t.name, isNotEmpty);
          expect(t.about.length, greaterThan(10), reason: t.id);
        }
        expect(
          all.map((t) => t.id),
          containsAll([
            'music',
            'tab',
            'dots',
            'isometric',
            'storyboard',
            'comic',
            'character',
            'beats',
            'song',
          ]),
        );
      },
    );

    test(
      'the paper templates make a note on that paper, and it is still that paper after saving and loading',
      () async {
        expect((await made('music')).background, PageBackground.staff);
        expect((await made('tab')).background, PageBackground.tab);
        expect((await made('dots')).background, PageBackground.dots);
        expect((await made('isometric')).background, PageBackground.isometric);
      },
    );

    List<Rect> rects(dynamic note) => [
      for (final TextBoxWidgetModel b in note.textBoxes[0]) b.position & b.size,
    ];

    test(
      'a storyboard has six frames in the 16:9 of a screen, each with a box for the action under it, all on the page and apart',
      () async {
        final note = await made('storyboard');
        final boxes = <TextBoxWidgetModel>[...note.textBoxes[0]];
        final frames = boxes.where((b) => b.id.startsWith('frame')).toList();
        final captions = boxes
            .where((b) => b.id.startsWith('caption'))
            .toList();
        expect(frames.length, 6);
        expect(captions.length, 6);
        for (final f in frames) {
          expect(f.size.width / f.size.height, closeTo(16 / 9, 0.01));
          expect(f.controller.text, isEmpty);
          final c = captions.firstWhere(
            (c) => c.id == 'caption${f.id.substring(5)}',
          );
          expect(c.position.dx, f.position.dx);
          expect(
            c.position.dy,
            greaterThan(f.position.dy + f.size.height - 1e-9),
            reason: 'under its frame',
          );
          expect(c.controller.text, startsWith(f.id.substring(5)));
        }
        final all = rects(note);
        final paper = Rect.fromLTWH(0, 0, 800, 800 * PageFormat.a4.ratio);
        for (final r in all) {
          expect(
            paper.contains(r.topLeft) && paper.contains(r.bottomRight),
            isTrue,
            reason: '$r',
          );
        }
        for (var i = 0; i < all.length; i++) {
          for (var j = i + 1; j < all.length; j++) {
            expect(all[i].overlaps(all[j]), isFalse, reason: '$i $j');
          }
        }
      },
    );

    test(
      'a comic page has six panels that fill the page, with gutters, and none over another',
      () async {
        final note = await made('comic');
        final all = rects(note);
        expect(all.length, 6);
        final paper = Rect.fromLTWH(0, 0, 800, 800 * PageFormat.a4.ratio);
        for (final r in all) {
          expect(
            paper.contains(r.topLeft) && paper.contains(r.bottomRight),
            isTrue,
            reason: '$r',
          );
          expect(r.width, greaterThan(150));
        }
        for (var i = 0; i < all.length; i++) {
          for (var j = i + 1; j < all.length; j++) {
            expect(all[i].overlaps(all[j]), isFalse, reason: '$i $j');
          }
        }
        final area = all.fold<double>(0, (a, r) => a + r.width * r.height);
        expect(
          area / (paper.width * paper.height),
          greaterThan(0.7),
          reason: 'the panels use most of the page',
        );
      },
    );

    test('the writing templates have their headings', () async {
      expect(
        (await made('character')).documentText,
        allOf(
          contains('# Character'),
          contains('## Looks'),
          contains('## History'),
        ),
      );
      expect(
        (await made('beats')).documentText,
        allOf(
          contains('## Act one'),
          contains('## Act two'),
          contains('## Act three'),
        ),
      );
      expect(
        (await made('song')).documentText,
        allOf(
          contains('## Verse 1'),
          contains('## Chorus'),
          contains('## Bridge'),
        ),
      );
    });

    test('a template kept as a note file keeps its paper', () async {
      final id = await service.createFrom(
        service.builtIn.firstWhere((t) => t.id == 'music'),
      );
      expect(await service.saveAsTemplate(id, 'Mine'), isTrue);
      final saved = (await service.saved()).single;
      final copy = await service.createFromSaved(saved.id);
      expect((await repo.loadNote(copy!))!.background, PageBackground.staff);
      await service.remove(saved.id);
    });
  });

  group('a database from before the new papers', () {
    test(
      'is upgraded in place, keeps its notes, and then takes any paper (the old check only allows three)',
      () async {
        final dir = await Directory.systemTemp.createTemp('oldpaper');
        addTearDown(() => dir.delete(recursive: true));
        final path = p.join(dir.path, 'notes.db');
        // the database as version 42 made it: the notes table without a `paper` column
        final old = await databaseFactory.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 42,
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
            onCreate: (db, _) async {
              for (final sql in createStatements) {
                await db.execute(
                  sql.replaceFirst(RegExp(r'\n\s*paper\s+TEXT,[^\n]*'), ''),
                );
              }
            },
          ),
        );
        expect(
          (await old.rawQuery(
            'PRAGMA table_info(notes)',
          )).map((c) => c['name']),
          isNot(contains('paper')),
        );
        await old.insert('notes', {
          'id': 'n1',
          'title': 'Old grid',
          'background': 'grid',
          'created_at': 1,
          'updated_at': 1,
        });
        await expectLater(
          old.update(
            'notes',
            {'background': 'staff'},
            where: 'id = ?',
            whereArgs: ['n1'],
          ),
          throwsA(anything),
          reason:
              'the old check only allows three: that is what the upgrade works around',
        );
        await old.close();

        final db = await AppDatabase.open(path: path);
        addTearDown(db.close);
        expect(
          (await db.rawQuery('PRAGMA table_info(notes)')).map((c) => c['name']),
          contains('paper'),
        );
        final repo = NoteRepository(db);
        const grid = 'n1';
        expect(
          (await repo.loadNote(grid))!.background,
          PageBackground.grid,
          reason: 'what was there is as it was',
        );
        for (final b in PageBackground.values) {
          final note = (await repo.loadNote(grid))!..background = b;
          await repo.saveNote(note);
          expect((await repo.loadNote(grid))!.background, b, reason: b.name);
        }
        // an older version reads what it cannot show as blank, and one that sets a paper it knows is believed over a stale `paper`
        await repo.saveNote(
          (await repo.loadNote(grid))!..background = PageBackground.staff,
        );
        expect(
          (await db.query(
            'notes',
            columns: ['background', 'paper'],
            where: 'id = ?',
            whereArgs: [grid],
          )).single,
          {'background': 'blank', 'paper': 'staff'},
        );
        await db.update(
          'notes',
          {'background': 'lines'},
          where: 'id = ?',
          whereArgs: [grid],
        );
        expect((await repo.loadNote(grid))!.background, PageBackground.lines);
      },
    );
  });

  group('choosing the paper', () {
    Future<NoteRepository> editor(
      WidgetTester tester, {
      PageFormat? format,
    }) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(
          await AppDatabase.open(path: inMemoryDatabasePath),
        );
        id = await repo.createNote();
        if (format != null) {
          final n = (await repo.loadNote(id))!..pageFormat = format;
          await repo.saveNote(n);
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FixedPageNoteEditor(
            key: ValueKey(id),
            noteId: id,
            repository: repo,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    Set<PageBackground> painted() => {
      for (final e
          in find
              .byWidgetPredicate(
                (w) => w is CustomPaint && w.painter is PageBackgroundPainter,
              )
              .evaluate())
        ((e.widget as CustomPaint).painter as PageBackgroundPainter).background,
    };

    testWidgets(
      'the page background menu has the new papers, and choosing one paints the page with it',
      (tester) async {
        await editor(tester);
        await tester.tap(find.byTooltip('Page background'));
        await tester.pumpAndSettle();
        for (final b in PageBackground.values) {
          expect(
            find.text(b.label),
            b == PageBackground.blank ? findsNWidgets(2) : findsOneWidget,
            reason: b.name,
          ); // (the paper in use is also the label of the button)
        }
        await tester.ensureVisible(find.text('Music staff'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Music staff'));
        await tester.pumpAndSettle();
        expect(painted(), {PageBackground.staff});
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'on an infinite canvas the menu leaves out the papers that are staves and isometric',
      (tester) async {
        await editor(tester, format: PageFormat.infinite);
        await tester.tap(find.byTooltip('Page background'));
        await tester.pumpAndSettle();
        expect(find.text('Dot grid'), findsOneWidget);
        expect(find.text('Grid'), findsOneWidget);
        expect(find.text('Music staff'), findsNothing);
        expect(find.text('Guitar tab'), findsNothing);
        expect(find.text('Isometric grid'), findsNothing);
      },
    );
  });
}
