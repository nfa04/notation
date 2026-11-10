import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/citation_style.dart';
import 'package:notes/citations/export.dart';
import 'package:notes/citations/import.dart';
import 'package:notes/citations/source.dart';

void main() {
  test('a month that is not 1 to 12 is no month: nothing that looks months up breaks on it', () {
    final sources = [
      ...importReferences('TY  - JOUR\nTI  - T\nAU  - Doe, J\nDA  - 2020/00/00\nER  - \n'),
      ...importReferences('@article{a, title={T}, author={Doe, J}, year={2020}, month={13}, urldate={2020-13-40}}'),
      ...importReferences('[{"id":"x","title":"T","issued":{"date-parts":[[2020,0,5]]},"accessed":{"date-parts":[[2021,14,2]]}}]'),
    ];
    for (final s in sources) {
      expect(s.year, 2020);
      expect(s.month, isNull);
      expect(s.day, isNull);
      for (final f in ExportFormat.values) {
        expect(() => f.write([s]), returnsNormally);
      }
      for (final style in citationStyles) {
        expect(() => style.entry(s.copyWith(type: SourceType.webpage, accessed: '2021-14-02')), returnsNormally);
      }
    }
    expect(CitationSource(id: 'a', title: 't', year: 2020, month: 5, day: 31).month, 5);
  });

  test('LaTeX commands that start with c or v keep their name; accents still work', () {
    expect(cleanLatex(r'See \cite{x} and \vec{v}'), r'See \citex and \vecv'); // (the name is not eaten: it was 'See itex and ecv')
    expect(cleanLatex(r'''Fran\c{c}ois \c c \v{s}tefan \"{u}ber \'e'''), 'François ç štefan über é');
  });

  test('a given name with an empty part has initials', () {
    expect(const Person('Doe', 'Jean-').initials, 'J.');
    expect(const Person('Doe', 'Jean -Paul').initials, 'J. P.');
    expect(const Person('Doe', 'Jean-Paul').initials, 'J.-P.');
  });

  test('one odd item does not stop the import of the rest', () {
    final r = importReferences('[{"title":"A","author":"Doe, Jane"},{"title":"B","author":[{"family":5,"given":null}]},{"title":"C","author":{"family":"Roe"}}]');
    expect(r.map((s) => s.title), ['A', 'B', 'C']);
    expect(r.first.authors.single.family, 'Doe');
    expect(r.last.authors.single.family, 'Roe');
  });
}
