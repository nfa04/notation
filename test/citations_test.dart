import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/citations.dart';

void main() {
  const note = [KnownMark('Page 1', page: 0), KnownMark('Page 2', page: 1), KnownMark('Page 3', page: 2)];
  const given = 'The note is called "Bio".\n\n[Page 1]\nChlorophyll absorbs red and blue light.\n\n[Page 2]\nGlycolysis yields two ATP.\n\n[Page 3]\nThe exam is on 20 June in room B12.';

  test('a statement that names the page it comes from is a source, and the page says it', () {
    final c = checkAnswer('Chlorophyll absorbs red and blue light [Page 1]. Glycolysis yields two ATP (p. 2).', given, note);
    expect(c.sources.map((s) => s.mark.mark), ['Page 1', 'Page 2']);
    expect(c.hasProblems, isFalse);
    expect(c.unknown, isEmpty);
  });

  test('a page that does not say it is marked, with the page that does', () {
    final c = checkAnswer('Glycolysis yields two ATP [Page 1].', given, note);
    expect(c.sources.single.supported, isFalse);
    expect(c.sources.single.better?.mark, 'Page 2');
  });

  test('a number the passage does not have is doubted', () {
    final c = checkAnswer('The exam is on 21 June in room B12 [Page 3].', given, note);
    expect(c.sources.single.supported, isFalse);
    expect(checkAnswer('The exam is on 20 June in room B12 [Page 3].', given, note).hasProblems, isFalse);
  });

  test('a page that was not given is told, and an answer without sources is not cited', () {
    expect(checkAnswer('It is in the text [Page 40].', given, note).unknown, ['Page 40']);
    final none = checkAnswer('Plants make sugar.', given, note);
    expect(none.cited, isFalse);
    expect(none.unknown, isEmpty);
  });

  test('pages written as a list or a range, and a citation on a line of its own', () {
    final c = checkAnswer('Both talk about energy.\n[Pages 1-2]', given, note);
    expect(c.sources.map((s) => s.mark.mark), ['Page 1', 'Page 2']);
    expect(checkAnswer('Light is absorbed [Page 1, 3].', given, note).sources.map((s) => s.mark.mark), ['Page 1', 'Page 3']);
  });

  test('in all notes a citation has the note and the page, with the date it may be marked with', () {
    const notes = [
      KnownMark('Biology - Page 3', title: 'Biology', page: 2, noteId: 'a'),
      KnownMark('History - Page 3', title: 'History', page: 2, noteId: 'b'),
    ];
    const text = '[Biology - Page 3 - changed 2026-11-01]\nMitosis has four phases.\n\n[History - Page 3]\nThe war ended in 1918.';
    final c = checkAnswer('Mitosis has four phases [Biology - Page 3]. The war ended in 1918 (History, p. 3).', text, notes);
    expect(c.sources.map((s) => s.mark.noteId), ['a', 'b']);
    expect(c.hasProblems, isFalse);
    // a page number alone does not say which note
    expect(checkAnswer('Four phases [Page 3].', text, notes).cited, isFalse);
  });
}
