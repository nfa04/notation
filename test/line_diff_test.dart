import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/line_diff.dart';

String show(List<DiffLine> d) => d.join('|');

void main() {
  test('the same text has no difference', () => expect(lineDiff('a\nb', 'a\nb'), isEmpty));

  test('a changed line is a removed and an added one, with a line around it', () {
    expect(show(lineDiff('one\ntwo\nthree\nfour\nfive', 'one\nTWO\nthree\nfour\nfive')), '  one|- two|+ TWO|  three');
  });

  test('lines added and taken out in different places, what is between them folded', () {
    final before = [for (var i = 1; i <= 12; i++) 'l$i'].join('\n');
    final after = before.replaceFirst('l2\n', 'l2\nnew\n').replaceFirst('\nl11', '');
    expect(show(lineDiff(before, after)), '  l1|  l2|+ new|  l3|..6|  l10|- l11|  l12');
  });

  test('a long difference is cut, saying how much more there is', () {
    final d = lineDiff(List.filled(5, 'a').join('\n'), List.generate(200, (i) => 'b$i').join('\n'), maxLines: 10);
    expect(d.length, 11);
    expect(d.last.kind, DiffKind.gap);
  });
}
