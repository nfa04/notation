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

  test('the words a statement rests on are named, to be found in the note, and handwriting is told', () {
    const text = '[Page 1]\nThe professor repeated that the slides are online. Chlorophyll absorbs mostly red and blue light in the leaf.\n\n[Page 2]\n✎ Glycolysis yields two ATP in the cytoplasm.\n✎ \$x^2\$';
    final c = checkAnswer('Chlorophyll absorbs red and blue light [Page 1]. Glycolysis yields two ATP [Page 2].', text, note);
    final one = c.sources[0], two = c.sources[1];
    expect(one.quote, 'Chlorophyll absorbs mostly red and blue');
    expect(one.handwriting, isFalse);
    expect(two.handwriting, isTrue);
    expect(two.quote, 'Glycolysis yields two ATP in the');
    expect(c.usesHandwriting, isTrue);
    // the search for them finds them with anything between the words
    final q = quoteQuery(one.quote);
    expect(q.find('Chlorophyll absorbs mostly\nred and blue light'), hasLength(1));
    expect(q.find('Chlorophyll absorbs red'), isEmpty);
  });

  test('each statement lists the passages it names; one that names none is shown as such, formulas are not held against a statement', () {
    final c = checkAnswer(
        'Chlorophyll absorbs red and blue light [Page 1]. The exam is on 20 June [Page 3]. Plants also make oxygen and many other useful things in the leaf.\nThe value is \$x^2 = 99\$ [Page 1].',
        given,
        note);
    expect(c.claims.map((x) => '${x.sources.map((s) => s.mark.mark).join('+')}|${x.doubt}'), [
      'Page 1|null',
      'Page 3|null',
      '|null',
      'Page 1|null', // (the formula and its digits are not looked for)
    ]);
    final wrong = checkAnswer('The exam is on 21 June [Page 3].', given, note).claims.single;
    expect(wrong.doubt, 'numbers:21');
  });

  test('the answer shows its citations as the numbers of its sources, and each source shows what the note says there', () {
    final c = checkAnswer('Chlorophyll absorbs red and blue light [Page 1]. Glycolysis yields two ATP [Page 2]. The exam is on 20 June [Page 3]; light matters [Page 1, 3].', given, note);
    expect(c.display, 'Chlorophyll absorbs red and blue light [1]. Glycolysis yields two ATP [2]. The exam is on 20 June [3]; light matters [1, 3].');
    expect(c.sources[0].evidence.first, 'Chlorophyll absorbs red and blue light.');
    expect(c.sources[2].evidence.first, 'The exam is on 20 June in room B12.');
    // a citation that names nothing is left as written
    expect(checkAnswer('It is so [Page 40].', given, note).display, 'It is so [Page 40].');
  });

  test('words to find a passage by are plain words, not formulas or Markdown', () {
    const text = '[Page 1]\nBinomial **distributed** with \$n\$ trials and \$p\$ success chance in every single trial of the experiment.';
    final c = checkAnswer('Success chance in every single trial [Page 1].', text, note);
    expect(c.sources.single.quote, 'success chance in every single trial');
    expect(c.sources.single.evidence.single, contains(r'$n$'));
  });
}
