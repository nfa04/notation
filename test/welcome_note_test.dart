import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/templates/welcome_note.dart';

void main() {
  NoteData fresh() => NoteData(id: 'n', title: 'Welcome');
  String boxesOf(NoteData n) => [for (final page in n.textBoxes.values) for (final b in page) b.controller.text].join('\n');

  test('the first page is a written document, with the parts of the tools that are on', () {
    final n = fresh();
    fillWelcomeNote(n, {Feature.diagrams});
    final text = n.documentText;
    expect(text, startsWith('# Welcome to Notation'));
    expect(text, contains('[toc]'));
    expect(text, contains('[^1]: '), reason: 'the footnote it speaks of');
    expect(text, contains('Diagrams from a few lines of text'));
    expect(text, isNot(contains('Truth tables')));
    expect(text, isNot(contains('Check my working')));
    expect(text, isNot(contains('Flashcards')));
    expect(boxesOf(n), contains('Mind maps'), reason: 'the mind map is on the page after the document');
  });

  test('the diagrams are on the notebook page after the document, not on the document', () {
    final n = fresh();
    fillWelcomeNote(n, {Feature.diagrams});
    expect(n.textBoxes.keys, everyElement(greaterThanOrEqualTo(1)));
    expect(n.strokes.keys, everyElement(greaterThanOrEqualTo(1)));
    expect(n.strokes, isNotEmpty);
  });

  test('with the tools of a student of maths it shows the checked working and the truth table, worked out now', () {
    final n = fresh();
    fillWelcomeNote(n, FeaturePresets.forAreas({UseArea.maths}));
    final text = n.documentText;
    expect(text, contains('> 2x = 8    ✓'));
    expect(text, contains('> x = 4    ✓'));
    expect(text, contains('17 · 24 = 408'));
    expect(text, contains('true in 7 of 8 rows'));
    expect(text, contains('| p | q | r |'));
  });

  test('without the tools of the pages nothing of them is there', () {
    final n = fresh();
    fillWelcomeNote(n, {Feature.highlighter});
    expect(n.documentText, isNot(contains('## Maths')));
    expect(n.documentText, isNot(contains('Truth tables')));
    expect(n.strokes, isEmpty, reason: 'no diagrams, no lines');
    expect(n.textBoxes, isEmpty);
    expect(n.documentText, contains('Write and draw'));
  });

  test('with every tool on, the diagrams lie inside their page', () {
    final n = fresh();
    fillWelcomeNote(n, Feature.values.toSet());
    for (final e in n.textBoxes.entries) {
      for (final b in e.value) {
        expect(b.position.dx, greaterThanOrEqualTo(0), reason: 'page ${e.key}: ${b.controller.text}');
        expect(b.position.dx + b.size.width, lessThanOrEqualTo(800.5), reason: 'page ${e.key}: ${b.controller.text}');
        expect(b.position.dy + b.size.height, lessThan(1131), reason: 'page ${e.key}: ${b.controller.text}');
      }
    }
    for (final e in n.strokes.entries) {
      for (final s in e.value) {
        for (final p in s.points) {
          expect(p.dx, inInclusiveRange(0, 800));
          expect(p.dy, inInclusiveRange(0, 1131), reason: 'page ${e.key}');
        }
      }
    }
  });
}
