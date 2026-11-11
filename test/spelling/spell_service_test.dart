import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/spelling/hunspell.dart';
import 'package:notes/spelling/spell_checker.dart';
import 'package:notes/spelling/spell_service.dart';

import 'hunspell_test.dart' show english, englishWords, german, germanWords;

Future<HunspellDictionary> dict(String aff, String dic) => HunspellDictionary.parse(utf8.encode(aff), utf8.encode(dic));

class Settings {
  final map = <String, String>{};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
}

void main() {
  group('finding the words to check', () {
    List<String> words(String text) => [for (final r in spellWords(text)) text.substring(r.start, r.end)];

    test('words, with their apostrophes and hyphens inside', () {
      expect(words("Don't stop, well-known facts."), ["Don't", 'stop', 'well-known', 'facts']);
      expect(words('naïve café Straße'), ['naïve', 'café', 'Straße']);
      expect(words('a I x'), isEmpty, reason: 'single letters');
    });

    test('code, formulas, addresses, tags and numbers are left alone', () {
      expect(words('see `foo_bar` and \$x^2 + yy\$ now'), ['see', 'and', 'now']);
      expect(words('```\ncode here\n```\nafter'), ['after']);
      expect(words('go to https://example.com/abc now'), ['go', 'to', 'now']);
      expect(words('mail me@example.org please'), ['mail', 'please']);
      expect(words(r'the \frac and #tag and @mention'), ['the', 'and', 'and']);
      expect(words('abc123 room 42 3rd'), ['room']);
      expect(words('a [link](https://x.y/zzz) here'), ['link', 'here']);
    });
  });

  group('the checker', () {
    late SpellChecker checker;
    setUp(() async {
      checker = SpellChecker()..dictionaries = [await dict(english, englishWords), await dict(german, germanWords)];
    });

    test('a word is right in any language that is on', () {
      expect(checker.isCorrect('cat'), isTrue);
      expect(checker.isCorrect('Haus'), isTrue);
      expect(checker.isCorrect('Hausbank'), isTrue);
      expect(checker.isCorrect('katz'), isFalse);
    });

    test('where the mistakes are', () {
      const text = 'The cat and the Haus have a catt.';
      expect([for (final r in checker.misspellings(text)) text.substring(r.start, r.end)], ['and', 'have', 'a', 'catt'].where((w) => w.length > 1 && !checker.isCorrect(w)).toList());
    });

    test('nothing is checked without a dictionary', () {
      expect((SpellChecker()).misspellings('anything goes hrre'), isEmpty);
    });

    test('the own words and the words set aside', () {
      expect(checker.isCorrect('Zorblax'), isFalse);
      checker.personal = {'Zorblax'};
      expect(checker.isCorrect('Zorblax'), isTrue);
      expect(checker.isCorrect('zorblax'), isFalse, reason: 'as it was added');
      checker.ignore('Wibble');
      expect(checker.isCorrect('wibble'), isTrue);
    });

    test('suggestions from every language', () {
      expect(checker.suggestions('teh'), contains('the'));
      expect(checker.suggestions('Haus bank'), isNotNull);
    });
  });

  group('the service', () {
    late Directory dir;
    late Settings settings;
    final downloads = <String>[];
    var failFrequencies = false;

    SpellService make() => SpellService(
          settings.read,
          settings.write,
          languages: const [
            DictionaryLanguage('en_US', 'English', 'en', 'en_US', 1),
            DictionaryLanguage('de_DE', 'Deutsch', 'de', 'de_DE', 1),
          ],
          directory: (l) async => Directory('${dir.path}/${l.id}'),
          download: (url, path, progress) async {
            downloads.add(url);
            if (url.contains('FrequencyWords')) {
              if (failFrequencies) throw const SocketException('no lists');
              await File(path).writeAsString('the 100\ncat 90\ndog 80\n');
              return;
            }
            final l = url.contains('/en/') ? 'en' : 'de';
            final isAff = url.endsWith('.aff');
            await File(path).writeAsString(l == 'en' ? (isAff ? english : englishWords) : (isAff ? german : germanWords));
            progress(1);
          },
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('spell');
      settings = Settings();
      downloads.clear();
      failFrequencies = false;
    });
    tearDown(() => dir.delete(recursive: true));

    test('turning a language on downloads its dictionary and checks with it', () async {
      final service = make();
      await service.load();
      expect(service.active, isFalse);
      expect(service.checker.misspellings('teh cat'), isEmpty, reason: 'nothing to check with yet');

      await service.setOn(service.packs.first.language, true);
      expect(downloads, hasLength(3), reason: 'the two files of the dictionary and the list of common words');
      expect(service.active, isTrue);
      expect(service.checker.misspellings('teh cat').length, 1);
    });

    test('what was turned on is still on after a restart, without a download', () async {
      var service = make();
      await service.load();
      await service.setOn(service.packs.first.language, true);
      downloads.clear();

      service = make();
      await service.load();
      expect(service.active, isTrue);
      expect(service.checker.misspellings('teh cat').length, 1);
      expect(downloads, isEmpty);
    });

    test('a language that is on but whose files are missing is fetched again at the start, and then checks', () async {
      // (the settings came along to another folder of the app, the files did not)
      await settings.write(SpellService.enabledKey, '["en_US"]');
      final service = make();
      await service.load();
      for (var i = 0; i < 50 && !service.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.active, isTrue);
      expect(service.checker.misspellings('teh cat').length, 1);
      expect(downloads.where((u) => u.contains('/en/en_US.')), hasLength(2), reason: 'the two files of the dictionary');
      expect(downloads.where((u) => u.contains('/de/de_DE.')), isEmpty, reason: 'only what is on');
    });

    test('turning it off stops the checking; deleting removes the files', () async {
      final service = make();
      await service.load();
      final en = service.packs.first;
      await service.setOn(en.language, true);
      await service.setOn(en.language, false);
      expect(service.active, isFalse);
      expect(en.installed, isTrue, reason: 'the files stay');
      await service.setOn(en.language, true);
      expect(service.active, isTrue);
      await service.delete(en.language);
      expect(service.active, isFalse);
      expect(en.installed, isFalse);
      expect(service.isOn(en.language), isFalse);
    });

    test('the list of common words is downloaded with the dictionary and ranks the suggestions', () async {
      final service = make();
      await service.load();
      await service.setOn(service.packs.first.language, true);
      expect(downloads.where((u) => u.contains('FrequencyWords')), hasLength(1));
      expect(downloads.last, contains('/en/en_50k.txt'));
      expect(File('${dir.path}/en_US/frequency.txt').existsSync(), isTrue);
    });

    test('a dictionary that was downloaded without the list gets it the next time it is read in', () async {
      var service = make();
      await service.load();
      await service.setOn(service.packs.first.language, true);
      File('${dir.path}/en_US/frequency.txt').deleteSync();
      downloads.clear();
      service = make();
      await service.load();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(downloads.single, contains('FrequencyWords'));
      expect(File('${dir.path}/en_US/frequency.txt').existsSync(), isTrue);
    });

    test('no list is no harm', () async {
      failFrequencies = true;
      final service = make();
      await service.load();
      await service.setOn(service.packs.first.language, true);
      expect(service.active, isTrue);
      expect(service.packs.first.error, isNull);
      expect(File('${dir.path}/en_US/frequency.txt').existsSync(), isFalse);
      expect(File('${dir.path}/en_US/frequency.txt.part').existsSync(), isFalse);
    });

    test('two languages together', () async {
      final service = make();
      await service.load();
      for (final p in service.packs) {
        await service.setOn(p.language, true);
      }
      expect(service.checker.isCorrect('cat'), isTrue);
      expect(service.checker.isCorrect('Haus'), isTrue);
    });

    test('the own words are kept', () async {
      var service = make();
      await service.load();
      await service.addWord('Zorblax');
      await service.addWord('  ');
      service = make();
      await service.load();
      expect(service.checker.personal, {'Zorblax'});
      await service.removeWord('Zorblax');
      expect(service.checker.personal, isEmpty);
    });

    test('a download that fails leaves the language off the air and says why', () async {
      final service = SpellService(settings.read, settings.write,
          languages: const [DictionaryLanguage('en_US', 'English', 'en', 'en_US', 1)],
          directory: (l) async => Directory('${dir.path}/${l.id}'),
          download: (u, p, pr) async => throw const SocketException('offline'));
      await service.load();
      await service.setOn(service.packs.first.language, true);
      expect(service.active, isFalse);
      expect(service.packs.first.error, contains('offline'));
    });
  });

  group('the text field', () {
    late SpellService service;
    setUp(() async {
      final settings = Settings();
      service = SpellService(settings.read, settings.write, languages: const []);
      service.checker.dictionaries = [await dict(english, englishWords)];
    });

    Future<void> later() => Future<void>.delayed(const Duration(milliseconds: 800));

    test('the misspelled words are found a moment after the text changed', () async {
      final c = RichInlineTextController()..useSpelling(service);
      c.text = 'the cat and teh dog';
      expect(c.misspelled, isEmpty, reason: 'not at once');
      await later();
      expect([for (final r in c.misspelled) c.text.substring(r.start, r.end)], ['and', 'teh']);
      c.dispose();
    });

    test('the marks move with the text meanwhile', () async {
      final c = RichInlineTextController()..useSpelling(service);
      c.text = 'teh cat';
      await later();
      expect(c.misspelled.single.start, 0);
      c.text = 'the teh cat';
      expect(c.misspelled, isEmpty, reason: 'the change touched it');
      await later();
      expect(c.text.substring(c.misspelled.single.start, c.misspelled.single.end), 'teh');
      c.text = 'the teh cat!!';
      expect(c.text.substring(c.misspelled.single.start, c.misspelled.single.end), 'teh', reason: 'a change after the word leaves it');
      c.text = 'xx the teh cat!!';
      expect(c.text.substring(c.misspelled.single.start, c.misspelled.single.end), 'teh', reason: 'a change before it moves it');
      c.dispose();
    });

    test('the word being typed is not marked', () async {
      final c = RichInlineTextController()..useSpelling(service);
      c.value = const TextEditingValue(text: 'the ca', selection: TextSelection.collapsed(offset: 6));
      await later();
      expect(c.misspelled, isEmpty);
      c.value = const TextEditingValue(text: 'the ca ', selection: TextSelection.collapsed(offset: 7));
      await later();
      expect(c.misspelled, hasLength(1));
      c.dispose();
    });

    test('words that are added are right at once', () async {
      final c = RichInlineTextController()..useSpelling(service);
      c.text = 'a zorblax here';
      await later();
      expect(c.misspelled.length, greaterThan(0));
      await service.addWord('zorblax');
      await later();
      expect(c.text.substring(c.misspelled.first.start, c.misspelled.first.end), isNot('zorblax'));
      c.dispose();
    });

    test('no marks when spelling is not used, or after it is turned off', () async {
      final c = RichInlineTextController();
      c.text = 'teh';
      await later();
      expect(c.misspelled, isEmpty);
      c.useSpelling(service);
      await later();
      expect(c.misspelled, hasLength(1));
      c.useSpelling(null);
      await later();
      c.text = 'teh teh';
      await later();
      expect(c.misspelled.length, lessThanOrEqualTo(1));
      c.dispose();
    });

    testWidgets('a wavy red line is drawn under the word', (tester) async {
      final c = RichInlineTextController()..useSpelling(service);
      await tester.runAsync(() async {
        c.text = 'the teh';
        await later();
      });
      late TextSpan span;
      await tester.pumpWidget(Builder(builder: (context) {
        span = c.buildTextSpan(context: context, withComposing: false, style: const TextStyle());
        return const SizedBox();
      }));
      final styles = [for (final s in span.children!) (s as TextSpan).style!];
      expect(styles[0].decoration, TextDecoration.none);
      expect(styles[4].decoration, TextDecoration.underline);
      expect(styles[4].decorationStyle, TextDecorationStyle.wavy);
      expect(styles[4].decorationColor, Colors.red);
      c.dispose();
    });
  });
}
