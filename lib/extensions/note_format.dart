import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../l10n/language.dart';
import '../markdown/markdown_formatting.dart';
import '../markdown/markdown_parser.dart';
import '../models/rich_text.dart';
import 'extension_host.dart';

/// How a piece of a note is to look: what `note.format` asks for, read and checked. It says how things should end up, so that asking
/// twice does the same as asking once (the bar's buttons take a look away again when it is there).
class NoteFormat {
  /// `all`, `selection`, or text quoted from the note.
  final String target;

  /// Looks written as Markdown in the text, by their mark: on or off.
  final Map<String, bool> inline;

  /// Looks kept beside the text, without a value: on or off.
  final Map<AttributeType, bool> marks;

  /// Looks kept beside the text, with a value (null: takes it away).
  final Map<AttributeType, String?> values;

  /// Whether the lines get [block] (null then: ordinary paragraphs).
  final bool setsBlock;
  final LineStyle? block;

  final String? align;
  final int? indent;
  final double? spacing;

  /// Takes the formatting off first.
  final bool clear;

  /// Text of the note whose formatting is copied first (what else is asked for then changes that): everything the bar's format painter
  /// takes, font, size, colour, highlight, underline, bold and the rest, the kind of line it is and how its paragraph is laid out.
  final String? like;

  const NoteFormat({
    required this.target,
    this.inline = const {},
    this.marks = const {},
    this.values = const {},
    this.setsBlock = false,
    this.block,
    this.align,
    this.indent,
    this.spacing,
    this.clear = false,
    this.like,
  });

  static const _inlineKeys = {'bold': '**', 'italic': '*', 'strikethrough': '~~', 'code': '`'};
  static const _markKeys = {'underline': AttributeType.underline, 'superscript': AttributeType.superscript, 'subscript': AttributeType.subscript};
  static const _blocks = {
    'paragraph': null,
    'heading1': LineStyle.heading1,
    'heading2': LineStyle.heading2,
    'heading3': LineStyle.heading3,
    'heading4': LineStyle.heading4,
    'heading5': LineStyle.heading5,
    'heading6': LineStyle.heading6,
    'bullet': LineStyle.bullet,
    'numbered': LineStyle.numbered,
    'task': LineStyle.task,
    'quote': LineStyle.quote,
  };
  static const _colors = {
    'black': '#000000',
    'white': '#FFFFFF',
    'gray': '#808080',
    'grey': '#808080',
    'red': '#D32F2F',
    'orange': '#F57C00',
    'yellow': '#FFF176',
    'green': '#388E3C',
    'blue': '#1976D2',
    'purple': '#7B1FA2',
    'pink': '#EC407A',
  };

  static const _yellow = 'yellow';

  /// Everything `note.format` takes.
  static const fields = 'target, like, bold, italic, strikethrough, code, underline, superscript, subscript, block, align, indent, spacing, color, highlight, font, size, clear';

  static String? _color(String key, Object? v) {
    if (v == null || v == 'none') return null;
    final text = v is String ? v.trim().toLowerCase() : '';
    final named = _colors[text];
    if (named != null) return named;
    if (RegExp(r'^#[0-9a-f]{6}$').hasMatch(text)) return text.toUpperCase();
    if (RegExp(r'^#[0-9a-f]{3}$').hasMatch(text)) return '#${text.substring(1).split('').map((c) => '$c$c').join()}'.toUpperCase();
    throw ExtensionError('"$key" has to be a colour like #D32F2F, or "none".');
  }

  /// Reads what a script or the assistant asked for; what is not right is refused with a reason.
  factory NoteFormat.fromJson(Map<String, Object?> json) {
    final allowed = fields.split(', ').toSet();
    for (final key in json.keys) {
      if (!allowed.contains(key)) throw ExtensionError('Unknown formatting "$key". It can be: $fields.');
    }
    final target = json['target'] ?? 'selection';
    if (target is! String || target.trim().isEmpty) throw ExtensionError('"target" has to be "all", "selection" or text from the note.');
    bool flag(String key) {
      final v = json[key];
      if (v is! bool) throw ExtensionError('"$key" has to be true or false.');
      return v;
    }

    final inline = {for (final e in _inlineKeys.entries) if (json[e.key] != null) e.value: flag(e.key)};
    final marks = {for (final e in _markKeys.entries) if (json[e.key] != null) e.value: flag(e.key)};
    if (marks[AttributeType.superscript] == true && marks[AttributeType.subscript] == true) throw ExtensionError('Text cannot be raised and lowered at once.');

    final values = <AttributeType, String?>{};
    if (json.containsKey('color')) values[AttributeType.color] = _color('color', json['color']);
    if (json.containsKey('highlight')) {
      final h = json['highlight'];
      // (the usual yellow is written in Markdown, as the bar does: ==marked==)
      final yellow = h is String && (h.trim().toLowerCase() == 'yellow' || h.trim().toUpperCase() == '#FFFF00');
      values[AttributeType.highlight] = yellow ? _yellow : _color('highlight', h);
    }
    if (json.containsKey('font')) {
      final v = json['font'];
      final name = documentFonts.keys.where((f) => v is String && f.toLowerCase() == v.toLowerCase()).firstOrNull;
      if (name == null && v != null && v != 'none') throw ExtensionError('"font" has to be one of ${documentFonts.keys.join(', ')}, or "none".');
      values[AttributeType.font] = name;
    }
    if (json.containsKey('size')) {
      final v = json['size'];
      if (v == null || v == 'none') {
        values[AttributeType.size] = null;
      } else {
        if (v is! num || v < 6 || v > 96) throw ExtensionError('"size" has to be a number of points from 6 to 96, or "none".');
        values[AttributeType.size] = v == documentPointSize ? null : (v == v.roundToDouble() ? '${v.round()}' : '$v');
      }
    }

    final block = json['block'];
    if (block != null && (block is! String || !_blocks.containsKey(block))) throw ExtensionError('"block" has to be one of ${_blocks.keys.join(', ')}.');
    final align = json['align'];
    if (align != null && !ParagraphFormat.aligns.contains(align)) throw ExtensionError('"align" has to be one of ${ParagraphFormat.aligns.join(', ')}.');
    final indent = json['indent'];
    if (indent != null && (indent is! num || indent != indent.roundToDouble() || indent < 0 || indent > 8)) throw ExtensionError('"indent" has to be a whole number from 0 to 8.');
    final spacing = json['spacing'];
    if (spacing != null && (spacing is! num || spacing < 0.5 || spacing > 4)) throw ExtensionError('"spacing" has to be a number from 0.5 to 4.');
    final clear = json['clear'] != null && flag('clear');
    final like = json['like'];
    if (like != null && (like is! String || like.trim().isEmpty)) throw ExtensionError('"like" has to be text from the note, whose formatting is copied.');

    final format = NoteFormat(
      target: target.trim(),
      inline: inline,
      marks: marks,
      values: values,
      setsBlock: block != null,
      block: block == null ? null : _blocks[block],
      align: align as String?,
      indent: (indent as num?)?.toInt(),
      spacing: (spacing as num?)?.toDouble(),
      clear: clear,
      like: (like as String?)?.trim(),
    );
    if (format._looks.isEmpty) throw ExtensionError('Say what to change: $fields.');
    return format;
  }

  bool get _changesParagraphs => align != null || indent != null || spacing != null;

  /// This format with what [base] says for what this one does not say.
  NoteFormat over(NoteFormat base) => NoteFormat(
        target: target,
        inline: {...base.inline, ...inline},
        marks: {...base.marks, ...marks},
        values: {...base.values, ...values},
        setsBlock: setsBlock || base.setsBlock,
        block: setsBlock ? block : base.block,
        align: align ?? base.align,
        indent: indent ?? base.indent,
        spacing: spacing ?? base.spacing,
        clear: clear || base.clear,
      );

  /// What is asked for, in words of the app (to be translated).
  List<(String, Map<String, Object?>)> get _looks => [
        if (like != null) ('like "{text}"', {'text': like}),
        if (clear) ('no formatting', const {}),
        for (final e in _inlineKeys.entries)
          if (inline[e.value] != null) (inline[e.value]! ? e.key : 'not {what}', {'what': e.key}),
        for (final e in _markKeys.entries)
          if (marks[e.value] != null) (marks[e.value]! ? e.key : 'not {what}', {'what': e.key}),
        if (setsBlock) (_blocks.entries.firstWhere((e) => e.value == block).key, const {}),
        if (align != null) ('aligned {how}', {'how': align}),
        if (indent != null) ('indent {n}', {'n': indent}),
        if (spacing != null) ('line spacing {n}', {'n': spacing}),
        for (final e in values.entries)
          e.value == null ? ('no {what}', {'what': e.key.name}) : ('{what} {value}', {'what': e.key.name, 'value': e.value == _yellow ? 'yellow' : e.value}),
      ];

  /// What is asked for, for the person to read.
  String describe() => _looks.map((l) => tr(l.$1, l.$2)).join(', ');
}

/// Lines nothing is done to: tables, fenced code, rules and the lines that are instructions to the document.
final _special = RegExp(r'^\s*(\|.*|-{3,}|\*{3,}|_{3,}|\\pagebreak|\[toc\]|\[header\]:.*|\[footer\]:.*|\[\^\d+\]:.*)\s*$');

class _Line {
  final int start, end;

  /// Empty, or one of the lines nothing is done to.
  final bool skipped;
  const _Line(this.start, this.end, this.skipped);
}

List<_Line> _linesOf(String text) {
  final lines = <_Line>[];
  var at = 0;
  var fenced = false;
  for (final line in text.split('\n')) {
    final body = withoutParagraphFormats(line);
    final fence = RegExp(r'^\s*(```|~~~)').hasMatch(body);
    lines.add(_Line(at, at + line.length, fenced || fence || body.trim().isEmpty || _special.hasMatch(body)));
    if (fence) fenced = !fenced;
    at += line.length + 1;
  }
  return lines;
}

/// [v] with the look of [marker] on or off, whichever it was before.
TextEditingValue _ensure(TextEditingValue v, String marker, bool on) {
  final next = toggleInline(v, marker);
  return (next.text.length > v.text.length) == on ? next : v;
}

/// Puts the lines of [next] in the place of those of [c] from [top] to [bottom], one at a time, so that the formatting stays on the
/// text of each.
void _replaceLines(RichInlineTextController c, String next, int top, int bottom) {
  final old = c.text.substring(top, bottom).split('\n');
  final now = next.substring(top, bottom + next.length - c.text.length).split('\n');
  var end = bottom;
  for (var i = old.length - 1; i >= 0; i--) {
    final start = end - old[i].length;
    if (old[i] != now[i]) {
      // (only what is in front of the text changes: formatting that begins at the line begins after it)
      var same = 0;
      while (same < old[i].length && same < now[i].length && old[i][old[i].length - 1 - same] == now[i][now[i].length - 1 - same]) {
        same++;
      }
      c.replaceRanges([(start: start, end: end - same, text: now[i].substring(0, now[i].length - same))]);
    }
    end = start - 1;
  }
}

void _apply(RichInlineTextController c, NoteFormat f, int start, int end) {
  void pick(int a, int b) => c.selection = TextSelection(baseOffset: a, extentOffset: b);

  pick(start, end);
  // Markdown where it can say it, as the bar writes it: raised and lowered text (not over spaces) and the usual yellow highlight
  final inline = {...f.inline};
  final marks = {...f.marks};
  final values = {...f.values};
  final spaced = c.text.substring(start, end).trim().contains(RegExp(r'\s'));
  for (final (type, mark, other) in [(AttributeType.superscript, '^', '~'), (AttributeType.subscript, '~', '^')]) {
    final on = marks[type];
    if (on == null) continue;
    if (on && !spaced) {
      marks.remove(type);
      inline[other] = false; // (first: the other mark is taken off, then this one put on)
      inline[mark] = true;
      marks[type == AttributeType.superscript ? AttributeType.subscript : AttributeType.superscript] = false;
    } else {
      inline[mark] = false;
      if (on) inline[other] = false;
    }
  }
  if (values.containsKey(AttributeType.highlight)) {
    final yellow = values[AttributeType.highlight] == NoteFormat._yellow;
    inline['=='] = yellow;
    if (yellow) values[AttributeType.highlight] = null;
  }
  if (f.clear) {
    c.clearAttributes();
    c.value = clearInlineMarkdown(c.value);
    start = c.selection.start;
    end = c.selection.end;
    pick(start, end);
  }
  for (final e in marks.entries) {
    if (!e.value) {
      c.setAttribute(e.key, null);
    } else {
      // (raised and lowered text exclude each other)
      if (e.key == AttributeType.superscript) c.setAttribute(AttributeType.subscript, null);
      if (e.key == AttributeType.subscript) c.setAttribute(AttributeType.superscript, null);
      if (!c.hasAttribute(e.key, start, end)) c.toggleAttribute(e.key);
    }
  }
  for (final e in values.entries) {
    c.setAttribute(e.key, e.value);
  }

  // from the end to the start: what is done to a line does not move those before it
  final touched = _linesOf(c.text).where((l) => l.start < end && l.end > start).toList().reversed;
  var run = <_Line>[];

  void flush() {
    if (run.isEmpty) return;
    var grown = 0;
    if (inline.isNotEmpty) {
      for (final l in run) {
        final a = math.max(l.start + lineMarkLength(c.text.substring(l.start, l.end)), start), b = math.min(l.end, end);
        if (a >= b) continue;
        pick(a, b);
        for (final e in inline.entries) {
          final before = c.text.length;
          c.value = _ensure(c.value, e.key, e.value);
          grown += c.text.length - before;
        }
      }
    }
    if (f.setsBlock || f._changesParagraphs) {
      final top = run.last.start, bottom = run.first.end + grown;
      var v = TextEditingValue(text: c.text, selection: TextSelection(baseOffset: top, extentOffset: bottom));
      if (f.setsBlock) v = setLineStyle(v, f.block);
      if (f._changesParagraphs) v = changeParagraphFormat(v, (p) => p.copyWith(align: f.align, indent: f.indent, spacing: f.spacing));
      _replaceLines(c, v.text, top, bottom);
    }
    run = [];
  }

  for (final l in touched) {
    if (l.skipped) {
      flush();
    } else {
      run.add(l);
    }
  }
  flush();
}

/// Where [quote] is in [text]: as it is written, else as it reads (without Markdown marks and layout, whatever the spaces and the
/// capitals). Null when it is not there.
TextRange? findInText(String text, String quote) {
  if (quote.trim().isEmpty) return null;
  final exact = text.indexOf(quote);
  if (exact >= 0) return TextRange(start: exact, end: exact + quote.length);
  final (hay, places) = _reads(text);
  final (needle, _) = _reads(quote);
  final at = needle.isEmpty ? -1 : hay.indexOf(needle);
  return at < 0 ? null : TextRange(start: places[at], end: places[at + needle.length - 1] + 1);
}

/// [text] as it reads, and for each of its characters where that is in [text].
(String, List<int>) _reads(String text) {
  final out = StringBuffer();
  final places = <int>[];
  var at = 0;
  var space = true;
  for (final line in text.split('\n')) {
    for (var i = at + lineMarkLength(line); i < at + line.length; i++) {
      final ch = text[i];
      if (ch == '*' || ch == '~' || ch == '`') continue;
      if (ch.trim().isEmpty) {
        if (!space) {
          out.write(' ');
          places.add(i);
        }
        space = true;
        continue;
      }
      final low = ch.toLowerCase();
      out.write(low.length == 1 ? low : ch);
      places.add(i);
      space = false;
    }
    if (!space) {
      out.write(' ');
      places.add(at + line.length - 1);
    }
    space = true;
    at += line.length + 1;
  }
  var s = out.toString();
  if (s.endsWith(' ')) {
    s = s.substring(0, s.length - 1);
    places.removeLast();
  }
  return (s, places);
}

/// A copy of [c] to try a change on: its text, its formatting and its selection.
RichInlineTextController scratchCopy(RichInlineTextController c) {
  final copy = RichInlineTextController()..text = c.text;
  copy.attributes.addAll([for (final a in c.attributes) a.copy()]);
  copy.selection = c.selection;
  return copy;
}

String _state(RichInlineTextController c) => '${c.text}${c.attributes.map((a) => '${a.start},${a.end},${a.type.index},${a.value}').join(';')}';

/// Formats the text of the note that is in [texts] as [f] says, and says what came of it. What cannot be done fails with [ExtensionError].
String formatNoteText(List<RichInlineTextController> texts, NoteFormat f) {
  final filled = texts.where((c) => c.text.trim().isNotEmpty).toList();
  if (filled.isEmpty) throw ExtensionError('The note has no text to format.');
  final before = [for (final c in filled) _state(c)];
  if (f.like != null) f = f.over(_formatLike(filled, f.like!));
  switch (f.target.toLowerCase()) {
    case 'all':
      for (final c in filled) {
        _apply(c, f, 0, c.text.length);
      }
      return _outcome(filled, before, 'the whole note');
    case 'selection':
      final c = filled.where((c) => c.selection.isValid && !c.selection.isCollapsed).firstOrNull;
      if (c == null) throw ExtensionError('Nothing is selected.');
      _apply(c, f, c.selection.start, c.selection.end);
      return _outcome(filled, before, 'the selection');
    default:
      for (final c in filled) {
        final found = findInText(c.text, f.target);
        if (found == null) continue;
        _apply(c, f, found.start, found.end);
        return _outcome(filled, before, '"${f.target}"');
      }
      throw ExtensionError('This text is not in the note, or it is in a part that cannot be changed: "${f.target}".');
  }
}

String _outcome(List<RichInlineTextController> texts, List<String> before, String what) {
  for (var i = 0; i < texts.length; i++) {
    if (_state(texts[i]) != before[i]) return 'Done: formatted $what.';
  }
  return 'Nothing changed: $what already looks like that.';
}

/// Replaces [find] in [texts] with [replacement], where it is first found (with [all]: everywhere it is written like that), and says
/// how many times. Fails with [ExtensionError] when it is not there.
int replaceNoteText(List<RichInlineTextController> texts, String find, String replacement, {bool all = false}) {
  if (find.isEmpty) throw ExtensionError('"find" is empty.');
  var count = 0;
  if (all) {
    for (final c in texts) {
      var at = c.text.lastIndexOf(find);
      while (at >= 0) {
        c.value = TextEditingValue(text: c.text.replaceRange(at, at + find.length, replacement), selection: TextSelection.collapsed(offset: at + replacement.length));
        count++;
        at = at < find.length ? -1 : c.text.lastIndexOf(find, at - find.length);
      }
    }
    if (count > 0) return count;
  }
  for (final c in texts) {
    final found = findInText(c.text, find);
    if (found == null) continue;
    c.value = TextEditingValue(text: c.text.replaceRange(found.start, found.end, replacement), selection: TextSelection.collapsed(offset: found.start + replacement.length));
    return 1;
  }
  throw ExtensionError('This text is not in the note, or it is in a part that cannot be changed: "$find".');
}

/// How the text at [start, end) of [c] is formatted, as a format that gives other text the same: what the format painter copies.
NoteFormat _looksAt(RichInlineTextController c, int start, int end) {
  final text = c.text;
  var a = start;
  while (a < end - 1 && text[a].trim().isEmpty) {
    a++;
  }
  final inline = {'**': false, '*': false, '~~': false, '`': false};
  var yellow = false, raised = false, lowered = false;
  for (final b in parseMarkdown(text)) {
    for (final m in b.markup) {
      if ((m.kind != MdMarkupKind.pair && m.kind != MdMarkupKind.code) || m.innerStart > a || a >= m.innerEnd) continue;
      final mark = m.kind == MdMarkupKind.code ? '`' : text.substring(m.start, m.innerStart);
      switch (mark) {
        case '***':
          inline['**'] = inline['*'] = true;
        case '**':
          inline['**'] = true;
        case '*' || '_':
          inline['*'] = true;
        case '~~':
          inline['~~'] = true;
        case '`':
          inline['`'] = true;
        case '==':
          yellow = true;
        case '^':
          raised = true;
        case '~':
          lowered = true;
      }
    }
  }
  String? value(AttributeType t) => c.attributeAt(t, a + 1)?.value;
  bool has(AttributeType t) => c.attributeAt(t, a + 1) != null;
  final style = lineStyleAt(text, a);
  final layout = paragraphFormatAt(text, a);
  return NoteFormat(
    target: '',
    inline: inline,
    marks: {
      AttributeType.underline: has(AttributeType.underline),
      AttributeType.superscript: raised || has(AttributeType.superscript),
      AttributeType.subscript: lowered || has(AttributeType.subscript),
    },
    values: {
      AttributeType.color: value(AttributeType.color),
      AttributeType.font: value(AttributeType.font),
      AttributeType.size: value(AttributeType.size),
      AttributeType.highlight: yellow ? NoteFormat._yellow : value(AttributeType.highlight),
    },
    setsBlock: true,
    block: style,
    align: layout.align,
    indent: layout.indent,
    spacing: layout.spacing,
  );
}

NoteFormat _formatLike(List<RichInlineTextController> texts, String quote) {
  for (final c in texts) {
    final found = findInText(c.text, quote);
    if (found != null) return _looksAt(c, found.start, found.end);
  }
  throw ExtensionError('The text to copy the formatting from is not in the note: "$quote".');
}

/// What the formatting of [texts] (named by [labels]) is, in words for a model to read: each line as it is written (the Markdown
/// marks and the layout token at the start of a line are part of it), and under it the looks kept beside the text, which Markdown
/// cannot say (font, size, colour, underline...). [target] says what to look at: `all`, `selection` or text of the note.
String describeNoteFormatting(List<RichInlineTextController> texts, List<String> labels, {String target = 'all', int limit = 8000}) {
  final out = StringBuffer(
      'Lines are shown as they are written: **bold**, *italic*, ~~strike~~, ==highlight==, ^raised^, ~lowered~, `code`, # headings, - and 1. lists, > quotes, '
      'and a {align=.. indent=.. spacing=..} token at the start of a laid-out paragraph are part of the text. "Looks" are kept beside the text: '
      'font, size (points), color, highlight, underline.\n');
  var shown = 0;
  for (var i = 0; i < texts.length; i++) {
    final c = texts[i];
    final text = c.text;
    if (text.trim().isEmpty) continue;
    TextRange? range;
    switch (target.toLowerCase()) {
      case 'all':
        range = TextRange(start: 0, end: text.length);
      case 'selection':
        range = c.selection.isValid && !c.selection.isCollapsed ? TextRange(start: c.selection.start, end: c.selection.end) : null;
      default:
        range = findInText(text, target);
    }
    if (range == null) continue;
    shown++;
    out.writeln('\n== ${labels[i]} ==');
    var at = 0, n = 0;
    for (final line in text.split('\n')) {
      n++;
      final end = at + line.length;
      if (end >= range.start && (at < range.end || at == range.start)) out.writeln('$n| $line');
      at = end + 1;
    }
    final looks = [
      for (final a in c.attributes.toList()..sort((x, y) => x.start.compareTo(y.start)))
        if (a.end > range.start && a.start < range.end) a,
    ];
    if (looks.isNotEmpty) {
      out.writeln('Looks:');
      for (final a in looks) {
        final quoted = text.substring(a.start.clamp(0, text.length), a.end.clamp(0, text.length)).replaceAll('\n', ' ');
        final value = switch (a.type) {
          AttributeType.font => 'font=${a.value}',
          AttributeType.size => 'size=${a.value}',
          AttributeType.color => 'color=${a.value}',
          AttributeType.highlight => 'highlight=${a.value ?? 'yellow'}',
          _ => a.type.name,
        };
        out.writeln('- "${quoted.length > 40 ? '${quoted.substring(0, 40)}...' : quoted}": $value');
      }
    } else {
      out.writeln('Looks: none.');
    }
  }
  if (shown == 0) {
    throw ExtensionError(target.toLowerCase() == 'selection'
        ? 'Nothing is selected.'
        : (target.toLowerCase() == 'all' ? 'The note has no text.' : 'This text is not in the note: "$target".'));
  }
  final s = out.toString();
  return s.length > limit ? '${s.substring(0, limit)}\n... (cut: ask for one part by its text)' : s;
}

/// Puts [text] into the first of [texts] that has the line [after] or [before] is on, on a line of its own after or before that line; or
/// at the start of the first text ([atStart]). Fails with [ExtensionError] when the line is not there.
void insertNoteText(List<RichInlineTextController> texts, String text, {String? after, String? before, bool atStart = false}) {
  if (atStart) {
    final c = texts.first;
    c.replaceRanges([(start: 0, end: 0, text: c.text.isEmpty ? text : '$text\n')]);
    return;
  }
  final quote = after ?? before;
  if (quote == null) throw ExtensionError('Say where: "after", "before" or "at".');
  for (final c in texts) {
    final found = findInText(c.text, quote);
    if (found == null) continue;
    final t = c.text;
    if (after != null) {
      final nl = t.indexOf('\n', found.end);
      final end = nl < 0 ? t.length : nl;
      c.replaceRanges([(start: end, end: end, text: '\n$text')]);
    } else {
      final start = found.start == 0 ? 0 : t.lastIndexOf('\n', found.start - 1) + 1;
      c.replaceRanges([(start: start, end: start, text: '$text\n')]);
    }
    return;
  }
  throw ExtensionError('This text is not in the note, or it is in a part that cannot be changed: "$quote".');
}
