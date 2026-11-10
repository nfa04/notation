import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/note_delta.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/pdf_models.dart';

DrawingStroke line(String id, double y) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

NoteData sample() {
  final box = TextBoxWidgetModel(id: 'b1', position: const Offset(40, 80), size: const Size(200, 60), initialText: 'Hello');
  return NoteData(id: 'n', title: 'Plan')
    ..documentText = 'doc'
    ..strokes = {0: [line('s1', 10), line('s2', 50)]}
    ..textBoxes = {0: [box]}
    ..highlights = {0: [PdfHighlight(id: 'h1', rect: const Rect.fromLTRB(1, 2, 3, 4), color: Colors.yellow)]};
}

void main() {
  test('a note that was not changed has no changes, and the digests do not depend on the run', () {
    final a = NoteDelta.digests(sample());
    expect(a.keys, containsAll(['stroke:s1', 'stroke:s2', 'box:b1', 'mark:h1', 'note:title', 'note:setup', 'note:doc']));
    expect(NoteDelta.digests(sample()), a);
    expect(NoteDelta.changesSince(sample(), a), isEmpty);
  });

  test('new, changed and deleted elements are found, and only those', () {
    final base = NoteDelta.digests(sample());
    final n = sample()
      ..title = 'Plan B'
      ..strokes[0]!.removeWhere((s) => s.id == 's2')
      ..strokes[1] = [line('s3', 99)];
    n.textBoxes[0]!.single.controller.text = 'Hello world';
    final ops = {for (final o in NoteDelta.changesSince(n, base)) Replica.keyOf(o.kind, o.id): o};
    expect(ops.keys.toSet(), {'note:title', 'stroke:s2', 'stroke:s3', 'box:b1'});
    expect(ops['stroke:s2']!.deleted, isTrue);
    expect(ops['stroke:s3']!.data['p'], 1);
    expect(ops['box:b1']!.data['text'], 'Hello world');
    expect(ops['note:title']!.data['title'], 'Plan B');
  });

  test('a new picture goes with its bytes, a moved one without', () {
    final withPic = sample()..images = {0: [ImageItem(id: 'i1', path: '/x/a.png', position: const Offset(5, 6), size: const Size(70, 80))]};
    final base = NoteDelta.digests(withPic);
    final fresh = sample();
    final added = NoteDelta.changesSince(withPic, NoteDelta.digests(fresh), readImage: (p) => Uint8List.fromList([1, 2, 3]));
    expect(added.single.kind, ElementKind.image);
    expect(added.single.data['bytes'], isNotNull);
    expect(added.single.data['ext'], 'png');

    withPic.images[0]!.single.position = const Offset(50, 60);
    final moved = NoteDelta.changesSince(withPic, base, readImage: (p) => Uint8List.fromList([1, 2, 3]));
    expect(moved.single.data.containsKey('bytes'), isFalse);
    expect(moved.single.data['x'], 50);
  });

  test('the owner takes in a delta that is sent again only for what changed since the last time', () {
    final base = NoteDelta.digests(sample());
    final n1 = sample()..strokes[1] = [line('s3', 99)];
    final first = NoteDelta.changesSince(n1, base);
    expect(NoteDelta.notYetApplied(first, {}).length, 1);
    final applied = NoteDelta.digestsOf(first);

    // the same delta again: nothing new
    expect(NoteDelta.notYetApplied(NoteDelta.changesSince(n1, base), applied), isEmpty);

    // the guest changed another thing, and the new stroke again
    final n2 = sample()
      ..strokes[1] = [line('s3', 120)]
      ..title = 'Other';
    final second = NoteDelta.changesSince(n2, base);
    expect(NoteDelta.notYetApplied(second, applied).map((o) => '${o.kind.name}:${o.id}').toSet(), {'stroke:s3', 'note:title'});

    // a deletion is taken in once
    final n3 = sample()..strokes[0]!.removeWhere((s) => s.id == 's1');
    final del = NoteDelta.changesSince(n3, base);
    expect(NoteDelta.notYetApplied(del, {}).single.deleted, isTrue);
    expect(NoteDelta.notYetApplied(del, NoteDelta.digestsOf(del)), isEmpty);
  });

  test('the changes, taken in by an owner who has the same note, give the guest\'s note', () {
    final base = NoteDelta.digests(sample());
    final guest = sample()
      ..title = 'Plan B'
      ..strokes[0]!.removeWhere((s) => s.id == 's2')
      ..strokes[1] = [line('s3', 99)];
    guest.textBoxes[0]!.single.controller.text = 'Changed';
    final owner = sample()..strokes[0]!.add(line('s9', 200)); // the owner kept working meanwhile
    final replica = Replica('import');
    for (final op in NoteDelta.changesSince(guest, base)) {
      replica.apply(owner, op, makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero), saveImage: (i, b, e) => '/x', onNoteField: (f, d) => Replica.applyNoteField(owner, f, d));
    }
    expect(owner.title, 'Plan B');
    expect(owner.textBoxes[0]!.single.controller.text, 'Changed');
    expect(owner.strokes[0]!.map((s) => s.id).toSet(), {'s1', 's9'}, reason: 's2 deleted by the guest, the owner\'s s9 kept');
    expect(owner.strokes[1]!.single.id, 's3');
  });
}
