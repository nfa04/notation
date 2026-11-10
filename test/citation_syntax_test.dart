import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/citation_document.dart';
import 'package:notes/citations/citation_style.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/markdown/markdown_parser.dart';

const smith = CitationSource(id: 'smith2020', type: SourceType.article, title: 'Alpha', authors: [Person('Smith', 'John')], year: 2020, container: 'J');
const doe = CitationSource(id: 'doe2019', title: 'Book', authors: [Person('Doe', 'Jane')], year: 2019, publisher: 'P');
const jones = CitationSource(id: 'jones2018', title: 'Gamma', authors: [Person('Jones', 'Ann')], year: 2018, publisher: 'P');

CitationDocument docOf(CitationStyle style, String text, [List<CitationSource> sources = const [smith, doe, jones]]) =>
    CitationDocument(style, {for (final s in sources) s.id: s}, text);

String read(CitationDocument d, String text) => d.inText(findCitations(text).first.items);

void main() {
  group('what a bracket can say', () {
    test('a word before, a remark after, the author left out', () {
      final items = findCitations('x [see @smith2020, p. 4, emphasis added; -@doe2019] y').single.items;
      expect(items[0].key, 'smith2020');
      expect(items[0].prefix, 'see');
      expect(items[0].locator!.text(), 'p. 4');
      expect(items[0].suffix, 'emphasis added');
      expect(items[1].key, 'doe2019');
      expect(items[1].suppressAuthor, isTrue);
      expect(items[1].prefix, isEmpty);
    });

    test('words that are not a place are a remark', () {
      final item = findCitations('[@a, passim]').single.items.single;
      expect(item.locator, isNull);
      expect(item.suffix, 'passim');
      final page = findCitations('[@a, 42 ff.]').single.items.single;
      expect(page.locator!.text(), 'p. 42');
      expect(page.suffix, 'ff.');
      expect(findCitations('[@a, pp. 3-5]').single.items.single.locator!.text(), 'pp. 3–5');
      expect(findCitations('[@a, xii]').single.items.single.locator!.text(), 'p. xii');
    });

    test('is written as it was read', () {
      for (final text in ['[see @a, p. 4, emphasis added]', '[-@a, ch. 2]', '[@a; @b, pp. 3–5]', '[@a, passim]']) {
        final items = findCitations(text).single.items;
        expect('[${items.map((i) => i.write()).join('; ')}]', text);
      }
    });

    test('not an address, a link or other brackets', () {
      expect(findCitations('[mail me@x.org] and [see @a](http://x.org) and [x [y] z]'), isEmpty);
      expect(findCitations('[x [see @a]'), hasLength(1));
      expect(findCitations('[x [see @a]').single.items.single.prefix, 'see');
    });
  });

  group('a citation in a sentence', () {
    test('is found with its place', () {
      final marks = findCitations('As @smith2020 [p. 4] says, and @doe2019.');
      expect(marks.map((m) => m.items.single.key), ['smith2020', 'doe2019']);
      expect(marks.first.items.single.narrative, isTrue);
      expect(marks.first.items.single.locator!.text(), 'p. 4');
      expect(marks.last.items.single.locator, isNull);
    });

    test('not in a word, an address or a link', () {
      expect(findCitations('me@x.org, https://x.org/@smith2020 and a@b'), isEmpty);
    });

    test('the parser gives it a run', () {
      final runs = parseMarkdown('As @smith2020 [p. 4] says.').single.runs;
      expect(runs.map((r) => r.text), ['As ', '@smith2020 [p. 4]', ' says.']);
      expect(runs[1].cite!.single.narrative, isTrue);
    });

    test('reads as the name and the year', () {
      expect(read(docOf(const ApaStyle(), '@smith2020'), '@smith2020'), 'Smith (2020)');
      expect(read(docOf(const ApaStyle(), '@smith2020 [p. 4]'), '@smith2020 [p. 4]'), 'Smith (2020, p. 4)');
      expect(read(docOf(const ChicagoStyle(), '@smith2020 [p. 4]'), '@smith2020 [p. 4]'), 'Smith (2020, 4)');
      expect(read(docOf(const MlaStyle(), '@smith2020 [p. 4]'), '@smith2020 [p. 4]'), 'Smith (4)');
      expect(read(docOf(const MlaStyle(), '@smith2020'), '@smith2020'), 'Smith');
      expect(read(docOf(const IeeeStyle(), '@smith2020 [p. 4]'), '@smith2020 [p. 4]'), 'Smith [1, p. 4]');
    });

    test('a name that is not a source stays text and is not a missing source', () {
      final d = docOf(const ApaStyle(), 'Ask @john about it');
      expect(d.missing, isEmpty);
      expect(d.isEmpty, isTrue);
      expect(d.inText(findCitations('Ask @john about it').single.items), '@john');
    });

    test('lists the source in the bibliography', () {
      final d = docOf(const ApaStyle(), 'As @smith2020 says.');
      expect(d.cited.map((s) => s.id), ['smith2020']);
      expect(d.bibliography().single, startsWith('Smith, J.'));
    });
  });

  group('prefix, suffix and no author', () {
    test('in the author-date styles', () {
      const text = '[see @smith2020, p. 4, emphasis added]';
      expect(read(docOf(const ApaStyle(), text), text), '(see Smith, 2020, p. 4, emphasis added)');
      expect(read(docOf(const HarvardStyle(), text), text), '(see Smith, 2020, p. 4, emphasis added)');
      expect(read(docOf(const ChicagoStyle(), text), text), '(see Smith 2020, 4, emphasis added)');
    });

    test('the author left out, because the text names them', () {
      expect(read(docOf(const ApaStyle(), '[-@smith2020]'), '[-@smith2020]'), '(2020)');
      expect(read(docOf(const ApaStyle(), '[-@smith2020, p. 4]'), '[-@smith2020, p. 4]'), '(2020, p. 4)');
      expect(read(docOf(const MlaStyle(), '[-@smith2020, p. 4]'), '[-@smith2020, p. 4]'), '(4)');
    });

    test('in a numbered style the number is cited', () {
      const text = '[see @smith2020, p. 4; -@doe2019]';
      expect(read(docOf(const IeeeStyle(), text), text), '[see 1, p. 4], [2]');
    });

    test('an unknown key stays visible', () {
      expect(read(docOf(const ApaStyle(), '[see @nobody]'), '[see @nobody]'), '[@nobody?]');
    });
  });

  group('numbers', () {
    const a = CitationSource(id: 'a', title: 'A', authors: [Person('A')], year: 2001);
    const b = CitationSource(id: 'b', title: 'B', authors: [Person('B')], year: 2002);
    const c = CitationSource(id: 'c', title: 'C', authors: [Person('C')], year: 2003);
    const d = CitationSource(id: 'd', title: 'D', authors: [Person('D')], year: 2004);

    // (the numbers are those of first use: the marks before the last give them)
    String ieee(String text) {
      final doc = docOf(const IeeeStyle(), '[@a] [@b] [@c] [@d] $text', [a, b, c, d]);
      return doc.inText(findCitations(text).first.items);
    }

    test('three in a row are a range', () {
      expect(ieee('[@a; @b; @c]'), '[1]–[3]');
      expect(ieee('[@a; @b; @c; @d]'), '[1]–[4]');
    });

    test('two in a row, or ones with something said, are not', () {
      expect(ieee('[@a; @b]'), '[1], [2]');
      expect(ieee('[@a; @b, p. 3; @c]'), '[1], [2, p. 3], [3]');
    });

    test('in the order of the numbers', () {
      expect(ieee('[@c; @a; @b]'), '[1]–[3]');
      expect(ieee('[@d; @a]'), '[1], [4]');
    });
  });

  group('the order of the list', () {
    CitationSource named(String id, String family, {String given = '', int year = 2000, String title = 'T', List<Person> more = const []}) =>
        CitationSource(id: id, title: title, authors: [Person(family, given), ...more], year: year);

    List<String> order(List<CitationSource> sources) => ([...sources]..sort(const ApaStyle().compare)).map((s) => s.id).toList();

    test('accents and capitals do not count', () {
      expect(order([named('z', 'Zander'), named('mu', 'Müller'), named('mt', 'Muller2'), named('o', 'Östlund'), named('p', 'Peters')]), ['mu', 'mt', 'o', 'p', 'z']);
      expect(order([named('b', 'beta'), named('a', 'Alpha')]), ['a', 'b']);
    });

    test('a leading article does not count for a source without an author', () {
      const the = CitationSource(id: 'the', title: 'The Zebra Book');
      const ant = CitationSource(id: 'ant', title: 'Ants');
      expect(order([the, ant]), ['ant', 'the']);
    });

    test('one author before the same author with others, then by the next name', () {
      final alone = named('alone', 'Smith', given: 'J', year: 2020);
      final withDoe = named('doe', 'Smith', given: 'J', year: 2019, more: [const Person('Doe', 'A')]);
      final withAbe = named('abe', 'Smith', given: 'J', year: 2021, more: [const Person('Abe', 'B')]);
      expect(order([withDoe, withAbe, alone]), ['alone', 'abe', 'doe']);
    });

    test('same family name: by given name', () {
      expect(order([named('b', 'Smith', given: 'Zoe'), named('a', 'Smith', given: 'Adam')]), ['a', 'b']);
    });
  });

  group('works told apart', () {
    const trio1 = CitationSource(id: 't1', title: 'First', authors: [Person('Smith', 'A'), Person('Jones', 'B'), Person('Lee', 'C')], year: 2020);
    const trio2 = CitationSource(id: 't2', title: 'Second', authors: [Person('Smith', 'A'), Person('Brown', 'D'), Person('Lee', 'C')], year: 2020);

    // (the letters follow the order of the list, which goes by the names of the authors: Brown before Jones)
    test('three authors with the same first one and year read the same in APA, so they get letters', () {
      const text = '[@t1] [@t2]';
      final d = docOf(const ApaStyle(), text, [trio1, trio2]);
      final reads = findCitations(text).map((m) => d.inText(m.items)).toList();
      expect(reads, ['(Smith et al., 2020b)', '(Smith et al., 2020a)']);
    });

    test('where all the names are written they do not', () {
      const text = '[@t1] [@t2]';
      final d = docOf(const ChicagoStyle(), text, [trio1, trio2]);
      expect(findCitations(text).map((m) => d.inText(m.items)).toList(), ['(Smith, Jones, and Lee 2020)', '(Smith, Brown, and Lee 2020)']);
    });
  });
}
