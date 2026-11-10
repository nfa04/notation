import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/grammar.dart';

List<String> messages(String text) => [for (final g in grammarIssues(text)) g.message];

const startsWithCapital = 'A sentence starts with a capital letter';

void main() {
  group('a short form does not end a sentence', () {
    test('the English and German ones, in any case and after an opening mark', () {
      for (final w in ['e.g.', 'i.e.', 'etc.', 'vs.', 'ca.', 'cf.', 'approx.', 'no.', 'Nr.', 'z.B.', 'bzw.', 'usw.', 'vgl.', 'ggf.', 'Dr.', 'Mr.',
        'Mrs.', 'Ms.', 'Prof.', 'St.', 'Fig.', 'p.', 'pp.', 'vol.', 'ed.', 'eds.', 'E.G.', 'DR.', '(e.g.', '"Dr.', '(vgl.', '(Prof.']) {
        expect(isAbbreviation(w), isTrue, reason: w);
      }
    });

    test('a single letter, an initial, and a number with a full stop', () {
      for (final w in ['A.', 'J.', 'J.R.R.', 'Ph.D.', '(B.', 'é.', 'Ä.', '3.', '2026.', 'Section 4.']) {
        expect(isAbbreviation(w), isTrue, reason: w);
      }
    });
  });

  group('a word that only ends like a short form is a word', () {
    test('ended, first, casino, claims, Africa, media, hundred, Ukraine', () {
      for (final w in ['ended.', 'first.', 'casino.', 'claims.', 'Africa.', 'media.', 'hundred.', 'Ukraine.', 'closed.', 'last.', 'Frost.', 'Mrs',
        'ceta.', 'topic.', 'ratio.', 'Monaco.', 'pro.', 'vsa.', 'help.', 'jump.', 'ag.']) {
        expect(isAbbreviation(w), isFalse, reason: w);
      }
    });

    test('without a full stop nothing is a short form', () {
      for (final w in ['Dr', 'e.g', 'etc', '', 'word', '.']) {
        expect(isAbbreviation(w), isFalse, reason: w);
      }
    });
  });

  group('a small letter after a full stop', () {
    test('is flagged after an ordinary word, also one that ends like a short form', () {
      expect(messages('It ended. then it started.'), contains(startsWithCapital));
      expect(messages('He came first. then she left.'), contains(startsWithCapital));
      expect(messages('We went to the casino. there was music.'), contains(startsWithCapital));
      expect(messages('Nobody has claims. nothing was found.'), contains(startsWithCapital));
      expect(messages('She was in Africa. it was hot.'), contains(startsWithCapital));
    });

    test('is not flagged after a short form', () {
      expect(messages('Ask Dr. smith about it.'), isNot(contains(startsWithCapital)));
      expect(messages('Fruit, e.g. apples and pears.'), isNot(contains(startsWithCapital)));
      expect(messages('Vegetables etc. are healthy.'), isNot(contains(startsWithCapital)));
      expect(messages('Siehe z.B. unten und bzw. oben.'), isNot(contains(startsWithCapital)));
      expect(messages('Written by J. smith in 1999.'), isNot(contains(startsWithCapital)));
      expect(messages('See Fig. 3 for the plan.'), isNot(contains(startsWithCapital)));
    });

    test('is not flagged after an ellipsis, in code, or at the start of the text', () {
      expect(messages('Well... maybe so.'), isNot(contains(startsWithCapital)));
      expect(messages('Run `a. b` now.'), isNot(contains(startsWithCapital)));
      expect(messages('lowercase at the very start.'), isNot(contains(startsWithCapital)));
    });

    test('the suggested replacement is the capital letter', () {
      final issues = grammarIssues('It ended. then it began.');
      final g = issues.firstWhere((g) => g.message == startsWithCapital);
      expect(g.replacement, 'T');
    });
  });

  group('other rules, as they stand', () {
    test('a text without any problem has none', () {
      expect(messages('This is fine. It works, and so does this.'), isEmpty);
      expect(messages(''), isEmpty);
    });

    test('a word written twice, two spaces, a space before a comma', () {
      expect(messages('This is is wrong.'), contains('"is" is written twice'));
      expect(messages('One  two.'), contains('Two spaces'));
      expect(messages('One , two.'), contains('A space before ","'));
    });

    test('a and an follow the sound, not the letter', () {
      expect(messages('An hour later.'), isEmpty);
      expect(messages('A user came.'), isEmpty);
      expect(messages('A apple fell.'), contains('"an" before a vowel'));
      expect(messages('He ate an pear.'), contains('"a" before a consonant'));
    });

    test('code, formulas and links are not prose', () {
      expect(messages('```\nthis is is code.  and  more\n```'), isEmpty);
      expect(messages(r'The value $a  a$ is fine.'), isEmpty);
    });
  });
}
