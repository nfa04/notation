import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../citations/citation_document.dart';
import '../citations/citation_service.dart';
import '../l10n/text.dart';
import '../l10n/language.dart';
import '../models/rich_text.dart';
import 'code_highlight.dart';
import 'document_dialogs.dart';
import 'document_images.dart';
import 'remote_image.dart';
import 'grammar.dart';
import 'markdown_parser.dart';
import 'markdown_view.dart';

/// The written document as it looks while it is written (what you see is what you get): the Markdown is applied in place and
/// its marks are hidden, except around the caret - the `#` of the heading the caret is on, the stars of the bold word it is in.
/// A table, a formula, a link, a citation and a rule show as themselves until the caret goes into them. The text itself stays
/// Markdown: every character is still there, only drawn differently (hidden ones have no size), so that the caret, the selection
/// and the undo of the text field work on it as on any text.

/// What tapping the parts of the document does (null: they are only shown).
class LiveMarkdownActions {
  final ValueChanged<String>? onLink;
  final ValueChanged<MdRun>? onCitation;

  /// Called with where the `[` of a task's box is, to tick it or take the tick away.
  final ValueChanged<int>? onToggleTask;

  /// Called when a comment's mark is tapped, to read, change or take away the comment.
  final void Function(BuildContext context, MdMarkup comment)? onComment;

  /// Called with where a heading is in the text when its entry in the table of contents is tapped, to go there.
  final ValueChanged<int>? onHeading;

  const LiveMarkdownActions({this.onLink, this.onCitation, this.onToggleTask, this.onComment, this.onHeading});
}

/// The style the written document is set in (the start for every piece of it).
TextStyle documentTextStyle(double fontSize, {Color color = Colors.black87}) =>
    TextStyle(fontSize: fontSize, height: 1.5, color: color, fontFamily: documentFonts['Sans']);

/// How far one step of indent moves a paragraph, for a text of [fontSize].
double indentStep(double fontSize) => fontSize * 2;

// how a character is drawn, worked out from the Markdown, the formatting picked for it, the spelling and the search
class _Char {
  bool hidden = false, dim = false, faint = false;
  bool bold = false, italic = false, underline = false, strike = false, mono = false, link = false, sup = false, sub = false;
  bool codeTint = false, inserted = false, deleted = false, commented = false, blurred = false;
  int? highlight, color, codeColor;
  String? font;
  double? size; // a size picked for it: a factor of the usual one (a heading's size does not apply then)
  double scale = 1; // a heading's
  double? lineHeight;
  double letterSpacing = 0;

  /// Whether [o] is drawn as this one is, as far as these say: a run of text is thousands of these, and a style is not made for each.
  bool looksLike(_Char o) =>
      hidden == o.hidden && dim == o.dim && faint == o.faint && bold == o.bold && italic == o.italic && underline == o.underline &&
      strike == o.strike && mono == o.mono && link == o.link && codeTint == o.codeTint && inserted == o.inserted && deleted == o.deleted &&
      commented == o.commented && blurred == o.blurred && highlight == o.highlight && color == o.color && codeColor == o.codeColor &&
      font == o.font && size == o.size && scale == o.scale && lineHeight == o.lineHeight && letterSpacing == o.letterSpacing;
}

const _hidden = TextStyle(fontSize: 0, color: Color(0x00000000));
const _yellow = 0xFFFFF176;

/// The text of [controller] as the written document shows it, in [base] and [width] wide. [reveal] is the selection while the
/// text is being written: the Markdown it touches shows; null shows none.
TextSpan liveMarkdownSpan(
  BuildContext context,
  RichInlineTextController controller,
  TextStyle base, {
  required double width,
  TextSelection? reveal,
  LiveMarkdownActions actions = const LiveMarkdownActions(),
}) {
  if (controller.text.isEmpty) return TextSpan(text: '', style: base);
  return _LiveBuilder(context, LiveSource.of(controller), base, width, reveal, actions).build();
}

/// About how many characters a piece of the document that is only read has (see [liveMarkdownPieces]).
const int _pieceSize = 2500;

/// The text of [controller] as [liveMarkdownSpan] shows it, in pieces that end where a block ends: one paragraph each, one below the
/// other, they look the same as one that holds it all. A paragraph with all of a long document in it would take very long to start:
/// each widget in it (a table, a tick box, a formula) has the accessibility of all of its text worked out again.
List<TextSpan> liveMarkdownPieces(
  BuildContext context,
  RichInlineTextController controller,
  TextStyle base, {
  required double width,
  LiveMarkdownActions actions = const LiveMarkdownActions(),
}) {
  return liveMarkdownPiecesInTurn(context, controller, base, width: width, actions: actions).toList();
}

/// [liveMarkdownPieces], each made when it is asked for (see [LivePieces]).
Iterable<TextSpan> liveMarkdownPiecesInTurn(
  BuildContext context,
  RichInlineTextController controller,
  TextStyle base, {
  required double width,
  LiveMarkdownActions actions = const LiveMarkdownActions(),
}) {
  if (controller.text.isEmpty) return [TextSpan(text: '', style: base)];
  return _LiveBuilder(context, LiveSource.of(controller), base, width, null, actions).pieces();
}

/// One block of the document as the written document shows it. [source] has only that block, its places counted from the block's start.
TextSpan liveBlockSpan(
  BuildContext context,
  LiveSource source,
  TextStyle base, {
  required double width,
  TextSelection? reveal,
  LiveMarkdownActions actions = const LiveMarkdownActions(),
}) {
  if (source.text.isEmpty) return TextSpan(text: '', style: base);
  return _LiveBuilder(context, source, base, width, reveal, actions).build();
}

/// What the blocks of a document know of each other: the numbers of its footnotes and captions, what its cross-references say, its
/// named styles, and for a table of contents and a list of sources all of it.
class LiveFacts {
  final String text;
  final List<MdBlock> blocks;
  final Map<String, int> footnotes;
  final Map<String, NamedStyle> styles;
  final Map<int, int> captions;
  final Map<String, String> references;

  const LiveFacts(this.text, this.blocks, {required this.footnotes, required this.styles, required this.captions, required this.references});

  factory LiveFacts.of(String text, List<MdBlock> blocks) => LiveFacts(
        text,
        blocks,
        footnotes: footnoteNumbers(blocks),
        styles: documentStyles(blocks),
        captions: captionNumbers(blocks),
        references: crossReferences(blocks, figure: tr('Figure'), table: tr('Table')),
      );

  /// These facts for a block with its places counted from its own start: a caption's number goes by where its block starts.
  LiveFacts forBlock(MdBlock b) => b.type != MdBlockType.caption
      ? this
      : LiveFacts(text, blocks, footnotes: footnotes, styles: styles, captions: {0: captions[b.start] ?? 0}, references: references);
}

/// What the document is drawn from: all of it, or one block of it with its places counted from the block's start.
class LiveSource {
  /// Whose tables are remembered (see [_LiveBuilder._tablesOf]).
  final Object owner;
  final String text;
  final Iterable<TextSpanAttribute> attributes;
  final List<({int start, int end})> misspelled;
  final List<({int start, int end})> found;
  final int foundNow;
  final List<({int start, int end})> Function() grammar;
  final bool focusMode;
  final List<MdBlock> blocks;
  final LiveFacts Function() facts;

  const LiveSource({
    required this.owner,
    required this.text,
    required this.attributes,
    required this.misspelled,
    required this.found,
    this.foundNow = -1,
    required this.grammar,
    this.focusMode = false,
    required this.blocks,
    required this.facts,
  });

  factory LiveSource.of(RichInlineTextController c) {
    final blocks = parsedMarkdown(c);
    return LiveSource(
      owner: c,
      text: c.text,
      attributes: c.attributes,
      misspelled: [for (final r in c.misspelled) (start: r.start, end: r.end)],
      found: c.found,
      foundNow: c.foundNow,
      grammar: () => c is LiveMarkdownController && c.checkGrammar ? [for (final g in c.grammar) (start: g.start, end: g.end)] : const [],
      focusMode: c is LiveMarkdownController && c.focusMode,
      blocks: blocks,
      facts: () => LiveFacts.of(c.text, blocks),
    );
  }
}

class _LiveBuilder {
  final BuildContext context;
  final LiveSource source;
  final TextStyle base;
  final double width;
  final TextSelection? reveal;
  final LiveMarkdownActions actions;
  final String text;
  final List<_Char> chars;
  final Map<int, InlineSpan> widgets = {};
  late final double fontSize = base.fontSize ?? 16;
  late final Color textColor = base.color ?? Colors.black87;
  late final bool dark = textColor.computeLuminance() > 0.5;
  late final CitationDocument? cites = CitationStyleScope.documentFor(context, facts.text);
  late final List<bool> wrong = _marks(source.misspelled);
  late final List<int> found = _found();
  late final List<bool> grammar = _marks(source.grammar());
  late final LiveFacts facts = source.facts();

  _LiveBuilder(this.context, this.source, this.base, this.width, this.reveal, this.actions)
      : text = source.text,
        chars = List.generate(source.text.length, (_) => _Char());

  int get n => text.length;

  Map<String, int> get footnotes => facts.footnotes;
  Map<String, NamedStyle> get styles => facts.styles;
  Map<int, int> get captions => facts.captions;
  Map<String, String> get references => facts.references;

  // (the widgets are named by which one of their kind they are, not by where they are in the text: a name that changed with each key
  // pressed before them would make each of them anew)
  int _tables = 0, _tasks = 0, _captions = 0, _paragraphs = 0, _comments = 0;

  late final Map<(String, double, Color), Widget> _tablesBefore = _tablesOf[source.owner] ?? const {};
  final Map<(String, double, Color), Widget> _tablesNow = {};

  /// The tables that were last shown of each owner of a text.
  static final Expando<Map<(String, double, Color), Widget>> _tablesOf = Expando('tables shown');

  List<bool> _marks(List<({int start, int end})> ranges) {
    final out = List<bool>.filled(n, false);
    for (final r in ranges) {
      for (var i = math.max(0, r.start); i < r.end && i < n; i++) {
        out[i] = true;
      }
    }
    return out;
  }

  List<int> _found() {
    final out = List<int>.filled(n, 0);
    for (var k = 0; k < source.found.length; k++) {
      final r = source.found[k];
      for (var i = math.max(0, r.start); i < r.end && i < n; i++) {
        out[i] = k == source.foundNow ? 2 : 1;
      }
    }
    return out;
  }

  bool touches(int a, int b) {
    final r = reveal;
    return r != null && r.isValid && r.start <= b && r.end >= a;
  }

  /// Whether the selection is inside `text[a, b)`, not only against it (a link, formula or citation shows as it is written then).
  bool inside(int a, int b) {
    final r = reveal;
    return r != null && r.isValid && r.start < b && r.end > a && !(r.isCollapsed && (r.start == a));
  }

  void hide(int a, int b) {
    for (var i = math.max(0, a); i < b && i < n; i++) {
      chars[i].hidden = true;
    }
  }

  void dim(int a, int b) {
    for (var i = math.max(0, a); i < b && i < n; i++) {
      chars[i].dim = true;
    }
  }

  /// Shows `text[a, b)` as [child]: its first character is drawn as the widget, the others are hidden.
  void fold(int a, int b, Widget child, {PlaceholderAlignment alignment = PlaceholderAlignment.middle}) {
    if (a >= n || a >= b) return;
    hide(a + 1, b);
    chars[a].hidden = false;
    widgets[a] = WidgetSpan(alignment: alignment, baseline: TextBaseline.alphabetic, child: child);
  }

  TextSpan build() {
    _workOut();
    final out = spans(0, n);
    return TextSpan(style: base, children: out);
  }

  /// [build] in pieces (see [liveMarkdownPieces]). The line break between two pieces is the one between them being paragraphs.
  Iterable<TextSpan> pieces() sync* {
    _workOut();
    var from = 0;
    for (final b in source.blocks) {
      if (b.end - from < _pieceSize || b.end >= n || text[b.end] != '\n' || chars[b.end].hidden) continue;
      yield TextSpan(style: base, children: spans(from, b.end));
      from = b.end + 1;
    }
    yield TextSpan(style: base, children: spans(from, n));
  }

  /// Works out how each character is drawn.
  void _workOut() {
    for (final a in source.attributes) {
      for (var i = math.max(0, a.start); i < a.end && i < n; i++) {
        final c = chars[i];
        switch (a.type) {
          case AttributeType.bold:
            c.bold = true;
          case AttributeType.italic:
            c.italic = true;
          case AttributeType.underline:
            c.underline = true;
          case AttributeType.font:
            c.font = a.value;
          case AttributeType.size:
            c.size = a.sizeValue;
          case AttributeType.color:
            c.color = a.colorValue;
          case AttributeType.highlight:
            c.highlight = a.colorValue ?? _yellow;
          case AttributeType.superscript:
            c.sup = true;
          case AttributeType.subscript:
            c.sub = true;
        }
      }
    }
    for (final b in source.blocks) {
      _block(b);
    }
    _tablesOf[source.owner] = _tablesNow;
  }

  void _block(MdBlock b) {
    final touched = touches(b.start, b.end);
    if (!touched && reveal != null && source.focusMode) {
      for (var i = b.start; i <= b.end && i < n; i++) {
        chars[i].blurred = true;
      }
    }
    hide(b.start, b.tokenEnd); // the layout of the paragraph, never shown
    if (b.format.spacing != 1.0) {
      final h = (base.height ?? 1.2) * b.format.spacing;
      for (var i = b.start; i <= b.end && i < n; i++) {
        chars[i].lineHeight = h;
      }
    }
    switch (b.type) {
      case MdBlockType.code:
        _code(b, touched);
      case MdBlockType.table:
        if (!touched) _table(b);
      case MdBlockType.rule:
        if (touched) {
          dim(b.tokenEnd, b.end);
        } else {
          fold(b.tokenEnd, b.end, SizedBox(
            key: const ValueKey('live-rule'),
            width: _fullWidth,
            height: fontSize * 1.5,
            child: Center(child: Container(height: 1, color: textColor.withValues(alpha: 0.35))),
          ));
        }
      case MdBlockType.math:
        final tex = b.runs.single;
        if (touched) {
          dim(b.tokenEnd, tex.src);
          dim(tex.src + tex.text.length, b.end);
        } else {
          fold(b.tokenEnd, b.end, SizedBox(
            width: _fullWidth,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: fontSize * 0.3),
              child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: _math(tex.text, display: true))),
            ),
          ));
        }
      case MdBlockType.pageBreak:
        if (touched) {
          dim(b.tokenEnd, b.end);
        } else {
          fold(b.tokenEnd, b.end, SizedBox(
            key: const ValueKey('live-page-break'),
            width: _fullWidth,
            height: fontSize * 1.8,
            child: Row(children: [
              Expanded(child: CustomPaint(painter: _DashPainter(textColor.withValues(alpha: 0.35)), size: const Size(double.infinity, 1))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('Page break', style: TextStyle(fontSize: fontSize * 0.7, color: textColor.withValues(alpha: 0.5))),
              ),
              Expanded(child: CustomPaint(painter: _DashPainter(textColor.withValues(alpha: 0.35)), size: const Size(double.infinity, 1))),
            ]),
          ));
        }
      case MdBlockType.toc:
        if (touched) {
          dim(b.tokenEnd, b.end);
        } else {
          fold(b.tokenEnd, b.end, SizedBox(key: const ValueKey('live-toc'), width: _fullWidth, child: _toc()));
        }
      case MdBlockType.setting:
        // (a setting of the pages, not text: small, so that it is seen and can be changed)
        for (var i = b.start; i < b.end; i++) {
          chars[i]
            ..faint = true
            ..size = 0.75;
        }
        if (!touched) {
          final value = b.runs.map((r) => r.text).join();
          fold(b.start, b.end, Container(
            key: ValueKey('live-setting-${b.label}'),
            padding: EdgeInsets.symmetric(horizontal: fontSize * 0.4, vertical: 2),
            decoration: BoxDecoration(color: textColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(4)),
            child: Text.verbatim('${_settingName(b.label)}: $value',
                style: TextStyle(fontSize: fontSize * 0.75, color: textColor.withValues(alpha: 0.6))),
          ));
        }
      case MdBlockType.footnote:
        for (var i = b.start; i < b.end; i++) {
          chars[i].size = 0.85;
        }
        if (touched) {
          dim(b.tokenEnd, b.contentStart);
        } else {
          hide(b.tokenEnd + 1, b.contentStart);
          widgets[b.tokenEnd] = WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: Text.verbatim('${footnotes[b.label] ?? b.label} ', style: base.copyWith(fontSize: fontSize * 0.65, height: 1)),
          );
        }
        _inline(b);
      case MdBlockType.bibliography:
        final c = cites;
        if (!touched && c != null && c.cited.isNotEmpty) {
          fold(b.tokenEnd, b.end, SizedBox(width: _fullWidth, child: ReferenceList(text: facts.text, fontSize: fontSize, textColor: textColor)));
        }
      default:
        _textBlock(b, touched);
    }
  }

  /// Wide enough to take the whole line, not so wide that what is after it goes onto a line of its own.
  double get _fullWidth => math.max(0, width - 1);

  void _code(MdBlock b, bool touched) {
    final firstEnd = text.indexOf('\n', b.start);
    final lastStart = text.lastIndexOf('\n', b.end - 1) + 1;
    if (firstEnd < 0 || lastStart <= firstEnd) return;
    if (touched) {
      dim(b.start, firstEnd);
      dim(lastStart, b.end);
    } else {
      hide(b.start, firstEnd);
      hide(lastStart, b.end);
    }
    var at = firstEnd + 1;
    for (var i = at; i < lastStart - 1; i++) {
      chars[i]
        ..mono = true
        ..codeTint = true;
    }
    for (final t in highlightCode(b.code, b.lang)) {
      final c = codeColor(t.kind, dark: dark);
      for (var k = 0; k < t.text.length && at + k < n; k++) {
        chars[at + k].codeColor = c;
      }
      at += t.text.length;
    }
  }

  void _table(MdBlock b) {
    final source = text.substring(b.start, b.end);
    final lines = '\n'.allMatches(source).length;
    // (the same widget as the last time for a table that did not change, so that what is typed elsewhere leaves it alone)
    final look = (source, fontSize, textColor);
    final table = _tablesNow[look] = _tablesBefore[look] ?? MarkdownView(controller: RichInlineTextController()..text = source, fontSize: fontSize, textColor: textColor);
    // the lines of the table after the first are hidden, but a line keeps a height even then: the table hangs over them
    final lift = lines * _hiddenLineHeight();
    fold(
      b.start,
      b.end,
      _Overhang(
        lift: lift,
        child: SizedBox(
          key: ValueKey('live-table-${_tables++}'),
          width: _fullWidth,
          child: table,
        ),
      ),
      alignment: PlaceholderAlignment.top,
    );
    if (b.end < n) hide(b.end, b.end + 1);
  }

  static final Map<(double, double?, String?, double), double> _hiddenHeights = {};

  /// The height a line of only hidden characters still has.
  double _hiddenLineHeight() {
    final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    final key = (fontSize, base.height, base.fontFamily, scaler.scale(1));
    return _hiddenHeights[key] ??= () {
      TextPainter painter(TextSpan span) =>
          TextPainter(text: span, textDirection: TextDirection.ltr, textScaler: scaler, strutStyle: StrutStyle.disabled)..layout();
      final one = painter(TextSpan(style: base, text: 'x'));
      final two = painter(TextSpan(style: base, children: const [TextSpan(text: 'x'), TextSpan(text: '\ny', style: _hidden)]));
      final h = two.height - one.height;
      one.dispose();
      two.dispose();
      return h;
    }();
  }

  void _textBlock(MdBlock b, bool touched) {
    final from = b.tokenEnd, to = b.contentStart;
    // the named style of the paragraph, under what is picked for its words
    final named = styleFor(b, styles);
    if (named != null && !named.isEmpty) {
      for (var i = from; i < b.end && i < n; i++) {
        final c = chars[i];
        if (named.font != null) c.font ??= named.font;
        if (named.size != null) c.size ??= named.size! / documentPointSize;
        if (named.color != null) c.color ??= named.color;
      }
    }
    // the spaces before a list item's marker nest it: each one is wider
    var marker = from;
    while (marker < to && text[marker] == ' ') {
      chars[marker].letterSpacing = fontSize * 0.5;
      marker++;
    }
    switch (b.type) {
      case MdBlockType.heading:
        if (touched) {
          dim(from, to);
        } else {
          hide(from, to);
        }
        for (var i = from; i < b.end; i++) {
          chars[i]
            ..scale = headingScale(b.level)
            ..bold = true;
        }
      case MdBlockType.bullet:
        widgets[marker] = WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          // (a mark for the eye: the list is in the text that is read out, and each widget here costs every key that is pressed)
          child: ExcludeSemantics(child: Text.verbatim(b.depth.isOdd ? '◦' : '•', style: base.copyWith(fontWeight: FontWeight.bold))),
        );
      case MdBlockType.task:
        final box = text.indexOf('[', marker);
        hide(marker, box);
        hide(box + 1, box + 3);
        final toggle = actions.onToggleTask;
        widgets[box] = WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: MouseRegion(
            cursor: toggle == null ? MouseCursor.defer : SystemMouseCursors.click,
            // (a screen reader says whether it is ticked, and ticks it; the picture of the box says nothing)
            child: Semantics(
              checked: b.checked,
              onTap: toggle == null ? null : () => toggle(box),
              excludeSemantics: true,
              child: GestureDetector(
                key: ValueKey('task-${_tasks++}'),
                behavior: HitTestBehavior.opaque,
                onTap: toggle == null ? null : () => toggle(box),
                child: Padding(
                  padding: EdgeInsets.only(right: fontSize * 0.15),
                  child: Icon(b.checked ? Icons.check_box : Icons.check_box_outline_blank, size: fontSize * 1.15, color: textColor.withValues(alpha: b.checked ? 0.6 : 0.8)),
                ),
              ),
            ),
          ),
        );
        if (b.checked) {
          for (var i = to; i < b.end; i++) {
            chars[i]
              ..faint = true
              ..strike = true;
          }
        }
      case MdBlockType.caption:
        // "Figure:" is shown numbered
        if (touched) {
          dim(from, to);
        } else {
          fold(from, to, Text.verbatim(captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table')),
              key: ValueKey('live-caption-${_captions++}'), style: base.copyWith(fontWeight: FontWeight.bold, fontSize: fontSize * 0.9)),
              alignment: PlaceholderAlignment.baseline);
        }
        for (var i = to; i < b.end; i++) {
          chars[i]
            ..italic = true
            ..size ??= 0.9;
        }
      case MdBlockType.quote:
        widgets[marker] = WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: ExcludeSemantics(
            child: Container(
              width: 3,
              height: fontSize * 1.3,
              margin: EdgeInsets.only(right: fontSize * 0.4),
              color: textColor.withValues(alpha: 0.3),
            ),
          ),
        );
        for (var i = to; i < b.end; i++) {
          chars[i]
            ..faint = true
            ..italic = true;
        }
      default:
        break;
    }
    _inline(b);
    if (!b.format.isPlain) _layout(b, touched);
  }

  void _inline(MdBlock b) {
    for (final run in b.runs) {
      for (var i = run.src; i < run.src + run.text.length && i < n; i++) {
        final c = chars[i];
        if (run.bold) c.bold = true;
        if (run.italic) c.italic = true;
        if (run.strike) c.strike = true;
        if (run.highlight) c.highlight ??= _yellow;
        if (run.superscript) c.sup = true;
        if (run.subscript) c.sub = true;
        if (run.code) {
          c
            ..mono = true
            ..codeTint = true;
        }
        if (run.link != null) c.link = true;
        if (run.inserted) c.inserted = true;
        if (run.deleted) c.deleted = true;
        if (run.commented) c.commented = true;
      }
    }
    for (final m in b.markup) {
      final touched = m.kind == MdMarkupKind.pair || m.kind == MdMarkupKind.code ? touches(m.start, m.end) : inside(m.start, m.end);
      switch (m.kind) {
        case MdMarkupKind.pair || MdMarkupKind.code:
          if (touched) {
            dim(m.start, m.innerStart);
            dim(m.innerEnd, m.end);
          } else {
            hide(m.start, m.innerStart);
            hide(m.innerEnd, m.end);
          }
        case MdMarkupKind.link:
          if (touched) {
            dim(m.start, m.innerStart);
            dim(m.innerEnd, m.end);
          } else {
            final run = b.runs.firstWhere((r) => r.src == m.innerStart && r.link != null);
            fold(m.start, m.end, _link(run), alignment: PlaceholderAlignment.baseline);
          }
        case MdMarkupKind.math:
          if (touched) {
            dim(m.start, m.innerStart);
            dim(m.innerEnd, m.end);
          } else {
            fold(m.start, m.end, _math(text.substring(m.innerStart, m.innerEnd)));
          }
        case MdMarkupKind.footnote:
          if (touched) {
            dim(m.start, m.end);
          } else {
            final label = text.substring(m.start + 2, m.end - 1);
            fold(m.start, m.end, Text.verbatim('${footnotes[label] ?? '?'}',
                key: ValueKey('footnote-$label'),
                style: base.copyWith(fontSize: fontSize * 0.65, height: 1, color: Colors.blue.shade700)),
                alignment: PlaceholderAlignment.top);
          }
        case MdMarkupKind.image:
          if (touched) {
            dim(m.start, m.end);
          } else {
            final run = b.runs.firstWhere((r) => r.image != null && r.src == m.innerStart);
            fold(m.start, m.end, _image(run), alignment: PlaceholderAlignment.bottom);
          }
        case MdMarkupKind.change:
          // (the marks of a tracked change are never shown: the colours say what it is)
          hide(m.start, m.innerStart);
          hide(m.innerEnd, m.end);
        case MdMarkupKind.comment:
          if (touched) {
            dim(m.start, m.end);
          } else {
            fold(m.start, m.end, _commentMark(m, text.substring(m.innerStart, m.innerEnd)));
          }
        case MdMarkupKind.anchor:
          if (touched) {
            dim(m.start, m.end);
          } else {
            hide(m.start, m.end);
          }
        case MdMarkupKind.ref:
          if (inside(m.start, m.end)) {
            dim(m.start, m.end);
          } else {
            fold(m.start, m.end, Text.verbatim(references[m.id] ?? '?${m.id}',
                key: ValueKey('ref-${m.id}'), style: base.merge(_styleOf(chars[m.innerStart], m.innerStart)).copyWith(color: Colors.blue.shade700)),
                alignment: PlaceholderAlignment.baseline);
          }
        case MdMarkupKind.cite:
          final c = cites;
          final run = b.runs.where((r) => r.src == m.start && r.cite != null).firstOrNull;
          if (!touched && c != null && run != null) fold(m.start, m.end, _citation(run, c), alignment: PlaceholderAlignment.baseline);
      }
    }
  }

  /// A paragraph laid out by its token: while the caret is elsewhere it is shown as a block of its own (centred, justified,
  /// indented); while it is written in, the first line is moved over by a space drawn on the token's last character.
  void _layout(MdBlock b, bool touched) {
    final f = b.format;
    final indent = f.indent * indentStep(fontSize);
    final room = math.max(0.0, width - indent);
    if (!touched && b.tokenEnd > b.start) {
      final inner = spans(b.tokenEnd, b.end);
      fold(
        b.start,
        b.end,
        SizedBox(
          width: _fullWidth,
          child: Padding(
            padding: EdgeInsets.only(left: indent),
            child: RichText(
              key: ValueKey('live-paragraph-${_paragraphs++}'),
              strutStyle: StrutStyle.disabled,
              textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
              textAlign: switch (f.align) { 'center' => TextAlign.center, 'right' => TextAlign.right, 'justify' => TextAlign.justify, _ => TextAlign.left },
              text: TextSpan(style: base.copyWith(height: chars[b.start].lineHeight), children: inner),
            ),
          ),
        ),
      );
      return;
    }
    if (b.tokenEnd <= b.start) return;
    var shift = indent;
    if (f.align == 'center' || f.align == 'right') {
      final painter = TextPainter(
        text: TextSpan(style: base, children: spans(b.tokenEnd, b.end, measuring: true)),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
        strutStyle: StrutStyle.disabled,
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout(maxWidth: math.max(1, room));
      if (painter.computeLineMetrics().length <= 1) {
        final free = math.max(0.0, room - painter.width - 4);
        shift += f.align == 'center' ? free / 2 : free;
      }
      painter.dispose();
    }
    chars[b.tokenEnd - 1].letterSpacing = shift;
  }

  /// The table of contents: the headings, indented by their level.
  Widget _toc() {
    final entries = tocEntries(facts.blocks);
    final top = entries.isEmpty ? 1 : entries.map((e) => e.$1).reduce(math.min);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Contents', style: base.copyWith(fontSize: fontSize * headingScale(2), fontWeight: FontWeight.bold)),
        if (entries.isEmpty)
          Text('(The document has no headings yet.)', style: base.copyWith(color: textColor.withValues(alpha: 0.5)))
        else
          for (final (level, title, at) in entries) _tocEntry(level - top, title, at, bold: level == top),
      ],
    );
  }

  Widget _tocEntry(int depth, String title, int at, {required bool bold}) {
    final go = actions.onHeading;
    return MouseRegion(
      cursor: go == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: _PointerTap(
        key: ValueKey('toc-$at'),
        onTap: go == null ? null : () => go(at),
        child: Padding(
          padding: EdgeInsets.only(left: depth * fontSize * 1.5),
          child: Text.verbatim(title, style: base.copyWith(fontWeight: bold ? FontWeight.w600 : null)),
        ),
      ),
    );
  }

  Widget _image(MdRun run) {
    final target = run.image!;
    final w = math.min(run.imageWidth ?? _fullWidth, _fullWidth);
    Widget missing(Object? e, StackTrace? _) => Container(
          width: math.min(w, 220),
          padding: const EdgeInsets.all(8),
          color: textColor.withValues(alpha: 0.06),
          child: Text.verbatim('🖼 ${run.text.isEmpty ? target : run.text}', style: TextStyle(fontSize: fontSize * 0.8, color: textColor.withValues(alpha: 0.6))),
        );
    final file = DocumentImages.fileOf(target);
    final Widget picture = file != null
        ? Image.file(file, width: run.imageWidth == null ? null : w, fit: BoxFit.contain, errorBuilder: (c, e, st) => missing(e, st))
        : RemoteImage.isWeb(target)
            ? RemoteImage(url: target, label: run.text, width: run.imageWidth == null ? null : w, fit: BoxFit.contain, fontSize: fontSize, color: textColor)
            : missing(null, null);
    return ConstrainedBox(
      key: ValueKey('live-image-${run.src}'),
      constraints: BoxConstraints(maxWidth: _fullWidth),
      child: Semantics(label: run.text, image: true, child: picture),
    );
  }

  Widget _math(String tex, {bool display = false}) => Math.tex(
        tex,
        textStyle: base,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        onErrorFallback: (_) => Text.verbatim(display ? '\$\$$tex\$\$' : '\$$tex\$', style: base),
      );

  Widget _link(MdRun run) {
    final open = actions.onLink;
    return MouseRegion(
      cursor: open == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('link-${run.link}'),
        behavior: HitTestBehavior.opaque,
        onTap: open == null ? null : () => open(run.link!),
        child: Text.verbatim(run.text, style: base.merge(_styleOf(chars[run.src], run.src))),
      ),
    );
  }

  Widget _citation(MdRun run, CitationDocument cites) {
    final tap = actions.onCitation;
    final c = chars[run.src];
    return MouseRegion(
      cursor: tap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('citation-${run.src}'),
        behavior: HitTestBehavior.opaque,
        onTap: tap == null ? null : () => tap(run),
        child: Text.verbatim(
          cites.inText(run.cite!),
          style: base.copyWith(
            fontSize: fontSize * _sizeOf(c),
            fontWeight: c.bold || run.bold ? FontWeight.bold : null,
            fontStyle: c.italic || run.italic ? FontStyle.italic : null,
            decoration: tap == null ? null : TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
          ),
        ),
      ),
    );
  }

  Widget _commentMark(MdMarkup m, String said) {
    final tap = actions.onComment;
    return Tooltip(
      message: said,
      child: MouseRegion(
        cursor: tap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: Builder(
          builder: (context) => GestureDetector(
            key: ValueKey('comment-${_comments++}'),
            behavior: HitTestBehavior.opaque,
            onTap: tap == null ? null : () => tap(context, m),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.mode_comment, size: fontSize * 0.9, color: const Color(0xFFF9A825)),
            ),
          ),
        ),
      ),
    );
  }

  static String _settingName(String label) => switch (label) {
        'header' => tr('Header'),
        'footer' => tr('Footer'),
        'columns' => tr('Columns (in the Word file and the web page)'),
        'style-body' => tr('Style of the text'),
        _ => tr('Style of heading {n}', {'n': label.substring(7)}),
      };

  double _sizeOf(_Char c) => c.size ?? c.scale;

  Color? _colorOf(_Char c) {
    final color = c.dim
        ? textColor.withValues(alpha: 0.4)
        : c.deleted
            ? const Color(0xFFC62828)
            : c.inserted
                ? const Color(0xFF2E7D32)
                : c.color != null
                    ? Color(c.color!)
                    : c.codeColor != null
                        ? Color(c.codeColor!)
                        : c.link
                            ? Colors.blue.shade700
                            : c.faint
                                ? textColor.withValues(alpha: 0.6)
                                : null;
    // (in focus mode the paragraphs not being written are faint, whatever their colour)
    return c.blurred ? (color ?? textColor).withValues(alpha: (color ?? textColor).a * 0.35) : color;
  }

  TextStyle _styleOf(_Char c, int i) {
    if (c.hidden) return c.letterSpacing == 0 ? _hidden : _hidden.copyWith(letterSpacing: c.letterSpacing, height: c.lineHeight);
    final mark = found[i];
    final misspelled = wrong[i] && !c.dim;
    final doubtful = !misspelled && grammar[i] && !c.dim;
    final family = c.mono ? documentFonts['Mono'] : (c.font == null ? null : documentFonts[c.font] ?? c.font);
    return TextStyle(
      fontFamily: family,
      fontSize: fontSize * _sizeOf(c) * (c.mono && c.size == null ? 0.9 : 1),
      fontWeight: c.bold ? FontWeight.bold : null,
      fontStyle: c.italic ? FontStyle.italic : null,
      color: _colorOf(c),
      backgroundColor: mark != 0
          ? (mark == 2 ? const Color(0xAAFF9800) : const Color(0x66FFEB3B))
          : c.highlight != null
              ? Color(c.highlight!)
              : c.commented
                  ? const Color(0x55FFC107)
                  : c.codeTint
                  ? textColor.withValues(alpha: 0.07)
                  : null,
      decoration: misspelled || doubtful || c.underline || c.link || c.strike || c.inserted || c.deleted
          ? TextDecoration.combine([
              if (misspelled || doubtful || c.underline || c.link || c.inserted) TextDecoration.underline,
              if (c.strike || c.deleted) TextDecoration.lineThrough,
            ])
          : null,
      decorationStyle: misspelled || doubtful ? TextDecorationStyle.wavy : null,
      decorationColor: misspelled ? Colors.red : (doubtful ? Colors.blue : null),
      letterSpacing: c.letterSpacing == 0 ? null : c.letterSpacing,
      height: c.lineHeight,
    );
  }

  /// The spans of `text[from, to)`: one per stretch drawn alike, the widgets in place of their characters. [measuring] draws the
  /// widgets as their characters (for working out how wide a line is).
  List<InlineSpan> spans(int from, int to, {bool measuring = false}) {
    final out = <InlineSpan>[];
    var i = from;
    while (i < to && i < n) {
      final w = widgets[i];
      if (w != null && !measuring) {
        out.add(w);
        i++;
        continue;
      }
      final c = chars[i];
      if ((c.sup || c.sub) && !c.hidden && !measuring && text[i] != '\n') {
        out.add(WidgetSpan(
          alignment: c.sup ? PlaceholderAlignment.top : PlaceholderAlignment.bottom,
          child: Text.verbatim(text[i], style: base.merge(_styleOf(c, i)).copyWith(fontSize: fontSize * _sizeOf(c) * 0.7, height: 1)),
        ));
        i++;
        continue;
      }
      final style = _styleOf(c, i);
      var j = i + 1;
      bool sameLook(int k) => c.looksLike(chars[k]) && found[k] == found[i] && wrong[k] == wrong[i] && grammar[k] == grammar[i];
      while (j < to && j < n && (measuring || !widgets.containsKey(j)) && !(chars[j].sup || chars[j].sub) && (sameLook(j) || _styleOf(chars[j], j) == style)) {
        j++;
      }
      // (marks that are not drawn are not read out either: "hash A heading", "star star bold star star")
      out.add(TextSpan(text: text.substring(i, j), style: style, semanticsLabel: c.hidden ? '' : null));
      i = j;
    }
    return out;
  }
}

class _DashPainter extends CustomPainter {
  final Color color;
  _DashPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, size.height / 2), Offset(math.min(x + 4, size.width), size.height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

/// A box that is [lift] shorter than its child, which hangs out below it (over lines that are hidden).
class _Overhang extends SingleChildRenderObjectWidget {
  final double lift;
  const _Overhang({required this.lift, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderOverhang(lift);

  @override
  void updateRenderObject(BuildContext context, _RenderOverhang renderObject) => renderObject.lift = lift;
}

class _RenderOverhang extends RenderProxyBox {
  double _lift;
  _RenderOverhang(this._lift);

  set lift(double v) {
    if (v == _lift) return;
    _lift = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(Size(c.size.width, math.max(1, c.size.height - _lift)));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final s = child?.getDryLayout(constraints.loosen()) ?? Size.zero;
    return constraints.constrain(Size(s.width, math.max(1, s.height - _lift)));
  }
}

/// The text controller of the written document: draws it as [liveMarkdownSpan] does, and makes typing in it work like in a word
/// processor - Enter continues a list (and ends it on an empty item), a paragraph's layout goes on to the next one, Backspace at
/// the start of a list item takes its marker away, and the caret never stops inside the hidden layout of a paragraph.
class LiveMarkdownController extends RichInlineTextController {
  /// How wide the text is laid out.
  double layoutWidth = 600;

  bool _revealing = false;

  /// Whether the text is being written in (the Markdown around the caret shows).
  bool get revealing => _revealing;
  set revealing(bool v) {
    if (v == _revealing) return;
    _revealing = v;
    notifyListeners();
  }

  ValueChanged<String>? onLink;
  ValueChanged<MdRun>? onCitation;

  bool _suggesting = false;

  /// Whether changes are tracked: what is typed is marked as put in, what is deleted as taken out (until accepted or rejected).
  bool get suggesting => _suggesting;
  set suggesting(bool v) {
    if (v == _suggesting) return;
    _suggesting = v;
    notifyListeners();
  }

  bool _direct = false;

  bool _checkGrammar = true;

  bool _readingView = false;

  /// Whether the document is only read: it cannot be changed, and no Markdown shows anywhere.
  bool get readingView => _readingView;
  set readingView(bool v) {
    if (v == _readingView) return;
    _readingView = v;
    notifyListeners();
  }

  bool _focusMode = false;

  /// Whether only the paragraph being written is shown fully, the others faint.
  bool get focusMode => _focusMode;
  set focusMode(bool v) {
    if (v == _focusMode) return;
    _focusMode = v;
    notifyListeners();
  }

  /// Whether places that may be written wrong are marked (see [grammarIssues]).
  bool get checkGrammar => _checkGrammar;
  set checkGrammar(bool v) {
    if (v == _checkGrammar) return;
    _checkGrammar = v;
    notifyListeners();
  }

  String? _grammarOf;
  List<GrammarIssue> _grammar = const [];

  /// The places of the text that may be written wrong (worked out once for a text).
  List<GrammarIssue> get grammar {
    if (_grammarOf != text) {
      _grammar = grammarIssuesAfter(parsedText(this), _grammarOf, _grammar);
      _grammarOf = text;
    }
    return _grammar;
  }

  /// The formatting copied with the format painter, to put on the next selection (null: none copied): the formatting from the bar
  /// by its kind, and the Markdown (`**`, `*`, `~~`) it had.
  ({Map<AttributeType, String?> attributes, Set<String> marks})? get copiedLook => _copiedLook;
  set copiedLook(({Map<AttributeType, String?> attributes, Set<String> marks})? v) {
    _copiedLook = v;
    notifyListeners();
  }

  ({Map<AttributeType, String?> attributes, Set<String> marks})? _copiedLook;

  /// Sets [v] as it is: not a keystroke (no list is continued, no change is tracked) - for the changes the formatting bar makes.
  void setDirectly(TextEditingValue v) {
    _direct = true;
    try {
      value = v;
    } finally {
      _direct = false;
    }
  }

  @override
  void replaceRanges(List<({int start, int end, String text})> edits) {
    final was = _direct;
    _direct = true;
    try {
      super.replaceRanges(edits);
    } finally {
      _direct = was;
    }
  }

  /// Reads, changes or takes away the comment [m].
  Future<void> editComment(BuildContext context, MdMarkup m) async {
    final said = text.substring(m.innerStart, m.innerEnd);
    final now = await showCommentDialog(context, initial: said);
    if (now == null || m.end > text.length || text.substring(m.innerStart, m.innerEnd) != said) return;
    if (now.isNotEmpty) {
      replaceRanges([(start: m.innerStart, end: m.innerEnd, text: now.replaceAll('\n', ' ').replaceAll('<<}', '<< }'))]);
      return;
    }
    // taken away: the comment, and the marking of the text it was on
    final edits = <({int start, int end, String text})>[];
    final before = text.substring(0, m.start);
    if (before.endsWith('==}')) {
      final open = before.lastIndexOf('{==');
      if (open >= 0 && !before.substring(open, before.length - 3).contains('\n')) {
        edits
          ..add((start: open, end: open + 3, text: ''))
          ..add((start: m.start - 3, end: m.start, text: ''));
      }
    }
    edits.add((start: m.start, end: m.end, text: ''));
    final caret = selection;
    replaceRanges(edits);
    selection = TextSelection.collapsed(offset: math.min(caret.baseOffset, text.length).clamp(0, text.length));
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) => liveMarkdownSpan(
        context,
        this,
        style ?? const TextStyle(),
        width: layoutWidth,
        reveal: _revealing && !_readingView ? selection : null,
        actions: LiveMarkdownActions(onLink: onLink, onCitation: onCitation, onToggleTask: toggleTask, onComment: editComment),
      );

  /// Ticks the task whose box starts at [bracket], or takes the tick away.
  void toggleTask(int bracket) {
    if (bracket + 1 >= text.length || text[bracket] != '[') return;
    final done = text[bracket + 1] != ' ';
    value = TextEditingValue(text: text.replaceRange(bracket + 1, bracket + 2, done ? ' ' : 'x'), selection: selection);
  }

  @override
  set value(TextEditingValue newValue) {
    if (_direct) {
      super.value = newValue;
      return;
    }
    final blocks = newValue.text == text ? null : parsedMarkdown(this);
    super.value = typed(super.value, newValue, suggesting: _suggesting, inCode: blocks == null ? null : (line) => opensCode(text, blocks, line), known: sameFrom, knownEnd: sameEnd);
  }
}

/// Whether the line that starts at [line] of [text] is in a block of code: between two fences, or after one that was not closed yet.
bool opensCode(String text, List<MdBlock> blocks, int line) {
  for (final b in blocks) {
    if (b.start >= line) return false;
    if (b.type == MdBlockType.code) {
      if (line <= b.end) return true;
    } else if (b.end > b.start && matchFenceOpen(text.substring(b.start, b.end)) != null) {
      return true;
    }
  }
  return false;
}

final _listMarker = RegExp(r'^(\s*)(?:([-*+])\s+\[[ xX]\]\s+|([-*+])\s+|(\d+)([.)])\s+|>\s?)');

/// What typing from [old] to [now] makes of the document (see [LiveMarkdownController]); only single keystrokes are looked at,
/// except while changes are tracked ([suggesting]): then every change of a line is marked as one. The first [known] characters and the
/// last [knownEnd] are known not to have changed.
TextEditingValue typed(TextEditingValue old, TextEditingValue now, {bool suggesting = false, bool Function(int line)? inCode, int known = 0, int knownEnd = 0}) {
  final a = old.text, b = now.text;
  if (a == b) return _caretOutOfToken(now);
  if (suggesting) {
    final marked = suggested(old, now);
    if (marked != null) return marked;
  }
  // what a key can have done: only the part that can differ is compared (a document is long, and this is every key)
  bool same(String x, int from, String y, int to, int count) {
    for (var i = 0; i < count; i++) {
      if (x.codeUnitAt(from + i) != y.codeUnitAt(to + i)) return false;
    }
    return true;
  }

  // [b] is [a] with one character put in at [p]
  bool onePutIn(int p) {
    final head = math.max(0, math.min(p, known));
    final tail = math.max(0, a.length - p - knownEnd);
    return same(a, head, b, head, p - head) && same(a, p, b, p + 1, tail);
  }

  // one character typed: typographic quotes and dashes
  if (b.length == a.length + 1 && now.selection.isCollapsed) {
    final p = now.selection.baseOffset - 1;
    if (p >= 0 && p < b.length && b[p] != '\n' && onePutIn(p)) {
      final fixed = autocorrect(b, p, inCode: inCode);
      if (fixed != null) return fixed;
    }
  }
  // one line break typed
  if (b.length == a.length + 1 && now.selection.isCollapsed) {
    final p = now.selection.baseOffset - 1;
    if (p >= 0 && p < b.length && b[p] == '\n' && onePutIn(p)) {
      return _lineBreak(a, p) ?? now;
    }
  }
  // one character taken away
  if (b.length == a.length - 1 && now.selection.isCollapsed) {
    final p = now.selection.baseOffset;
    if (p >= 0 && p <= b.length) {
      final head = math.max(0, math.min(p, known));
      if (same(a, head, b, head, p - head) && same(a, p + 1, b, p, math.max(0, b.length - p - knownEnd))) {
        return _removed(a, p, backspace: old.selection.isCollapsed && old.selection.baseOffset == p + 1) ?? now;
      }
    }
  }
  return now;
}

/// [text] after the character at [p] was typed, with that typing made typographic: a straight quote turned (“ ” ‘ ’, an apostrophe
/// ’), ` -- ` an en dash. Not in code or a formula. Null: nothing to change.
TextEditingValue? autocorrect(String text, int p, {bool Function(int line)? inCode}) {
  final c = text[p];
  if (c != '"' && c != "'" && c != ' ') return null;
  final start = _lineStartOf(text, p);
  final before = text.substring(start, p);
  // in code (between backticks, or in a block of code) or in a formula: as typed
  if ('`'.allMatches(before).length.isOdd || '\$'.allMatches(before).length.isOdd) return null;
  // (in a block of code: after an opening fence, closed or not yet)
  if (inCode?.call(start) ?? RegExp(r'^\s*(```|~~~)', multiLine: true).allMatches(text.substring(0, start)).length.isOdd) return null;
  TextEditingValue put(int from, int to, String s, int caret) =>
      TextEditingValue(text: text.replaceRange(from, to, s), selection: TextSelection.collapsed(offset: caret));
  final prev = p == 0 ? '\n' : text[p - 1];
  final opens = RegExp(r'[\s(\[{“‘—–-]').hasMatch(prev);
  if (c == '"') return put(p, p + 1, opens ? '“' : '”', p + 1);
  if (c == "'") return put(p, p + 1, opens ? '‘' : '’', p + 1);
  // `a -- ` -> `a – ` (not a rule or a list marker at the start of a line)
  if (before.endsWith(' --') && before.trim().length > 2) return put(p - 2, p, '–', p);
  // a sentence starts with a capital letter: the word just finished, when it is the first of its sentence (and written all small:
  // "iPhone" stays)
  final word = RegExp(r'(?<=^|[\s}])\p{Ll}+$', unicode: true).firstMatch(before);
  if (word != null && _startsSentence(before.substring(0, word.start))) {
    final w = word.group(0)!;
    return put(start + word.start, p, w[0].toUpperCase() + w.substring(1), p + 1);
  }
  return null;
}

/// Whether a word after [before] (the start of its line) is the first of a sentence: at the start of the line, after what marks
/// the line as a heading, a list item, a quote or a footnote, or after a sentence's end. Not in settings or tables.
bool _startsSentence(String before) {
  final line = before.replaceFirst(RegExp(r'^\{[a-z]+=[^}\n]*\}'), '');
  if (line.startsWith('[') && !line.startsWith('[^') || line.trimLeft().startsWith('|')) return false;
  final rest = line.replaceFirst(RegExp(r'^\s*(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|\[\^[^\]]+\]:\s*)?'), '');
  if (rest.isEmpty) return true;
  final end = RegExp(r'(\S*[.!?])[”’"\)]?\s+$').firstMatch(rest);
  if (end == null) return false;
  final last = end.group(1)!;
  return !last.endsWith('.') || !(isAbbreviation(last) || last.endsWith('...'));
}

/// A line break typed at [p] of [text] while changes are tracked: a change it falls in is closed before it and goes on after it
/// (a change stays on one line), and a half left empty goes. Null: not in a change, the break is typed as usual.
TextEditingValue? _brokenChange(String text, int p) {
  final r = _changesAround(text, p).where((r) => p >= r.innerStart && p <= r.innerEnd).firstOrNull;
  if (r == null) return null;
  final mark = r.insert ? '++' : '--';
  final split = text.replaceRange(p, p, '$mark}{$mark');
  final broken = _lineBreak(split, p + 3) ??
      TextEditingValue(text: split.replaceRange(p + 3, p + 3, '\n'), selection: TextSelection.collapsed(offset: p + 4));
  var t = broken.text;
  var caret = broken.selection.baseOffset;
  for (final m in RegExp(r'\{\+\+\+\+\}|\{----\}').allMatches(t).toList().reversed) {
    t = t.replaceRange(m.start, m.end, '');
    if (caret > m.start) caret = math.max(m.start, caret - 6);
  }
  // (what is typed next goes on with the insertion)
  if (t.startsWith('{++', caret)) caret += 3;
  return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: caret));
}

final _changeRegion = RegExp(r'\{(\+\+|--)(.*?)(\+\+|--)\}');

/// The tracked changes (`{++...++}`, `{--...--}`) of the line [at] is on: (whether put in, start, end, where its text starts and
/// ends).
List<({bool insert, int start, int end, int innerStart, int innerEnd})> _changesAround(String text, int at) {
  final start = _lineStartOf(text, at);
  final line = text.substring(start, _lineEndOf(text, start));
  return [
    for (final m in _changeRegion.allMatches(line))
      if (m.group(1) == m.group(3))
        (insert: m.group(1) == '++', start: start + m.start, end: start + m.end, innerStart: start + m.start + 3, innerEnd: start + m.end - 3),
  ];
}

/// The change from [old] to [now] marked as a tracked change: what was put in as `{++...++}`, what was taken out kept as
/// `{--...--}`. Text put in while tracking is changed freely; deleting what is already taken out only moves the caret. Null: not a
/// change that can be marked (one across lines), it stays as it is.
TextEditingValue? suggested(TextEditingValue old, TextEditingValue now) {
  final a = old.text, b = now.text;
  // where the change is: by the caret when it says so (typing "a" after an "a" is not ambiguous then), else by the text
  int p, q;
  String ins;
  final c = now.selection.isValid && now.selection.isCollapsed ? now.selection.baseOffset : -1;
  if (b.length > a.length && c >= b.length - a.length && c <= b.length &&
      a.startsWith(b.substring(0, c - (b.length - a.length))) && b.substring(c) == a.substring(c - (b.length - a.length))) {
    p = q = c - (b.length - a.length);
    ins = b.substring(p, c);
  } else if (b.length < a.length && c >= 0 && c <= b.length && a.startsWith(b.substring(0, c)) && a.substring(c + a.length - b.length) == b.substring(c)) {
    p = c;
    q = c + a.length - b.length;
    ins = '';
  } else {
    p = 0;
    while (p < a.length && p < b.length && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    var tail = 0;
    while (tail < a.length - p && tail < b.length - p && a.codeUnitAt(a.length - 1 - tail) == b.codeUnitAt(b.length - 1 - tail)) {
      tail++;
    }
    q = a.length - tail;
    ins = b.substring(p, b.length - tail);
  }
  var del = a.substring(p, q);
  if (ins == '\n' && del.isEmpty) return _brokenChange(a, p);
  if (ins.contains('\n') || del.contains('\n')) return null;
  final backspace = old.selection.isCollapsed && old.selection.baseOffset == q && ins.isEmpty;
  TextEditingValue at(String text, int caret) => TextEditingValue(text: text, selection: TextSelection.collapsed(offset: caret));

  final regions = _changesAround(a, p);
  // a character of the hidden marks taken out: it is the one next to them that is meant
  if (ins.isEmpty && q - p == 1) {
    for (final r in regions) {
      if (p >= r.innerEnd && p < r.end) {
        // at the end of a change (Backspace): its last character
        if (r.innerEnd == r.innerStart) return at(a.replaceRange(r.start, r.end, ''), r.start);
        p = r.innerEnd - 1;
        q = r.innerEnd;
      } else if (p >= r.start && p < r.innerStart) {
        if (r.innerEnd == r.innerStart) return at(a.replaceRange(r.start, r.end, ''), r.start);
        p = r.innerStart;
        q = r.innerStart + 1;
      }
    }
    del = a.substring(p, q);
  }
  ({bool insert, int start, int end, int innerStart, int innerEnd})? inside(int from, int to) =>
      regions.where((r) => from >= r.innerStart && to <= r.innerEnd).firstOrNull;
  final within = inside(p, q);
  // in text that is itself put in: changed as it is (an insertion that is emptied goes)
  if (within != null && within.insert) {
    final text = a.replaceRange(p, q, ins);
    final emptied = within.innerEnd - within.innerStart == q - p && ins.isEmpty;
    if (emptied) return at(text.replaceRange(within.start, within.start + 6, ''), within.start);
    return at(text, p + ins.length);
  }
  // in text already taken out: nothing more to take out
  if (within != null && !within.insert && ins.isEmpty) return at(a, backspace ? p : q);
  if (del.isEmpty) {
    // put in next to an insertion: it joins it
    final joins = regions.where((r) => r.insert && (r.end == p || r.start == p)).firstOrNull;
    if (joins != null && joins.end == p) {
      return at(a.replaceRange(joins.innerEnd, joins.innerEnd, ins), joins.innerEnd + ins.length);
    }
    return at(a.replaceRange(p, p, '{++$ins++}'), p + 3 + ins.length);
  }
  if (ins.isEmpty) {
    // taken out next to what is already taken out: joins it
    if (a.startsWith('{--', q)) return at(a.replaceRange(p, q + 3, '{--$del'), backspace ? p : p + 3 + del.length);
    if (a.substring(0, p).endsWith('--}')) {
      final text = a.replaceRange(p - 3, q, '$del--}');
      return at(text, backspace ? text.lastIndexOf('{--', p - 3) : p + del.length);
    }
    return at(a.replaceRange(p, q, '{--$del--}'), backspace ? p : p + del.length + 6);
  }
  // replaced: the old taken out, the new put in
  return at(a.replaceRange(p, q, '{--$del--}{++$ins++}'), p + del.length + 9 + ins.length);
}

int _lineStartOf(String text, int at) => at <= 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;

int _lineEndOf(String text, int at) {
  final e = text.indexOf('\n', at);
  return e < 0 ? text.length : e;
}

/// A collapsed caret inside the hidden layout token at the start of a line goes to just after it.
TextEditingValue _caretOutOfToken(TextEditingValue v) {
  final s = v.selection;
  if (!s.isValid || !s.isCollapsed) return v;
  final start = _lineStartOf(v.text, s.baseOffset);
  final token = paragraphFormatOf(v.text.substring(start, _lineEndOf(v.text, start)));
  if (token == null || s.baseOffset >= start + token.$1) return v;
  return v.copyWith(selection: TextSelection.collapsed(offset: start + token.$1));
}

/// A line break typed at [p] in [a]: the new line gets the layout of the one it was split from and, in a list, the next marker;
/// on an empty list item the marker goes instead (the list ends). Null: nothing more than the line break.
TextEditingValue? _lineBreak(String a, int p) {
  final start = _lineStartOf(a, p);
  final line = a.substring(start, _lineEndOf(a, start));
  final token = paragraphFormatOf(line);
  final t = token?.$1 ?? 0;
  final tokenText = line.substring(0, t);
  // at the very start of a laid-out line: the empty line goes above it, the text keeps its layout
  if (t > 0 && p == start + t) {
    final text = a.replaceRange(start, start, '\n');
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start + 1 + t));
  }
  final rest = line.substring(t);
  final m = _listMarker.firstMatch(rest);
  var prefix = tokenText;
  if (m != null && p >= start + t + m.end) {
    if (rest.substring(m.end).trim().isEmpty && p == start + line.length) {
      // an empty item: Enter ends the list
      final text = a.replaceRange(start + t, start + line.length, '');
      return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start + t));
    }
    final indent = m.group(1)!;
    if (m.group(2) != null) {
      prefix += '$indent${m.group(2)} [ ] ';
    } else if (m.group(3) != null) {
      prefix += '$indent${m.group(3)} ';
    } else if (m.group(4) != null) {
      prefix += '$indent${int.parse(m.group(4)!) + 1}${m.group(5)} ';
    } else {
      prefix += '$indent> ';
    }
  }
  if (prefix.isEmpty) return null;
  final text = a.replaceRange(p, p, '\n$prefix');
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: p + 1 + prefix.length));
}

/// The character at [p] was taken out of [a] (with Backspace when [backspace]): taking a character of the hidden layout token
/// takes the whole layout away; a line joined to the one before loses its layout; Backspace right after a list marker takes the
/// marker away. Null: the change stays as it is.
TextEditingValue? _removed(String a, int p, {required bool backspace}) {
  final start = _lineStartOf(a, p);
  final line = a.substring(start, _lineEndOf(a, start));
  final token = paragraphFormatOf(line);
  final t = token?.$1 ?? 0;
  if (a[p] == '\n') {
    // the next line is joined to this one: its layout token would be in the middle of a line
    final next = a.substring(p + 1, _lineEndOf(a, p + 1));
    final nextToken = paragraphFormatOf(next);
    if (nextToken == null) return null;
    final text = a.replaceRange(p, p + 1 + nextToken.$1, '');
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: p));
  }
  if (p < start + t) {
    final text = a.replaceRange(start, start + t, '');
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start));
  }
  if (backspace) {
    final m = _listMarker.firstMatch(line.substring(t));
    if (m != null && p == start + t + m.end - 1) {
      final text = a.replaceRange(start + t + m.group(1)!.length, start + t + m.end, '');
      return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start + t + m.group(1)!.length));
    }
  }
  return null;
}

/// The written document shown, not written in: drawn exactly as while it is written (so that it takes the same room), with the
/// list of the sources it cites under it.
class LiveMarkdownView extends StatelessWidget {
  final RichInlineTextController controller;
  final double fontSize;
  final LiveMarkdownActions actions;
  final bool references;

  /// Only these pieces of the document, made by [liveMarkdownPieces], beginning with piece number [first]; null: all of it. For the
  /// sheets of a long document, each of which shows a part of it.
  final List<TextSpan>? pieces;
  final int first;

  /// [pieces] end before the end of the document: what comes after it is not shown.
  final bool ended;

  /// Comes to show all of the document in turns, and says so here; null: at once.
  final LivePieces? inTurn;

  const LiveMarkdownView({super.key, required this.controller, required this.fontSize, this.actions = const LiveMarkdownActions(), this.references = true, this.pieces, this.first = 0, this.ended = true, this.inTurn});

  /// How wide the text of a view [width] wide is laid out: as while it is written, with room for the caret at the end of a line.
  static double textWidth(double width) => width - liveCaretRoom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = textWidth(box.maxWidth.isFinite ? box.maxWidth : 600);
      if (inTurn != null) return _PiecesInTurn(view: this, into: inTurn!, width: width);
      final shown = pieces ?? liveMarkdownPieces(context, controller, documentTextStyle(fontSize), width: width, actions: actions);
      return _column(context, shown, width, first: first, ended: ended);
    });
  }

  Widget _column(BuildContext context, List<TextSpan> shown, double width, {required int first, required bool ended}) {
    final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < shown.length; i++)
          SizedBox(
            width: width,
            child: _ExactHeight(child: RichText(key: LivePieceKey(first + i), strutStyle: StrutStyle.disabled, textScaler: scaler, text: shown[i])),
          ),
        if (references && ended) ReferenceList(text: controller.text, fontSize: fontSize, appended: true),
      ],
    );
  }
}

/// The pieces of a document that is only read as far as they were made. Making them and laying them out for all of a long document is
/// more than a frame has, and the note opening stood still for it: a [LiveMarkdownView] that is told of this makes a few to a frame, so
/// that the first page is there at once. One list, for that view and for the sheets that show parts of it.
class LivePieces extends ChangeNotifier {
  /// Makes all of them in the first frame: for what has to know where the end of the document is at once.
  final bool atOnce;

  LivePieces({this.atOnce = false});

  /// Those made so far; while [working] after a change, the rest are those of before it.
  List<TextSpan> shown = const [];

  bool working = false;

  /// Whether all of the document was here at least once.
  bool whole = false;

  void _tell() => notifyListeners();
}

class _PiecesInTurn extends StatefulWidget {
  final LiveMarkdownView view;
  final LivePieces into;
  final double width;
  const _PiecesInTurn({required this.view, required this.into, required this.width});

  @override
  State<_PiecesInTurn> createState() => _PiecesInTurnState();
}

class _PiecesInTurnState extends State<_PiecesInTurn> {
  LivePieces get _into => widget.into;
  Iterator<TextSpan>? _rest;
  var _made = 0;

  /// How many to a frame: as many as take a few milliseconds of it, whatever this machine is.
  var _batch = 2;
  final Stopwatch _clock = Stopwatch();
  bool _stepDue = false;

  @override
  void initState() {
    super.initState();
    widget.view.controller.addListener(_begin);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _begin();
    _take(_into.atOnce ? 1 << 30 : _batch);
  }

  @override
  void didUpdateWidget(_PiecesInTurn old) {
    super.didUpdateWidget(old);
    if (!identical(old.view.controller, widget.view.controller)) {
      old.view.controller.removeListener(_begin);
      widget.view.controller.addListener(_begin);
    }
    if (old.width != widget.width) _begin();
  }

  @override
  void dispose() {
    widget.view.controller.removeListener(_begin);
    _into.working = false;
    super.dispose();
  }

  /// From the first piece again, over those there are.
  void _begin() {
    final v = widget.view;
    _rest = liveMarkdownPiecesInTurn(context, v.controller, documentTextStyle(v.fontSize), width: widget.width, actions: v.actions).iterator;
    _made = 0;
    _into.working = true;
    _stepSoon();
  }

  void _take(int count) {
    final rest = _rest;
    if (rest == null) return;
    final now = _into.shown.toList();
    for (var i = 0; i < count; i++) {
      if (!rest.moveNext()) {
        now.length = _made;
        _rest = null;
        _into
          ..working = false
          ..whole = true;
        break;
      }
      _made < now.length ? now[_made] = rest.current : now.add(rest.current);
      _made++;
    }
    _into.shown = now;
  }

  void _stepSoon() {
    if (_stepDue) return;
    _stepDue = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _stepDue = false;
      if (!mounted) return;
      final took = _clock.elapsedMicroseconds;
      _clock
        ..stop()
        ..reset();
      if (took > 0) _batch = (_batch * (took < 4000 ? 2 : (took > 12000 ? 0.5 : 1))).round().clamp(1, 64);
      _into._tell();
      if (_rest == null) return;
      _clock.start();
      setState(() => _take(_batch));
      _stepSoon();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => widget.view._column(context, _into.shown, widget.width, first: 0, ended: _into.whole);
}

/// A tap on [child], seen from the pointer itself: the finger goes down and comes up in the same place, soon. Not a gesture that has to be
/// won: where the text is read, a selection of it is under the same finger and wins every one of those.
class _PointerTap extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;
  const _PointerTap({super.key, required this.onTap, required this.child});

  @override
  State<_PointerTap> createState() => _PointerTapState();
}

class _PointerTapState extends State<_PointerTap> {
  int? _pointer;
  Offset _from = Offset.zero;
  Duration _at = Duration.zero;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          _pointer = e.pointer;
          _from = e.position;
          _at = e.timeStamp;
        },
        onPointerUp: (e) {
          final was = _pointer == e.pointer;
          _pointer = null;
          // (after what else the tap does, which the text being written does when the finger is up: the caret goes where it is)
          if (was && (e.position - _from).distance <= kTouchSlop && e.timeStamp - _at < const Duration(milliseconds: 600)) scheduleMicrotask(() => widget.onTap?.call());
        },
        onPointerCancel: (_) => _pointer = null,
        child: widget.child,
      );
}

/// As tall as the lines of the paragraph in it are. A paragraph makes itself a whole number of pixels tall, which pieces of a text would
/// add up: the text would slowly move away from where it is while it is written, and pages would end elsewhere.
class _ExactHeight extends SingleChildRenderObjectWidget {
  const _ExactHeight({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderExactHeight();
}

class RenderExactHeight extends RenderProxyBox {
  @override
  void performLayout() {
    final text = child! as RenderParagraph;
    text.layout(constraints, parentUsesSize: true);
    final end = text.text.toPlainText(includeSemanticsLabels: false).length;
    final last = end == 0 ? const <TextBox>[] : text.getBoxesForSelection(TextSelection(baseOffset: end - 1, extentOffset: end), boxHeightStyle: BoxHeightStyle.max);
    size = constraints.constrain(Size(text.size.width, last.isEmpty ? text.size.height : last.last.bottom));
  }
}

/// Names a piece of the document in a [LiveMarkdownView] (by its place in the list of [liveMarkdownPieces]).
class LivePieceKey extends ValueKey<int> {
  const LivePieceKey(super.value);
}

/// Which of the pieces that begin at [tops] (down from the top of the document) lie between [from] and [to], and where the first one
/// begins: `[first, end)`.
({int first, int end, double top}) piecesBetween(List<double> tops, double from, double to) {
  var first = 0;
  while (first + 1 < tops.length && tops[first + 1] <= from) {
    first++;
  }
  var end = first + 1;
  while (end < tops.length && tops[end] < to) {
    end++;
  }
  return (first: first, end: end, top: tops[first]);
}

/// The room kept at the end of a line for the caret.
const double liveCaretRoom = 3;
