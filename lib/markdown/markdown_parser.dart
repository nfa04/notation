import '../citations/citation_document.dart';
import '../models/rich_text.dart';
import 'code_highlight.dart';
import 'markdown_table.dart';

/// A small Markdown subset shared by the on-screen text boxes, the written document and the PDF
/// export: `#`-`######` headings, `-`/`*`/`+` bullets (nested by the spaces before them), `- [ ]` tasks,
/// `1.` lists, `>` quotes, `---` rules and inline `**bold**`, `*italic*`/`_italic_`, `~~strike~~`,
/// `==highlight==` and `` `code` ``, and LaTeX formulas: `$inline$`, and `$$display$$` on a line of its
/// own, and links `[text](target)`; a target `note:<id>` points at another note.
/// Unmatched markers are kept as literal text.
///
/// A line may start with how its paragraph is laid out, `{align=center indent=1 spacing=1.5}` (see
/// [ParagraphFormat]); the written document hides it and lays the paragraph out by it.

enum MdBlockType { paragraph, heading, bullet, numbered, task, quote, rule, math, table, code, bibliography, toc, pageBreak, footnote, setting, caption }

/// A caption: `Figure: what it shows {#fig:cat}`, `Table: ...` (German `Abbildung:`, `Tabelle:` too); they are numbered.
final _caption = RegExp(r'^(Figure|Fig\.|Abbildung|Abb\.|Table|Tabelle|Tab\.):\s+');

/// What `{@id}` reads as for each `{#id}` of a document: "Figure 2", "Table 1", or the title of the heading the id is on.
/// [figure] and [table] are the words for them.
Map<String, String> crossReferences(List<MdBlock> blocks, {String figure = 'Figure', String table = 'Table'}) {
  final out = <String, String>{};
  final numbers = captionNumbers(blocks);
  for (final b in blocks) {
    for (final m in b.markup) {
      if (m.kind != MdMarkupKind.anchor) continue;
      out[m.id] = switch (b.type) {
        MdBlockType.caption => '${b.label == 'table' ? table : figure} ${numbers[b.start]}',
        MdBlockType.heading => b.runs.where((r) => r.ref == null).map((r) => r.text).join().trim(),
        _ => m.id,
      };
    }
  }
  return out;
}

/// What a caption starts with: "Figure 2: " ([figure] and [table] are the words for them).
String captionPrefix(MdBlock b, Map<int, int> numbers, {String figure = 'Figure', String table = 'Table'}) =>
    '${b.label == 'table' ? table : figure} ${numbers[b.start] ?? ''}: ';

/// The number of each caption of [blocks] (by where its block starts): figures and tables counted apart.
Map<int, int> captionNumbers(List<MdBlock> blocks) {
  final counts = <String, int>{};
  return {
    for (final b in blocks)
      if (b.type == MdBlockType.caption) b.start: counts[b.label] = (counts[b.label] ?? 0) + 1,
  };
}

/// A line of its own that is the table of contents of the document.
final tocMarker = RegExp(r'^\s*\[toc\]\s*$', caseSensitive: false);

/// A line of its own after which the document goes on on a new page.
final pageBreakMarker = RegExp(r'^\s*\\(pagebreak|newpage)\s*$');

/// The text of a footnote: `[^1]: what it says`.
final _footnoteDef = RegExp(r'^\[\^([\w-]+)\]:\s?');

/// What the pages of the document have at the top and the bottom: `[header]: My report` and `[footer]: Page {page} of {pages}`.
final _setting = RegExp(r'^\[(header|footer|columns|style-(?:body|h[1-6]))\]:\s?');

/// How a kind of paragraph looks in a document (a named style): its font ([documentFonts]), size in points and colour (ARGB).
/// Written as a setting, `[style-h1]: font=Serif size=20 color=#1565C0` (`style-body` for the usual text).
class NamedStyle {
  final String? font;
  final double? size;
  final int? color;
  const NamedStyle({this.font, this.size, this.color});

  bool get isEmpty => font == null && size == null && color == null;

  static NamedStyle parse(String s) {
    String? font;
    double? size;
    int? color;
    for (final m in RegExp(r'(font|size|color)=("[^"]*"|\S+)').allMatches(s)) {
      final v = m.group(2)!.replaceAll('"', '');
      switch (m.group(1)) {
        case 'font':
          font = v;
        case 'size':
          size = double.tryParse(v);
        case 'color':
          final rgb = v.startsWith('#') && v.length == 7 ? int.tryParse(v.substring(1), radix: 16) : null;
          color = rgb == null ? null : 0xFF000000 | rgb;
      }
    }
    return NamedStyle(font: font, size: size, color: color);
  }

  @override
  String toString() => [
        if (font != null) 'font=${font!.contains(' ') ? '"$font"' : font}',
        if (size != null) 'size=${size! == size!.roundToDouble() ? size!.toInt() : size}',
        if (color != null) 'color=#${(color! & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
      ].join(' ');
}

/// The named styles of a document by what they are for: `body`, `h1`-`h6`.
Map<String, NamedStyle> documentStyles(List<MdBlock> blocks) => {
      for (final e in documentSettings(blocks).entries)
        if (e.key.startsWith('style-')) e.key.substring(6): NamedStyle.parse(e.value),
    };

/// The named style that is for block [b] (null: none).
NamedStyle? styleFor(MdBlock b, Map<String, NamedStyle> styles) => styles[b.type == MdBlockType.heading ? 'h${b.level}' : 'body'];

/// The settings of the document written in it ([MdBlockType.setting] lines): `header` and `footer`.
Map<String, String> documentSettings(List<MdBlock> blocks) => {
      for (final b in blocks)
        if (b.type == MdBlockType.setting) b.label: b.runs.map((r) => r.text).join(),
    };

/// The number of each footnote, in the order the text first refers to them.
Map<String, int> footnoteNumbers(List<MdBlock> blocks) {
  final out = <String, int>{};
  void see(List<MdRun> runs) {
    for (final r in runs) {
      if (r.footnote != null) out.putIfAbsent(r.footnote!, () => out.length + 1);
    }
  }

  for (final b in blocks) {
    if (b.type == MdBlockType.footnote) continue;
    see(b.runs);
    for (final row in b.rows) {
      for (final cell in row) {
        see(cell);
      }
    }
  }
  return out;
}

/// The headings of [blocks] for a table of contents: (level, text, where the heading is in the source).
List<(int, String, int)> tocEntries(List<MdBlock> blocks) => [
      for (final b in blocks)
        if (b.type == MdBlockType.heading && b.runs.isNotEmpty) (b.level, b.runs.where((r) => r.footnote == null).map((r) => r.text).join().trim(), b.start),
    ];

/// How a paragraph is laid out: written at the start of its line as `{align=center indent=1 spacing=1.5}`.
class ParagraphFormat {
  /// `left` (the usual), `center`, `right` or `justify`.
  final String align;

  /// Steps the whole paragraph is moved in from the left (0-8).
  final int indent;

  /// The height of a line, as a multiple of the usual one (1.0: as usual).
  final double spacing;

  const ParagraphFormat({this.align = 'left', this.indent = 0, this.spacing = 1.0});

  static const plain = ParagraphFormat();

  static const aligns = ['left', 'center', 'right', 'justify'];

  bool get isPlain => align == 'left' && indent == 0 && spacing == 1.0;

  ParagraphFormat copyWith({String? align, int? indent, double? spacing}) =>
      ParagraphFormat(align: align ?? this.align, indent: (indent ?? this.indent).clamp(0, 8), spacing: spacing ?? this.spacing);

  /// The token that starts a line laid out like this (empty for the usual layout).
  String get token {
    if (isPlain) return '';
    final parts = [
      if (align != 'left') 'align=$align',
      if (indent != 0) 'indent=$indent',
      if (spacing != 1.0) 'spacing=${_number(spacing)}',
    ];
    return '{${parts.join(' ')}}';
  }

  static String _number(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  bool operator ==(Object other) => other is ParagraphFormat && other.align == align && other.indent == indent && other.spacing == spacing;

  @override
  int get hashCode => Object.hash(align, indent, spacing);
}

final _formatToken = RegExp(r'^\{((?:align|indent|spacing)=[a-z0-9.]+(?: (?:align|indent|spacing)=[a-z0-9.]+)*)\}');

/// The layout token at the start of [line] and what it says; null when the line has none (an unknown word makes it no token).
(int length, ParagraphFormat format)? paragraphFormatOf(String line) {
  final m = _formatToken.firstMatch(line);
  if (m == null) return null;
  var f = ParagraphFormat.plain;
  for (final part in m.group(1)!.split(' ')) {
    final [key, value] = part.split('=');
    switch (key) {
      case 'align':
        if (!ParagraphFormat.aligns.contains(value)) return null;
        f = f.copyWith(align: value);
      case 'indent':
        final n = int.tryParse(value);
        if (n == null) return null;
        f = f.copyWith(indent: n);
      case 'spacing':
        final n = double.tryParse(value);
        if (n == null || n < 0.5 || n > 4) return null;
        f = f.copyWith(spacing: n);
    }
  }
  return (m.end, f);
}

/// [text] without the layout tokens at the start of its lines (for what reads the text, not shows it).
String withoutParagraphFormats(String text) => text.contains('{')
    ? text.split('\n').map((l) {
        final f = paragraphFormatOf(l);
        return f == null ? l : l.substring(f.$1);
      }).join('\n')
    : text;

/// A piece of inline Markdown that shows less than is written: `**bold**` shows without its stars, a link shows only its text, a
/// formula or citation shows as something else entirely. `source[start, end)` is all of it, `source[innerStart, innerEnd)` the part
/// that is text to show (for [MdMarkupKind.math] the formula, for [MdMarkupKind.cite] all of it).
class MdMarkup {
  final MdMarkupKind kind;
  final int start, end, innerStart, innerEnd;

  /// For a name (`{#id}`) or a reference (`{@id}`): the id.
  final String id;
  const MdMarkup(this.kind, this.start, this.end, this.innerStart, this.innerEnd, {this.id = ''});

  /// The same [by] characters further on in the text.
  MdMarkup shifted(int by) => MdMarkup(kind, start + by, end + by, innerStart + by, innerEnd + by, id: id);
}

enum MdMarkupKind { pair, code, link, math, cite, footnote, image, change, comment, anchor, ref }

/// A piece of text with one style, taken from `source[src, src + text.length)`.
class MdRun {
  final String text;
  final int src;
  final bool bold, italic, strike, code;

  /// `==marked==` text.
  final bool highlight;

  /// `^raised^` and `~lowered~` text (as Pandoc writes them: no spaces in it).
  final bool superscript, subscript;

  /// A change suggested while changes were tracked: `{++put in++}`, `{--taken out--}`; text a comment is on: `{==this==}`.
  final bool inserted, deleted, commented;

  /// A comment, `{>>what it says<<}` ([text] is what it says).
  final bool comment;

  /// [text] is LaTeX, not text to show as it is.
  final bool math;

  /// Where a `[text](target)` link goes (`note:<id>` for another note), else null.
  final String? link;

  /// For a citation, `[@smith2020, p. 42]`: what it cites ([text] is the citation as it was written, which is what shows
  /// while there is no library to read it with); else null.
  final List<CiteRef>? cite;

  /// For a reference to a footnote, `[^1]`: the footnote's label ([text] is how it is written).
  final String? footnote;

  /// For a cross-reference, `{@fig:cat}`: what it refers to.
  final String? ref;

  /// For a picture, `![text|width](target)`: where it is (`image:<file>` for one kept by the app) and how wide it is drawn
  /// (null: as wide as it is, at most the width of the text).
  final String? image;
  final double? imageWidth;

  const MdRun(this.text, this.src,
      {this.bold = false,
      this.italic = false,
      this.strike = false,
      this.code = false,
      this.highlight = false,
      this.superscript = false,
      this.subscript = false,
      this.inserted = false,
      this.deleted = false,
      this.commented = false,
      this.comment = false,
      this.math = false,
      this.link,
      this.cite,
      this.footnote,
      this.ref,
      this.image,
      this.imageWidth});

  /// The same [by] characters further on in the text.
  MdRun shifted(int by) => MdRun(text, src + by,
      bold: bold,
      italic: italic,
      strike: strike,
      code: code,
      highlight: highlight,
      superscript: superscript,
      subscript: subscript,
      inserted: inserted,
      deleted: deleted,
      commented: commented,
      comment: comment,
      math: math,
      link: link,
      cite: cite,
      footnote: footnote,
      ref: ref,
      image: image,
      imageWidth: imageWidth);
}

/// One block of a Markdown text (a paragraph, heading, list item, formula, table or code block).
/// The on-screen view and the PDF export both draw from these.
class MdBlock {
  final MdBlockType type;

  /// Heading level (1-6) or the number of a numbered item.
  final int level;

  List<MdRun> _runs;
  List<List<List<MdRun>>> _rows;
  List<MdMarkup> _markup;

  /// How far [_runs], [_rows] and [_markup] are behind this block: a block that only moved has them moved when they are asked for. A key
  /// that is pressed moves all the blocks after it, and nobody looks at what is in most of them.
  int _behind = 0;

  void _catchUp() {
    final by = _behind;
    if (by == 0) return;
    _behind = 0;
    _runs = [for (final r in _runs) r.shifted(by)];
    if (_rows.isNotEmpty) _rows = [for (final row in _rows) [for (final cell in row) [for (final r in cell) r.shifted(by)]]];
    _markup = [for (final m in _markup) m.shifted(by)];
  }

  List<MdRun> get runs {
    _catchUp();
    return _runs;
  }

  /// For a table: its rows of cells, each cell the runs of its text; the first row is the head.
  List<List<List<MdRun>>> get rows {
    _catchUp();
    return _rows;
  }

  /// For a table: how each column is aligned (`left`, `center`, `right`, empty: as usual).
  final List<String> aligns;

  /// For a block of code: the code, and the language named after the opening fence (empty when none).
  final String code;
  final String lang;

  /// Where the block is in the source: from the start of its first line to the end of its last (without the line break).
  final int start, end;

  /// Where its layout token ends and where its text starts (after the `# `, `- [ ] `, `> `...).
  final int tokenEnd, contentStart;

  /// How deep a list item or quote is nested: the spaces before its marker, two to a step.
  final int depth;

  /// A task that is done (`- [x]`).
  final bool checked;

  final ParagraphFormat format;

  /// The inline Markdown in the block's text, outermost first.
  List<MdMarkup> get markup {
    _catchUp();
    return _markup;
  }

  /// A footnote's label, or which setting a [MdBlockType.setting] line is.
  final String label;

  MdBlock(this.type, List<MdRun> runs,
      {this.level = 0,
      List<List<List<MdRun>>> rows = const [],
      this.aligns = const [],
      this.code = '',
      this.lang = '',
      this.start = 0,
      this.end = 0,
      this.tokenEnd = 0,
      this.contentStart = 0,
      this.depth = 0,
      this.checked = false,
      this.format = ParagraphFormat.plain,
      List<MdMarkup> markup = const [],
      this.label = ''})
      : _runs = runs,
        _rows = rows,
        _markup = markup;

  /// The same [by] characters further on in the text.
  MdBlock shifted(int by) => MdBlock(type, _runs,
      level: level,
      rows: _rows,
      aligns: aligns,
      code: code,
      lang: lang,
      start: start + by,
      end: end + by,
      tokenEnd: tokenEnd + by,
      contentStart: contentStart + by,
      depth: depth,
      checked: checked,
      format: format,
      markup: _markup,
      label: label)
    .._words = _words
    .._behind = _behind + by;

  int? _words;

  /// How many words the block has as it reads (its Markdown and layout not counted); counted once for a block.
  int get words => _words ??= () {
        if (type == MdBlockType.code) return _word.allMatches(code).length;
        var count = 0;
        if (type == MdBlockType.table) {
          for (final row in _rows) {
            for (final cell in row) {
              for (final r in cell) {
                count += _word.allMatches(r.text).length;
              }
            }
          }
        } else if (type != MdBlockType.bibliography && type != MdBlockType.rule) {
          for (final r in _runs) {
            if (r.deleted || r.comment) continue;
            count += r.math || r.cite != null ? 1 : _word.allMatches(r.text).length;
          }
        }
        return count;
      }();
}

final _word = RegExp(r"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*", unicode: true);

/// A [MdRun] split further so that it also carries the manual
/// bold/italic/underline attributes of a [RichInlineTextController].
class MdSegment {
  final String text;
  final bool bold, italic, underline, strike, code;

  /// `==marked==` (yellow) when [highlightColor] is null; a highlight picked from the bar is an ARGB colour.
  final bool highlight;
  final int? highlightColor;

  /// The font family ([documentFonts]), size factor and colour (ARGB) picked for the text; null: the usual one.
  final String? font;
  final double? size;
  final int? color;
  final bool superscript, subscript;

  const MdSegment(this.text,
      {this.bold = false,
      this.italic = false,
      this.underline = false,
      this.strike = false,
      this.code = false,
      this.highlight = false,
      this.highlightColor,
      this.font,
      this.size,
      this.color,
      this.superscript = false,
      this.subscript = false});
}

final _heading = RegExp(r'^(#{1,6})\s+');
final _bullet = RegExp(r'^(\s*)[-*+]\s+');
final _task = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s+');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+');
final _quote = RegExp(r'^(\s*)>\s?');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _displayMath = RegExp(r'^\s*\$\$(.+?)\$\$\s*$');

/// A line of its own that is the list of the sources the note cites, wherever it is put.
final bibliographyMarker = RegExp(r'^\s*\[bibliography\]\s*$');

/// A text as it was parsed: its blocks, and which part of them is new since the text before: `[changedFrom, changedTo)` here was
/// `[changedFrom, oldTo)` there. Null [changedFrom]: all of it is new.
class ParsedText {
  final String text;
  final List<MdBlock> blocks;

  /// The text before, for [changedFrom].
  final String? previous;
  final int? changedFrom;
  final int changedTo, oldTo;

  const ParsedText(this.text, this.blocks, {this.previous, this.changedFrom, this.changedTo = 0, this.oldTo = 0});
}

final Expando<ParsedText> _parsedText = Expando('parsed Markdown');

/// What [parseMarkdown] makes of the text of [controller], kept with the controller: a key that is pressed asks for it from several
/// places (the drawing of the text, the toolbar, the word count, the grammar check, where pages end), and a change reads only the
/// blocks it touches. What is kept goes when the controller does.
List<MdBlock> parsedMarkdown(RichInlineTextController controller) => parsedText(controller).blocks;

/// [parsedMarkdown], with what changed since the text before.
ParsedText parsedText(RichInlineTextController controller) {
  final text = controller.text;
  final kept = _parsedText[controller];
  if (kept != null && kept.text == text) return kept;
  if (kept == null) return _parsedText[controller] = ParsedText(text, parseMarkdown(text));
  final edit = controller.lastEdit;
  final known = identical(edit.of, kept.text) && identical(edit.now, text);
  return _parsedText[controller] = reparsed(kept.text, kept.blocks, text, from: known ? edit.start : 0, tail: known ? edit.tail : 0);
}

/// The first of [blocks] that ends at or after [at].
int blockAt(List<MdBlock> blocks, int at) {
  var low = 0, high = blocks.length - 1;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (blocks[middle].end < at) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

final _fenceLine = RegExp(r'^ {0,3}(?:`{3,}|~{3,}).*$', multiLine: true);

/// The blocks of [now], made from [blocks], those of [old]: what lies before the change stays as it is, what lies after it moves, and
/// only the blocks it touches are read. Every line is a block of its own but for tables and code: the rows next to a change are read
/// with it, and when the lines that open and close code are not what they were, all of the text is read.
ParsedText reparsed(String old, List<MdBlock> blocks, String now, {int from = 0, int tail = 0}) {
  var p = from;
  final common = old.length < now.length ? old.length : now.length;
  while (p < common && old.codeUnitAt(p) == now.codeUnitAt(p)) {
    p++;
  }
  while (tail < common - p && old.codeUnitAt(old.length - 1 - tail) == now.codeUnitAt(now.length - 1 - tail)) {
    tail++;
  }
  final q = old.length - tail, delta = now.length - old.length;
  var first = blockAt(blocks, p), last = blockAt(blocks, q);
  bool rowLike(MdBlock b) => b.type == MdBlockType.table || isTableRow(old.substring(b.start, b.end));
  while (first > 0 && rowLike(blocks[first - 1])) {
    first--;
  }
  while (last + 1 < blocks.length && rowLike(blocks[last + 1])) {
    last++;
  }
  final at = blocks[first].start, to = blocks[last].end;
  final before = old.substring(at, to), after = now.substring(at, to + delta);
  final fences = [for (final m in _fenceLine.allMatches(before)) m.group(0)!];
  final fencesNow = [for (final m in _fenceLine.allMatches(after)) m.group(0)!];
  if (fences.length != fencesNow.length) return ParsedText(now, parseMarkdown(now));
  for (var i = 0; i < fences.length; i++) {
    if (fences[i] != fencesNow[i]) return ParsedText(now, parseMarkdown(now));
  }
  return ParsedText(
    now,
    [
      ...blocks.take(first),
      for (final b in parseMarkdown(after)) at == 0 ? b : b.shifted(at),
      for (var i = last + 1; i < blocks.length; i++) delta == 0 ? blocks[i] : blocks[i].shifted(delta),
    ],
    previous: old,
    changedFrom: at,
    changedTo: to + delta,
    oldTo: to,
  );
}

List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  var offset = 0;
  final lines = source.split('\n');
  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    // a block of code: between two lines of three backticks, the language after the first
    final fence = matchFenceOpen(line);
    if (fence != null) {
      final body = <String>[];
      final closing = findFenceEnd(lines, n, fence);
      final end = closing ?? lines.length;
      for (var k = n + 1; k < end; k++) {
        body.add(lines[k]);
      }
      if (closing != null) {
        final start = offset;
        for (var k = n; k <= end; k++) {
          offset += lines[k].length + 1;
        }
        blocks.add(MdBlock(MdBlockType.code, const [],
            code: body.join('\n'), lang: fence.lang, start: start, end: offset - 1, tokenEnd: start, contentStart: start));
        n = end;
        continue;
      }
    }
    // a table: rows of bars, the second line only dashes
    if (isTableRow(line) && n + 1 < lines.length && isTableRow(lines[n + 1]) && tableSeparator.hasMatch(lines[n + 1])) {
      final rows = <List<List<MdRun>>>[];
      var at = offset, end = n;
      for (var k = n; k < lines.length && isTableRow(lines[k]); k++) {
        if (k != n + 1) {
          rows.add([
            for (final (a, b) in cellSpans(lines[k]))
              () {
                final cell = <MdRun>[];
                var from = a, to = b;
                while (from < to && lines[k][from] == ' ') {
                  from++;
                }
                while (to > from && lines[k][to - 1] == ' ') {
                  to--;
                }
                _inline(lines[k], from, to, at, cell, <MdMarkup>[]);
                return cell;
              }(),
          ]);
        }
        at += lines[k].length + 1;
        end = k;
      }
      final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
      for (final r in rows) {
        while (r.length < width) {
          r.add(const []);
        }
      }
      blocks.add(MdBlock(MdBlockType.table, const [],
          rows: rows, aligns: columnAligns(lines[n + 1]), start: offset, end: at - 1, tokenEnd: offset, contentStart: offset));
      offset = at;
      n = end;
      continue;
    }
    final token = paragraphFormatOf(line);
    final t = token?.$1 ?? 0;
    final rest = t == 0 ? line : line.substring(t);
    final runs = <MdRun>[];
    final markup = <MdMarkup>[];
    var type = MdBlockType.paragraph;
    var level = 0, depth = 0, content = t;
    var checked = false;
    Match? m;
    var label = '';
    if (bibliographyMarker.hasMatch(rest)) {
      type = MdBlockType.bibliography;
      runs.add(MdRun(rest.trim(), offset + t + rest.indexOf('[')));
    } else if (tocMarker.hasMatch(rest)) {
      type = MdBlockType.toc;
      content = line.length;
    } else if (pageBreakMarker.hasMatch(rest)) {
      type = MdBlockType.pageBreak;
      content = line.length;
    } else if (t == 0 && (m = _setting.firstMatch(line)) != null) {
      type = MdBlockType.setting;
      label = m!.group(1)!;
      content = m.end;
      if (m.end < line.length) runs.add(MdRun(line.substring(m.end), offset + m.end));
    } else if ((m = _footnoteDef.firstMatch(rest)) != null) {
      type = MdBlockType.footnote;
      label = m!.group(1)!;
      content = t + m.end;
      _inline(line, content, line.length, offset, runs, markup);
    } else if ((m = _displayMath.firstMatch(rest)) != null) {
      final tex = m!.group(1)!.trim();
      runs.add(MdRun(tex, offset + t + rest.indexOf(tex), math: true));
      type = MdBlockType.math;
    } else if (_rule.hasMatch(rest)) {
      type = MdBlockType.rule;
      content = line.length;
    } else {
      if ((m = _heading.firstMatch(rest)) != null) {
        type = MdBlockType.heading;
        level = m!.group(1)!.length;
      } else if ((m = _task.firstMatch(rest)) != null) {
        type = MdBlockType.task;
        depth = m!.group(1)!.length ~/ 2;
        checked = m.group(2) != ' ';
      } else if ((m = _bullet.firstMatch(rest)) != null) {
        type = MdBlockType.bullet;
        depth = m!.group(1)!.length ~/ 2;
      } else if ((m = _numbered.firstMatch(rest)) != null) {
        type = MdBlockType.numbered;
        depth = m!.group(1)!.length ~/ 2;
        level = int.parse(m.group(2)!);
      } else if ((m = _quote.firstMatch(rest)) != null) {
        type = MdBlockType.quote;
        depth = m!.group(1)!.length ~/ 2;
      } else if ((m = _caption.firstMatch(rest)) != null) {
        type = MdBlockType.caption;
        label = m!.group(1)!.startsWith('Ta') ? 'table' : 'figure';
      }
      content = t + (m?.end ?? 0);
      _inline(line, content, line.length, offset, runs, markup);
    }
    blocks.add(MdBlock(type, runs,
        level: level,
        start: offset,
        end: offset + line.length,
        tokenEnd: offset + t,
        contentStart: offset + content,
        depth: depth,
        checked: checked,
        format: token?.$2 ?? ParagraphFormat.plain,
        markup: markup,
        label: label));
    offset += line.length + 1;
  }
  return blocks;
}

bool _isWordChar(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);

/// Parses `line[start, end)`; [base] is the source offset of `line[0]`. The inline Markdown found goes into [markup].
void _inline(String line, int start, int end, int base, List<MdRun> out, List<MdMarkup> markup,
    {bool bold = false,
    bool italic = false,
    bool strike = false,
    bool highlight = false,
    bool superscript = false,
    bool subscript = false,
    bool inserted = false,
    bool deleted = false,
    bool commented = false}) {
  final buf = StringBuffer();
  var bufStart = start;

  void flush(int upTo) {
    if (buf.isNotEmpty) {
      out.add(MdRun(buf.toString(), base + bufStart,
          bold: bold,
          italic: italic,
          strike: strike,
          highlight: highlight,
          superscript: superscript,
          subscript: subscript,
          inserted: inserted,
          deleted: deleted,
          commented: commented));
      buf.clear();
    }
    bufStart = upTo;
  }

  var i = start;
  while (i < end) {
    final c = line[i];

    // a name for a heading or caption, `{#fig:cat}`, and a reference to one, `{@fig:cat}`
    if (c == '{' && i + 2 < end && (line[i + 1] == '#' || line[i + 1] == '@')) {
      final close = line.indexOf('}', i + 2);
      final id = close < 0 || close >= end ? '' : line.substring(i + 2, close);
      if (RegExp(r'^[\w:.\-]+$').hasMatch(id)) {
        // (a name takes the space before it along: it is not part of the text)
        var from = i;
        if (line[i + 1] == '#' && buf.isNotEmpty && buf.toString().endsWith(' ')) {
          final kept = buf.toString();
          buf
            ..clear()
            ..write(kept.substring(0, kept.length - 1));
          from = i - 1;
        }
        flush(close + 1);
        if (line[i + 1] == '#') {
          markup.add(MdMarkup(MdMarkupKind.anchor, base + from, base + close + 1, base + i + 2, base + close, id: id));
        } else {
          markup.add(MdMarkup(MdMarkupKind.ref, base + i, base + close + 1, base + i + 2, base + close, id: id));
          out.add(MdRun(id, base + i + 2, bold: bold, italic: italic, ref: id));
        }
        i = close + 1;
        bufStart = i;
        continue;
      }
    }

    // tracked changes and comments (CriticMarkup): `{++put in++}`, `{--taken out--}`, `{==this==}{>>a comment on it<<}`
    if (c == '{' && i + 3 < end) {
      final kind = line.substring(i, i + 3);
      final close = switch (kind) { '{++' => '++}', '{--' => '--}', '{==' => '==}', '{>>' => '<<}', _ => null };
      final to = close == null ? -1 : line.indexOf(close, i + 3);
      if (close != null && to >= i + 3 && to + 3 <= end) {
        flush(to + 3);
        if (kind == '{>>') {
          markup.add(MdMarkup(MdMarkupKind.comment, base + i, base + to + 3, base + i + 3, base + to));
          out.add(MdRun(line.substring(i + 3, to), base + i + 3, comment: true));
        } else {
          markup.add(MdMarkup(MdMarkupKind.change, base + i, base + to + 3, base + i + 3, base + to));
          _inline(line, i + 3, to, base, out, markup,
              bold: bold,
              italic: italic,
              strike: strike,
              highlight: highlight,
              superscript: superscript,
              subscript: subscript,
              inserted: inserted || kind == '{++',
              deleted: deleted || kind == '{--',
              commented: commented || kind == '{==');
        }
        i = to + 3;
        bufStart = i;
        continue;
      }
    }

    // a formula: `$x^2$`. A dollar sign that is only money ("$5 and $6") stays text:
    // the formula starts and ends against its text, and is not followed by a digit
    if (c == '\$' && (i == start || line[i - 1] != '\\') && i + 1 < end && line[i + 1] != ' ' && line[i + 1] != '\$') {
      var close = line.indexOf('\$', i + 1);
      while (close > 0 && close < end && line[close - 1] == '\\') {
        close = line.indexOf('\$', close + 1); // an escaped dollar sign belongs to the formula
      }
      if (close > i + 1 &&
          close < end &&
          line[close - 1] != ' ' &&
          !(close + 1 < end && RegExp(r'[0-9]').hasMatch(line[close + 1]))) {
        flush(close + 1);
        markup.add(MdMarkup(MdMarkupKind.math, base + i, base + close + 1, base + i + 1, base + close));
        out.add(MdRun(line.substring(i + 1, close), base + i + 1, bold: bold, italic: italic, strike: strike, math: true));
        i = close + 1;
        bufStart = i;
        continue;
      }
    }

    // a reference to a footnote: `[^1]`
    if (c == '[' && i + 2 < end && line[i + 1] == '^') {
      final close = line.indexOf(']', i + 2);
      if (close > i + 2 && close < end && RegExp(r'^[\w-]+$').hasMatch(line.substring(i + 2, close))) {
        flush(close + 1);
        markup.add(MdMarkup(MdMarkupKind.footnote, base + i, base + close + 1, base + i, base + close + 1));
        out.add(MdRun(line.substring(i, close + 1), base + i, bold: bold, italic: italic, footnote: line.substring(i + 2, close)));
        i = close + 1;
        bufStart = i;
        continue;
      }
    }

    // a picture: `![what it shows](where it is)`, `![what it shows|300](where it is)` for one 300 wide
    if (c == '!' && i + 1 < end && line[i + 1] == '[') {
      final mid = line.indexOf('](', i + 2);
      final close = mid < 0 ? -1 : line.indexOf(')', mid + 2);
      if (mid >= i + 2 && close > mid + 2 && close < end) {
        final target = line.substring(mid + 2, close);
        if (!target.contains(' ')) {
          var alt = line.substring(i + 2, mid);
          double? w;
          final bar = alt.lastIndexOf('|');
          if (bar >= 0 && double.tryParse(alt.substring(bar + 1)) != null) {
            w = double.parse(alt.substring(bar + 1));
            alt = alt.substring(0, bar);
          }
          flush(close + 1);
          markup.add(MdMarkup(MdMarkupKind.image, base + i, base + close + 1, base + i + 2, base + mid));
          out.add(MdRun(alt, base + i + 2, image: target, imageWidth: w));
          i = close + 1;
          bufStart = i;
          continue;
        }
      }
    }

    // a citation: `[@smith2020, p. 42; @doe2019]`, or in a sentence `@smith2020 [p. 42]`
    if (c == '[' || c == '@') {
      final hit = c == '[' ? citationAt(line, i, end) : narrativeAt(line, i, end);
      if (hit != null) {
        flush(hit.$1);
        markup.add(MdMarkup(MdMarkupKind.cite, base + i, base + hit.$1, base + i, base + hit.$1));
        out.add(MdRun(line.substring(i, hit.$1), base + i, bold: bold, italic: italic, strike: strike, cite: hit.$2));
        i = hit.$1;
        bufStart = i;
        continue;
      }
    }

    // a link: `[text](target)`, the target without spaces
    if (c == '[') {
      final mid = line.indexOf('](', i + 1);
      final close = mid < 0 ? -1 : line.indexOf(')', mid + 2);
      if (mid > i + 1 && close > mid + 2 && close < end && mid < end) {
        final target = line.substring(mid + 2, close);
        if (!target.contains(' ')) {
          flush(close + 1);
          markup.add(MdMarkup(MdMarkupKind.link, base + i, base + close + 1, base + i + 1, base + mid));
          out.add(MdRun(line.substring(i + 1, mid), base + i + 1,
              bold: bold, italic: italic, strike: strike, highlight: highlight, link: target));
          i = close + 1;
          bufStart = i;
          continue;
        }
      }
    }

    // (marker, closing index) for the formats that nest
    String? marker;
    if (line.startsWith('**', i) && i + 2 < end) {
      marker = '**';
    } else if (line.startsWith('~~', i) && i + 2 < end) {
      marker = '~~';
    } else if (line.startsWith('==', i) && i + 2 < end) {
      marker = '==';
    } else if (c == '*' && i + 1 < end) {
      marker = '*';
    } else if (c == '_' && i + 1 < end && (i == start || !_isWordChar(line[i - 1]))) {
      marker = '_';
    } else if ((c == '^' || c == '~') && i + 1 < end) {
      marker = c;
    }

    if (marker != null) {
      var close = line.indexOf(marker, i + marker.length);
      // `**a *b***`: close on the last two stars of the run
      if (marker == '**') {
        while (close > 0 && close + 2 < end && line[close + 2] == '*') {
          close++;
        }
      }
      final valid = close > i + marker.length &&
          close < end &&
          line[i + marker.length] != ' ' &&
          // `*a**b**` style ambiguity: a single * must not close on a **
          !(marker.length == 1 && close + 1 < end && line.startsWith(marker * 2, close)) &&
          !(marker == '_' && close + 1 < end && _isWordChar(line[close + 1])) &&
          // `^raised^`, `~lowered~`: no spaces in them (so "~5 to ~10" stays as it is)
          !((marker == '^' || marker == '~') && line.substring(i + 1, close).contains(RegExp(r'\s')));
      if (valid) {
        flush(close + marker.length);
        markup.add(MdMarkup(MdMarkupKind.pair, base + i, base + close + marker.length, base + i + marker.length, base + close));
        _inline(line, i + marker.length, close, base, out, markup,
            bold: bold || marker == '**',
            italic: italic || marker == '*' || marker == '_',
            strike: strike || marker == '~~',
            highlight: highlight || marker == '==',
            superscript: superscript || marker == '^',
            subscript: subscript || marker == '~',
            inserted: inserted,
            deleted: deleted,
            commented: commented);
        i = close + marker.length;
        bufStart = i;
        continue;
      }
    }

    if (c == '`') {
      final close = line.indexOf('`', i + 1);
      if (close > i + 1 && close < end) {
        flush(close + 1);
        markup.add(MdMarkup(MdMarkupKind.code, base + i, base + close + 1, base + i + 1, base + close));
        out.add(MdRun(line.substring(i + 1, close), base + i + 1,
            bold: bold, italic: italic, strike: strike, code: true));
        i = close + 1;
        bufStart = i;
        continue;
      }
    }

    // keep marker characters that did not form a pair as literal text
    if (buf.isEmpty) bufStart = i;
    buf.write(c);
    i++;
  }
  flush(end);
}

/// Splits [run] wherever a manual attribute of [attributes] starts or ends.
List<MdSegment> segmentsOf(MdRun run, List<TextSpanAttribute> attributes) {
  final segs = <MdSegment>[];
  final lo = run.src, hi = run.src + run.text.length;

  final cuts = <int>{lo, hi};
  for (final a in attributes) {
    if (a.start > lo && a.start < hi) cuts.add(a.start);
    if (a.end > lo && a.end < hi) cuts.add(a.end);
  }
  final sorted = cuts.toList()..sort();

  for (var k = 0; k + 1 < sorted.length; k++) {
    final a = sorted[k], b = sorted[k + 1];
    TextSpanAttribute? find(AttributeType t) => attributes.where((x) => x.type == t && x.start <= a && x.end >= b).lastOrNull;
    bool has(AttributeType t) => find(t) != null;
    final mark = find(AttributeType.highlight);
    segs.add(MdSegment(run.text.substring(a - lo, b - lo),
        bold: run.bold || has(AttributeType.bold),
        italic: run.italic || has(AttributeType.italic),
        underline: has(AttributeType.underline),
        strike: run.strike,
        code: run.code,
        highlight: run.highlight || mark != null,
        highlightColor: mark?.colorValue,
        font: find(AttributeType.font)?.value,
        size: find(AttributeType.size)?.sizeValue,
        color: find(AttributeType.color)?.colorValue,
        superscript: run.superscript || has(AttributeType.superscript),
        subscript: run.subscript || has(AttributeType.subscript)));
  }
  return segs;
}

/// Font size multiplier for a heading level.
double headingScale(int level) => switch (level) { 1 => 1.6, 2 => 1.35, 3 => 1.15, 4 => 1.05, 5 => 1.0, _ => 0.9 };
