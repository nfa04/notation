import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/history/version_diff.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke line(String id, double y) => DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

NoteData note({Map<int, List<DrawingStroke>>? strokes, Map<int, List<TextBoxWidgetModel>>? boxes, String text = ''}) =>
    NoteData(id: 'n', strokes: strokes ?? {}, textBoxes: boxes ?? {}, documentText: text);

void main() {
  test('the counts say what was added, removed and changed, by sort of thing', () {
    final older = note(strokes: {0: [line('keep', 10), line('gone', 30), line('edit', 50)]}, boxes: {0: [TextBoxWidgetModel(id: 'b', position: Offset.zero, initialText: 'a')]});
    final newer = note(strokes: {0: [line('keep', 10), line('edit', 55), line('new1', 70), line('new2', 90)]});
    final diff = VersionDiff.between(older, newer);
    expect(diff.count(ChangeKind.added), 2);
    expect(diff.count(ChangeKind.removed), 2);
    expect(diff.count(ChangeKind.changed), 1);
    expect(diff.byKind(ChangeKind.added), {ElementKind.stroke: 2});
    expect(diff.byKind(ChangeKind.removed), {ElementKind.stroke: 1, ElementKind.box: 1});
  });

  test('a drawing moved to another page is one change, not one removed and one added', () {
    final older = note(strokes: {0: [line('a', 10), line('b', 30)]});
    final newer = note(strokes: {0: [line('a', 10)], 1: [line('b', 30)]});
    final diff = VersionDiff.between(older, newer);
    expect(diff.count(ChangeKind.added), 0);
    expect(diff.count(ChangeKind.removed), 0);
    expect(diff.count(ChangeKind.changed), 1);
    expect(diff.elements.length, 2, reason: 'both pages still show it');
  });

  test('the written document is counted by line', () {
    final diff = VersionDiff.between(note(text: 'one\ntwo\nthree'), note(text: 'one\n2\nthree\nfour'));
    expect(diff.linesAdded, 2); // "2" and "four"
    expect(diff.linesRemoved, 1); // "two"
    expect(diff.fields, {'doc'});
    final same = VersionDiff.between(note(text: 'a\nb'), note(text: 'a\nb'));
    expect(same.linesAdded + same.linesRemoved, 0);
    expect(same.isEmpty, isTrue);
  });
}
