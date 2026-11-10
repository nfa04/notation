import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../l10n/language.dart';
import 'markdown_parser.dart';

/// Simple checks of how the written document is written (offline, by rules): a word written twice, two spaces, a space before
/// a punctuation mark, a sentence that starts small, "a" before a vowel and "an" before a consonant. Code, formulas, links,
/// citations and the like are not looked at.
class GrammarIssue {
  final int start, end;

  /// What is wrong, and what to write instead.
  final String message, replacement;

  const GrammarIssue(this.start, this.end, this.message, this.replacement);

  @override
  String toString() => 'GrammarIssue($start, $end, $message -> "$replacement")';
}

// (each word against the one after it, also in "a a a": what a word is judged by is only what is next to it)
final _repeated = RegExp(r"\b([\p{L}']+)(\s+)(?=\1\b)", unicode: true, caseSensitive: false);
final _doubleSpace = RegExp(r'(?<=\S)  +(?=\S)');
final _spaceBefore = RegExp(r'(?<=[\p{L}\p{N})\]”’"])\s+([,.;!?])(?!\d)', unicode: true);
final _sentence = RegExp(r'(?<=[.!?][”’"]?\s+)(\p{Ll})', unicode: true);
final _aBeforeVowel = RegExp(r'\b([Aa])\s+(?=([aeiouAEIOU][\p{L}]*))', unicode: true);
final _anBeforeConsonant = RegExp(r'\b([Aa]n)\s+(?=([bcdfgjklmnpqrstvwxyzBCDFGJKLMNPQRSTVWXYZ][\p{L}]*))', unicode: true);

/// Words that sound as if they started with a consonant though they start with a vowel ("a university"), and the other way round
/// ("an hour").
final _vowelButConsonant = RegExp(r'^(uni|use|usu|uti|ure|eu|one|once|ewe|ubiq)', caseSensitive: false);
final _consonantButVowel = RegExp(r'^(hour|honest|honou?r|heir|herb)', caseSensitive: false);

/// Short words that end with a full stop without ending a sentence.
/// (the short words stand on their own: "ended." and "casino." only end in "ed." and "no.", and a sentence starts after them)
final _abbreviation = RegExp(r'(?:(?<![\p{L}\d_])\p{L}|(?<!\p{L})(?:e\.g|i\.e|etc|vs|ca|cf|approx|no|nr|z\.b|bzw|usw|vgl|ggf|dr|mr|mrs|ms|prof|st|fig|p|pp|vol|ed|eds))\.$',
    unicode: true, caseSensitive: false);

/// Whether [word] (with its full stop) is a short form that does not end a sentence: "e.g.", "Dr.", "z.B.", a single letter.
bool isAbbreviation(String word) => _abbreviation.hasMatch(word) || RegExp(r'\d\.$').hasMatch(word);

/// Where the text of [blocks] has prose, from block [first] to block [last]: which characters are plain text (not code, a formula, a
/// link's target, a citation...).
bool Function(int) _prose(String text, List<MdBlock> blocks, int first, int last) {
  final base = blocks[first].start, end = blocks[last].end;
  final out = Uint8List(math.max(0, end - base) + 1);
  for (var k = first; k <= last; k++) {
    final b = blocks[k];
    if (b.type == MdBlockType.code || b.type == MdBlockType.table || b.type == MdBlockType.math || b.type == MdBlockType.setting) continue;
    for (final r in b.runs) {
      if (r.code || r.math || r.cite != null || r.image != null || r.footnote != null || r.ref != null || r.comment || r.deleted) continue;
      for (var i = r.src; i < r.src + r.text.length && i < text.length; i++) {
        if (i >= base && i <= end) out[i - base] = 1;
      }
    }
  }
  return (i) => i >= base && i <= end && out[i - base] == 1;
}

/// The places in [text] that may be written wrong. [blocks]: [text] as it was parsed already.
List<GrammarIssue> grammarIssues(String text, {List<MdBlock>? blocks}) {
  if (text.isEmpty) return const [];
  final parsed = blocks ?? parseMarkdown(text);
  return _issues(text, parsed, 0, parsed.length - 1, 0, parsed.last.end + 1);
}

/// [grammarIssues] of [now], from the [before] of the text it was changed from when it is known: only the blocks around the change
/// are looked at, since a check can reach over the line break to the text next to it (a word written twice, a sentence that starts small).
List<GrammarIssue> grammarIssuesAfter(ParsedText now, String? previous, List<GrammarIssue> before) {
  final from = now.changedFrom;
  final blocks = now.blocks;
  if (from == null || previous == null || !identical(now.previous, previous)) return grammarIssues(now.text, blocks: blocks);
  bool blank(MdBlock b) => now.text.substring(b.start, b.end).trim().isEmpty;
  var first = blockAt(blocks, from), last = blockAt(blocks, now.changedTo);
  for (var i = 0; i < 2 && first > 0; i++) {
    first--;
    while (first > 0 && blank(blocks[first])) {
      first--;
    }
  }
  while (last + 1 < blocks.length && blank(blocks[last + 1])) {
    last++;
  }
  if (last + 1 < blocks.length) last++;
  final start = blocks[first].start, end = blocks[last].end + 1;
  var further = last;
  while (further + 1 < blocks.length && blank(blocks[further + 1])) {
    further++;
  }
  if (further + 1 < blocks.length) further++;
  final delta = now.text.length - previous.length;
  return [
    for (final g in before)
      if (g.start < start) g,
    ..._issues(now.text, blocks, first, further, start, end),
    for (final g in before)
      if (g.start >= end - delta) GrammarIssue(g.start + delta, g.end + delta, g.message, g.replacement),
  ]..sort((a, b) => a.start.compareTo(b.start));
}

/// What is written wrong and begins between [from] and [to], looking at the blocks from [first] to [last].
List<GrammarIssue> _issues(String text, List<MdBlock> blocks, int first, int last, int from, int to) {
  final prose = _prose(text, blocks, first, last);
  bool plain(int a, int b) {
    for (var i = a; i < b && i < text.length; i++) {
      if (!prose(i) && text[i].trim().isNotEmpty) return false;
    }
    return a < text.length && prose(a);
  }

  // (cut after the part looked at: a check that finds nothing there would otherwise go on to the end of the text)
  final cut = to + 64 >= text.length ? text : text.substring(0, blocks[last].end + 1 > text.length ? text.length : blocks[last].end + 1);
  Iterable<RegExpMatch> found(RegExp check) sync* {
    for (final m in check.allMatches(cut, from)) {
      if (m.start >= to) return;
      yield m;
    }
  }

  final out = <GrammarIssue>[];
  for (final m in found(_repeated)) {
    final word = m.group(1)!;
    // (a few words are written twice on purpose: "had had", "that that")
    final end = m.end + word.length;
    if (const {'had', 'that', 'die', 'das', 'der'}.contains(word.toLowerCase()) || !plain(m.start, end)) continue;
    out.add(GrammarIssue(m.start, end, tr('"{word}" is written twice', {'word': word}), word));
  }
  for (final m in found(_doubleSpace)) {
    if (!plain(m.start - 1, m.end + 1)) continue;
    out.add(GrammarIssue(m.start, m.end, tr('Two spaces'), ' '));
  }
  for (final m in found(_spaceBefore)) {
    if (!plain(m.start - 1, m.end) || m.group(0)!.contains('\n')) continue;
    out.add(GrammarIssue(m.start, m.end, tr('A space before "{mark}"', {'mark': m.group(1)!}), m.group(1)!));
  }
  for (final m in found(_sentence)) {
    // (the word before it, looked for from here back: this is asked for every sentence of the text)
    bool space(int i) => text[i].trim().isEmpty;
    var end = m.start;
    while (end > 0 && space(end - 1)) {
      end--;
    }
    var start = end;
    while (start > 0 && !space(start - 1)) {
      start--;
    }
    if (isAbbreviation(text.substring(start, end)) || !plain(m.start, m.end)) continue;
    // (an ellipsis goes on a sentence)
    if (text.startsWith('...', math.max(0, end - 3)) || (end > 0 && text[end - 1] == '…')) continue;
    out.add(GrammarIssue(m.start, m.end, tr('A sentence starts with a capital letter'), m.group(1)!.toUpperCase()));
  }
  for (final m in found(_aBeforeVowel)) {
    if (_vowelButConsonant.hasMatch(m.group(2)!) || m.group(2)!.length == 1 || !plain(m.start, m.end + m.group(2)!.length)) continue;
    final a = m.group(1)!;
    out.add(GrammarIssue(m.start, m.start + a.length, tr('"an" before a vowel'), a == 'A' ? 'An' : 'an'));
  }
  for (final m in found(_anBeforeConsonant)) {
    final next = m.group(2)!;
    // (an acronym spoken by its letters: "an MP", and the words that start with a silent h)
    if (_consonantButVowel.hasMatch(next) || next == next.toUpperCase() || !plain(m.start, m.end + next.length)) continue;
    final an = m.group(1)!;
    out.add(GrammarIssue(m.start, m.start + an.length, tr('"a" before a consonant'), an == 'An' ? 'A' : 'a'));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// The menu items for the issue at the caret (or the selection) of [controller]: the change, which [hide]s the menu.
List<ContextMenuButtonItem> grammarMenuItems(TextEditingController controller, List<GrammarIssue> issues, TextSelection selection, VoidCallback hide) {
  if (!selection.isValid) return const [];
  final issue = issues.where((g) => g.start <= selection.start && g.end >= selection.end).firstOrNull;
  if (issue == null) return const [];
  final shown = issue.replacement.trim().isEmpty ? tr('one space') : issue.replacement;
  return [
    ContextMenuButtonItem(
      label: '${issue.message}: $shown',
      onPressed: () {
        hide();
        final text = controller.text;
        if (issue.end > text.length) return;
        controller.value = TextEditingValue(
          text: text.replaceRange(issue.start, issue.end, issue.replacement),
          selection: TextSelection.collapsed(offset: issue.start + issue.replacement.length),
        );
      },
    ),
  ];
}
