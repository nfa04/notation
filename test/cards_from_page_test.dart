import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/export/anki_export.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/card_from_selection.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/review_export.dart';
import 'package:notes/screens/review_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A plain PNG [w] x [h] pixels.
Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF3366CC));
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  return bytes;
}

void main() {
  setUpAll(AppDatabase.initFfi);
  final now = DateTime(2026, 11, 26, 10);
  const base = RegionCard(picture: 'p1', width: 400, height: 200, note: 'n1', page: 2, area: [10, 20, 200, 100]);

  group('drafts', () {
    test('a picture card: the picture asks and the text answers, or the other way round', () {
      final card = const CardDraft(kind: CardDraftKind.picture, text: ' The Krebs cycle ').cards(base).single;
      expect((card.kind, card.front, card.back, card.page), (CardKind.region, '', 'The Krebs cycle', 2));
      final r = RegionCard.of(card)!;
      expect((r.picture, r.width, r.height, r.note, r.ask, r.reverse), ('p1', 400, 200, 'n1', -1, false));
      expect(r.area, [10, 20, 200, 100]);
      final turned = const CardDraft(kind: CardDraftKind.picture, text: 'Draw the Krebs cycle', reverse: true).cards(base).single;
      expect((turned.front, turned.back, RegionCard.of(turned)!.reverse), ('Draw the Krebs cycle', '', true));
      expect(turned.identity, isNot(card.identity));
      expect(const CardDraft(kind: CardDraftKind.picture).count, 0, reason: 'no answer, no card');
    });

    test('covers: a card for each, asking for it; the others stay on or come off', () {
      final masks = [
        [0.1, 0.1, 0.2, 0.1],
        [0.5, 0.5, 0.2, 0.1],
        [0.7, 0.2, 0.1, 0.1],
      ];
      final cards = CardDraft(kind: CardDraftKind.covers, masks: masks, hideAll: true).cards(base);
      expect(cards, hasLength(3));
      expect(cards.map((c) => c.identity).toSet(), hasLength(3));
      final second = RegionCard.of(cards[1])!;
      expect(second.ask, 1);
      // (as text: records with lists in them compare the lists by identity)
      String covers(RegionCard r, bool front) => '${r.coversOn(front: front)}';
      expect(covers(second, true), '${[(masks[0], false, true), (masks[1], true, true), (masks[2], false, true)]}');
      expect(covers(second, false), '${[(masks[0], false, true), (masks[1], true, false), (masks[2], false, true)]}', reason: 'the answer lifts only its own');
      final alone = RegionCard.of(CardDraft(kind: CardDraftKind.covers, masks: masks).cards(base)[1])!;
      expect(covers(alone, true), '${[(masks[1], true, true)]}');
      expect(covers(alone, false), '${[(masks[1], true, false)]}');
    });

    test('hidden words: cloze cards with the page', () {
      final cards = const CardDraft(kind: CardDraftKind.words, clozeText: '{{c1::ATP}} is made in the {{c2::mitochondria}}.').cards(base);
      expect(cards.map((c) => (c.kind, c.clozeNumber, c.page)), [(CardKind.cloze, 1, 2), (CardKind.cloze, 2, 2)]);
    });
  });

  group('the pictures', () {
    late Database db;
    late CardRepository cards;
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['review_cards', 'review_log', 'card_pictures']) {
        await db.delete(t);
      }
      cards = CardRepository(db);
    });
    tearDown(() => db.close());

    testWidgets('are kept once, shown on the card with its covers, and go when no card shows them', (tester) async {
      late String id;
      await tester.runAsync(() async {
        final png = await _png(40, 20);
        id = await cards.putPicture(png, width: 40, height: 20);
        expect(await cards.putPicture(png, width: 40, height: 20), id);
        final made = CardDraft(kind: CardDraftKind.covers, masks: const [
          [0.1, 0.1, 0.3, 0.3],
          [0.6, 0.6, 0.3, 0.3],
        ]).cards(RegionCard(picture: id, width: 40, height: 20, note: 'n1', page: 0));
        expect(await cards.addAll('n1', made, now: now), 2);
        await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, clock: () => now)));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 500));
      });
      expect(find.byKey(const ValueKey('card-picture')), findsOneWidget);
      expect(find.text('2 left'), findsOneWidget);

      await tester.runAsync(() async {
        final all = await cards.all();
        await cards.remove(all.first.id);
        expect(await cards.picture(id), isNotNull, reason: 'the other card still shows it');
        await cards.remove(all.last.id);
        expect((await db.query('card_pictures')), isEmpty);
      });
    });
  });

  testWidgets('the Anki package carries the pictures of the cards as its media', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['review_cards', 'review_log', 'card_pictures']) {
        await db.delete(t);
      }
      final cards = CardRepository(db);
      final id = await cards.putPicture(await _png(40, 20), width: 40, height: 20);
      await cards.addAll('n1', [
        ...CardDraft(kind: CardDraftKind.covers, masks: const [
          [0.1, 0.1, 0.3, 0.3],
        ]).cards(RegionCard(picture: id, width: 40, height: 20, note: 'n1', page: 0)),
        const Flashcard('Plain', 'card'),
      ], now: now);
      final anki = [for (final c in await cards.all()) await ankiCardOf(c, deck: 'Biology', cards: cards)];
      expect(anki.first.frontPicture, isNotNull);
      expect(anki.first.backPicture, isNotNull);
      expect(anki.first.frontPicture, isNot(anki.first.backPicture), reason: 'the cover is filled on the question, outlined on the answer');
      expect(anki.last.frontPicture, isNull);
      final work = Directory.systemTemp.createTempSync('anki_pictures');
      final zip = ZipDecoder().decodeBytes(await ankiPackage(anki, workDirectory: work, now: now));
      final media = jsonDecode(utf8.decode(zip.findFile('media')!.content)) as Map<String, dynamic>;
      expect(media, hasLength(2));
      expect(media.values.every((n) => (n as String).startsWith('notation-') && n.endsWith('.png')), isTrue);
      expect(zip.findFile('0'), isNotNull);
      final out = Directory.systemTemp.createTempSync('anki_pictures_out');
      File('${out.path}/c.anki2').writeAsBytesSync(zip.findFile('collection.anki2')!.content);
      final col = await databaseFactoryFfi.openDatabase('${out.path}/c.anki2', options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
      final fields = [for (final n in await col.query('notes')) n['flds'] as String];
      expect(fields.first, startsWith('<img src="${media['0']}">'));
      await col.close();
      out.deleteSync(recursive: true);
      work.deleteSync(recursive: true);
      await db.close();
    });
  });

  testWidgets('in the editor a lassoed drawing becomes cards: covers dragged over its picture, kept with the note and its page', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late CardRepository cards;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['review_cards', 'review_log', 'card_pictures']) {
        await db.delete(t);
      }
      repo = NoteRepository(db);
      cards = CardRepository(db);
      await repo.settings.set('index_handwriting', '0');
      await repo.settings.set('pdf_handwriting_text', '0');
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      DrawingStroke stroke(List<Offset> p) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: p);
      note.strokes[0] = [
        stroke([for (var i = 0; i <= 20; i++) Offset(150 + i * 15.0, 300)]),
        stroke([for (var i = 0; i <= 20; i++) Offset(150 + i * 15.0, 360)]),
      ];
      await repo.saveNote(note);
    });

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, cards: cards)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final lasso = await tester.startGesture(at(100, 250), kind: PointerDeviceKind.touch);
    for (final p in [at(100, 250), at(520, 250), at(520, 420), at(100, 420), at(100, 255)]) {
      await lasso.moveTo(p);
      await tester.pump();
    }
    await lasso.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('make-cards-from-selection')));
    for (var i = 0; i < 20 && find.byKey(const ValueKey('make-card-save')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('make-card-save')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('make-card-save'))).onPressed, isNull, reason: 'no answer typed yet');

    await tester.tap(find.byKey(const ValueKey('make-card-mode-covers')));
    await tester.pumpAndSettle();
    final area = tester.getRect(find.byKey(const ValueKey('make-card-cover-area')));
    for (final y in [0.2, 0.7]) {
      await tester.dragFrom(Offset(area.left + area.width * 0.2, area.top + area.height * y), Offset(area.width * 0.3, area.height * 0.2));
      await tester.pumpAndSettle();
    }
    expect(find.text('Make 2 cards'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('make-card-save')));
    for (var i = 0; i < 10 && find.byKey(const ValueKey('cards-made')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.text('2 cards kept for review'), findsOneWidget);

    final kept = (await tester.runAsync(() => cards.all(source: id)))!;
    expect(kept, hasLength(2));
    final r = RegionCard.of(kept.first.card)!;
    expect((r.note, r.page, r.masks.length, r.ask), (id, 0, 2, 0));
    expect(r.width, greaterThan(400), reason: 'sharper than the page');
    expect(r.area![0], lessThan(150));
    expect(await tester.runAsync(() => cards.picture(r.picture)), isNotNull);
    expect(kept.first.schedule.isDue(now.add(const Duration(days: 9999))), isTrue);
  });
}
