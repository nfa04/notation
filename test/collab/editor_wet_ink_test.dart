import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';

/// Anna (the host, with the editor on the screen) and Ben (a guest without a screen) in one session.
typedef Pair = ({CollabSession anna, CollabSession ben, NoteData benNote, Future<void> Function({int rounds}) let});

/// Opens the editor for Anna, starts a session from its panel and lets Ben in.
Future<Pair> openSession(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late NoteRepository repo, guestRepo;
  late CollabService service, guestService;
  late String id;
  final hub = LoopbackHub();
  late Directory dir;
  await tester.runAsync(() async {
    dir = Directory.systemTemp.createTempSync('editor_wet_');
    repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/a.db'));
    guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/b.db'));
    service = CollabService(repo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/a')..createSync());
    guestService = CollabService(guestRepo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/b')..createSync());
    await service.load();
    await guestService.load();
    await service.setName('Anna');
    await guestService.setName('Ben');
    id = await repo.createNote(title: 'Shared');
    await repo.settings.set('draw_bar_more', '1'); // (the rarely used tools, symmetry among them, are folded away by default)
  });
  addTearDown(() => dir.deleteSync(recursive: true));

  await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, collab: service)));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pumpAndSettle();

  await tester.ensureVisible(find.byKey(const ValueKey('live-button')));
  await tester.tap(find.byKey(const ValueKey('live-button')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('live-server')), 'ws://localhost:8787');
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const ValueKey('live-start')));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pumpAndSettle();
  late JoinAttempt attempt;
  await tester.runAsync(() async {
    attempt = guestService.join(service.inviteFor(id)!);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.text('Let in'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
  await tester.tap(find.text('Close'));
  await tester.pumpAndSettle();
  final ben = attempt.session!;
  final benNote = (await tester.runAsync(() => guestRepo.loadNote(attempt.noteId!)))!;
  ben.attach(CollabBinding(
    note: () => benNote,
    change: (f) => f(),
    makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero),
    saveImage: guestService.saveImage,
    onNoteField: (f, d) => Replica.applyNoteField(benNote, f, d),
  ));

  /// Time goes on, on the fake clock of the screen and on the real one of the links.
  Future<void> let({int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    }
  }

  return (anna: service.sessionFor(id)!, ben: ben, benNote: benNote, let: let);
}

/// Ends the session from the panel, as a person does (the host's side of the session lives on the screen's clock).
Future<void> endSession(WidgetTester tester, Pair s) async {
  await tester.ensureVisible(find.byKey(const ValueKey('live-button')));
  await tester.tap(find.byKey(const ValueKey('live-button')));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const ValueKey('live-end')));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
  expect(s.anna.state, SessionState.ended);
  for (var i = 0; i < 20 && s.ben.state != SessionState.ended; i++) {
    await s.let(rounds: 1);
  }
  expect(s.ben.state, SessionState.ended);
}

Future<void> pickDraw(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Draw'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Draw'));
  await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
}

const pointer = 77;

PointerEvent pen(Type kind, Offset at) => switch (kind) {
      PointerDownEvent => PointerDownEvent(pointer: pointer, position: at, kind: PointerDeviceKind.stylus, buttons: kPrimaryButton, pressure: 0.5, pressureMin: 0, pressureMax: 1),
      PointerMoveEvent => PointerMoveEvent(pointer: pointer, position: at, kind: PointerDeviceKind.stylus, buttons: kPrimaryButton, pressure: 0.5, pressureMin: 0, pressureMax: 1),
      _ => PointerUpEvent(pointer: pointer, position: at, kind: PointerDeviceKind.stylus, pressure: 0.5, pressureMin: 0, pressureMax: 1),
    };

/// The editor and wet ink: what the pen draws on the screen is seen growing by a guest (and is no change of the note until the pen is
/// lifted), and what a guest draws is shown on the page while it grows.
void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the pen on the host\'s screen: the guest sees the line grow, and gets it as a line of the note when the pen is lifted', (tester) async {
    final s = await openSession(tester);
    final anna = s.anna, ben = s.ben, benNote = s.benNote, let = s.let;

    int benSees() => ben.wet.all.where((w) => w.site == anna.site).fold(0, (n, w) => n + w.length);
    bool benHasLine() => benNote.strokes.values.any((l) => l.isNotEmpty);

    // Anna draws with the pen
    await pickDraw(tester);
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);
    await tester.sendEventToBinding(pen(PointerDownEvent, origin));
    await tester.pump();
    final seen = <int>[];
    for (var i = 1; i <= 12; i++) {
      await tester.sendEventToBinding(pen(PointerMoveEvent, origin + Offset(i * 12.0, (i % 3) * 7.0)));
      await let(rounds: 1);
      seen.add(benSees());
    }
    await let();
    expect(benSees(), 13, reason: 'Ben sees all of the line while the pen is still down (growth: $seen)');
    expect(seen.where((n) => n > 0).toSet().length, greaterThan(2), reason: 'and saw it grow: $seen');
    expect(benHasLine(), isFalse, reason: 'it is not a line of the note yet');

    await tester.sendEventToBinding(pen(PointerUpEvent, origin + const Offset(144, 0)));
    await tester.pump();
    await let(rounds: 8);
    expect(benHasLine(), isTrue, reason: 'the finished line arrives when the pen is lifted');
    expect(ben.wet.isEmpty, isTrue, reason: 'and its wet form is gone');

    // Ben draws: Anna's page shows the line while it grows
    final line = DrawingStroke(id: 'ben-line', color: Colors.green, width: 4, points: [const Offset(400, 400)]);
    (benNote.strokes[0] ??= []).add(line);
    await tester.runAsync(() async {
      for (var i = 1; i <= 10; i++) {
        line.points.add(Offset(400.0 + i * 10, 400));
        ben.drawing(0, line);
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await let();
    expect(anna.wet['ben-line']?.length, 11);
    expect(anna.wet.on(0, except: anna.site), hasLength(1));
    expect(find.byKey(const ValueKey('wet-ink')), findsWidgets, reason: 'the page paints the wet ink of others');
    await tester.runAsync(() async {
      ben.drawingEnded('ben-line', kept: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await let();
    expect(anna.wet['ben-line'], isNull);

    await endSession(tester, s);
  });

  testWidgets('drawing with a mirror: the guest sees the mirrored line grow with the line, and gets both when the pen is lifted', (tester) async {
    final s = await openSession(tester);
    final anna = s.anna, ben = s.ben, benNote = s.benNote, let = s.let;

    await pickDraw(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('symmetry-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('symmetry-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('symmetry-leftRight')));
    await tester.pumpAndSettle();

    final page = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final origin = page + const Offset(150, 200);
    await tester.sendEventToBinding(pen(PointerDownEvent, origin));
    await tester.pump();
    final growth = <List<int>>[];
    for (var i = 1; i <= 10; i++) {
      await tester.sendEventToBinding(pen(PointerMoveEvent, origin + Offset(i * 10.0, i * 4.0)));
      await let(rounds: 1);
      growth.add([for (final w in ben.wet.all) if (w.site == anna.site) w.length]);
    }
    await let();
    final wet = [for (final w in ben.wet.all) if (w.site == anna.site) w];
    expect(wet, hasLength(2), reason: 'the line and its mirror image, while the pen is down (growth: $growth)');
    expect(wet.map((w) => w.length), everyElement(11));
    expect(growth.where((g) => g.length == 2).length, greaterThan(3), reason: 'the mirror grew along with the line: $growth');
    final xs = [for (final w in wet) w.stroke.points.last.dx]..sort();
    expect(xs[1] - xs[0], greaterThan(100), reason: 'one on either side of the middle');
    expect(benNote.strokes.values.expand((l) => l), isEmpty);

    await tester.sendEventToBinding(pen(PointerUpEvent, origin + const Offset(100, 40)));
    await tester.pump();
    await let(rounds: 8);
    final lines = benNote.strokes.values.expand((l) => l).toList();
    expect(lines, hasLength(2), reason: 'both lines are lines of the note now');
    expect({for (final l in lines) l.id}, {for (final w in wet) w.id}, reason: 'the wet lines were these');
    expect(ben.wet.isEmpty, isTrue);

    await endSession(tester, s);
  });
}
