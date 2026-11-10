import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/ai/translation.dart';

void main() {
  group('protecting', () {
    test('formulas, code, link addresses, citations and web addresses are swapped for marks and come back', () {
      const text = r'The area is $\pi r^2$ (see [Circles](note:abc123) and [@knuth84]), run `ls -l`, or https://example.org/a?b=1.';
      final p = protectMarkdown(text);
      expect(p.masked, 'The area is §1§ (see [Circles]§2§ and §3§), run §4§, or §5§.');
      expect(p.pieces, [r'$\pi r^2$', '(note:abc123)', '[@knuth84]', '`ls -l`', 'https://example.org/a?b=1']);
      expect(restoreMarkdown(p.masked, p.pieces), text);
    });

    test('a translation that lost, repeated or invented a mark is refused', () {
      final pieces = ['A', 'B'];
      expect(restoreMarkdown('x §1§ y §2§', pieces), 'x A y B');
      expect(restoreMarkdown('x §1§ y', pieces), isNull);
      expect(restoreMarkdown('x §1§ y §2§ §2§', pieces), isNull);
      expect(restoreMarkdown('x §1§ y §2§ §3§', pieces), isNull);
      expect(restoreMarkdown('no marks', const []), 'no marks');
    });

    test('text with display maths and code blocks keeps them whole', () {
      const text = 'Before\n\$\$\nx = 1\n\$\$\nand\n```dart\nvar a = 1;\n```\n';
      final p = protectMarkdown(text);
      expect(p.pieces.length, 2);
      expect(p.masked, 'Before\n§1§\nand\n§2§\n');
    });
  });

  test('only text with words is worth translating', () {
    expect(worthTranslating('Hello world'), isTrue);
    expect(worthTranslating('12 + 7 = 19'), isFalse);
    expect(worthTranslating(r'$x^2$ `code` 3'), isFalse);
    expect(worthTranslating(r'the area $x$'), isTrue);
    expect(worthTranslating('Привет'), isTrue);
    expect(worthTranslating('   '), isFalse);
  });

  group('chunks', () {
    test('short text is one chunk, long text is cut at blank lines and joins back whole', () {
      expect(chunkForTranslation('short'), ['short']);
      final text = [for (var i = 0; i < 10; i++) 'Paragraph $i ${'word ' * 30}'].join('\n\n');
      final chunks = chunkForTranslation(text, maxChars: 400);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= 400), isTrue);
      expect(joinChunks(chunks), text);
      expect(chunks.skip(1).every((c) => c.startsWith('Paragraph')), isTrue);
    });

    test('one huge paragraph is cut at sentence ends, and still joins back whole', () {
      final text = List.generate(40, (i) => 'This is sentence number $i.').join(' ');
      final chunks = chunkForTranslation(text, maxChars: 300);
      expect(chunks.every((c) => c.length <= 300), isTrue);
      expect(joinChunks(chunks), text);
      expect(chunks.first.endsWith('. '), isTrue);
    });

    test('a long line without spaces is cut anyway', () {
      final text = 'x' * 1000;
      expect(joinChunks(chunkForTranslation(text, maxChars: 300)), text);
    });
  });

  group('cleaning', () {
    test('introductions, thinking, quotes and fences are taken off; the space of the original stays', () {
      expect(cleanTranslation('Here is the translation:\n\nHallo Welt', 'Hello world'), 'Hallo Welt');
      expect(cleanTranslation('<think>hmm</think>Hallo Welt', 'Hello world'), 'Hallo Welt');
      expect(cleanTranslation('"Hallo Welt"', 'Hello world'), 'Hallo Welt');
      expect(cleanTranslation('```\nHallo Welt\n```', 'Hello world'), 'Hallo Welt');
      expect(cleanTranslation('Hallo Welt', '\n\nHello world\n'), '\n\nHallo Welt\n');
    });

    test('quotes that the original had stay', () {
      expect(cleanTranslation('"Hallo"', '"Hello"'), '"Hallo"');
    });
  });

  test('the prompt tells the language and asks for the marks to be kept', () {
    final p = translationPrompt('Hello §1§', 'German');
    expect(p.system, contains('German'));
    expect(p.system, contains('§1§'));
    expect(p.user, 'Hello §1§');
  });

  group('NoteTranslator', () {
    Future<String> fake(AiPrompt p, {AiCancel? cancel}) async => switch (p.user) {
          'Hello' => 'Hallo',
          'The area is §1§' => 'Die Fläche ist §1§',
          'Lose the mark §1§' => 'Verliere die Marke',
          'Boom' => throw StateError('model failed'),
          _ => 'Hier ist die Übersetzung:\n${p.user}',
        };

    test('each part is translated with the marks restored', () async {
      final t = NoteTranslator(fake);
      expect(await t.translate('Hello', 'German'), 'Hallo');
      expect(await t.translate(r'The area is $x^2$', 'German'), r'Die Fläche ist $x^2$');
      expect(t.kept, 0);
    });

    test('a part the model spoiled stays as it was, and is counted', () async {
      final t = NoteTranslator(fake);
      expect(await t.translate(r'Lose the mark $a$', 'German'), r'Lose the mark $a$');
      expect(await t.translate('Boom', 'German'), 'Boom');
      expect(t.kept, 2);
    });

    test('text with no words is not sent, and a cancelled run keeps the rest', () async {
      var asked = 0;
      final t = NoteTranslator((p, {cancel}) async {
        asked++;
        return 'Hallo';
      });
      expect(await t.translate('1 + 2', 'German'), '1 + 2');
      expect(asked, 0);
      final cancel = AiCancel()..cancel();
      expect(await t.translate('Hello', 'German', cancel: cancel), 'Hello');
      expect(asked, 0);
    });
  });

  group('translating the lines of a page', () {
    // answers numbered lines the way a good model does
    String answer(String user, Map<String, String> words) => [
          for (final line in user.split('\n'))
            () {
              final m = RegExp(r'^(\d+)\| (.*)$').firstMatch(line)!;
              var text = m.group(2)!;
              words.forEach((from, to) => text = text.replaceAll(from, to));
              return '${m.group(1)}| $text';
            }(),
        ].join('\n');

    test('the lines go out numbered in one request and come back one for one, formulas kept', () async {
      final prompts = <AiPrompt>[];
      final t = NoteTranslator((p, {cancel}) async {
        prompts.add(p);
        return answer(p.user, {'Hello there,': 'Hallo,', 'the area is': 'die Fläche ist'});
      });
      final out = await t.translateLines(['Hello there,', 'the area is \$x^2\$', '42', 'the area is \$y\$'], 'German');
      expect(out, ['Hallo,', 'die Fläche ist \$x^2\$', '42', 'die Fläche ist \$y\$']);
      expect(prompts.length, 1); // ("42" has no words and is not sent)
      expect(prompts.single.user, startsWith('1| Hello there,\n2| the area is §101§'));
      expect(prompts.single.system, contains('German'));
      expect(t.kept, 0);
    });

    test('a line the model left out is asked for on its own, and one it cannot do stays as it was', () async {
      final prompts = <String>[];
      final t = NoteTranslator((p, {cancel}) async {
        prompts.add(p.user);
        if (p.user.contains('|')) return '1| Eins\n3| Drei'; // (line 2 skipped)
        return p.user == 'Two' ? 'Zwei' : throw StateError('failed');
      });
      final out = await t.translateLines(['One', 'Two', 'Three'], 'German');
      expect(out, ['Eins', 'Zwei', 'Drei']);
      expect(t.kept, 0);

      final t2 = NoteTranslator((p, {cancel}) async => throw StateError('down'));
      expect(await t2.translateLines(['One', 'Two'], 'German'), ['One', 'Two']);
      expect(t2.kept, 2);
    });

    test('long pages go out in several requests, and the progress is reported', () async {
      var requests = 0;
      final t = NoteTranslator((p, {cancel}) async {
        requests++;
        return answer(p.user, {});
      });
      final progress = <int>[];
      await t.translateLines([for (var i = 0; i < 10; i++) 'Line number $i of the page'], 'German', maxChars: 60, onBatch: progress.add);
      expect(requests, greaterThan(2));
      expect(progress.last, 10);
    });
  });
}
