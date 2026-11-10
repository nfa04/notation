import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/citation_style.dart';
import 'package:notes/citations/source.dart';

void main() {
  const article = CitationSource(
    id: 'smith2020',
    type: SourceType.article,
    title: 'Deep learning for notes',
    authors: [Person('Smith', 'John Albert'), Person('Jones', 'Mary')],
    year: 2020,
    container: 'Journal of Notes',
    volume: '5',
    issue: '2',
    pages: '10-25',
    doi: '10.1000/xyz',
  );
  const book = CitationSource(
    id: 'doe2019',
    title: 'The Book of Citing',
    authors: [Person('Doe', 'Jane')],
    year: 2019,
    publisher: 'Penguin',
    place: 'London',
    edition: '2nd',
  );
  const numbers = {'smith2020': 1, 'doe2019': 2};

  group('entries', () {
    test('APA', () {
      const s = ApaStyle();
      expect(s.entry(article), 'Smith, J. A., & Jones, M. (2020). Deep learning for notes. *Journal of Notes*, *5*(2), 10–25. https://doi.org/10.1000/xyz');
      expect(s.entry(book), 'Doe, J. (2019). *The Book of Citing* (2nd ed.). Penguin.');
    });

    test('MLA', () {
      const s = MlaStyle();
      expect(s.entry(article), 'Smith, John Albert, and Mary Jones. "Deep learning for notes." *Journal of Notes*, vol. 5, no. 2, 2020, pp. 10–25, doi.org/10.1000/xyz.');
      expect(s.entry(book), 'Doe, Jane. *The Book of Citing*. 2nd ed., Penguin, 2019.');
    });

    test('Chicago', () {
      const s = ChicagoStyle();
      expect(s.entry(article), 'Smith, John Albert, and Mary Jones. 2020. "Deep learning for notes." *Journal of Notes* 5 (2): 10–25. https://doi.org/10.1000/xyz.');
      expect(s.entry(book), 'Doe, Jane. 2019. *The Book of Citing*. 2nd ed. London: Penguin.');
    });

    test('Harvard', () {
      const s = HarvardStyle();
      expect(s.entry(article), "Smith, J. A. and Jones, M. (2020) 'Deep learning for notes', *Journal of Notes*, 5(2), pp. 10–25. doi:10.1000/xyz.");
      expect(s.entry(book), 'Doe, J. (2019) *The Book of Citing*. 2nd edn. London: Penguin.');
    });

    test('IEEE', () {
      const s = IeeeStyle();
      expect(s.entry(article, number: 1), '[1] J. A. Smith and M. Jones, "Deep learning for notes," *Journal of Notes*, vol. 5, no. 2, pp. 10–25, 2020, doi: 10.1000/xyz.');
      expect(s.entry(book, number: 2), '[2] J. Doe, *The Book of Citing*, 2nd ed., London: Penguin, 2019.');
    });

    test('a source without a year is n.d., one without authors starts with its title', () {
      const web = CitationSource(id: 'w', type: SourceType.webpage, title: 'A page', container: 'Site', url: 'https://x.org/a');
      expect(const ApaStyle().entry(web), '*A page*. (n.d.). Site. https://x.org/a');
    });
  });

  group('in the text', () {
    final withPage = [Cite(article, Locator.parse('p. 42')), Cite(book)];

    test('APA sorts by author and writes the page with p.', () {
      expect(const ApaStyle().inText(withPage, numbers), '(Doe, 2019; Smith & Jones, 2020, p. 42)');
    });

    test('MLA writes the page without p.', () {
      expect(const MlaStyle().inText(withPage, numbers), '(Smith and Jones 42; Doe)');
    });

    test('Chicago', () {
      expect(const ChicagoStyle().inText(withPage, numbers), '(Smith and Jones 2020, 42; Doe 2019)');
    });

    test('Harvard', () {
      expect(const HarvardStyle().inText(withPage, numbers), '(Doe, 2019; Smith and Jones, 2020, p. 42)');
    });

    test('IEEE cites by number', () {
      expect(const IeeeStyle().inText(withPage, numbers), '[1, p. 42], [2]');
    });

    test('three authors become et al. in APA', () {
      const many = CitationSource(id: 'm', title: 'T', year: 2001, authors: [Person('A', 'x'), Person('B', 'y'), Person('C', 'z')]);
      expect(const ApaStyle().inText([Cite(many)], {}), '(A et al., 2001)');
      expect(const HarvardStyle().inText([Cite(many)], {}), '(A, B and C, 2001)');
    });
  });

  group('locators', () {
    test('are read from what a person types', () {
      expect(Locator.parse('p. 42')!.text(), 'p. 42');
      expect(Locator.parse('42')!.text(), 'p. 42');
      expect(Locator.parse('pp. 3-5')!.text(), 'pp. 3–5');
      expect(Locator.parse('ch. 2')!.text(), 'ch. 2');
      expect(Locator.parse('ch. 2')!.text(bare: true), 'ch. 2');
      expect(Locator.parse('p. 42')!.text(bare: true), '42');
      expect(Locator.parse('  '), isNull);
    });
  });
}
