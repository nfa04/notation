import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/checker.dart';
import 'package:notes/algebra/mistake_card.dart';

void main() {
  test('a wrong line becomes a card: the line in front, what is wrong and what it should be behind', () {
    final check = checkLines([r'17 \cdot 24 = 418'])[0];
    expect(check.verdict, Verdict.wrong);
    final card = mistakeCard(r'17 \cdot 24 = 418', check, headline: 'The sum does not work out', page: 2)!;
    expect(card.front, contains(r'17 \cdot 24 = 418'));
    expect(card.front, startsWith('Find the mistake'));
    expect(card.back, startsWith('The sum does not work out.'));
    expect(card.back, contains('408'));
    expect(card.page, 2);
  });

  test('a line that is right, and one the checker said nothing about, make no card', () {
    final right = checkLines([r'17 \cdot 24 = 408'])[0];
    expect(mistakeCard(r'17 \cdot 24 = 408', right, headline: 'x'), isNull);
    expect(mistakeCard('x', LineCheck.nothing, headline: 'x'), isNull);
  });

  test('a problem with nothing to show but the verdict makes no card', () {
    expect(mistakeCard('x = 1', const LineCheck(verdict: Verdict.wrong, reason: Reason.step), headline: 'x'), isNull);
    expect(mistakeCard('  ', const LineCheck(verdict: Verdict.wrong, expected: 'y'), headline: 'x'), isNull);
  });

  test('the words in front of the answer are the ones the sheet uses, and white space is tidied', () {
    final card = mistakeCard('a  =\n b', const LineCheck(verdict: Verdict.wrong, expected: 'a  =  c', counter: r'x=2:\; 1 \neq 2'),
        headline: 'Wrong', expectedLabel: 'The line above has:', counterLabel: 'For example:')!;
    expect(card.front, endsWith('a = b'));
    expect(card.back, 'Wrong.\nThe line above has: a = c\nFor example: ${r'x=2:\; 1 \neq 2'}');
  });
}
