import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/export.dart';
import 'package:notes/citations/import.dart';
import 'package:notes/citations/source.dart';

const article = CitationSource(
  id: 'smith2020',
  type: SourceType.article,
  title: 'Cats & dogs: 100% of the _best_ #1',
  authors: [Person('Smith', 'John'), Person('Müller', 'Anna Maria')],
  year: 2020,
  month: 3,
  day: 4,
  container: 'Journal of Pets',
  volume: '12',
  issue: '3',
  pages: '34–56',
  doi: '10.1000/xyz123',
);
const book = CitationSource(
  id: 'doe2019',
  title: 'A Book',
  authors: [Person.literal('World Health Organization')],
  editors: [Person('Doe', 'Jane')],
  year: 2019,
  publisher: 'Press',
  place: 'Bern',
  edition: '2nd',
  isbn: '9783161484100',
);
const chapter = CitationSource(
  id: 'ch1',
  type: SourceType.chapter,
  title: 'A chapter',
  authors: [Person('Plato')],
  editors: [Person('Ed', 'Itor'), Person('Other', 'Ed')],
  year: 1999,
  container: 'The Big Book',
  publisher: 'Pub',
  pages: 'e1234',
);
const web = CitationSource(
  id: 'web',
  type: SourceType.webpage,
  title: 'A page',
  authors: [Person('Roe', 'Rick')],
  year: 2021,
  container: 'Example Site',
  url: 'https://example.org/a?b=1&c=2',
  accessed: '2024-05-06',
);
const thesis = CitationSource(id: 'th', type: SourceType.thesis, title: 'On things', authors: [Person('Lee', 'Kim')], year: 2015, publisher: 'ETH Zürich');
const report = CitationSource(id: 'rep', type: SourceType.report, title: 'A report', authors: [Person('Ng', 'Al')], year: 2012, publisher: 'Agency');
const conference = CitationSource(
  id: 'conf',
  type: SourceType.conference,
  title: 'A talk',
  authors: [Person('Kay', 'Al')],
  year: 2018,
  container: 'Proceedings of Things',
  pages: '1-10',
);

const all = [article, book, chapter, web, thesis, report, conference];

/// What of a source has to survive the way out and back in.
void same(CitationSource got, CitationSource want, {bool day = true}) {
  expect(got.id, want.id);
  expect(got.type, want.type);
  expect(got.title, want.title);
  expect([for (final p in got.authors) p.family], [for (final p in want.authors) p.family]);
  expect([for (final p in got.authors) p.given], [for (final p in want.authors) p.given]);
  expect([for (final p in got.editors) p.family], [for (final p in want.editors) p.family]);
  expect(got.year, want.year);
  expect(got.month, want.month);
  if (day) expect(got.day, want.day);
  expect(got.container, want.container);
  expect(got.publisher, want.publisher);
  expect(got.place, want.place);
  expect(got.volume, want.volume);
  expect(got.issue, want.issue);
  expect(got.pages.replaceAll('-', '–'), want.pages.replaceAll('-', '–'));
  expect(got.edition, want.edition);
  expect(got.doi, want.doi);
  expect(got.url, want.url);
  expect(got.isbn, want.isbn);
  expect(got.accessed, want.accessed);
}

void main() {
  group('CSL-JSON', () {
    test('is an array another manager can read, and comes back whole', () {
      final text = exportCslJson(all);
      expect(jsonDecode(text), isA<List>());
      final back = importReferences(text);
      expect(back, hasLength(all.length));
      for (final (i, s) in all.indexed) {
        same(back[i], s);
      }
    });

    test('a day a page was read is a date Zotero understands', () {
      final item = (jsonDecode(exportCslJson([web])) as List).single as Map;
      expect(item['accessed'], {
        'date-parts': [
          [2024, 5, 6],
        ],
      });
    });
  });

  group('BibTeX', () {
    test('comes back whole (the day of a date is not kept)', () {
      final back = importReferences(exportBibtex(all));
      expect(back, hasLength(all.length));
      for (final (i, s) in all.indexed) {
        same(back[i], s, day: false);
      }
    });

    test('writes what LaTeX needs', () {
      final text = exportBibtex([article, web]);
      expect(text, contains('@article{smith2020,'));
      expect(text, contains('@online{web,'));
      expect(text, contains(r'title = {Cats \& dogs: 100\% of the \_best\_ \#1}'));
      expect(text, contains('author = {Smith, John and Müller, Anna Maria}'));
      expect(text, contains('pages = {34--56}'));
      expect(text, contains('month = mar'));
      expect(text, contains('urldate = {2024-05-06}'));
    });

    test('an organisation is one name, braced', () {
      expect(exportBibtex([book]), contains('author = {{World Health Organization}}'));
      final back = importReferences(exportBibtex([book])).single;
      expect(back.authors.single.literal, isTrue);
    });

    test('a key BibTeX would not take is made one', () {
      final text = exportBibtex([article.copyWith(id: 'a b,c')]);
      expect(text, contains('@article{a_b_c,'));
    });

    test('braces in a title cannot unbalance an entry', () {
      final back = importReferences(exportBibtex([book.copyWith(title: 'Odd {title} }')])).single;
      expect(back.title, 'Odd title');
    });
  });

  group('RIS', () {
    test('comes back whole', () {
      final back = importReferences(exportRis(all));
      expect(back, hasLength(all.length));
      for (final (i, s) in all.indexed) {
        same(back[i], s);
      }
    });

    test('has the tags of the format', () {
      final text = exportRis([article]);
      expect(text, startsWith('TY  - JOUR\nID  - smith2020\n'));
      expect(text, contains('AU  - Smith, John\n'));
      expect(text, contains('JO  - Journal of Pets\n'));
      expect(text, contains('SP  - 34\nEP  - 56\n'));
      expect(text, contains('DA  - 2020/03/04\n'));
      expect(text, contains('ER  - \n'));
    });

    test('an empty library is an empty text', () {
      expect(exportRis(const []), '');
      expect(exportBibtex(const []), '');
      expect(importReferences(exportCslJson(const [])), isEmpty);
    });
  });

  test('the formats are named for the menu', () {
    expect(ExportFormat.values.map((f) => f.extension), ['bib', 'ris', 'json']);
    expect(ExportFormat.ris.write([article]), exportRis([article]));
  });
}
