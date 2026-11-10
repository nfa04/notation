import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/import.dart';
import 'package:notes/citations/lookup.dart';
import 'package:notes/citations/source.dart';

void main() {
  test('BibTeX: an article with braces, accents and a @string', () {
    final out = parseBibtex(r'''
@string{jn = "Journal of Notes"}
@comment{ignored}
@article{smith2020,
  author = {Smith, John and M{\"u}ller, Anna and {World Health Organization}},
  title = {Deep {L}earning for {N}otes},
  journal = jn,
  year = 2020, month = mar,
  volume = {5}, number = {2}, pages = {10--25},
  doi = {10.1000/xyz},
}
@book{doe,
  author = "Jane Doe",
  title = "The Book",
  publisher = "Penguin",
  address = "London",
  year = "2019"
}
''');
    expect(out, hasLength(2));
    final a = out.first;
    expect(a.id, 'smith2020');
    expect(a.type, SourceType.article);
    expect(a.title, 'Deep Learning for Notes');
    expect(a.authors, [const Person('Smith', 'John'), const Person('Müller', 'Anna'), const Person.literal('World Health Organization')]);
    expect(a.container, 'Journal of Notes');
    expect((a.year, a.month), (2020, 3));
    expect(a.pages, '10–25');
    expect(a.doi, '10.1000/xyz');
    final b = out.last;
    expect(b.type, SourceType.book);
    expect(b.authors.single, const Person('Doe', 'Jane'));
    expect((b.publisher, b.place, b.year), ('Penguin', 'London', 2019));
  });

  test('BibTeX: a file cut off in its last entry, just after a backslash, keeps the entries before it', () {
    final sources = parseBibtex(r'@book{a, title={First}, year={2000}} @article{b, title={Caf\');
    expect(sources.first.id, 'a');
  });

  test('importReferences recognises the format', () {
    expect(importReferences('@book{k, title={T}, year={2000}}').single.id, 'k');
    expect(importReferences('[{"id":"j","type":"book","title":"T","issued":{"date-parts":[[1999,5]]},"author":[{"family":"F","given":"G"}]}]').single.year, 1999);
    final ris = importReferences('TY  - JOUR\nAU  - Smith, John\nTI  - A title\nJO  - A Journal\nPY  - 2018/03/01\nSP  - 5\nEP  - 9\nDO  - 10.1/abc\nER  - \n');
    expect(ris.single.type, SourceType.article);
    expect((ris.single.year, ris.single.month, ris.single.pages), (2018, 3, '5–9'));
    expect(ris.single.authors.single, const Person('Smith', 'John'));
  });

  test('CSL-JSON round-trips', () {
    const s = CitationSource(
      id: 'k',
      type: SourceType.chapter,
      title: 'T',
      authors: [Person('A', 'B'), Person.literal('Org')],
      editors: [Person('E', 'F')],
      year: 2001,
      month: 2,
      container: 'Book',
      pages: '1–2',
      doi: '10.1/x',
    );
    final back = CitationSource.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
  });

  test('names are parsed the way people write them', () {
    expect(Person.parse('Smith, John'), const Person('Smith', 'John'));
    expect(Person.parse('John Albert Smith'), const Person('Smith', 'John Albert'));
    expect(Person.parse('Ludwig van Beethoven'), const Person('van Beethoven', 'Ludwig'));
    expect(const Person('Smith', 'Jean-Paul').initials, 'J.-P.');
  });

  test('keys are made from the first author and the year, and stay free', () {
    const s = CitationSource(id: '', title: 'T', authors: [Person('Müller', 'A')], year: 2020);
    expect(CitationSource.makeKey(s, {}), 'mller2020');
    expect(CitationSource.makeKey(s, {'mller2020'}), 'mller2020a');
  });

  group('lookup', () {
    test('finds DOIs and checks ISBNs', () {
      expect(CitationLookup.doiIn('https://doi.org/10.1000/xyz123.'), '10.1000/xyz123');
      expect(CitationLookup.doiIn('doi:10.1038/nature12373'), '10.1038/nature12373');
      expect(CitationLookup.isbnIn('978-3-16-148410-0'), '9783161484100');
      expect(CitationLookup.isbnIn('0-306-40615-2'), '0306406152');
      expect(CitationLookup.isbnIn('978-3-16-148410-1'), isNull);
    });

    test('Crossref answers become sources', () async {
      final lookup = CitationLookup(get: (url) async {
        expect(url, 'https://api.crossref.org/works/10.1000/xyz');
        return '{"message":{"type":"journal-article","title":["A paper"],"author":[{"given":"Ann","family":"Lee"},{"name":"The Group"}],'
            '"container-title":["Nature"],"issued":{"date-parts":[[2013,8]]},"volume":"500","issue":"7","page":"1-5","DOI":"10.1000/xyz","publisher":"NPG"}}';
      });
      final s = (await lookup.find('https://doi.org/10.1000/xyz'))!;
      expect(s.type, SourceType.article);
      expect(s.title, 'A paper');
      expect(s.authors, [const Person('Lee', 'Ann'), const Person.literal('The Group')]);
      expect((s.container, s.year, s.month, s.volume, s.pages), ('Nature', 2013, 8, '500', '1-5'));
    });

    test('Open Library answers become books', () async {
      final lookup = CitationLookup(get: (url) async => '{"ISBN:9783161484100":{"title":"A Book","authors":[{"name":"Jane Doe"}],'
          '"publishers":[{"name":"Penguin"}],"publish_date":"March 2019","publish_places":[{"name":"London"}]}}');
      final s = (await lookup.find('978-3-16-148410-0'))!;
      expect((s.title, s.year, s.publisher, s.place, s.isbn), ('A Book', 2019, 'Penguin', 'London', '9783161484100'));
      expect(s.authors.single, const Person('Doe', 'Jane'));
    });

    test('something that is neither is not looked up', () async {
      expect(await CitationLookup(get: (_) => throw StateError('no request')).find('hello'), isNull);
    });
  });
}
