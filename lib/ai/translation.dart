import 'ai_prompt.dart';
import 'text_provider.dart';

/// The languages a note can be translated into: the code of the language picker -> its name in English, as the model is told it.
const translationTargets = {
  'en': 'English',
  'de': 'German',
  'fr': 'French',
  'es': 'Spanish',
  'it': 'Italian',
  'pt': 'Portuguese',
  'nl': 'Dutch',
  'pl': 'Polish',
  'ru': 'Russian',
  'tr': 'Turkish',
  'ar': 'Arabic',
  'zh-CN': 'Chinese (Simplified)',
  'ja': 'Japanese',
  'ko': 'Korean',
};

/// Text with two letters in a row is words; the rest (a number, a formula, a symbol) is left as it is.
bool worthTranslating(String text) => RegExp(r'\p{L}{2}', unicode: true).hasMatch(text.replaceAll(RegExp(r'\$[^$]*\$|`[^`]*`|https?://\S+'), ' '));

/// The pieces of Markdown that must come through a translation unchanged: formulas, code, the address of a link or picture
/// (`](note:id)`), a citation (`[@key]`) and web addresses.
final _protected = RegExp(
  r'\$\$[\s\S]+?\$\$|\$[^$\n]+\$|```[\s\S]*?```|`[^`\n]+`|(?<=\])\([^)\n]*\)|\[[^\]\n]*@[^\]\n]+\]|(?<![\w@.])@[A-Za-z0-9_][\w:.\-/]*|https?://[^\s)]*[^\s).,;:!?]',
);

/// [text] with the protected pieces replaced by marks (`§1§`) that the model is told to keep, and the pieces.
({String masked, List<String> pieces}) protectMarkdown(String text) {
  final pieces = <String>[];
  final masked = text.replaceAllMapped(_protected, (m) {
    pieces.add(m.group(0)!);
    return '§${pieces.length}§';
  });
  return (masked: masked, pieces: pieces);
}

/// [translated] with the marks replaced by the pieces again; null when a mark is missing or came twice (the model dropped or
/// repeated it, so the text cannot be trusted to have the same formulas and links).
String? restoreMarkdown(String translated, List<String> pieces) {
  for (var i = 1; i <= pieces.length; i++) {
    if ('§$i§'.allMatches(translated).length != 1) return null;
  }
  // marks that were not given
  if (RegExp(r'§(\d+)§').allMatches(translated).any((m) => int.parse(m.group(1)!) > pieces.length)) return null;
  return translated.replaceAllMapped(RegExp(r'§(\d+)§'), (m) => pieces[int.parse(m.group(1)!) - 1]);
}

/// [text] cut into parts of at most [maxChars] characters at blank lines (a paragraph longer than that at its line ends, then at
/// the ends of sentences), so that each part is a request the model can answer whole. Joined with [joinChunks] they give [text] back.
List<String> chunkForTranslation(String text, {int maxChars = 1200}) {
  if (text.length <= maxChars) return [text];
  final parts = <String>[];
  for (final paragraph in text.split(RegExp(r'(?<=\n\n)'))) {
    if (paragraph.length <= maxChars) {
      parts.add(paragraph);
      continue;
    }
    for (final line in paragraph.split(RegExp(r'(?<=\n)'))) {
      if (line.length <= maxChars) {
        parts.add(line);
        continue;
      }
      var rest = line;
      while (rest.length > maxChars) {
        var cut = rest.lastIndexOf(RegExp(r'[.!?。] '), maxChars);
        cut = cut > maxChars ~/ 3 ? cut + 2 : rest.lastIndexOf(' ', maxChars);
        if (cut <= 0) cut = maxChars;
        parts.add(rest.substring(0, cut));
        rest = rest.substring(cut);
      }
      if (rest.isNotEmpty) parts.add(rest);
    }
  }
  // put small neighbours together again
  final out = <String>[];
  for (final p in parts) {
    if (out.isNotEmpty && out.last.length + p.length <= maxChars) {
      out[out.length - 1] = out.last + p;
    } else {
      out.add(p);
    }
  }
  return out;
}

String joinChunks(List<String> chunks) => chunks.join();

/// The request to translate [masked] text into [language] (its English name).
AiPrompt translationPrompt(String masked, String language) => AiPrompt(
      system: 'You are a translator inside a note-taking app. Translate the text the user gives you into $language. '
          'Keep the Markdown as it is: headings (#), lists, bold (**), tables (|), line breaks and blank lines. '
          'Marks like §1§ stand for formulas, code or links: copy each one exactly once, in the right place. '
          'Do not add anything: no introduction, no notes, no quotation marks around the answer. Answer with the translation only.',
      user: masked,
      exact: true,
    );

/// What a model wrote with the extras that models put around a translation taken off: a line that announces it, quotation marks or
/// a code block around all of it, and the thinking of models that think aloud. The space at the start and end is that of [original].
String cleanTranslation(String raw, String original) {
  var t = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
  t = t.replaceFirst(RegExp(r'^(?:here(?:\x27s| is) (?:the )?translation[^\n:]*:|translation[^\n:]{0,30}:)\s*', caseSensitive: false), '');
  final fenced = RegExp(r'^```[a-z]*\n([\s\S]*?)\n?```$').firstMatch(t);
  if (fenced != null && !original.trimLeft().startsWith('```')) t = fenced.group(1)!;
  if (t.length > 1 && !original.trim().startsWith('"') && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith('“') && t.endsWith('”')))) {
    t = t.substring(1, t.length - 1);
  }
  t = t.trim();
  final lead = RegExp(r'^\s*').stringMatch(original) ?? '';
  final trail = RegExp(r'\s*$').stringMatch(original) ?? '';
  return '$lead$t$trail';
}

/// Translates text with a model, keeping what must not change, and says how it went.
class NoteTranslator {
  /// Asks the model; the answer is its text.
  final Future<String> Function(AiPrompt prompt, {AiCancel? cancel}) ask;

  NoteTranslator(this.ask);

  /// How many parts could not be translated (the model lost a formula or link, or failed) and were left as they were.
  int kept = 0;

  /// [text] in [language] (the English name). Text with no words in it is returned as it is without asking.
  Future<String> translate(String text, String language, {AiCancel? cancel}) async {
    if (!worthTranslating(text)) return text;
    final out = <String>[];
    for (final chunk in chunkForTranslation(text)) {
      if (cancel?.cancelled ?? false) {
        out.add(chunk);
        continue;
      }
      if (!worthTranslating(chunk)) {
        out.add(chunk);
        continue;
      }
      final p = protectMarkdown(chunk);
      String? result;
      try {
        final answer = await ask(translationPrompt(p.masked, language), cancel: cancel);
        final cleaned = cleanTranslation(answer, p.masked);
        result = cleaned.trim().isEmpty ? null : restoreMarkdown(cleaned, p.pieces);
      } catch (_) {
        result = null;
      }
      if (result == null) kept++;
      out.add(result ?? chunk);
    }
    return joinChunks(out);
  }

  /// The lines of a page (as a PDF draws them) in [language], one answer for each line, in the same order. The lines go to the
  /// model in batches, numbered (`3| text`), so that a sentence cut across lines is read whole; a line the model skipped or
  /// garbled is asked for again on its own, and then left as it was. [onBatch] is told how many lines are done.
  Future<List<String>> translateLines(List<String> lines, String language, {AiCancel? cancel, void Function(int done)? onBatch, int maxChars = 1200}) async {
    final out = List<String>.of(lines);
    final todo = [for (var i = 0; i < lines.length; i++) if (worthTranslating(lines[i])) i];
    var done = 0;
    var from = 0;
    while (from < todo.length) {
      if (cancel?.cancelled ?? false) break;
      var to = from;
      var size = 0;
      while (to < todo.length && (to == from || size + lines[todo[to]].length < maxChars)) {
        size += lines[todo[to]].length + 8;
        to++;
      }
      final batch = todo.sublist(from, to);
      final marks = <int, List<String>>{};
      final masked = StringBuffer();
      for (var n = 0; n < batch.length; n++) {
        final p = protectMarkdown(lines[batch[n]].replaceAll('\n', ' '));
        // (the marks are numbered across the batch, so that they are not mixed up between lines)
        var text = p.masked;
        for (var k = p.pieces.length; k >= 1; k--) {
          text = text.replaceAll('§$k§', '§${n * 100 + k}§');
        }
        marks[n] = p.pieces;
        masked.writeln('${n + 1}| $text');
      }
      final answers = <int, String>{};
      try {
        final answer = await ask(linesPrompt(masked.toString().trimRight(), language), cancel: cancel);
        for (final m in RegExp(r'^\s*(\d+)\s*\|\s?(.*)$', multiLine: true).allMatches(cleanTranslation(answer, masked.toString()))) {
          final n = int.parse(m.group(1)!) - 1;
          if (n >= 0 && n < batch.length) answers.putIfAbsent(n, () => m.group(2)!.trim());
        }
      } catch (_) {}
      for (var n = 0; n < batch.length; n++) {
        String? result;
        final got = answers[n];
        if (got != null && got.isNotEmpty) {
          var t = got;
          for (var k = 1; k <= marks[n]!.length; k++) {
            t = t.replaceAll('§${n * 100 + k}§', '§$k§');
          }
          result = restoreMarkdown(t, marks[n]!);
        }
        // not answered as a line: asked again on its own
        if (result == null && !(cancel?.cancelled ?? false)) {
          final before = kept;
          final alone = await translate(lines[batch[n]], language, cancel: cancel);
          result = kept > before ? null : alone;
          kept = before;
        }
        if (result == null) {
          kept++;
        } else {
          out[batch[n]] = result.replaceAll('\n', ' ').trim();
        }
      }
      done += batch.length;
      onBatch?.call(done);
      from = to;
    }
    return out;
  }
}

/// The request to translate numbered lines of a page.
AiPrompt linesPrompt(String numbered, String language) => AiPrompt(
      system: 'You are a translator inside a note-taking app. The user gives you lines from a page of a document, each starting with a number and a bar ("3| text"). '
          'Together they are running text, cut into lines where the page broke them: read them as one text. '
          'Translate them into $language and answer with the same numbers, one line per number: "3| translated text". '
          'Never merge lines, split a line, skip one or add one; spread the translation over the numbered lines in the order of the original, so each line is about as long as it was. '
          'Marks like §101§ stand for formulas, code or links: copy each one exactly once, on the same line. '
          'Do not add anything: no introduction, no notes. Answer with the numbered lines only.',
      user: numbered,
      exact: true,
    );
