import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/l10n/german.dart';

/// Texts that are shown as they are in every language: addresses and examples of them, names, labels that are not shown at all (a few
/// words that look like texts to the search below).
const _asTheyAre = {
  '10.1000/xyz123  /  978-3-16-148410-0',
  'live',
  'title',
  'Notation',
  'Nextcloud',
  'https://',
  'wss://signal.example.org',
  'turn:turn.example.org:3478',
  'https://cloud.example.com',
  'https://<account>.r2.cloudflarestorage.com',
  'notation://sync?...',
  'ABCDE-FGHJK-MNPQR-STUVW-XY234',
  '{error}',
};

final _literal = RegExp(r'''\'((?:[^'\\\n]|\\.)*)'|"((?:[^"\\\n]|\\.)*)"''');
final _space = RegExp(r'\s*');

/// The string literals that follow each other from [at] (Dart joins them), cut into the text they make; null if there is none.
({String text, int end})? _joined(String source, int at) {
  final parts = StringBuffer();
  var i = at, any = false;
  while (true) {
    final m = _literal.matchAsPrefix(source, i);
    if (m == null) break;
    parts.write(m.group(1) ?? m.group(2));
    any = true;
    i = m.end;
    final next = _space.matchAsPrefix(source, i)!.end;
    if (_literal.matchAsPrefix(source, next) != null) {
      i = next;
      continue;
    }
    break;
  }
  return any ? (text: parts.toString(), end: i) : null;
}

String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m.group(1)) { 'n' => '\n', 't' => '\t', final c => c!});

/// The texts of [source] that the app translates (`Text('...')`, `tr('...')`, `trCount(n, '...', '...')`, a `tooltip:`, `label:`, `title:`,
/// `hintText:` and the like with a literal) and that [known] has no entry for. A text with `$` in it is put together at run time and
/// is not looked at; `Text.verbatim` is left alone, as it is not translated.
Set<String> untranslatedIn(String source, Set<String> known) {
  final start = RegExp(r"""(?:\bText\(|\btr\(|\btrCount\((?:[^,()]|\((?:[^()]|\([^()]*\))*\))*,\s*|(?:tooltip|labelText|hintText|label|title|helperText|semanticsLabel):\s*(?:const\s+)?(?:Text\()?)\s*(?:const\s+)?(?=['"])""");
  final missing = <String>{};
  for (final m in start.allMatches(source)) {
    final first = _joined(source, m.end);
    if (first == null) continue;
    final texts = [first.text];
    if (source.startsWith('trCount(', m.start)) {
      final comma = RegExp(r'\s*,\s*').matchAsPrefix(source, first.end);
      final second = comma == null ? null : _joined(source, comma.end);
      if (second != null) texts.add(second.text);
    }
    for (final raw in texts) {
      if (raw.contains(r'$')) continue;
      final text = _unescape(raw);
      if (!RegExp(r'[A-Za-z]{3}').hasMatch(text) || known.contains(text) || _asTheyAre.contains(text)) continue;
      missing.add(text);
    }
  }
  return missing;
}

void main() {
  group('finding the texts that are not translated', () {
    final known = {'Known', 'Joined text', '{n} apple', '{n} apples'};

    test('a text in Text, tr, a tooltip or a label is looked for, one in the table is fine', () {
      const code = """
        Text('Known'), Text('Unknown one'), tr('Another unknown'), IconButton(tooltip: 'A tip'), const Text("Double quoted"),
        label: 'Label here', hintText: const Text('Hint here')
      """;
      expect(untranslatedIn(code, known), {'Unknown one', 'Another unknown', 'A tip', 'Double quoted', 'Label here', 'Hint here'});
    });

    test('texts that Dart joins are one text', () {
      const code = """
        Text('Joined '
            'text'),
        Text('Half of '
            "a text"),
      """;
      expect(untranslatedIn(code, known), {'Half of a text'});
    });

    test('both words of a count are looked for, also after a call', () {
      const code = "trCount(items.length, '{n} apple', '{n} pears'), trCount(math.max(a, b).round(), '{n} cat', '{n} apples')";
      expect(untranslatedIn(code, known), {'{n} pears', '{n} cat'});
    });

    test('a verbatim text, a text put together at run time, an escaped quote and a word that is not one', () {
      const code = r"""
        Text.verbatim('Not translated'), Text('Value $x'), Text('It\'s new'), Text('...'), Text(variable)
      """;
      expect(untranslatedIn(code, known), {"It's new"});
    });
  });

  test('every text of the app that is shown is in the German table', () {
    final known = germanTexts.keys.toSet();
    final missing = <String, Set<String>>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart') || entity.path.startsWith('lib/l10n')) continue;
      final texts = untranslatedIn(entity.readAsStringSync(), known);
      if (texts.isNotEmpty) missing[entity.path] = texts;
    }
    expect(missing, isEmpty,
        reason: 'add these to lib/l10n/german.dart (or, if they are not words, to _asTheyAre in this test):\n'
            '${missing.entries.map((e) => '${e.key}\n${e.value.map((t) => '    $t').join('\n')}').join('\n')}');
  });
}
