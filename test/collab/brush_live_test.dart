import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/brush_desc.dart';
import 'package:notes/models/canvas_models.dart';

import '../brush_look_frozen_test.dart' show lookOf;

DrawingStroke stroke(String brush, {String? id}) =>
    DrawingStroke(id: id, color: Colors.black, width: 4, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, 30.0 + i)], brush: brush);

/// One device: a note and its replica.
class Device {
  final NoteData note = NoteData(id: 'n');
  final Replica replica;
  Device(String site) : replica = Replica(site);

  List<CollabOp> changes() => replica.localChanges(note);

  void take(Iterable<CollabOp> ops) {
    for (final op in ops) {
      replica.apply(note, op, makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero), saveImage: (id, b, e) => '', onNoteField: (f, d) => Replica.applyNoteField(note, f, d));
    }
  }
}

void main() {
  final fancy = BrushDesc(BrushKind.charcoal, 'Dusty', const {'dust': 2.5, 'dryness': 0.5});
  final kept = <BrushDesc>[];

  setUp(() {
    kept.clear();
    CustomBrushes.sync([(desc: fancy, listed: true)]); // (this device has made the brush)
    CustomBrushes.keeper = (d) async => kept.add(d);
  });
  tearDown(() {
    CustomBrushes.keeper = null;
    CustomBrushes.sync(const []);
  });

  /// This device forgets every designed brush: the next one that is seen is a stranger.
  void becomeAnotherDevice() => CustomBrushes.sync(const []);

  test('a line of a designed brush carries the numbers of the brush, the lines of the pen and of the app\'s own brushes do not', () {
    final a = Device('a');
    a.note.strokes[0] = [stroke(fancy.id, id: 'x'), stroke(penBrushId, id: 'p'), stroke('pencil', id: 'q')];
    final byId = {for (final op in a.changes()) op.id: op.data};
    expect(byId['x']!['b'], fancy.id);
    expect(BrushDesc.fromCompactJson(byId['x']!['bd']), fancy);
    expect(byId['p']!.containsKey('bd'), isFalse);
    expect(byId['q']!.containsKey('bd'), isFalse);
  });

  test('a device that never had the brush draws the line with it, not in the brush menu, and keeps it', () {
    final a = Device('a'), b = Device('b');
    a.note.strokes[0] = [stroke(fancy.id, id: 'x')];
    final ops = a.changes();
    becomeAnotherDevice();
    expect(Brushes.byId(fancy.id), isNull);
    b.take(ops);
    expect(b.note.strokes[0]!.single.brush, fancy.id);
    expect(Brushes.byId(fancy.id), isNotNull);
    expect(CustomBrushes.of(fancy.id), fancy);
    expect(Brushes.isListed(fancy.id), isFalse);
    expect(kept, [fancy]);
  });

  test('it looks the same on the other device as where it was made', () {
    final a = Device('a'), b = Device('b');
    a.note.strokes[0] = [stroke(fancy.id, id: 'x')];
    final ops = a.changes();
    final shape = Brushes.byId(fancy.id)!.shape(a.note.strokes[0]!.single)!;
    becomeAnotherDevice();
    b.take(ops);
    final there = Brushes.byId(fancy.id)!.shape(b.note.strokes[0]!.single)!;
    expect(there.layers.length, shape.layers.length);
    expect([for (final l in there.layers) l.opacity], [for (final l in shape.layers) l.opacity]);
  });

  test('a guest who comes later is given the brush with the lines on the page', () {
    final a = Device('a');
    a.note.strokes[0] = [stroke(fancy.id, id: 'x')];
    a.changes();
    final state = a.replica.state(a.note);
    becomeAnotherDevice();
    final late = Device('late')..take(state);
    expect(Brushes.byId(fancy.id), isNotNull);
    expect(late.note.strokes[0]!.single.brush, fancy.id);
  });

  test('a brush is kept once, however many lines come with it, and one that is here already is not touched', () {
    final a = Device('a'), b = Device('b');
    a.note.strokes[0] = [for (var i = 0; i < 5; i++) stroke(fancy.id, id: 's$i')];
    final ops = a.changes();
    becomeAnotherDevice();
    b.take(ops);
    expect(kept.length, 1);
    // (a device that has it, listed, keeps it listed)
    CustomBrushes.sync([(desc: fancy, listed: true)]);
    kept.clear();
    Device('c').take(ops);
    expect(kept, isEmpty);
    expect(Brushes.isListed(fancy.id), isTrue);
  });

  test('a line cannot bring a brush under the id of another: the numbers have to make the id', () {
    final other = BrushDesc(BrushKind.roller, 'Imposter');
    final a = Device('a'), b = Device('b');
    a.note.strokes[0] = [stroke(fancy.id, id: 'x')];
    final op = a.changes().firstWhere((o) => o.kind == ElementKind.stroke);
    becomeAnotherDevice();
    final forged = CollabOp(op.kind, op.id, op.version, data: {...op.data, 'bd': other.toCompactJson()});
    b.take([forged]);
    expect(Brushes.byId(fancy.id), isNull);
    expect(Brushes.byId(other.id), isNull);
    expect(b.note.strokes[0]!.single.brush, fancy.id, reason: 'the line keeps its name and is drawn as the pen where the brush is not known');
    expect(kept, isEmpty);
  });

  test('a mixed brush and a brush with effects and curves arrive with all their numbers and their parts, and look the same there', () {
    final duo = BrushDesc(BrushKind.mix, 'Duo', const {'sizeB': 2, 'underneath': 1}, [
      BrushDesc(BrushKind.ink, 'Neon', const {'glow': 1, 'dash': 2, 'pressureAt0': 0.5, 'pressureAt50': 1.5, 'rainbow': 8}),
      BrushDesc(BrushKind.stamp, 'Stars', const {'shape': 3, 'outline': 0.5, 'fade': 0.5}),
    ]);
    CustomBrushes.sync([(desc: duo, listed: true)]);
    final a = Device('a'), b = Device('b');
    a.note.strokes[0] = [stroke(duo.id, id: 'x')];
    final ops = a.changes();
    final here = Brushes.byId(duo.id)!.shape(a.note.strokes[0]!.single)!;
    becomeAnotherDevice();
    b.take(ops);
    expect(Brushes.byId(duo.id), isA<MixBrush>());
    expect(CustomBrushes.of(duo.id), duo);
    expect(kept, [duo]);
    final there = Brushes.byId(duo.id)!.shape(b.note.strokes[0]!.single)!;
    expect(lookOf(there), lookOf(here));
  });

  test('a mix with a mix in it that comes in a line is not taken, and does no harm', () {
    final inner = BrushDesc(BrushKind.mix, 'Inner');
    final a = Device('a'), b = Device('b');
    a.note.strokes[0] = [stroke(fancy.id, id: 'x')];
    final op = a.changes().firstWhere((o) => o.kind == ElementKind.stroke);
    becomeAnotherDevice();
    final nested = {'k': 'mix', 'n': 'Bad', 'p': <String, Object?>{}, 'parts': [inner.toCompactJson(), fancy.toCompactJson()]};
    expect(() => b.take([CollabOp(op.kind, op.id, op.version, data: {...op.data, 'bd': nested})]), returnsNormally);
    expect(kept, isEmpty);
  });

  test('numbers that are not a brush are ignored, and numbers out of range are brought into range before the id is checked', () {
    final b = Device('b');
    for (final junk in <Object?>['text', 5, {'k': 'glitter', 'p': {}}, {'k': 'ink', 'p': {'width': 'thick'}}, {'k': 'ink', 'p': []}, <String, Object?>{}]) {
      becomeAnotherDevice();
      final a = Device('a');
      a.note.strokes[0] = [stroke(fancy.id, id: 'x')];
      final op = a.changes().firstWhere((o) => o.kind == ElementKind.stroke);
      expect(() => b.take([CollabOp(op.kind, op.id, op.version, data: {...op.data, 'bd': junk})]), returnsNormally, reason: '$junk');
    }
    expect(Brushes.byId(fancy.id), isNull);
    // a 'bd' that is not even there: the line is as before
    final a = Device('a2');
    a.note.strokes[0] = [stroke(fancy.id, id: 'y')];
    final op = a.changes().firstWhere((o) => o.kind == ElementKind.stroke);
    final data = {...op.data}..remove('bd');
    becomeAnotherDevice();
    Device('b2').take([CollabOp(op.kind, op.id, op.version, data: data)]);
    expect(Brushes.byId(fancy.id), isNull);
  });

  test('a device that has as many brushes as it takes does not take another from a line', () {
    CustomBrushes.sync([for (var i = 0; i < CustomBrushes.maxLearned; i++) (desc: BrushDesc(BrushKind.ink, 'b$i', {'width': 0.2 + i * 0.0191}), listed: false)]);
    final stranger = BrushDesc(BrushKind.roller, 'One too many');
    final a = Device('a')..note.strokes[0] = [stroke(stranger.id, id: 'x')];
    final op = a.changes().firstWhere((o) => o.kind == ElementKind.stroke);
    final forged = CollabOp(op.kind, op.id, op.version, data: {...op.data, 'bd': stranger.toCompactJson()});
    Device('b').take([forged]);
    expect(Brushes.byId(stranger.id), isNull);
    expect(CustomBrushes.all.length, CustomBrushes.maxLearned);
    expect(kept, isEmpty);
  });

  group('in a session', () {
    late Directory dir;
    late LoopbackHub hub;
    late CollabSession host;
    final toClose = <CollabSession>[];

    /// Whether the brush was there right after some change that a device that was a stranger to it took in.
    final drawnWith = <NoteData, bool>{};
    CollabBinding bindingFor(NoteData note, {bool stranger = false}) => CollabBinding(
          note: () => note,
          // (a device that has never had the brush: what it is told is taken in with none)
          change: (f) {
            if (stranger) becomeAnotherDevice();
            f();
            if (stranger && note.strokes[0]?.isNotEmpty == true) drawnWith[note] = drawnWith[note] == true || Brushes.byId(fancy.id) != null;
          },
          makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
          saveImage: (id, bytes, ext) => '',
          onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
        );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('brush_live_');
      hub = LoopbackHub();
    });
    tearDown(() async {
      for (final s in toClose) {
        await s.end();
        s.dispose();
      }
      toClose.clear();
      drawnWith.clear();
      dir.deleteSync(recursive: true);
    });

    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('what the host draws with a designed brush reaches a guest and, through the host, a third, who all draw it with the brush', () async {
      final invite = SessionInvite.create('ws://localhost:1', random: Random(9));
      final hostNote = NoteData(id: 'n');
      host = CollabSession.host(invite, hub.host, bindingFor(hostNote), name: 'Anna');
      toClose.add(host);

      Future<NoteData> guest(String name) async {
        final note = NoteData(id: 'n');
        final welcomed = Completer<Welcome>();
        final s = await CollabSession.join(invite, hub.guest, name: name, onWelcome: welcomed.complete, imageSaver: (id, b, e) => '');
        toClose.add(s);
        await settle();
        await host.approve(host.pending.single.id);
        final w = await welcomed.future.timeout(const Duration(seconds: 2));
        note
          ..title = w.note.title
          ..strokes = w.note.strokes;
        s.attach(bindingFor(note, stranger: true));
        await settle();
        return note;
      }

      final ben = await guest('Ben');
      final cleo = await guest('Cleo');
      CustomBrushes.sync([(desc: fancy, listed: true)]); // (the guests' joining made this device forget it: the host has it)
      hostNote.strokes[0] = [stroke(fancy.id, id: 'x')];
      host.localChanged();
      await settle();
      expect(ben.strokes[0]!.single.brush, fancy.id);
      expect(cleo.strokes[0]!.single.brush, fancy.id);
      expect(drawnWith[ben], isTrue, reason: 'the guest had the brush as soon as the line was there');
      expect(drawnWith[cleo], isTrue, reason: 'and the third, who was told through the host');
    });
  });
}
