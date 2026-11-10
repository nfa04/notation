import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/models/rich_text.dart';

DrawingStroke line(double y, {int points = 6}) =>
    DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < points; i++) Offset(10.0 + i * 5, y + i)]);

/// One device: a note and its replica, and what it does with changes from others.
class Device {
  final String site;
  final NoteData note;
  late final Replica replica = Replica(site);
  final Directory dir;
  final applied = <CollabOp>[];

  Device(this.site, this.dir) : note = NoteData(id: 'n');

  List<CollabOp> changes() => replica.localChanges(note);

  bool take(CollabOp op) {
    final ok = replica.apply(
      note,
      op,
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: (id, bytes, ext) {
        final f = File('${dir.path}/$site-$id.$ext')..writeAsBytesSync(bytes);
        return f.path;
      },
      onNoteField: (field, data) => Replica.applyNoteField(note, field, data),
    );
    if (ok) applied.add(op);
    return ok;
  }

  void takeAll(Iterable<CollabOp> ops) {
    for (final op in ops) {
      take(op);
    }
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('replica_'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<double> ys(NoteData n, int page) => [for (final s in n.strokes[page] ?? const <DrawingStroke>[]) s.points.first.dy];

  test('a stroke drawn on one device appears on the other, with the same id and points', () {
    final a = Device('a', dir), b = Device('b', dir);
    final s = line(40);
    a.note.strokes[0] = [s];
    b.takeAll(a.changes());
    expect(b.note.strokes[0]!.single.id, s.id);
    expect(b.note.strokes[0]!.single.points.length, 6);
    expect(b.note.strokes[0]!.single.points[5], const Offset(35, 45));
    expect(b.changes().where((o) => o.kind == ElementKind.stroke), isEmpty); // what came in is not sent back
  });

  test('nothing changed means nothing to send', () {
    final a = Device('a', dir);
    a.note.strokes[0] = [line(1)];
    expect(a.changes(), isNotEmpty);
    expect(a.changes(), isEmpty);
  });

  test('a moved or straightened stroke is a change to that stroke, an erased one a deletion', () {
    final a = Device('a', dir), b = Device('b', dir);
    a.note.strokes[0] = [line(10), line(50), line(90)];
    b.takeAll(a.changes());

    final moved = a.note.strokes[0]![1];
    for (var i = 0; i < moved.points.length; i++) {
      moved.points[i] += const Offset(0, 100);
    }
    a.note.strokes[0]!.removeAt(2);
    final ops = a.changes();
    expect(ops.length, 2);
    b.takeAll(ops);
    expect(ys(b.note, 0), [10, 150]);
    expect(b.note.strokes[0]![1].id, moved.id);
  });

  test('an erase that is taken back is a new change that wins over the deletion', () {
    final a = Device('a', dir), b = Device('b', dir);
    final s = line(10);
    a.note.strokes[0] = [s];
    b.takeAll(a.changes());
    a.note.strokes[0]!.clear();
    b.takeAll(a.changes());
    expect(b.note.strokes[0], isEmpty);
    a.note.strokes[0]!.add(s); // undo
    b.takeAll(a.changes());
    expect(ys(b.note, 0), [10]);
  });

  test('a late change to something deleted does not bring it back', () {
    final a = Device('a', dir), b = Device('b', dir);
    final s = line(10);
    a.note.strokes[0] = [s];
    final first = a.changes();
    b.takeAll(first);
    // b moves it, a deletes it, at the same time
    b.note.strokes[0]![0].points[0] += const Offset(5, 5);
    final fromB = b.changes();
    a.note.strokes[0]!.clear();
    final fromA = a.changes();
    // in either order the stroke ends up deleted: a change cannot undo a deletion it did not know of
    a.takeAll(fromB);
    b.takeAll(fromA);
    expect(a.note.strokes[0], isEmpty);
    expect(b.note.strokes[0], isEmpty);
  });

  test('two changes to one text box: the later one wins on both devices, whatever the order', () {
    final a = Device('a', dir), b = Device('b', dir);
    final box = TextBoxWidgetModel(id: 'box', position: const Offset(1, 1), initialText: 'start');
    a.note.textBoxes[0] = [box];
    b.takeAll(a.changes());

    a.note.textBoxes[0]!.single.controller.text = 'from a';
    b.note.textBoxes[0]!.single.controller.text = 'from b';
    final opsA = a.changes();
    final opsB = b.changes();
    a.takeAll(opsB);
    b.takeAll(opsA);
    expect(a.note.textBoxes[0]!.single.controller.text, b.note.textBoxes[0]!.single.controller.text);
    expect(a.note.textBoxes[0]!.single.controller.text, isIn(['from a', 'from b']));
  });

  test('text box position, size, text, spans and style all arrive', () {
    final a = Device('a', dir), b = Device('b', dir);
    final box = TextBoxWidgetModel(
      id: 'box',
      position: const Offset(30, 60),
      size: const Size(300, 90),
      initialText: 'Hello world',
      fontSize: 20,
      style: const TextBoxStyle(background: Color(0xFFFFF8E1), borderWidth: 0),
    );
    box.controller.attributes.add(TextSpanAttribute(start: 0, end: 5, type: AttributeType.bold));
    a.note.textBoxes[2] = [box];
    b.takeAll(a.changes());
    final got = b.note.textBoxes[2]!.single;
    expect((got.position, got.size, got.fontSize), (const Offset(30, 60), const Size(300, 90), 20.0));
    expect(got.controller.text, 'Hello world');
    expect(got.controller.attributes.single.type, AttributeType.bold);
    expect(got.style.background, const Color(0xFFFFF8E1));
    // moved to another page, and then deleted
    a.note.textBoxes[2]!.clear();
    a.note.textBoxes[3] = [box];
    b.takeAll(a.changes());
    expect(b.note.textBoxes[2], isEmpty);
    expect(b.note.textBoxes[3]!.single.id, 'box');
    a.note.textBoxes[3]!.clear();
    b.takeAll(a.changes());
    expect(b.note.textBoxes[3], isEmpty);
  });

  test('a picture comes with its bytes the first time, and later moves are small', () {
    final a = Device('a', dir), b = Device('b', dir);
    final file = File('${dir.path}/pic.png')..writeAsBytesSync([5, 6, 7, 8]);
    final m = ImageItem(id: 'img', path: file.path, position: const Offset(10, 20), size: const Size(50, 60));
    a.note.images[0] = [m];
    final first = a.changes().singleWhere((o) => o.kind == ElementKind.image);
    expect(first.data['bytes'], isNotNull);
    b.take(first);
    final got = b.note.images[0]!.single;
    expect(File(got.path).readAsBytesSync(), [5, 6, 7, 8]);
    expect((got.position, got.size), (const Offset(10, 20), const Size(50, 60)));

    m.position = const Offset(99, 99);
    final move = a.changes().singleWhere((o) => o.kind == ElementKind.image);
    expect(move.data['bytes'], isNull);
    b.take(move);
    expect(b.note.images[0]!.single.position, const Offset(99, 99));
  });

  test('highlights, the title, the page setup and the written document are shared', () {
    final a = Device('a', dir), b = Device('b', dir);
    a.note
      ..title = 'Shared notes'
      ..background = PageBackground.grid
      ..landscape = true
      ..nativePages = {0, 3}
      ..documentText = '# Hello'
      ..highlights[1] = [PdfHighlight(rect: const Rect.fromLTWH(1, 2, 3, 4), color: Colors.yellow, commentBox: 'c')];
    b.takeAll(a.changes());
    expect(b.note.title, 'Shared notes');
    expect(b.note.background, PageBackground.grid);
    expect(b.note.landscape, isTrue);
    expect(b.note.nativePages, {0, 3});
    expect(b.note.documentText, '# Hello');
    expect(b.note.highlights[1]!.single.rect, const Rect.fromLTWH(1, 2, 3, 4));
    expect(b.note.highlights[1]!.single.commentBox, 'c');
    expect(b.changes(), isEmpty); // nothing to send back

    b.note.title = 'Renamed by b';
    a.takeAll(b.changes());
    expect(a.note.title, 'Renamed by b');
    expect(a.changes(), isEmpty);
  });

  test('a deleted element stays deleted for a late change, and comes back only on purpose', () {
    final a = Device('a', dir), b = Device('b', dir);
    final s = line(10);
    a.note.strokes[0] = [s];
    b.takeAll(a.changes());
    a.note.strokes[0]!.clear();
    final deletion = a.changes().single;
    s.points[0] += const Offset(50, 50); // changed on b before b heard of the deletion
    b.note.strokes[0]!.single.points[0] += const Offset(1, 1);
    final lateChange = b.changes().single;
    expect(a.take(lateChange), isFalse); // ignored on a: it is deleted there
    b.take(deletion);
    expect(b.note.strokes[0], isEmpty); // and the deletion wins on b, though the change was later
    // but putting it back is a decision that wins
    a.note.strokes[0]!.add(s);
    b.takeAll(a.changes());
    expect(b.note.strokes[0]!.length, 1);
  });

  test('a device that joins is given the whole state, and then follows along', () {
    final a = Device('a', dir), b = Device('late', dir);
    a.note.strokes[0] = [line(10), line(50)];
    a.note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: const Offset(5, 5), initialText: 'hi')];
    a.note.title = 'Old note';
    a.changes();
    a.note.strokes[0]!.removeAt(0); // one is deleted before the other joins
    a.changes();

    b.takeAll(a.replica.state(a.note));
    expect(ys(b.note, 0), [50]);
    expect(b.note.textBoxes[0]!.single.controller.text, 'hi');
    expect(b.note.title, 'Old note');

    // the late device's changes are later than everything it was given
    b.note.strokes[0]!.add(line(200));
    a.takeAll(b.changes());
    expect(ys(a.note, 0), [50, 200]);
    // and an old change that arrives again changes nothing
    expect(b.take(a.replica.state(a.note).first), isFalse);
  });

  test('applying the same change twice, or an older one, does nothing', () {
    final a = Device('a', dir), b = Device('b', dir);
    a.note.strokes[0] = [line(10)];
    final ops = a.changes();
    expect(b.take(ops.first), isTrue);
    expect(b.take(ops.first), isFalse);
    a.note.strokes[0]![0].points[1] += const Offset(9, 9);
    final newer = a.changes().single;
    expect(b.take(newer), isTrue);
    expect(b.take(ops.first), isFalse); // the older one now
    expect(b.note.strokes[0]!.single.points[1], const Offset(24, 20));
  });

  test('the clock moves past what was seen, so the next change here is later', () {
    final a = Device('a', dir), b = Device('b', dir);
    for (var i = 0; i < 5; i++) {
      a.note.title = 'v$i';
      a.changes();
    }
    b.takeAll(a.replica.state(a.note));
    expect(b.replica.clock, greaterThanOrEqualTo(a.replica.clock - 5));
    b.note.title = 'b wins';
    final op = b.changes().single;
    expect(op.version.clock, greaterThan(a.replica.clock - 5));
    a.take(op);
    expect(a.note.title, 'b wins');
  });

  test('changes survive being written as JSON, and unknown ones are skipped', () {
    final a = Device('a', dir);
    a.note.strokes[0] = [line(10)];
    final op = a.changes().first;
    final back = CollabOp.fromJson(op.toJson())!;
    expect((back.kind, back.id, back.version), (op.kind, op.id, op.version));
    expect(CollabOp.fromJson({'k': 'hologram', 'i': 'x', 'v': [1, 'a']}), isNull);
    expect(CollabOp.fromJson('nonsense'), isNull);
    // (an id longer than a note file can keep would make the file the note is saved in unreadable)
    expect(CollabOp.fromJson({...op.toJson(), 'i': 'x' * 256}), isNull);
    expect(CollabOp.fromJson({...op.toJson(), 'i': 'x' * 255}), isNotNull);
  });

  test('three devices that exchange their changes in different orders end up the same', () {
    final ds = [Device('a', dir), Device('b', dir), Device('c', dir)];
    ds[0].changes();
    ds[1].takeAll(ds[0].replica.state(ds[0].note)); // they all start from the same note
    ds[2].takeAll(ds[0].replica.state(ds[0].note));
    ds[0].note.strokes[0] = [line(1)];
    ds[1].note.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: Offset.zero, initialText: 'b')];
    ds[2].note.title = 'c title';
    final outgoing = [for (final d in ds) d.changes()];
    // each device takes the others' changes in its own order
    ds[0].takeAll([...outgoing[2], ...outgoing[1]]);
    ds[1].takeAll([...outgoing[2].reversed, ...outgoing[0]]);
    ds[2].takeAll([...outgoing[1], ...outgoing[0]]);
    for (final d in ds) {
      expect(ys(d.note, 0), [1]);
      expect(d.note.textBoxes[0]!.single.controller.text, 'b');
      expect(d.note.title, 'c title');
    }
  });
}
