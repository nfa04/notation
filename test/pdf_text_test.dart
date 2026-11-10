import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/pdf_text.dart';

String why(void Function() f) {
  try {
    f();
  } on ExtensionError catch (e) {
    return e.message;
  }
  return 'fine';
}

void main() {
  final pages = ['Cells are small.', '', 'Mitochondria make energy.\nThe cell needs it.', 'The end.'];

  test('pages are read under their numbers, a page without text says so', () {
    final text = readPdfPages(pages);
    expect(text, startsWith('The PDF has 4 pages.'));
    expect(text, contains('Page 1:\nCells are small.'));
    expect(text, contains('Page 2:\n(no text on this page'));
    expect(text, contains('Page 3:\nMitochondria make energy.\nThe cell needs it.'));
    expect(text, contains('Page 4:\nThe end.'));
    expect(readPdfPages(pages, from: 3, to: 3), isNot(contains('Page 4')));
    expect(readPdfPages(pages, from: 3), contains('Page 4'));
    expect(readPdfPages(pages, from: 4, to: 9), contains('The PDF ends at page 4'));
  });

  test('a long PDF is read in parts that say where to go on', () {
    final long = [for (var i = 0; i < 30; i++) 'word ' * 200];
    final first = readPdfPages(long);
    expect(first.length, lessThanOrEqualTo(pdfReadLimit + 200));
    final stop = RegExp(r'Stopped before page (\d+)').firstMatch(first)!;
    final next = int.parse(stop.group(1)!);
    expect(first, contains('Page ${next - 1}:'));
    expect(first, isNot(contains('Page $next:')));
    expect(first, contains('"from": $next'));
    expect(readPdfPages(long, from: next), contains('Page $next:'));
  });

  test('one page longer than the limit is cut and the rest of the PDF is pointed to', () {
    final text = readPdfPages(['x' * 30000, 'second'], limit: 1000);
    expect(text.length, lessThan(1200));
    expect(text, contains('it is cut here'));
    expect(text, contains('"from": 2'));
  });

  test('pages that are not there are said', () {
    expect(why(() => readPdfPages(pages, from: 5)), contains('There is no page 5: the PDF has 4 pages'));
    expect(why(() => readPdfPages(pages, from: 0)), contains('There is no page 0'));
    expect(why(() => readPdfPages(pages, from: 3, to: 2)), contains('before'));
    expect(why(() => readPdfPages([])), contains('no pages'));
  });

  test('the pages with all the words are found, with a snippet', () {
    final found = searchPdfPages(pages, 'cell needs');
    expect(found.map((f) => f['page']), [3]);
    expect(found.single['snippet'], contains('The cell needs it.'));
    expect(searchPdfPages(pages, 'CELLS').map((f) => f['page']), [1]);
    expect(searchPdfPages(pages, 'nothing here'), isEmpty);
    expect(searchPdfPages([for (var i = 0; i < 50; i++) 'cell'], 'cell'), hasLength(20));
    expect(why(() => searchPdfPages(pages, '  ')), contains('empty'));
  });
}
