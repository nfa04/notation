import 'package:flutter/services.dart';

import 'markdown_parser.dart';

/// Edits that apply Markdown syntax to a [TextEditingValue], used by the
/// formatting bar. Only syntax that markdown_parser.dart renders is offered.

enum LineStyle { heading1, heading2, heading3, bullet, numbered, heading4, heading5, heading6, quote, task }

final _prefix = RegExp(r'^(#{1,6}\s+|\s*[-*+]\s+\[[ xX]\]\s+|\s*[-*+]\s+|\s*\d+[.)]\s+|\s*>\s?)');

/// How many characters at the start of [line] are not its text: the layout token and the mark of a heading, list item or quote.
int lineMarkLength(String line) {
  final token = paragraphFormatOf(line)?.$1 ?? 0;
  return token + (_prefix.firstMatch(line.substring(token))?.group(0)?.length ?? 0);
}

TextSelection _selectionOf(TextEditingValue v) {
  final s = v.selection;
  return s.isValid ? s : TextSelection.collapsed(offset: v.text.length);
}

/// Wraps the selection in [marker] (`**`, `*`, `~~`, `` ` ``), or removes the
/// marker if the selection already has it. Without a selection a marker pair
/// is inserted and the cursor placed between.
TextEditingValue toggleInline(TextEditingValue v, String marker) {
  final text = v.text;
  final sel = _selectionOf(v);
  var a = sel.start, b = sel.end;
  final m = marker.length;

  if (a == b) {
    final between = a >= m && text.startsWith(marker, a - m) && text.startsWith(marker, a);
    if (between) {
      // cursor in an empty pair: remove it again
      return _replace(text, a - m, a + m, '', cursor: a - m);
    }
    return _replace(text, a, a, marker * 2, cursor: a + m);
  }

  // markers do not work next to spaces: wrap only the trimmed core
  while (a < b && text[a].trim().isEmpty) {
    a++;
  }
  while (b > a && text[b - 1].trim().isEmpty) {
    b--;
  }
  if (a == b) return v;

  // already formatted, markers inside the selection
  final inner = text.substring(a, b);
  if (inner.length >= 2 * m && _hasAt(inner, 0, marker, fromStart: true) && _hasAt(inner, inner.length, marker, fromStart: false)) {
    final unwrapped = inner.substring(m, inner.length - m);
    return _replace(text, a, b, unwrapped, select: TextSelection(baseOffset: a, extentOffset: a + unwrapped.length));
  }
  // already formatted, markers just outside the selection
  if (a >= m && _hasAt(text, a, marker, fromStart: false) && _hasAt(text, b, marker, fromStart: true)) {
    return _replace(text, a - m, b + m, inner, select: TextSelection(baseOffset: a - m, extentOffset: a - m + inner.length));
  }
  return _replace(text, a, b, '$marker$inner$marker',
      select: TextSelection(baseOffset: a + m, extentOffset: b + m));
}

/// Whether [marker] sits at [index], reading forwards from there
/// ([fromStart]) or backwards from there. A single `*` only counts when it
/// is not one half of a `**`, while `***` (bold + italic) contains both.
bool _hasAt(String s, int index, String marker, {required bool fromStart}) {
  final m = marker.length;
  if (fromStart ? !s.startsWith(marker, index) : index < m || !s.startsWith(marker, index - m)) {
    return false;
  }
  // (a single ~ is not one half of a ~~)
  if (marker == '~') return !(fromStart ? s.startsWith('~~', index) || index > 0 && s[index - 1] == '~' : index >= 2 && s.startsWith('~~', index - 2) || s.startsWith('~', index));
  if (marker != '*' && marker != '**') return true;
  var run = 0;
  if (fromStart) {
    while (index + run < s.length && s[index + run] == '*') {
      run++;
    }
  } else {
    while (index - run > 0 && s[index - run - 1] == '*') {
      run++;
    }
  }
  return marker == '*' ? run.isOdd : run >= 2;
}

TextEditingValue _replace(String text, int from, int to, String replacement,
    {int? cursor, TextSelection? select}) {
  return TextEditingValue(
    text: text.replaceRange(from, to, replacement),
    selection: select ?? TextSelection.collapsed(offset: cursor ?? from + replacement.length),
  );
}

/// The lines the selection touches: from the start of the first to the end of the last.
(int, int) _selectedLines(String text, TextSelection sel) {
  final first = sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
  // a selection that ends right after a line break does not include that next line
  final lastPos = (sel.end > sel.start && sel.end > 0 && text[sel.end - 1] == '\n') ? sel.end - 1 : sel.end;
  var lastEnd = text.indexOf('\n', lastPos);
  if (lastEnd < 0) lastEnd = text.length;
  return (first, lastEnd);
}

/// Changes every line the selection touches with [change] (given the line and its number among them); the selection stays on
/// the same text.
TextEditingValue _changeLines(TextEditingValue v, String Function(String line, int index) change) {
  final text = v.text;
  final sel = _selectionOf(v);
  final (first, lastEnd) = _selectedLines(text, sel);
  final lines = text.substring(first, lastEnd).split('\n');
  var delta0 = 0, total = 0;
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = change(lines[i], i);
    final delta = line.length - lines[i].length;
    if (i == 0) delta0 = delta;
    total += delta;
    out.add(line);
  }
  final start = (sel.start + delta0).clamp(first, first + out.first.length);
  final end = (sel.end + total).clamp(start, first + out.join('\n').length);
  return TextEditingValue(
    text: text.replaceRange(first, lastEnd, out.join('\n')),
    selection: TextSelection(baseOffset: start, extentOffset: end),
  );
}

/// [line] split into its layout token and the rest.
(String, String) _splitToken(String line) {
  final t = paragraphFormatOf(line)?.$1 ?? 0;
  return (line.substring(0, t), line.substring(t));
}

/// Applies [style] to every line touched by the selection. If all of them
/// already have exactly that style it is removed instead.
TextEditingValue toggleLineStyle(TextEditingValue v, LineStyle style) {
  final text = v.text;
  final (first, lastEnd) = _selectedLines(text, _selectionOf(v));
  final remove = text.substring(first, lastEnd).split('\n').every((l) => _styleOf(_splitToken(l).$2) == style);
  return setLineStyle(v, remove ? null : style);
}

/// Gives every line touched by the selection [style] (null: an ordinary paragraph).
TextEditingValue setLineStyle(TextEditingValue v, LineStyle? style) {
  var n = 0;
  return _changeLines(v, (line, i) {
    final (token, rest) = _splitToken(line);
    final body = rest.replaceFirst(_prefix, '');
    if (style == null) return '$token$body';
    // a list item keeps how deep it is
    final indent = _isList(style) && _isList(_styleOf(rest)) ? RegExp(r'^\s*').stringMatch(rest)! : '';
    n++;
    return '$token$indent${_prefixFor(style, n)}$body';
  });
}

bool _isList(LineStyle? s) => s == LineStyle.bullet || s == LineStyle.numbered || s == LineStyle.task;

/// The style of the line the caret is on (null: an ordinary paragraph).
LineStyle? lineStyleAt(String text, int offset) {
  final start = offset <= 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
  var end = text.indexOf('\n', start);
  if (end < 0) end = text.length;
  return _styleOf(_splitToken(text.substring(start, end)).$2);
}

LineStyle? _styleOf(String line) {
  final m = _prefix.firstMatch(line);
  if (m == null) return null;
  final p = m.group(0)!;
  if (p.startsWith('#')) {
    return switch (p.trim().length) {
      1 => LineStyle.heading1,
      2 => LineStyle.heading2,
      3 => LineStyle.heading3,
      4 => LineStyle.heading4,
      5 => LineStyle.heading5,
      _ => LineStyle.heading6,
    };
  }
  if (p.trim().startsWith('>')) return LineStyle.quote;
  if (p.contains('[')) return LineStyle.task;
  return RegExp(r'^\s*\d').hasMatch(p) ? LineStyle.numbered : LineStyle.bullet;
}

String _prefixFor(LineStyle style, int number) => switch (style) {
      LineStyle.heading1 => '# ',
      LineStyle.heading2 => '## ',
      LineStyle.heading3 => '### ',
      LineStyle.heading4 => '#### ',
      LineStyle.heading5 => '##### ',
      LineStyle.heading6 => '###### ',
      LineStyle.bullet => '- ',
      LineStyle.numbered => '$number. ',
      LineStyle.quote => '> ',
      LineStyle.task => '- [ ] ',
    };

/// How the paragraph the caret is in is laid out.
ParagraphFormat paragraphFormatAt(String text, int offset) {
  final start = offset <= 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
  var end = text.indexOf('\n', start);
  if (end < 0) end = text.length;
  return paragraphFormatOf(text.substring(start, end))?.$2 ?? ParagraphFormat.plain;
}

/// Lays out every paragraph the selection touches by [change] of how it is laid out now.
TextEditingValue changeParagraphFormat(TextEditingValue v, ParagraphFormat Function(ParagraphFormat) change) => _changeLines(v, (line, _) {
      final token = paragraphFormatOf(line);
      final now = token?.$2 ?? ParagraphFormat.plain;
      return '${change(now).token}${line.substring(token?.$1 ?? 0)}';
    });

/// Nests the list items the selection touches one step deeper (or, not [deeper], one step out). Null when it touches no list item.
TextEditingValue? nestListItems(TextEditingValue v, {required bool deeper}) {
  final text = v.text;
  final (first, lastEnd) = _selectedLines(text, _selectionOf(v));
  if (!text.substring(first, lastEnd).split('\n').any((l) => _isList(_styleOf(_splitToken(l).$2)))) return null;
  return _changeLines(v, (line, _) {
    final (token, rest) = _splitToken(line);
    if (!_isList(_styleOf(rest))) return line;
    if (deeper) return '$token  $rest';
    return '$token${rest.startsWith('  ') ? rest.substring(2) : rest.trimLeft()}';
  });
}

/// A rule (`---`) on a line of its own: in place of the empty line the caret is on, else after its line. The caret goes to the
/// line after the rule.
TextEditingValue insertRule(TextEditingValue v) => insertBlockLine(v, '---');

/// [line] (a rule, `[toc]`, `\pagebreak`) on a line of its own: in place of the empty line the caret is on, else after its line.
/// The caret goes to the line after it.
TextEditingValue insertBlockLine(TextEditingValue v, String line) {
  final text = v.text;
  final sel = _selectionOf(v);
  final lineStart = sel.end == 0 ? 0 : text.lastIndexOf('\n', sel.end - 1) + 1;
  var end = text.indexOf('\n', sel.end);
  if (end < 0) end = text.length;
  final empty = text.substring(lineStart, end).trim().isEmpty;
  final result = empty ? text.replaceRange(lineStart, end, '$line\n') : text.replaceRange(end, end, '\n$line\n');
  final caret = empty ? lineStart + line.length + 1 : end + line.length + 2;
  return TextEditingValue(text: result, selection: TextSelection.collapsed(offset: caret));
}

/// [s] in place of the selection; the caret after it.
TextEditingValue insertText(TextEditingValue v, String s) {
  final sel = _selectionOf(v);
  return TextEditingValue(text: v.text.replaceRange(sel.start, sel.end, s), selection: TextSelection.collapsed(offset: sel.start + s.length));
}

/// A footnote: its mark (`[^n]`, the next free number) at the caret, and a line for its text at the end of the document, where
/// the caret goes.
TextEditingValue insertFootnote(TextEditingValue v) {
  final text = v.text;
  final used = RegExp(r'\[\^(\d+)\]').allMatches(text).map((m) => int.parse(m.group(1)!)).toSet();
  var n = 1;
  while (used.contains(n)) {
    n++;
  }
  final sel = _selectionOf(v);
  final marked = text.replaceRange(sel.end, sel.end, '[^$n]');
  final trimmed = marked.trimRight();
  // with the other footnotes when the text ends with them, else after a blank line
  final lastLine = trimmed.substring(trimmed.lastIndexOf('\n') + 1);
  final glue = trimmed.isEmpty ? '' : (RegExp(r'^\[\^[\w-]+\]:').hasMatch(lastLine) ? '\n' : '\n\n');
  final result = '$trimmed$glue[^$n]: ';
  return TextEditingValue(text: result, selection: TextSelection.collapsed(offset: result.length));
}

/// The document with its [key] setting (`header`, `footer`) set to [value]: on its line at the top, which goes when [value] is
/// empty. The selection stays on the same text.
TextEditingValue setDocumentSetting(TextEditingValue v, String key, String value) {
  final text = v.text;
  final sel = _selectionOf(v);
  final line = RegExp('^\\[${RegExp.escape(key)}\\]:.*\$', multiLine: true).firstMatch(text);
  final clean = value.replaceAll('\n', ' ').trim();
  int from, to;
  String put;
  if (line != null) {
    from = line.start;
    to = line.end;
    put = clean.isEmpty ? '' : '[$key]: $clean';
    if (clean.isEmpty && to < text.length && text[to] == '\n') to++;
  } else {
    if (clean.isEmpty) return v;
    from = to = 0;
    // the settings stay together at the top, a blank line after them
    final rest = text.startsWith(RegExp(r'\[(header|footer|columns|style-[a-z0-9]+)\]:')) ? '\n' : (text.isEmpty ? '' : '\n\n');
    put = '[$key]: $clean$rest';
  }
  final delta = put.length - (to - from);
  int moved(int p) => p <= from ? p : (p >= to ? p + delta : from + put.length);
  return TextEditingValue(
    text: text.replaceRange(from, to, put),
    selection: TextSelection(baseOffset: moved(sel.baseOffset), extentOffset: moved(sel.extentOffset)),
  );
}

/// The selection without the Markdown formatting in it or around it (bold, italic, strike, highlight, code); links, formulas and
/// citations stay.
TextEditingValue clearInlineMarkdown(TextEditingValue v) {
  final text = v.text;
  final sel = _selectionOf(v);
  final cut = <(int, int)>[];
  for (final b in parseMarkdown(text)) {
    for (final m in b.markup) {
      if (m.kind != MdMarkupKind.pair && m.kind != MdMarkupKind.code) continue;
      final overlaps = sel.isCollapsed ? m.start <= sel.start && m.end >= sel.end : m.start < sel.end && m.end > sel.start;
      if (!overlaps) continue;
      cut
        ..add((m.start, m.innerStart))
        ..add((m.innerEnd, m.end));
    }
  }
  if (cut.isEmpty) return v;
  cut.sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  int moved(int p) {
    var q = p;
    for (final (a, b) in cut) {
      if (p >= b) {
        q -= b - a;
      } else if (p > a) {
        q -= p - a;
      }
    }
    return q;
  }

  for (final (a, b) in cut) {
    out = out.replaceRange(a, b, '');
  }
  return TextEditingValue(text: out, selection: TextSelection(baseOffset: moved(sel.start), extentOffset: moved(sel.end)));
}

/// How many words [text] has as it reads (its Markdown and layout not counted). [blocks]: [text] as it was parsed already.
int wordCount(String text, {List<MdBlock>? blocks}) => (blocks ?? parseMarkdown(text)).fold(0, (count, b) => count + b.words);

/// [value] with [spoken] put in at the cursor (in place of the selected text), a space on either side where it would
/// otherwise run into a word; the cursor ends up after it.
TextEditingValue insertSpoken(TextEditingValue value, String spoken) {
  final sel = value.selection;
  final start = sel.start.clamp(0, value.text.length);
  final end = sel.end.clamp(start, value.text.length);
  final before = value.text.substring(0, start);
  final after = value.text.substring(end);
  final needsBefore = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before);
  final needsAfter = after.isNotEmpty && !RegExp(r'^[\s.,;:!?)\]]').hasMatch(after);
  final inserted = '${needsBefore ? ' ' : ''}$spoken${needsAfter ? ' ' : ''}';
  final caret = before.length + inserted.length - (needsAfter ? 1 : 0);
  return TextEditingValue(text: '$before$inserted$after', selection: TextSelection.collapsed(offset: caret));
}

final _trackedChange = RegExp(r'\{\+\+(.*?)\+\+\}|\{--(.*?)--\}');

/// The edits that accept ([accept]) or reject the tracked changes of [text]: all of them, or with [only] those it touches. An
/// accepted insertion keeps its text, an accepted deletion goes; rejecting does the opposite.
List<({int start, int end, String text})> decideChanges(String text, {required bool accept, TextSelection? only}) => [
      for (final m in _trackedChange.allMatches(text))
        if (only == null || (only.start <= m.end && only.end >= m.start))
          (start: m.start, end: m.end, text: (m.group(1) != null) == accept ? (m.group(1) ?? m.group(2)!) : ''),
    ];

/// Whether [text] has tracked changes.
bool hasTrackedChanges(String text) => _trackedChange.hasMatch(text);

/// A comment saying [said] on the selection (`{==selected==}{>>said<<}`), or at the caret.
TextEditingValue addComment(TextEditingValue v, String said) {
  final sel = _selectionOf(v);
  final clean = said.replaceAll('\n', ' ').replaceAll('<<}', '<< }');
  final picked = v.text.substring(sel.start, sel.end);
  if (picked.isEmpty || picked.contains('\n')) {
    final at = sel.end;
    final put = '{>>$clean<<}';
    return TextEditingValue(text: v.text.replaceRange(at, at, put), selection: TextSelection.collapsed(offset: at + put.length));
  }
  final put = '{==$picked==}{>>$clean<<}';
  return TextEditingValue(text: v.text.replaceRange(sel.start, sel.end, put), selection: TextSelection.collapsed(offset: sel.start + put.length));
}

/// [text] without its comments (and their marking); tracked changes [accept]ed (or, false, rejected) - how it reads when done.
String settledText(String text, {bool accept = true}) => text
    .replaceAllMapped(_trackedChange, (m) => (m.group(1) != null) == accept ? (m.group(1) ?? m.group(2)!) : '')
    .replaceAll(RegExp(r'\{>>.*?<<\}'), '')
    .replaceAllMapped(RegExp(r'\{==(.*?)==\}'), (m) => m.group(1)!);

/// The headings and captions of [text] a cross-reference can point to: (where the block starts, what it reads as in the list, its
/// id when it has one).
List<(int, String, String?)> referenceTargets(String text, {String figure = 'Figure', String table = 'Table'}) {
  final blocks = parseMarkdown(text);
  final numbers = captionNumbers(blocks);
  return [
    for (final b in blocks)
      if (b.type == MdBlockType.heading || b.type == MdBlockType.caption)
        (
          b.start,
          '${b.type == MdBlockType.caption ? captionPrefix(b, numbers, figure: figure, table: table) : '  ' * (b.level - 1)}'
              '${b.runs.where((r) => r.ref == null && !r.comment).map((r) => r.text).join().trim()}',
          b.markup.where((m) => m.kind == MdMarkupKind.anchor).firstOrNull?.id,
        ),
  ];
}

/// A reference (`{@id}`) at the caret to the heading or caption whose block starts at [target]; one without a name gets one
/// (`{#...}` at the end of its line, made from its text).
TextEditingValue insertCrossReference(TextEditingValue v, int target) {
  final text = v.text;
  final block = parseMarkdown(text).where((b) => b.start == target).firstOrNull;
  if (block == null) return v;
  var id = block.markup.where((m) => m.kind == MdMarkupKind.anchor).firstOrNull?.id;
  var out = text;
  final sel = _selectionOf(v);
  var caret = sel.end;
  if (id == null) {
    final words = block.runs.map((r) => r.text).join().toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final kind = block.type == MdBlockType.caption ? (block.label == 'table' ? 'tbl:' : 'fig:') : 'sec:';
    final base = '$kind${words.isEmpty ? 'x' : (words.length > 24 ? words.substring(0, 24) : words)}';
    id = base;
    for (var n = 2; out.contains('{#$id}'); n++) {
      id = '$base-$n';
    }
    final put = ' {#$id}';
    out = out.replaceRange(block.end, block.end, put);
    if (caret > block.end || (caret == block.end && sel.isCollapsed && block.end < sel.end)) caret += put.length;
  }
  final ref = '{@$id}';
  out = out.replaceRange(caret, caret, ref);
  return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: caret + ref.length));
}
