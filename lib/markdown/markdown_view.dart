import 'package:flutter/material.dart' hide Text;
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../citations/citation_document.dart';
import '../citations/citation_service.dart';
import '../models/rich_text.dart';
import 'markdown_parser.dart';
import 'code_highlight.dart';
import 'document_images.dart';
import 'remote_image.dart';

/// How a piece of text formatted by [s] is drawn (over the style of its block), the text being [fontSize] large.
TextStyle segmentStyle(MdSegment s, double fontSize) => TextStyle(
      fontWeight: s.bold ? FontWeight.bold : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: TextDecoration.combine([
        if (s.underline) TextDecoration.underline,
        if (s.strike) TextDecoration.lineThrough,
      ]),
      fontFamily: s.code ? 'monospace' : (s.font == null ? null : documentFonts[s.font] ?? s.font),
      fontSize: s.size == null ? null : fontSize * s.size!,
      color: s.color == null ? null : Color(s.color!),
      backgroundColor: s.code ? Colors.black12 : (s.highlightColor != null ? Color(s.highlightColor!) : (s.highlight ? const Color(0xFFFFF176) : null)),
    );

/// [style] with how a tracked change or the text of a comment looks: put in green and underlined, taken out red and struck
/// through, commented on a light yellow.
TextStyle changeStyle(MdRun run, TextStyle style) {
  if (!run.inserted && !run.deleted && !run.commented) return style;
  return style.copyWith(
    color: run.deleted ? const Color(0xFFC62828) : (run.inserted ? const Color(0xFF2E7D32) : null),
    decoration: run.deleted ? TextDecoration.lineThrough : (run.inserted ? TextDecoration.underline : style.decoration),
    backgroundColor: run.commented ? const Color(0x55FFC107) : style.backgroundColor,
  );
}

/// The list of the sources [text] cites, with its heading; nothing when it cites none (or citations are off). With [appended], also
/// nothing when the text has a `[bibliography]` line of its own (the list is there).
class ReferenceList extends StatelessWidget {
  final String text;
  final double fontSize;
  final Color textColor;
  final bool appended;

  const ReferenceList({super.key, required this.text, required this.fontSize, this.textColor = Colors.black87, this.appended = false});

  @override
  Widget build(BuildContext context) {
    final cites = CitationStyleScope.documentFor(context, text);
    if (cites == null || cites.cited.isEmpty) return const SizedBox.shrink();
    if (appended && text.split('\n').any(bibliographyMarker.hasMatch)) return const SizedBox.shrink();
    final view = MarkdownView(controller: RichInlineTextController(), fontSize: fontSize, textColor: textColor);
    final base = TextStyle(fontSize: fontSize, height: 1.4, color: textColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (appended) SizedBox(height: fontSize),
        ...view._references(cites, base),
      ],
    );
  }
}

/// Read-only rendering of a text box's Markdown.
class MarkdownView extends StatelessWidget {
  final RichInlineTextController controller;
  final double fontSize;

  /// Called with the target of a link that was tapped (`note:<id>`, a web address).
  final ValueChanged<String>? onLink;

  /// The colour of the text (formulas included).
  final Color textColor;

  /// Writes the list of the sources the text cites under it (the written document does; a text box does not) - unless a line
  /// `[bibliography]` puts it where the person wants it.
  final bool bibliography;

  /// Called with the citation that was tapped (its run: where it is in the text and what it cites); null: citations are not tappable.
  final ValueChanged<MdRun>? onCitation;

  const MarkdownView(
      {super.key, required this.controller, required this.fontSize, this.onLink, this.textColor = Colors.black87, this.bibliography = false, this.onCitation});

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize, height: 1.4, color: textColor);
    final blocks = parseMarkdown(controller.text);
    final cites = CitationStyleScope.documentFor(context, controller.text);
    final listed = blocks.any((b) => b.type == MdBlockType.bibliography);
    final appended = bibliography && !listed && cites != null && cites.cited.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final b in blocks)
          _block(b, base, cites,
              notes: footnoteNumbers(blocks),
              blocks: blocks,
              refs: crossReferences(blocks, figure: tr('Figure'), table: tr('Table')),
              captions: captionNumbers(blocks)),
        if (appended) ...[
          SizedBox(height: fontSize),
          ..._references(cites, base),
        ],
      ],
    );
  }

  /// The list of the sources: a heading and the entries. They are made here, so no manual attribute of the text belongs to them.
  List<Widget> _references(CitationDocument cites, TextStyle base) =>
      [for (final b in parseMarkdown('## ${tr('References')}\n${cites.bibliography().join('\n')}')) _block(b, base, null, plain: true)];

  Widget _block(MdBlock b, TextStyle base, CitationDocument? cites,
      {bool plain = false,
      Map<String, int> notes = const {},
      List<MdBlock> blocks = const [],
      Map<String, String> refs = const {},
      Map<int, int> captions = const {}}) {
    final spaced = b.format.spacing == 1.0 ? base : base.copyWith(height: (base.height ?? 1.2) * b.format.spacing);
    final style = b.type == MdBlockType.heading
        ? spaced.copyWith(
            fontSize: fontSize * headingScale(b.level), fontWeight: FontWeight.bold)
        : spaced;
    if (b.type == MdBlockType.math) {
      // a formula on a line of its own, centred
      return SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: fontSize * 0.3),
          child: FittedBox(fit: BoxFit.scaleDown, child: _math(b.runs.single.text, style, display: true)),
        ),
      );
    }
    if (b.type == MdBlockType.bibliography) {
      // (without any source cited, or with citations off, the line stays as it was written)
      if (cites == null || cites.cited.isEmpty) return Text.verbatim(b.runs.single.text, style: style);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: _references(cites, base));
    }
    if (b.type == MdBlockType.table) return _table(b, style, cites);
    if (b.type == MdBlockType.setting) return const SizedBox.shrink();
    if (b.type == MdBlockType.pageBreak) {
      return SizedBox(height: fontSize * 1.5, child: Center(child: Container(height: 1, color: textColor.withValues(alpha: 0.15))));
    }
    if (b.type == MdBlockType.toc) {
      final entries = tocEntries(blocks);
      final top = entries.isEmpty ? 1 : entries.map((e) => e.$1).reduce((a, c) => a < c ? a : c);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('Contents', style: base.copyWith(fontSize: fontSize * headingScale(2), fontWeight: FontWeight.bold)),
        for (final (level, title, _) in entries)
          Padding(padding: EdgeInsets.only(left: (level - top) * fontSize * 1.5), child: Text.verbatim(title, style: base)),
      ]);
    }
    if (b.type == MdBlockType.caption) {
      final small = base.copyWith(fontSize: fontSize * 0.9, fontStyle: FontStyle.italic);
      return SizedBox(
        width: double.infinity,
        child: Text.rich(
          TextSpan(style: small, children: [
            TextSpan(text: captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table')), style: const TextStyle(fontWeight: FontWeight.bold)),
            ..._spans(b, small, cites, notes: notes, refs: refs),
          ]),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (b.type == MdBlockType.footnote) {
      final small = base.copyWith(fontSize: fontSize * 0.85);
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: fontSize * 1.6, child: Text.verbatim('${notes[b.label] ?? b.label}.', style: small)),
        Expanded(child: Text.rich(TextSpan(children: _spans(b, small, cites, notes: notes), style: small))),
      ]);
    }
    if (b.type == MdBlockType.code) return _code(b);
    if (b.type == MdBlockType.rule) {
      return SizedBox(width: double.infinity, height: fontSize * 1.5, child: Center(child: Container(height: 1, color: textColor.withValues(alpha: 0.35))));
    }
    final faint = b.type == MdBlockType.quote || (b.type == MdBlockType.task && b.checked);
    final text = Text.rich(
      TextSpan(
        children: _spans(b, style, cites, plain: plain, notes: notes, refs: refs),
        style: faint
            ? style.copyWith(
                color: textColor.withValues(alpha: 0.6),
                fontStyle: b.type == MdBlockType.quote ? FontStyle.italic : null,
                decoration: b.type == MdBlockType.task ? TextDecoration.lineThrough : null)
            : style,
      ),
      textAlign: switch (b.format.align) { 'center' => TextAlign.center, 'right' => TextAlign.right, 'justify' => TextAlign.justify, _ => null },
    );
    final Widget? marker = switch (b.type) {
      MdBlockType.bullet => Text.verbatim(b.depth.isOdd ? '◦' : '•', style: style),
      MdBlockType.numbered => Text.verbatim('${b.level}.', style: style),
      MdBlockType.task => Icon(b.checked ? Icons.check_box : Icons.check_box_outline_blank, size: fontSize * 1.15, color: textColor.withValues(alpha: 0.7)),
      MdBlockType.quote => Container(width: 3, height: fontSize * 1.3, color: textColor.withValues(alpha: 0.3)),
      _ => null,
    };
    final indent = EdgeInsets.only(left: b.format.indent * fontSize * 2 + b.depth * fontSize * 1.5);
    Widget body;
    if (marker == null) {
      // an empty line still takes up a line of height
      body = b.runs.isEmpty ? Text(' ', style: style) : (b.format.align == 'left' ? text : SizedBox(width: double.infinity, child: text));
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: fontSize * 1.6, child: Align(alignment: Alignment.centerLeft, child: marker)),
          Expanded(child: text),
        ],
      );
    }
    return indent.left == 0 ? body : Padding(padding: indent, child: body);
  }

  Widget _picture(MdRun run) {
    final file = DocumentImages.fileOf(run.image!);
    Widget missing(BuildContext _, Object _, StackTrace? _) => Text.verbatim('🖼 ${run.text}', style: TextStyle(fontSize: fontSize * 0.8));
    return file != null
        ? Image.file(file, width: run.imageWidth, errorBuilder: missing)
        : RemoteImage.isWeb(run.image!)
            ? RemoteImage(url: run.image!, label: run.text, width: run.imageWidth, fontSize: fontSize, color: textColor)
            : Builder(builder: (context) => missing(context, 'not a picture', null));
  }

  /// A block of code on a tint, in a fixed-width font, with its language's colours.
  Widget _code(MdBlock b) {
    final dark = textColor.computeLuminance() > 0.5;
    final mono = TextStyle(fontFamily: 'monospace', fontSize: fontSize * 0.9, height: 1.35, color: textColor);
    return Container(
      key: const ValueKey('code-block'),
      width: double.infinity,
      margin: EdgeInsets.symmetric(vertical: fontSize * 0.3),
      padding: EdgeInsets.all(fontSize * 0.6),
      decoration: BoxDecoration(color: textColor.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(6)),
      child: Text.rich(
        TextSpan(
          style: mono,
          children: [
            for (final t in highlightCode(b.code, b.lang))
              TextSpan(text: t.text, style: codeColor(t.kind, dark: dark) == null ? null : TextStyle(color: Color(codeColor(t.kind, dark: dark)!), fontStyle: t.kind == 'comment' ? FontStyle.italic : null)),
          ],
        ),
      ),
    );
  }

  /// A table: its head in bold on a tint, thin lines between the cells.
  Widget _table(MdBlock b, TextStyle style, CitationDocument? cites) {
    final line = BorderSide(color: textColor.withValues(alpha: 0.35), width: 0.8);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: fontSize * 0.3),
      child: Table(
        border: TableBorder(top: line, bottom: line, left: line, right: line, horizontalInside: line, verticalInside: line),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          for (var r = 0; r < b.rows.length; r++)
            TableRow(
              decoration: r == 0 ? BoxDecoration(color: textColor.withValues(alpha: 0.08)) : null,
              children: [
                for (var c = 0; c < b.rows[r].length; c++)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: fontSize * 0.4, vertical: fontSize * 0.2),
                    child: Text.rich(
                      textAlign: switch (c < b.aligns.length ? b.aligns[c] : '') { 'center' => TextAlign.center, 'right' => TextAlign.right, _ => null },
                      TextSpan(
                        children: _spans(MdBlock(MdBlockType.paragraph, b.rows[r][c]), style, cites),
                        style: r == 0 ? style.copyWith(fontWeight: FontWeight.bold) : style,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// A formula; one that cannot be read shows its source.
  static Widget _math(String tex, TextStyle style, {bool display = false}) => Math.tex(
        tex,
        textStyle: style,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        onErrorFallback: (_) => Text.verbatim(display ? '\$\$$tex\$\$' : '\$$tex\$', style: style),
      );

  List<InlineSpan> _spans(MdBlock b, TextStyle style, CitationDocument? cites,
          {bool plain = false, Map<String, int> notes = const {}, Map<String, String> refs = const {}}) =>
      [
        for (final run in b.runs)
          if (run.ref != null)
            TextSpan(text: refs[run.ref] ?? run.ref, style: TextStyle(color: Colors.blue.shade700))
          else if (run.comment)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Tooltip(message: run.text, child: Icon(Icons.mode_comment, size: fontSize * 0.9, color: const Color(0xFFF9A825))),
            )
          else if (run.footnote != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Text.verbatim('${notes[run.footnote] ?? run.footnote}', style: style.copyWith(fontSize: fontSize * 0.65, height: 1)),
            )
          else if (run.image != null)
            WidgetSpan(alignment: PlaceholderAlignment.bottom, child: _picture(run))
          else if (run.cite != null && cites != null && onCitation != null)
            // a citation that can be tapped, to change it
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey('citation-${run.src}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onCitation!(run),
                  child: Text.verbatim(
                    cites.inText(run.cite!),
                    style: style.copyWith(
                      fontWeight: run.bold ? FontWeight.bold : null,
                      fontStyle: run.italic ? FontStyle.italic : null,
                      decoration: TextDecoration.underline,
                      decorationStyle: TextDecorationStyle.dotted,
                    ),
                  ),
                ),
              ),
            )
          else if (run.cite != null && cites != null)
            TextSpan(
              text: cites.inText(run.cite!),
              style: TextStyle(
                fontWeight: run.bold ? FontWeight.bold : null,
                fontStyle: run.italic ? FontStyle.italic : null,
                decoration: run.strike ? TextDecoration.lineThrough : null,
              ),
            )
          else if (run.math)
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: _math(run.text, style))
          else if (run.link != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey('link-${run.link}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onLink == null ? null : () => onLink!(run.link!),
                  child: Text.verbatim(
                    run.text,
                    style: style.copyWith(
                      color: Colors.blue.shade700,
                      decoration: TextDecoration.underline,
                      fontWeight: run.bold ? FontWeight.bold : null,
                      fontStyle: run.italic ? FontStyle.italic : null,
                    ),
                  ),
                ),
              ),
            )
          else
            for (final s in segmentsOf(run, plain ? const [] : controller.attributes))
              if (s.superscript || s.subscript)
                WidgetSpan(
                  alignment: s.superscript ? PlaceholderAlignment.top : PlaceholderAlignment.bottom,
                  child: Text.verbatim(s.text, style: style.merge(segmentStyle(s, fontSize)).copyWith(fontSize: fontSize * (s.size ?? 1) * 0.7, height: 1)),
                )
              else
                TextSpan(text: s.text, style: changeStyle(run, segmentStyle(s, fontSize))),
      ];
}
