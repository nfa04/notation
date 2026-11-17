import 'package:flutter_test/flutter_test.dart';
import 'package:notes/search/fuzzy.dart';
import 'package:notes/search/search_filter.dart';
import 'package:notes/search/search_query.dart';

List<String> found(String text, String query) => [for (final r in fuzzyRanges(text, query)) text.substring(r.start, r.end)];

void main() {
  group('typos', () {
    test('the distance counts a letter put in, left out, changed or swapped as one', () {
      expect(editDistance('receive', 'recieve', 2), 1); // swapped
      expect(editDistance('kitten', 'sitting', 3), 3);
      expect(editDistance('abc', 'abc', 2), 0);
      expect(editDistance('a', 'abcdef', 2), greaterThan(2));
    });

    test('longer words may be more off; short ones must be right', () {
      expect(found('I will receive it', 'recieve'), ['receive']);
      expect(found('Herr Schmitt kommt', 'Schmidt'), ['Schmitt']);
      expect(found('the cat sat', 'cot'), isEmpty); // three letters: no typos
      expect(found('the cat sat', 'cat'), ['cat']);
      expect(found('photosynthesis in leaves', 'fotosynthesis'), ['photosynthesis']); // two off in a long word
    });

    test('several words are found next to each other, in order, each with its own typos', () {
      expect(found('The quick brown fox', 'quik brwn'), ['quick brown']);
      expect(found('brown quick', 'quick brown'), isEmpty);
      expect(found('quick red brown', 'quick brown'), isEmpty);
    });

    test('case is ignored unless asked for; a query with no words finds nothing', () {
      expect(found('RECEIVE', 'recieve'), ['RECEIVE']);
      expect(fuzzyRanges('RECEIVE', 'recieve', caseSensitive: true), isEmpty);
      expect(fuzzyRanges('anything', '  ... '), isEmpty);
    });

    test('a search that finds nothing as typed is tried again with typos, and says so; one that finds something is left alone', () {
      const sources = [SearchSource('a', SearchPlace.document, 'I will receive it')];
      final near = searchWithTypos(const SearchQuery('recieve'), sources);
      expect(near.similar, isTrue);
      expect(near.total, 1);
      final exact = searchWithTypos(const SearchQuery('receive'), sources);
      expect(exact.similar, isFalse);
      expect(searchWithTypos(const SearchQuery('xyzzyplugh'), sources).total, 0);
      expect(searchWithTypos(const SearchQuery('rec.eve', regex: true), sources).similar, isFalse);
      expect(searchWithTypos(const SearchQuery('cat'), sources).similar, isFalse); // too short for typos
    });

    test('a query with typos allowed finds both, and goes over to the isolate and back', () {
      const q = SearchQuery('recieve');
      expect(q.find('I receive it'), isEmpty);
      expect(q.withTypos.find('I receive it'), hasLength(1));
      expect(SearchQuery.fromJson(q.withTypos.toJson()).fuzzy, isTrue);
      expect(SearchQuery.fromJson(q.toJson()).fuzzy, isFalse);
    });
  });

  group('best match first', () {
    SearchHit hit(SearchPlace p) => SearchHit(noteId: 'n', place: p, page: 0, before: '', match: 'x', after: '');

    test('a title says more than the body, and the body more than a PDF', () {
      final inTitle = relevanceOf([hit(SearchPlace.title)], 1);
      final inBody = relevanceOf([hit(SearchPlace.textBox)], 1);
      final inPdf = relevanceOf([hit(SearchPlace.pdfText)], 1);
      expect(inTitle, greaterThan(inBody));
      expect(inBody, greaterThan(inPdf));
    });

    test('each further match in a place counts less, so ten are not ten times as good', () {
      final one = relevanceOf([hit(SearchPlace.textBox)], 1);
      final ten = relevanceOf([for (var i = 0; i < 10; i++) hit(SearchPlace.textBox)], 10);
      expect(ten, greaterThan(one));
      expect(ten, lessThan(one * 5));
    });
  });
}
