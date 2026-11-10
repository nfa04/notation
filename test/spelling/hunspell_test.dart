import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/spelling/hunspell.dart';

Future<HunspellDictionary> dict(String aff, String dic) => HunspellDictionary.parse(utf8.encode(aff), utf8.encode(dic));

const english = '''
SET UTF-8
TRY esianrtolcdugmphbyfvkwzESIANRTOLCDUGMPHBYFVKWZ'
REP 2
REP ei ie
REP f ph
ICONV 1
ICONV ’ '
KEEPCASE K
FORBIDDENWORD X
NOSUGGEST !

PFX U Y 1
PFX U 0 un .

SFX S Y 2
SFX S y ies [^aeiou]y
SFX S 0 s [^y]

SFX D Y 3
SFX D 0 d e
SFX D y ied [^aeiou]y
SFX D 0 ed [^ey]

SFX G Y 2
SFX G e ing e
SFX G 0 ing [^e]

SFX R N 1
SFX R 0 er/S .
''';

const englishWords = '''
12
the/
cat/S
dog/S
try/SDG
bake/DG
happy/UR
Paris
iPhone
NASA/K
badword/X
receive/DG
phone/S
''';

const german = '''
SET UTF-8
TRY enisrtadhulgcmobwfkzpvjyxq
COMPOUNDBEGIN A
COMPOUNDMIDDLE B
COMPOUNDEND C
COMPOUNDMIN 3
COMPOUNDPERMITFLAG P
ONLYINCOMPOUND O
SFX E Y 1
SFX E 0 e/P .
''';
const germanWords = '''
6
Haus/ABCE
Tür/ABCE
Schlüssel/ABC
Bank/ABC
Garten/ABC
Fugen/O
''';

void main() {
  group('words and their forms', () {
    late HunspellDictionary d;
    setUpAll(() async => d = await dict(english, englishWords));

    test('words in the list, and words with their capital', () {
      expect(d.isCorrect('the'), isTrue);
      expect(d.isCorrect('The'), isTrue, reason: 'at the start of a sentence');
      expect(d.isCorrect('THE'), isTrue);
      expect(d.isCorrect('teh'), isFalse);
      expect(d.isCorrect('Paris'), isTrue);
      expect(d.isCorrect('paris'), isFalse, reason: 'a name keeps its capital');
      expect(d.isCorrect('PARIS'), isTrue);
      expect(d.isCorrect('iPhone'), isTrue);
      expect(d.isCorrect('IPhone'), isFalse);
      expect(d.isCorrect('iphone'), isFalse);
    });

    test('suffixes and the conditions they have', () {
      expect(d.isCorrect('cats'), isTrue);
      expect(d.isCorrect('tries'), isTrue);
      expect(d.isCorrect('tried'), isTrue);
      expect(d.isCorrect('trying'), isTrue);
      expect(d.isCorrect('baked'), isTrue);
      expect(d.isCorrect('baking'), isTrue);
      expect(d.isCorrect('phones'), isTrue);
      expect(d.isCorrect('bakeed'), isFalse);
      expect(d.isCorrect('trys'), isFalse, reason: 'the rule for -s is not for words that end in y');
      expect(d.isCorrect('catss'), isFalse);
    });

    test('prefixes, both together, and a suffix that allows another', () {
      expect(d.isCorrect('unhappy'), isTrue);
      expect(d.isCorrect('happily'), isFalse);
      expect(d.isCorrect('happyer'), isTrue);
      expect(d.isCorrect('happyers'), isTrue, reason: 'the suffix -er allows -s');
      expect(d.isCorrect('unhappyer'), isFalse, reason: 'the suffix -er does not combine with a prefix');
      expect(d.isCorrect('unhappies'), isFalse);
      expect(d.isCorrect('untries'), isFalse);
      expect(d.isCorrect('untry'), isFalse, reason: 'try has no flag for un-');
    });

    test('flags: keep case, forbidden', () {
      expect(d.isCorrect('NASA'), isTrue);
      expect(d.isCorrect('nasa'), isFalse);
      expect(d.isCorrect('Nasa'), isFalse);
      expect(d.isCorrect('badword'), isFalse);
    });

    test('numbers, hyphens and the other apostrophe', () {
      expect(d.isCorrect('2024'), isTrue);
      expect(d.isCorrect('3rd'), isTrue);
      expect(d.isCorrect('cat-dog'), isTrue);
      expect(d.isCorrect('cat-xyz'), isFalse);
      expect(d.isCorrect('the’'), isFalse);
    });
  });

  group('suggestions', () {
    late HunspellDictionary d;
    setUpAll(() async => d = await dict(english, englishWords));

    test('a swap, a missing letter, an extra letter, a wrong letter', () {
      expect(d.suggest('teh'), contains('the'));
      expect(d.suggest('recieve'), contains('receive'));
      expect(d.suggest('catt'), contains('cat'));
      expect(d.suggest('cst'), contains('cat'));
      expect(d.suggest('dg'), contains('dog'));
    });

    test('the case is kept', () {
      expect(d.suggest('Teh').first, 'The');
      expect(d.suggest('paris'), contains('Paris'));
    });

    test('one word that should be two', () {
      expect(d.suggest('catdog'), contains('cat dog'));
    });

    test('words with no suggestion flag, forbidden words, and what is correct', () {
      expect(d.suggest('badwor'), isNot(contains('badword')));
      expect(d.suggest('the'), isNot(contains('the')));
    });

    test('two letters wrong, when asked for the deep search', () {
      expect(d.suggest('recive', deep: true), contains('receive'));
      expect(d.suggest('recceivee', deep: true), contains('receive'));
    });
  });

  group('which suggestion comes first', () {
    const aff = "SET UTF-8\nTRY esiarntolcdugmphbyfvkwz'\n";
    const words = "this\nits\nis\nTV\nTVs\nT's\nTia\ntie\ntin\ntip\nlot\ndon\ndon't\nthe\na\n";
    late HunspellDictionary d;
    setUpAll(() async => d = await dict(aff, '15\n$words'));

    // a list of common words as a language has: a few very common ones, then a long tail
    List<String> common(List<String> first, List<String> rare) => [...first, for (var i = 0; i < 3000; i++) 'filler$i', ...rare];

    test('abbreviations and words with apostrophes are not what was meant by an ordinary word', () {
      final s = d.suggest('tis', max: 8);
      expect(s, contains('this'));
      for (final odd in ["T's", 'TVs']) {
        if (s.contains(odd)) expect(s.indexOf('this'), lessThan(s.indexOf(odd)));
      }
    });

    test('with the common words, the common one comes first', () {
      d.useFrequencies(common(['the', 'is', 'this'], ['its', 'tie', 'tip', 'tin']));
      expect(d.suggest('tis').first, 'this');
      expect(d.suggest('Tis').first, 'This', reason: 'at the start of a sentence: with its capital');
      expect(d.suggest('tis'), isNot(contains('TVs')));
    });

    test('a word that only lacks its apostrophe', () {
      d.useFrequencies(common(['the', 'is', 'don'], ['lot']));
      expect(d.suggest('dont').first, "don't");
    });

    test('one word that is two (a single letter only if it is a very common word)', () {
      d.useFrequencies(common(['a', 'the', 'is'], ['lot']));
      expect(d.suggest('alot'), contains('a lot'));
      d.useFrequencies(common(['the'], ['a', 'lot']));
      expect(d.suggest('alot'), isNot(contains('a lot')), reason: 'a is not a common word there');
    });
  });

  group('compounds', () {
    late HunspellDictionary d;
    setUpAll(() async => d = await dict(german, germanWords));

    test('words joined from parts', () {
      expect(d.isCorrect('Haus'), isTrue);
      expect(d.isCorrect('Hausbank'), isTrue);
      expect(d.isCorrect('Haustür'), isTrue);
      expect(d.isCorrect('Haustürschlüssel'), isTrue);
      expect(d.isCorrect('Gartenbank'), isTrue);
      expect(d.isCorrect('Hausfoo'), isFalse);
      expect(d.isCorrect('Fugen'), isFalse, reason: 'only inside a compound');
    });

    test('the last part may have its ending', () {
      expect(d.isCorrect('Haustüre'), isTrue);
    });
  });

  group('character sets', () {
    test('a Latin-1 file', () async {
      final aff = latin1.encode('SET ISO8859-1\nTRY e\n');
      final dic = latin1.encode('2\nGrüße\nStraße\n');
      final d = await HunspellDictionary.parse(aff, dic);
      expect(d.isCorrect('Grüße'), isTrue);
      expect(d.isCorrect('Gruße'), isFalse);
      expect(d.suggest('Strase'), isNotNull);
    });

    test('numbered and long flags', () async {
      final d = await dict('FLAG long\nSFX Aa Y 1\nSFX Aa 0 s .\n', '1\ncat/Aa\n');
      expect(d.isCorrect('cats'), isTrue);
      final n = await dict('FLAG num\nSFX 100 Y 1\nSFX 100 0 s .\n', '1\ncat/100,7\n');
      expect(n.isCorrect('cats'), isTrue);
    });

    test('a broken file is not a crash', () async {
      final d = await dict('SFX A Y 2\nSFX A 0\nPFX\nREP\n', '3\n\n/\nword/\n');
      expect(d.isCorrect('word'), isTrue);
    });
  });
}
