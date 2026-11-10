import 'dart:ui' show Color;

import 'ai_prompt.dart';

/// What the assistant is asked for ideas about.
enum IdeaKind {
  drawing('Drawing', 'drawing prompts for an artist: each a concrete scene or subject with a twist that makes it worth drawing'),
  character('Character', 'characters for a story or a comic: each with a name, a trait, something they want and something that holds them back'),
  story('Story', 'story premises: each says who wants what and what stands in the way'),
  song('Song', 'song ideas: each with a theme, a mood and a first line'),
  design('Design', 'design concepts for a poster, a logo or a cover: each with a central image, a mood and a way to use type');

  /// Shown on the chip (translated where it is shown).
  final String label;

  /// How the instruction names what to make.
  final String phrase;

  const IdeaKind(this.label, this.phrase);
}

/// The prompt that asks for [count] ideas of [kind], on [topic] if there is one. The ideas come back as lines of a bullet list, which
/// [parseIdeas] reads. [language] is where the topic gives none (the app's language).
AiPrompt ideasPrompt(IdeaKind kind, String topic, {int count = 5, String language = 'en'}) => AiPrompt(
      system: 'You help a creative person who is stuck and wants a spark. Give $count different ${kind.phrase}. Make them specific and '
          'surprising, not generic, and keep each to one or two sentences. Answer with a bullet list only: each idea on one line that '
          'starts with "- ". No introduction, no numbering, no closing remarks. Write in the language of the topic; if there is none, '
          'write in the language with the code "$language".',
      user: topic.trim().isEmpty ? 'Give me $count ideas, on any subject.' : 'Topic: ${topic.trim()}',
      exact: true,
    );

final _bullet = RegExp(r'^\s*(?:[-*•]|\d+[.)])\s+');

/// The ideas in what the assistant wrote: the lines of a bullet or numbered list (or, with no list, every line), without the
/// marks, bold or quotes; an introduction that ends with a colon is left out, and so are the ideas that come twice.
List<String> parseIdeas(String text, {int max = 10}) {
  final lines = text.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty).toList();
  final listed = lines.where(_bullet.hasMatch).toList();
  final ideas = <String>[];
  for (final raw in listed.isNotEmpty ? listed : lines) {
    var line = raw.replaceFirst(_bullet, '').replaceAll('**', '').replaceAll('__', '').trim();
    if (line.length > 1 && line.startsWith('"') && line.endsWith('"')) line = line.substring(1, line.length - 1).trim();
    if (line.isEmpty || (listed.isEmpty && line.endsWith(':'))) continue;
    if (!ideas.contains(line)) ideas.add(line);
    if (ideas.length >= max) break;
  }
  return ideas;
}

/// The prompt that asks for a palette of [count] colours for [description], which [parsePalette] reads.
AiPrompt palettePrompt(String description, {int count = 6}) => AiPrompt(
      system: 'You are a colour designer. Suggest a palette of $count colours that go well together for the mood or subject you are '
          'given, from the darkest to the lightest. Answer with exactly $count lines, each like "#RRGGBB name of the colour". '
          'No other text.',
      user: description.trim(),
      exact: true,
    );

final _hex = RegExp(r'#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-zA-Z])');
final _rgb = RegExp(r'rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)', caseSensitive: false);

/// The colours in what the assistant wrote, in the order it wrote them: `#RRGGBB` (or `#RGB`) and `rgb(r, g, b)`. Each colour once;
/// anything else in the text is ignored.
List<Color> parsePalette(String text, {int max = 12}) {
  final found = <(int, Color)>[];
  for (final m in _hex.allMatches(text)) {
    var h = m.group(1)!;
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    found.add((m.start, Color(0xFF000000 | int.parse(h, radix: 16))));
  }
  for (final m in _rgb.allMatches(text)) {
    final r = int.parse(m.group(1)!), g = int.parse(m.group(2)!), b = int.parse(m.group(3)!);
    if (r > 255 || g > 255 || b > 255) continue;
    found.add((m.start, Color.fromARGB(255, r, g, b)));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  final colours = <Color>[];
  for (final (_, c) in found) {
    if (!colours.any((x) => x.toARGB32() == c.toARGB32())) colours.add(c);
    if (colours.length >= max) break;
  }
  return colours;
}
