import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../models/rich_text.dart';
import '../style/tool_columns.dart';
import 'document_dialogs.dart';
import 'document_templates.dart';
import 'live_markdown.dart';
import 'markdown_formatting.dart';
import 'markdown_parser.dart';
import 'markdown_table.dart';

/// How many words there are, at most a few times a second while the text changes: the bar is not built again for it.
class _WordCount extends StatefulWidget {
  final RichInlineTextController controller;
  final bool vertical;
  const _WordCount({required this.controller, required this.vertical});

  @override
  State<_WordCount> createState() => _WordCountState();
}

class _WordCountState extends State<_WordCount> {
  Timer? _due;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() => _due ??= Timer(const Duration(milliseconds: 300), () {
        _due = null;
        if (mounted) setState(() {});
      });

  @override
  void dispose() {
    _due?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final text = controller.text;
    final sel = controller.selection.isValid ? controller.selection : TextSelection.collapsed(offset: text.length);
    final words = wordCount(text, blocks: parsedMarkdown(controller));
    return Text.verbatim(
      sel.isCollapsed ? trCount(words, '1 word', '{n} words') : tr('{n} of {m} words', {'n': wordCount(text.substring(sel.start, sel.end)), 'm': words}),
      key: const ValueKey('doc-word-count'),
      textAlign: widget.vertical ? TextAlign.center : null,
      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// A [DocumentToolbar] that is built again only when what it shows changes, which is looked at after the frame of a change. A key that is
/// pressed then pays for the text and not for the bar.
class FollowingToolbar extends StatefulWidget {
  final RichInlineTextController controller;
  final DocumentToolbar Function(BuildContext context) builder;
  const FollowingToolbar({super.key, required this.controller, required this.builder});

  @override
  State<FollowingToolbar> createState() => _FollowingToolbarState();
}

class _FollowingToolbarState extends State<FollowingToolbar> {
  List<Object?>? _shows;
  bool _due = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_due) return;
    _due = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _due = false;
      if (!mounted) return;
      final now = widget.builder(context).shows;
      if (!listEquals(now, _shows)) setState(() {});
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bar = widget.builder(context);
    _shows = bar.shows;
    return bar;
  }
}

/// The formatting bar of the written document: the style of the paragraph, the font and its size, bold and the like, colours,
/// how the paragraph is laid out, lists, and what can be put in. Simple formatting is written as Markdown into the text (bold is
/// `**`), the rest is kept beside the text (fonts, sizes, colours) or at the start of the paragraph (its layout).
class DocumentToolbar extends StatelessWidget {
  final RichInlineTextController controller;
  final VoidCallback? onSolve;
  final VoidCallback? onTable;
  final VoidCallback? onCite;
  final VoidCallback? onBibliography;

  /// Puts a picture into the text (asks for it).
  final VoidCallback? onPicture;

  /// Reads a Word document into the document (asks for it).
  final VoidCallback? onImportWord;

  /// Stands at the right of the page, in columns that keep each group of tools whole with the wide tools on lines across them (see
  /// [ToolColumns]), in place of lying along the bottom.
  final bool vertical;

  const DocumentToolbar(
      {super.key,
      required this.controller,
      this.onSolve,
      this.onTable,
      this.onCite,
      this.onBibliography,
      this.onPicture,
      this.onImportWord,
      this.vertical = false});

  static const _sizes = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48, 72];

  /// The colours offered for text, and for highlighting.
  static const textColors = [
    Color(0xFF000000), Color(0xFF616161), Color(0xFFC62828), Color(0xFFE65100), Color(0xFF2E7D32),
    Color(0xFF1565C0), Color(0xFF6A1B9A), Color(0xFFAD1457),
  ];
  static const highlightColors = [Color(0xFFFFF176), Color(0xFFA5D6A7), Color(0xFF90CAF9), Color(0xFFF48FB1), Color(0xFFFFCC80)];

  static const _styles = <(String, LineStyle?)>[
    ('Normal text', null),
    ('Heading 1', LineStyle.heading1),
    ('Heading 2', LineStyle.heading2),
    ('Heading 3', LineStyle.heading3),
    ('Heading 4', LineStyle.heading4),
    ('Heading 5', LineStyle.heading5),
    ('Heading 6', LineStyle.heading6),
    ('Quote', LineStyle.quote),
  ];

  TextSelection get _sel => controller.selection.isValid ? controller.selection : TextSelection.collapsed(offset: controller.text.length);

  /// Makes a change of the bar's (directly: it is not typing, so it is not a tracked change).
  void _edit(TextEditingValue Function(TextEditingValue) change) => _set(change(controller.value));

  void _set(TextEditingValue v) {
    final c = controller;
    c is LiveMarkdownController ? c.setDirectly(v) : c.value = v;
  }

  void _decide({required bool accept, required bool all}) {
    final edits = decideChanges(controller.text, accept: accept, only: all ? null : _sel);
    if (edits.isEmpty) return;
    final caret = _sel.start;
    var moved = caret;
    for (final e in edits) {
      if (e.end <= caret) moved += e.text.length - (e.end - e.start);
    }
    controller.replaceRanges(edits);
    controller.selection = TextSelection.collapsed(offset: moved.clamp(0, controller.text.length));
  }

  /// The Markdown run the caret is in (or the selection starts in).
  MdRun? _runAt(List<MdBlock> blocks) {
    final s = _sel;
    final at = s.isCollapsed && s.start > 0 ? s.start - 1 : s.start;
    if (blocks.isEmpty) return null;
    final b = blocks[blockAt(blocks, at)];
    if (at < b.start || at > b.end) return null;
    for (final r in b.runs) {
      if (at >= r.src && at < r.src + r.text.length) return r;
    }
    return null;
  }

  /// All that the bar shows (but for how many words there are, see [_WordCount]): built again only when this changes, it costs a key nothing.
  List<Object?> get shows {
    final text = controller.text;
    final sel = _sel;
    final run = _runAt(parsedMarkdown(controller));
    final c = controller;
    return [
      sel.isCollapsed,
      lineStyleAt(text, sel.start),
      paragraphFormatAt(text, sel.start).toString(),
      tableAt(text, sel.start) != null,
      run?.bold,
      run?.italic,
      run?.strike,
      run?.superscript,
      run?.subscript,
      run?.highlight,
      run?.code,
      for (final t in AttributeType.values) (sel.isCollapsed ? c.attributeAt(t, sel.start) != null : c.hasAttribute(t, sel.start, sel.end)),
      for (final t in AttributeType.values) c.attributeAt(t, sel.isCollapsed ? sel.start : sel.start + 1)?.value,
      if (c is LiveMarkdownController) ...[c.copiedLook != null, c.suggesting, c.readingView, c.focusMode, c.checkGrammar],
    ];
  }

  /// The Markdown pair written with [mark] (`==`, `^`, `~`) the selection is in, else null.
  MdMarkup? _pairAround(List<MdBlock> blocks, String mark) {
    final s = _sel, text = controller.text;
    for (final b in blocks) {
      for (final m in b.markup) {
        if (m.kind == MdMarkupKind.pair && m.innerStart - m.start == mark.length && text.startsWith(mark, m.start) &&
            m.innerStart <= s.start && s.end <= m.innerEnd) {
          return m;
        }
      }
    }
    return null;
  }

  /// Takes the marks of [m] away, the selection kept on the same text.
  void _unwrap(MdMarkup m) {
    final s = _sel, k = m.innerStart - m.start;
    int moved(int p) => p <= m.start ? p : (p >= m.end ? p - 2 * k : (p - k).clamp(m.start, m.innerEnd - k));
    _set(TextEditingValue(
      text: controller.text.replaceRange(m.innerEnd, m.end, '').replaceRange(m.start, m.innerStart, ''),
      selection: TextSelection(baseOffset: moved(s.baseOffset), extentOffset: moved(s.extentOffset)),
    ));
  }

  /// Superscript or subscript, written in Markdown (`^raised^`, `~lowered~`) where it can be: not over spaces, which those marks
  /// cannot hold; then as a look of the text. The other of the two goes.
  void _script(List<MdBlock> blocks, {required bool raised}) {
    final (mark, other) = raised ? ('^', '~') : ('~', '^');
    final (type, otherType) = raised ? (AttributeType.superscript, AttributeType.subscript) : (AttributeType.subscript, AttributeType.superscript);
    bool has(AttributeType t) => _sel.isCollapsed ? controller.attributeAt(t, _sel.start) != null : controller.hasAttribute(t, _sel.start, _sel.end);
    final mine = _pairAround(blocks, mark);
    if (_pairAround(blocks, other) case final o?) _unwrap(o);
    if (has(otherType)) controller.toggleAttribute(otherType);
    if (mine != null) {
      _unwrap(_pairAround(parseMarkdown(controller.text), mark) ?? mine);
    } else if (has(type) || controller.text.substring(_sel.start, _sel.end).trim().contains(RegExp(r'\s'))) {
      controller.toggleAttribute(type);
    } else {
      _edit((v) => toggleInline(v, mark));
    }
  }

  /// A highlight: the usual yellow as Markdown (`==marked==`), another colour as a look of the text.
  void _highlight(List<MdBlock> blocks, Color? c) {
    final yellow = c != null && c.toARGB32() == highlightColors.first.toARGB32();
    final marked = _pairAround(blocks, '==');
    if (yellow && marked != null) return controller.setAttribute(AttributeType.highlight, null);
    if (marked != null) _unwrap(marked);
    controller.setAttribute(AttributeType.highlight, yellow || c == null || c.a == 0 ? null : TextSpanAttribute.hexOf(c));
    if (yellow) _edit((v) => toggleInline(v, '=='));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = controller.text;
    final sel = _sel;
    final blocks = parsedMarkdown(controller);
    final run = _runAt(blocks);
    final lineStyle = lineStyleAt(text, sel.start);
    final format = paragraphFormatAt(text, sel.start);
    bool has(AttributeType t) => sel.isCollapsed ? controller.attributeAt(t, sel.start) != null : controller.hasAttribute(t, sel.start, sel.end);
    final font = controller.attributeAt(AttributeType.font, sel.isCollapsed ? sel.start : sel.start + 1)?.value;
    final size = controller.attributeAt(AttributeType.size, sel.isCollapsed ? sel.start : sel.start + 1)?.value;

    Widget button(IconData icon, String tooltip, VoidCallback? onPressed, {bool active = false, Key? key}) => IconButton(
          key: key,
          icon: Icon(icon, size: 20),
          tooltip: tr(tooltip),
          visualDensity: VisualDensity.compact,
          isSelected: active,
          style: active ? IconButton.styleFrom(backgroundColor: scheme.secondaryContainer, foregroundColor: scheme.onSecondaryContainer) : null,
          onPressed: onPressed,
        );
    Widget menu<T>({required Key key, required String tooltip, required Widget label, required List<PopupMenuEntry<T>> items, required ValueChanged<T> onSelected, bool line = false}) =>
        PopupMenuButton<T>(
          key: key,
          tooltip: tr(tooltip),
          onSelected: onSelected,
          itemBuilder: (_) => items,
          child: Padding(
            padding: line ? const EdgeInsets.fromLTRB(6, 6, 0, 6) : const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Row(mainAxisSize: line ? MainAxisSize.max : MainAxisSize.min, children: [line ? Expanded(child: label) : label, Icon(Icons.arrow_drop_down, size: line ? 16 : 18)]),
          ),
        );
    Widget swatches(List<Color> colors, AttributeType type, String noneLabel, IconData icon, String tooltip, Key key, {bool marked = false, ValueChanged<Color?>? onSelected}) =>
        PopupMenuButton<Color?>(
          key: key,
          tooltip: tr(tooltip),
          icon: Icon(icon,
              size: 20,
              color: has(type)
                  ? Color(controller.attributeAt(type, sel.isCollapsed ? sel.start : sel.start + 1)?.colorValue ?? 0xFFFFF176)
                  : (marked ? const Color(0xFFFFF176) : null)),
          onSelected: onSelected ?? (c) => controller.setAttribute(type, c == null || c.a == 0 ? null : TextSpanAttribute.hexOf(c)),
          itemBuilder: (_) => [
            PopupMenuItem<Color?>(value: const Color(0x00000000), child: Text(noneLabel)),
            for (final c in colors)
              PopupMenuItem<Color?>(
                value: c,
                child: Row(children: [
                  Container(width: 18, height: 18, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3), border: Border.all(color: Colors.black26))),
                  const SizedBox(width: 10),
                  Text.verbatim(TextSpanAttribute.hexOf(c)),
                ]),
              ),
          ],
        );
    final divider = vertical
        ? const ToolGroupDivider(width: 36, height: 12)
        : const SizedBox(height: 24, child: VerticalDivider(width: 16));
    final styleName = _styles.firstWhere((s) => s.$2 == lineStyle, orElse: () => _styles.first).$1;
    // (at the side these take a line across the bar, as wide as it is)
    Widget named(double width, Widget name) => vertical ? name : SizedBox(width: width, child: name);
    final nameSize = vertical ? 12.0 : 13.0;

    final styleMenu = menu<LineStyle?>(
        key: const ValueKey('doc-style'),
        tooltip: 'Paragraph style',
        line: vertical,
        label: named(92, Text(styleName, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: nameSize))),
        items: [
          for (final (label, style) in _styles)
            PopupMenuItem(
              key: ValueKey('doc-style-${style?.name ?? 'normal'}'),
              value: style,
              child: Text(label,
                  style: TextStyle(
                    fontSize: style == null || style == LineStyle.quote ? 14 : 14 * headingScale(style.index < 3 ? style.index + 1 : style.index - 1).clamp(0.9, 1.4),
                    fontWeight: style == null || style == LineStyle.quote ? null : FontWeight.bold,
                    fontStyle: style == LineStyle.quote ? FontStyle.italic : null,
                  )),
            ),
        ],
        onSelected: (style) => _edit((v) => setLineStyle(v, style)),
      );
    final stylesButton = button(Icons.style_outlined, 'Styles of this document', () async {
        final now = documentStyles(parseMarkdown(controller.text));
        final styles = await showStylesDialog(context, now);
        if (styles == null) return;
        var v = controller.value;
        // (a new setting goes on top, so the last first: they read body, h1, h2...)
        for (final (key, _) in styleNames.reversed) {
          v = setDocumentSetting(v, 'style-$key', styles[key]?.toString() ?? '');
        }
        _set(v);
      }, key: const ValueKey('doc-styles'));
    final fontMenu = menu<String>(
        key: const ValueKey('doc-font'),
        tooltip: 'Font',
        line: vertical,
        label: named(74, Text.verbatim(font ?? tr('Default'), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: nameSize, fontFamily: documentFonts[font]))),
        items: [
          PopupMenuItem(value: '', child: Text('Default')),
          for (final f in documentFonts.keys)
            PopupMenuItem(key: ValueKey('doc-font-$f'), value: f, child: Text.verbatim(f, style: TextStyle(fontFamily: documentFonts[f]))),
        ],
        onSelected: (f) => controller.setAttribute(AttributeType.font, f.isEmpty ? null : f),
      );
    final sizeMenu = menu<int>(
        key: const ValueKey('doc-size'),
        tooltip: 'Font size',
        line: vertical,
        label: named(22, Text.verbatim(size ?? '${documentPointSize.toInt()}', style: TextStyle(fontSize: nameSize))),
        items: [
          for (final s in _sizes) PopupMenuItem(key: ValueKey('doc-size-$s'), value: s, child: Text.verbatim('$s')),
        ],
        onSelected: (s) => controller.setAttribute(AttributeType.size, s == documentPointSize ? null : '$s'),
      );
    final count = Padding(
      padding: EdgeInsets.symmetric(horizontal: vertical ? 2 : 8, vertical: vertical ? 2 : 0),
      child: _WordCount(controller: controller, vertical: vertical),
    );

    final tools = <Widget>[
      if (!vertical) ...[styleMenu, stylesButton, fontMenu, sizeMenu, divider],
      button(Icons.format_bold, 'Bold', () => _edit((v) => toggleInline(v, '**')), active: run?.bold ?? false),
      button(Icons.format_italic, 'Italic', () => _edit((v) => toggleInline(v, '*')), active: run?.italic ?? false),
      button(Icons.format_underlined, 'Underline', () => controller.toggleAttribute(AttributeType.underline),
          active: has(AttributeType.underline), key: const ValueKey('doc-underline')),
      button(Icons.format_strikethrough, 'Strikethrough', () => _edit((v) => toggleInline(v, '~~')), active: run?.strike ?? false),
      button(Icons.superscript, 'Superscript', () => _script(blocks, raised: true),
          active: has(AttributeType.superscript) || (run?.superscript ?? false), key: const ValueKey('doc-superscript')),
      button(Icons.subscript, 'Subscript', () => _script(blocks, raised: false),
          active: has(AttributeType.subscript) || (run?.subscript ?? false), key: const ValueKey('doc-subscript')),
      swatches(textColors, AttributeType.color, 'Automatic', Icons.format_color_text, 'Text colour', const ValueKey('doc-color')),
      swatches(highlightColors, AttributeType.highlight, 'No highlight', Icons.border_color, 'Highlight', const ValueKey('doc-highlight'),
          marked: run?.highlight ?? false, onSelected: (c) => _highlight(blocks, c)),
      button(Icons.code, 'Code', () => _edit((v) => toggleInline(v, '`')), active: run?.code ?? false),
      if (controller is LiveMarkdownController)
        button(Icons.format_paint_outlined, 'Copy formatting, then select text and press again to apply it',
            () => _paint(run), active: (controller as LiveMarkdownController).copiedLook != null, key: const ValueKey('doc-painter')),
      button(Icons.format_clear, 'Clear formatting', () {
        _edit(clearInlineMarkdown);
        controller.clearAttributes();
      }, key: const ValueKey('doc-clear')),
      divider,
      for (final (align, icon, label) in const [
        ('left', Icons.format_align_left, 'Align left'),
        ('center', Icons.format_align_center, 'Centre'),
        ('right', Icons.format_align_right, 'Align right'),
        ('justify', Icons.format_align_justify, 'Justify'),
      ])
        button(icon, label, () => _edit((v) => changeParagraphFormat(v, (f) => f.copyWith(align: align))),
            active: format.align == align, key: ValueKey('doc-align-$align')),
      button(Icons.format_indent_decrease, 'Decrease indent', format.indent == 0 && lineStyle == null ? null : () => _indent(false),
          key: const ValueKey('doc-outdent')),
      button(Icons.format_indent_increase, 'Increase indent', () => _indent(true), key: const ValueKey('doc-indent')),
      menu<double>(
        key: const ValueKey('doc-spacing'),
        tooltip: 'Line spacing',
        label: const Icon(Icons.format_line_spacing, size: 20),
        items: [
          for (final s in const [1.0, 1.15, 1.5, 2.0])
            CheckedPopupMenuItem(key: ValueKey('doc-spacing-$s'), value: s, checked: format.spacing == s, child: Text.verbatim('$s')),
        ],
        onSelected: (s) => _edit((v) => changeParagraphFormat(v, (f) => f.copyWith(spacing: s))),
      ),
      divider,
      button(Icons.format_list_bulleted, 'Bulleted list', () => _edit((v) => toggleLineStyle(v, LineStyle.bullet)), active: lineStyle == LineStyle.bullet),
      button(Icons.format_list_numbered, 'Numbered list', () => _edit((v) => toggleLineStyle(v, LineStyle.numbered)), active: lineStyle == LineStyle.numbered),
      button(Icons.checklist, 'Checklist', () => _edit((v) => toggleLineStyle(v, LineStyle.task)),
          active: lineStyle == LineStyle.task, key: const ValueKey('doc-checklist')),
      button(Icons.horizontal_rule, 'Horizontal line', () => _edit(insertRule), key: const ValueKey('doc-rule')),
      PopupMenuButton<String>(
        key: const ValueKey('doc-insert'),
        tooltip: tr('Insert'),
        icon: const Icon(Icons.add_box_outlined, size: 20),
        onSelected: (what) => _insert(context, what),
        itemBuilder: (_) => [
          if (onPicture != null)
            PopupMenuItem(key: const ValueKey('doc-insert-picture'), value: 'picture', child: _item(Icons.image_outlined, 'Picture...')),
          PopupMenuItem(key: const ValueKey('doc-insert-footnote'), value: 'footnote', child: _item(Icons.notes, 'Footnote')),
          PopupMenuItem(key: const ValueKey('doc-insert-toc'), value: 'toc', child: _item(Icons.toc, 'Table of contents')),
          PopupMenuItem(key: const ValueKey('doc-insert-caption'), value: 'caption', child: _item(Icons.short_text, 'Caption')),
          PopupMenuItem(key: const ValueKey('doc-insert-ref'), value: 'ref', child: _item(Icons.link, 'Cross-reference...')),
          PopupMenuItem(key: const ValueKey('doc-insert-pagebreak'), value: 'pagebreak', child: _item(Icons.insert_page_break_outlined, 'Page break')),
          PopupMenuItem(key: const ValueKey('doc-insert-symbol'), value: 'symbol', child: _item(Icons.emoji_symbols, 'Special character...')),
          PopupMenuItem(key: const ValueKey('doc-insert-edges'), value: 'edges', child: _item(Icons.vertical_split_outlined, 'Header and footer...')),
          PopupMenuItem(key: const ValueKey('doc-insert-columns'), value: 'columns', child: _item(Icons.view_column_outlined, 'Columns...')),
          PopupMenuItem(key: const ValueKey('doc-insert-template'), value: 'template', child: _item(Icons.dashboard_customize_outlined, 'Template...')),
          if (onImportWord != null)
            PopupMenuItem(key: const ValueKey('doc-insert-word'), value: 'word', child: _item(Icons.description_outlined, 'Open a file (Word, web page, Markdown, text, PDF)...')),
        ],
      ),
      if (onTable != null) button(Icons.table_chart_outlined, 'Insert a table', onTable, key: const ValueKey('table-in-text')),
      if (tableAt(text, sel.start) != null)
        PopupMenuButton<TableAction>(
          key: const ValueKey('doc-table'),
          tooltip: tr('Change the table'),
          icon: Icon(Icons.table_view, size: 20, color: scheme.primary),
          onSelected: (a) {
            final changed = editTable(controller.value, a);
            if (changed != null) _set(changed);
          },
          itemBuilder: (_) => [
            for (final (action, icon, label) in const [
              (TableAction.rowAbove, Icons.arrow_upward, 'Add a row above'),
              (TableAction.rowBelow, Icons.arrow_downward, 'Add a row below'),
              (TableAction.deleteRow, Icons.playlist_remove, 'Delete this row'),
              (TableAction.columnLeft, Icons.arrow_back, 'Add a column to the left'),
              (TableAction.columnRight, Icons.arrow_forward, 'Add a column to the right'),
              (TableAction.deleteColumn, Icons.remove_road_outlined, 'Delete this column'),
              (TableAction.alignLeft, Icons.format_align_left, 'Align the column left'),
              (TableAction.alignCenter, Icons.format_align_center, 'Centre the column'),
              (TableAction.alignRight, Icons.format_align_right, 'Align the column right'),
            ])
              PopupMenuItem(key: ValueKey('doc-table-${action.name}'), value: action, child: _item(icon, label)),
          ],
        ),
      if (onCite != null) button(Icons.format_quote, 'Cite a source', onCite, key: const ValueKey('cite-in-text')),
      if (onBibliography != null) button(Icons.menu_book_outlined, 'Insert the list of sources', onBibliography, key: const ValueKey('bibliography-in-text')),
      if (onSolve != null) ...[
        divider,
        button(Icons.functions, 'Solve, differentiate or integrate', onSolve, key: const ValueKey('solve-in-text')),
      ],
      divider,
      if (controller is LiveMarkdownController)
        button(Icons.track_changes, 'Track changes', () {
          final c = controller as LiveMarkdownController;
          c.suggesting = !c.suggesting;
        }, active: (controller as LiveMarkdownController).suggesting, key: const ValueKey('doc-track')),
      PopupMenuButton<String>(
        key: const ValueKey('doc-changes'),
        tooltip: tr('Tracked changes'),
        enabled: hasTrackedChanges(text),
        icon: Icon(Icons.rule, size: 20, color: hasTrackedChanges(text) ? null : scheme.onSurface.withValues(alpha: 0.38)),
        onSelected: (what) => _decide(accept: what.startsWith('accept'), all: what.endsWith('all')),
        itemBuilder: (_) => [
          PopupMenuItem(key: const ValueKey('doc-accept-here'), value: 'accept', child: _item(Icons.check, 'Accept this change')),
          PopupMenuItem(key: const ValueKey('doc-reject-here'), value: 'reject', child: _item(Icons.close, 'Reject this change')),
          PopupMenuItem(key: const ValueKey('doc-accept-all'), value: 'accept-all', child: _item(Icons.done_all, 'Accept all changes')),
          PopupMenuItem(key: const ValueKey('doc-reject-all'), value: 'reject-all', child: _item(Icons.remove_done, 'Reject all changes')),
        ],
      ),
      if (controller is LiveMarkdownController)
        PopupMenuButton<String>(
          key: const ValueKey('doc-view'),
          tooltip: tr('View'),
          icon: const Icon(Icons.visibility_outlined, size: 20),
          onSelected: (what) {
            final c = controller as LiveMarkdownController;
            switch (what) {
              case 'grammar':
                c.checkGrammar = !c.checkGrammar;
              case 'focus':
                c.focusMode = !c.focusMode;
              case 'reading':
                c.readingView = !c.readingView;
            }
          },
          itemBuilder: (_) {
            final c = controller as LiveMarkdownController;
            return [
              CheckedPopupMenuItem(key: const ValueKey('doc-grammar'), value: 'grammar', checked: c.checkGrammar, child: Text('Check grammar')),
              CheckedPopupMenuItem(key: const ValueKey('doc-focus'), value: 'focus', checked: c.focusMode, child: Text('Focus on the paragraph being written')),
              CheckedPopupMenuItem(key: const ValueKey('doc-reading'), value: 'reading', checked: c.readingView, child: Text('Reading view')),
            ];
          },
        ),
      button(Icons.add_comment_outlined, 'Comment', () async {
        final said = await showCommentDialog(context);
        if (said != null && said.isNotEmpty) _edit((v) => addComment(v, said));
      }, key: const ValueKey('doc-comment')),
      if (!vertical) ...[divider, count],
    ];
    const lineDivider = Divider(height: 12, indent: 8, endIndent: 8);

    // taps must not take the focus away from the text being written
    return ExcludeFocus(
      child: Material(
        elevation: 6,
        color: scheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: vertical ? 8 : 0),
              child: vertical
                  ? ToolColumns(
                      lineWidth: 96,
                      top: [styleMenu, fontMenu, Row(children: [Expanded(child: sizeMenu), stylesButton]), lineDivider],
                      bottom: [lineDivider, count],
                      children: tools,
                    )
                  : Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: tools),
          ),
        ),
      ),
    );
  }

  static Widget _item(IconData icon, String label) =>
      Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Flexible(child: Text(label, overflow: TextOverflow.ellipsis))]);

  Future<void> _insert(BuildContext context, String what) async {
    switch (what) {
      case 'picture':
        onPicture?.call();
      case 'word':
        onImportWord?.call();
      case 'footnote':
        _edit(insertFootnote);
      case 'toc':
        _edit((v) => insertBlockLine(v, '[toc]'));
      case 'pagebreak':
        _edit((v) => insertBlockLine(v, r'\pagebreak'));
      case 'template':
        final markdown = await showTemplatePicker(context);
        if (markdown == null) return;
        // an empty document becomes the template; else it goes after what is there
        final now = controller.text;
        final text = now.trim().isEmpty ? markdown : '${now.trimRight()}\n\n$markdown';
        _set(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: now.trim().isEmpty ? 0 : now.trimRight().length + 2)));
      case 'caption':
        // under the picture or table the caret is at: a figure's caption, or a table's
        final inTable = tableAt(controller.text, _sel.start) != null;
        final v = controller.value;
        final lineEnd = v.text.indexOf('\n', _sel.end);
        final end = lineEnd < 0 ? v.text.length : lineEnd;
        // (the word in the language in use: the caption is read in English and German)
        final put = '\n${inTable ? tr('Table') : tr('Figure')}: ';
        if (inTable) {
          final t = tableAt(controller.text, _sel.start)!;
          _set(TextEditingValue(text: v.text.replaceRange(t.end, t.end, put), selection: TextSelection.collapsed(offset: t.end + put.length)));
        } else {
          _set(TextEditingValue(text: v.text.replaceRange(end, end, put), selection: TextSelection.collapsed(offset: end + put.length)));
        }
      case 'ref':
        final targets = referenceTargets(controller.text, figure: tr('Figure'), table: tr('Table'));
        final picked = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Refer to'),
            children: targets.isEmpty
                ? [Padding(padding: const EdgeInsets.all(16), child: Text('There are no headings or captions to refer to yet.'))]
                : [
                    for (final (start, label, _) in targets)
                      SimpleDialogOption(key: ValueKey('ref-target-$start'), onPressed: () => Navigator.pop(context, start), child: Text.verbatim(label)),
                  ],
          ),
        );
        if (picked != null) _edit((v) => insertCrossReference(v, picked));
      case 'columns':
        final now = int.tryParse(documentSettings(parseMarkdown(controller.text))['columns']?.trim() ?? '') ?? 1;
        final picked = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Columns'),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text('The text flows in columns in the exported Word file and web page.', style: Theme.of(context).textTheme.bodySmall),
              ),
              for (final n in const [1, 2, 3])
                SimpleDialogOption(
                  key: ValueKey('columns-$n'),
                  onPressed: () => Navigator.pop(context, n),
                  child: Row(children: [Icon(n == now ? Icons.radio_button_checked : Icons.radio_button_off, size: 18), const SizedBox(width: 12), Text(trCount(n, '1 column', '{n} columns'))]),
                ),
            ],
          ),
        );
        if (picked != null) _edit((v) => setDocumentSetting(v, 'columns', picked == 1 ? '' : '$picked'));
      case 'symbol':
        final c = await showSymbolPicker(context);
        if (c != null) _edit((v) => insertText(v, c));
      case 'edges':
        final now = documentSettings(parseMarkdown(controller.text));
        final got = await showHeaderFooterDialog(context, header: now['header'] ?? '', footer: now['footer'] ?? '');
        if (got == null) return;
        _edit((v) => setDocumentSetting(setDocumentSetting(v, 'header', got.$1), 'footer', got.$2));
    }
  }

  static const _painted = [
    AttributeType.font,
    AttributeType.size,
    AttributeType.color,
    AttributeType.highlight,
    AttributeType.underline,
    AttributeType.superscript,
    AttributeType.subscript,
  ];

  /// The format painter: copies the formatting at the caret, or puts the copied one on the selection (with nothing selected, a
  /// copied one is let go).
  void _paint(MdRun? run) {
    final c = controller as LiveMarkdownController;
    final sel = _sel;
    final look = c.copiedLook;
    if (look == null) {
      final at = sel.isCollapsed ? sel.start : sel.start + 1;
      c.copiedLook = (
        attributes: {for (final t in _painted) t: c.attributeAt(t, at)?.value ?? (c.attributeAt(t, at) != null ? '' : null)},
        marks: {if (run?.bold ?? false) '**', if (run?.italic ?? false) '*', if (run?.strike ?? false) '~~'},
      );
      return;
    }
    c.copiedLook = null;
    if (sel.isCollapsed) return;
    for (final e in look.attributes.entries) {
      c.setAttribute(e.key, e.value);
    }
    // the Markdown: put on what the copied text had, taken off what it had not
    for (final mark in const ['**', '*', '~~']) {
      final r = _runAt(parseMarkdown(c.text));
      final has = switch (mark) { '**' => r?.bold ?? false, '*' => r?.italic ?? false, _ => r?.strike ?? false };
      if (has != look.marks.contains(mark)) _edit((v) => toggleInline(v, mark));
    }
  }

  /// A list item goes one step deeper or out; any other paragraph is moved in or out as a whole.
  void _indent(bool deeper) {
    final nested = nestListItems(controller.value, deeper: deeper);
    _set(nested ?? changeParagraphFormat(controller.value, (f) => f.copyWith(indent: f.indent + (deeper ? 1 : -1))));
  }
}
