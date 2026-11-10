import 'dart:typed_data';

import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw_widgets;

import '../citations/citation_document.dart';
import '../l10n/language.dart';
import '../models/rich_text.dart';
import 'markdown_parser.dart';
import 'code_highlight.dart';
import 'math_images.dart';

/// Markdown as one PDF widget per block, mirroring [MarkdownView]. Separate
/// widgets let a `MultiPage` break the text between blocks.
/// Formulas come in as pictures ([math], see [renderMathImages]); one without a
/// picture is written out as it is.
///
/// [citations] reads the citations of the text (`[@key]`); with [bibliography] the list of the sources it cites comes under it.
///
/// [pictures] has the bytes of the pictures in the text, by where they are (`image:<file>`); one without bytes is left out.
List<pw_widgets.Widget> markdownBlocksToPdf(RichInlineTextController controller, double fontSize,
    {MathImages math = MathImages.empty,
    pw.PdfColor? color,
    CitationDocument? citations,
    bool bibliography = false,
    Map<String, Uint8List> pictures = const {},
    double maxPictureWidth = 450}) {
  final base = pw_widgets.TextStyle(fontSize: fontSize, lineSpacing: fontSize * 0.2, color: color);
  final blocks = parseMarkdown(controller.text);
  final notes = footnoteNumbers(blocks);
  final named = documentStyles(blocks);
  final refs = crossReferences(blocks, figure: tr('Figure'), table: tr('Table'));
  final captions = captionNumbers(blocks);

  pw_widgets.Widget richText(List<MdRun> runs, pw_widgets.TextStyle style, {bool plain = false, pw_widgets.TextAlign align = pw_widgets.TextAlign.left}) => pw_widgets.RichText(
        textAlign: align,
        text: pw_widgets.TextSpan(style: style, children: [
          for (final run in runs)
            if (run.comment)
              pw_widgets.TextSpan(text: '')
            else if (run.ref != null)
              pw_widgets.TextSpan(text: refs[run.ref] ?? run.ref, style: pw_widgets.TextStyle(fontWeight: run.bold ? pw_widgets.FontWeight.bold : null))
            else if (run.footnote != null)
              pw_widgets.TextSpan(text: '${notes[run.footnote] ?? run.footnote}', baseline: fontSize * 0.35, style: pw_widgets.TextStyle(fontSize: fontSize * 0.65))
            else if (run.image != null)
              if (pictures[run.image] case final bytes?)
                pw_widgets.WidgetSpan(
                  child: pw_widgets.Image(pw_widgets.MemoryImage(bytes),
                      width: run.imageWidth == null ? null : (run.imageWidth! < maxPictureWidth ? run.imageWidth : maxPictureWidth),
                      fit: pw_widgets.BoxFit.contain),
                )
              else
                pw_widgets.TextSpan(text: run.text)
            else if (run.cite != null && citations != null && !plain)
              pw_widgets.TextSpan(
                text: citations.inText(run.cite!),
                style: pw_widgets.TextStyle(
                  fontWeight: run.bold ? pw_widgets.FontWeight.bold : null,
                  fontStyle: run.italic ? pw_widgets.FontStyle.italic : null,
                ),
              )
            else if (run.math)
              _inlineMath(run.text, math.of(run.text), style)
            else
              for (final s in segmentsOf(run, plain ? const [] : controller.attributes))
                pw_widgets.TextSpan(
                  text: s.text,
                  baseline: s.superscript ? fontSize * 0.35 : (s.subscript ? -fontSize * 0.15 : 0),
                  style: _segmentFont(s.code ? 'Mono' : s.font).copyWith(
                    fontSize: s.size == null && !s.superscript && !s.subscript ? null : fontSize * (s.size ?? 1) * (s.superscript || s.subscript ? 0.7 : 1),
                    fontWeight: s.bold ? pw_widgets.FontWeight.bold : null,
                    fontStyle: s.italic ? pw_widgets.FontStyle.italic : null,
                    background: s.code
                        ? const pw_widgets.BoxDecoration(color: pw.PdfColor(0.9, 0.9, 0.9))
                        : (s.highlight || s.highlightColor != null)
                            ? pw_widgets.BoxDecoration(color: pw.PdfColor.fromInt(s.highlightColor ?? 0xFFFFF176))
                            : null,
                    color: run.deleted
                        ? const pw.PdfColor(0.78, 0.16, 0.16)
                        : run.inserted
                            ? const pw.PdfColor(0.18, 0.49, 0.2)
                            : run.link != null
                                ? const pw.PdfColor(0.08, 0.35, 0.7)
                                : (s.color == null ? null : pw.PdfColor.fromInt(s.color!)),
                    decoration: pw_widgets.TextDecoration.combine([
                      if (s.underline || run.link != null || run.inserted) pw_widgets.TextDecoration.underline,
                      if (s.strike || run.deleted) pw_widgets.TextDecoration.lineThrough,
                    ]),
                  ),
                ),
        ]),
      );

  /// A table: the head in bold on a tint, thin lines between the cells.
  pw_widgets.Widget table(MdBlock b, pw_widgets.TextStyle style) {
    final line = (color ?? pw.PdfColors.grey800).shade(0.5);
    return pw_widgets.Padding(
      padding: pw_widgets.EdgeInsets.symmetric(vertical: fontSize * 0.3),
      child: pw_widgets.Table(
        border: pw_widgets.TableBorder.all(color: line, width: 0.6),
        defaultVerticalAlignment: pw_widgets.TableCellVerticalAlignment.middle,
        children: [
          for (var r = 0; r < b.rows.length; r++)
            pw_widgets.TableRow(
              decoration: r == 0 ? const pw_widgets.BoxDecoration(color: pw.PdfColor(0.93, 0.93, 0.93)) : null,
              children: [
                for (var c = 0; c < b.rows[r].length; c++)
                  pw_widgets.Padding(
                    padding: pw_widgets.EdgeInsets.symmetric(horizontal: fontSize * 0.4, vertical: fontSize * 0.2),
                    child: richText(b.rows[r][c], r == 0 ? style.copyWith(fontWeight: pw_widgets.FontWeight.bold) : style,
                        align: switch (c < b.aligns.length ? b.aligns[c] : '') {
                          'center' => pw_widgets.TextAlign.center,
                          'right' => pw_widgets.TextAlign.right,
                          _ => pw_widgets.TextAlign.left,
                        }),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  pw_widgets.Widget block(MdBlock b, {bool plain = false}) {
    final spaced = b.format.spacing == 1.0 ? base : base.copyWith(lineSpacing: fontSize * (0.2 + 1.2 * (b.format.spacing - 1)));
    var style = b.type == MdBlockType.heading
        ? spaced.copyWith(
            fontSize: fontSize * headingScale(b.level), fontWeight: pw_widgets.FontWeight.bold)
        : spaced;
    // the document's named style for this kind of paragraph
    final look = styleFor(b, named);
    if (look != null && !look.isEmpty) {
      final font = _segmentFont(look.font);
      style = style.copyWith(
        font: font.font,
        fontBold: font.fontBold,
        fontItalic: font.fontItalic,
        fontBoldItalic: font.fontBoldItalic,
        fontSize: look.size == null ? null : fontSize * look.size! / documentPointSize,
        color: look.color == null ? null : pw.PdfColor.fromInt(look.color!),
      );
    }
    if (b.type == MdBlockType.math) {
      final tex = b.runs.single.text;
      final picture = math.of(tex, display: true);
      return pw_widgets.Padding(
        padding: pw_widgets.EdgeInsets.symmetric(vertical: fontSize * 0.3),
        child: pw_widgets.Center(
          child: picture == null
              ? pw_widgets.Text('\$\$$tex\$\$', style: style)
              : pw_widgets.Image(pw_widgets.MemoryImage(picture.png), width: picture.width, height: picture.height),
        ),
      );
    }
    if (b.type == MdBlockType.bibliography) {
      if (citations == null || citations.cited.isEmpty) return pw_widgets.Text(b.runs.single.text, style: style);
      return pw_widgets.Column(
        crossAxisAlignment: pw_widgets.CrossAxisAlignment.start,
        children: [for (final r in parseMarkdown('## ${tr('References')}\n${citations.bibliography().join('\n')}')) block(r, plain: true)],
      );
    }
    if (b.type == MdBlockType.table) return table(b, style);
    if (b.type == MdBlockType.code) {
      final mono = pw_widgets.TextStyle(font: pw_widgets.Font.courier(), fontSize: fontSize * 0.85);
      return pw_widgets.Container(
        width: double.infinity,
        margin: pw_widgets.EdgeInsets.symmetric(vertical: fontSize * 0.3),
        padding: pw_widgets.EdgeInsets.all(fontSize * 0.5),
        decoration: pw_widgets.BoxDecoration(color: pw.PdfColor(0.95, 0.95, 0.95), borderRadius: pw_widgets.BorderRadius.circular(4)),
        child: pw_widgets.RichText(
          text: pw_widgets.TextSpan(
            style: mono,
            children: [
              for (final t in highlightCode(b.code, b.lang))
                pw_widgets.TextSpan(text: t.text, style: codeColor(t.kind, dark: false) == null ? null : pw_widgets.TextStyle(color: pw.PdfColor.fromInt(codeColor(t.kind, dark: false)!))),
            ],
          ),
        ),
      );
    }
    if (b.type == MdBlockType.setting) return pw_widgets.SizedBox();
    if (b.type == MdBlockType.pageBreak) return pw_widgets.NewPage();
    if (b.type == MdBlockType.toc) {
      final entries = tocEntries(blocks);
      final top = entries.isEmpty ? 1 : entries.map((e) => e.$1).reduce((a, c) => a < c ? a : c);
      return pw_widgets.Column(crossAxisAlignment: pw_widgets.CrossAxisAlignment.start, children: [
        pw_widgets.Text(tr('Contents'), style: base.copyWith(fontSize: fontSize * headingScale(2), fontWeight: pw_widgets.FontWeight.bold)),
        for (final (level, title, _) in entries)
          pw_widgets.Padding(padding: pw_widgets.EdgeInsets.only(left: (level - top) * fontSize * 1.5), child: pw_widgets.Text(title, style: base)),
      ]);
    }
    if (b.type == MdBlockType.caption) {
      final small = style.copyWith(fontSize: fontSize * 0.9, fontStyle: pw_widgets.FontStyle.italic);
      return pw_widgets.Padding(
        padding: pw_widgets.EdgeInsets.only(bottom: fontSize * 0.3),
        child: pw_widgets.SizedBox(
          width: double.infinity,
          child: pw_widgets.RichText(
            textAlign: pw_widgets.TextAlign.center,
            text: pw_widgets.TextSpan(style: small, children: [
              pw_widgets.TextSpan(
                  text: captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table')),
                  style: pw_widgets.TextStyle(fontWeight: pw_widgets.FontWeight.bold)),
              ...[for (final r in b.runs) if (r.ref != null) pw_widgets.TextSpan(text: refs[r.ref] ?? r.ref) else if (!r.comment) pw_widgets.TextSpan(text: r.text)],
            ]),
          ),
        ),
      );
    }
    if (b.type == MdBlockType.footnote) {
      final small = base.copyWith(fontSize: fontSize * 0.85);
      return pw_widgets.Row(crossAxisAlignment: pw_widgets.CrossAxisAlignment.start, children: [
        pw_widgets.SizedBox(width: fontSize * 1.6, child: pw_widgets.Text('${notes[b.label] ?? b.label}.', style: small)),
        pw_widgets.Expanded(child: richText(b.runs, small)),
      ]);
    }
    if (b.type == MdBlockType.rule) {
      return pw_widgets.Padding(
        padding: pw_widgets.EdgeInsets.symmetric(vertical: fontSize * 0.6),
        child: pw_widgets.Divider(height: 1, thickness: 0.6, color: (color ?? pw.PdfColors.grey800).shade(0.5)),
      );
    }
    final faint = b.type == MdBlockType.quote || (b.type == MdBlockType.task && b.checked);
    final text = richText(
      b.runs,
      faint
          ? style.copyWith(
              color: pw.PdfColors.grey700,
              fontStyle: b.type == MdBlockType.quote ? pw_widgets.FontStyle.italic : null,
              decoration: b.type == MdBlockType.task ? pw_widgets.TextDecoration.lineThrough : null)
          : style,
      plain: plain,
      align: switch (b.format.align) {
        'center' => pw_widgets.TextAlign.center,
        'right' => pw_widgets.TextAlign.right,
        'justify' => pw_widgets.TextAlign.justify,
        _ => pw_widgets.TextAlign.left,
      },
    );
    final marker = switch (b.type) {
      MdBlockType.bullet => '-',
      MdBlockType.numbered => '${b.level}.',
      MdBlockType.task => b.checked ? '[x]' : '[ ]',
      MdBlockType.quote => '|',
      _ => null,
    };
    final indent = b.format.indent * fontSize * 2 + b.depth * fontSize * 1.5;
    pw_widgets.Widget body;
    if (marker == null) {
      body = b.runs.isEmpty
          ? pw_widgets.Text(' ', style: style)
          : (b.format.align == 'left' ? text : pw_widgets.SizedBox(width: double.infinity, child: text));
    } else {
      body = pw_widgets.Row(
        crossAxisAlignment: pw_widgets.CrossAxisAlignment.start,
        children: [
          pw_widgets.SizedBox(width: fontSize * 1.6, child: pw_widgets.Text(marker, style: style)),
          pw_widgets.Expanded(child: text),
        ],
      );
    }
    return indent == 0 ? body : pw_widgets.Padding(padding: pw_widgets.EdgeInsets.only(left: indent), child: body);
  }

  final sources = bibliography && citations != null && citations.cited.isNotEmpty && !blocks.any((b) => b.type == MdBlockType.bibliography)
      ? citations.bibliography()
      : const <String>[];
  return [
    for (final b in blocks) block(b),
    if (sources.isNotEmpty) ...[
      pw_widgets.SizedBox(height: fontSize),
      for (final b in parseMarkdown('## ${tr('References')}\n${sources.join('\n')}')) block(b, plain: true),
    ],
  ];
}

/// A formula inside a line of text: its picture, sitting on the baseline with a
/// little below it for the descenders.
pw_widgets.InlineSpan _inlineMath(String tex, MathImage? picture, pw_widgets.TextStyle style) {
  if (picture == null) return pw_widgets.TextSpan(text: '\$$tex\$', style: style);
  return pw_widgets.WidgetSpan(
    baseline: picture.height * 0.25,
    child: pw_widgets.Image(pw_widgets.MemoryImage(picture.png), width: picture.width, height: picture.height),
  );
}

/// Markdown of a text box as a single PDF widget.
pw_widgets.Widget markdownToPdf(RichInlineTextController controller, double fontSize,
        {MathImages math = MathImages.empty, pw.PdfColor? color, CitationDocument? citations, bool bibliography = false}) =>
    pw_widgets.Column(
      crossAxisAlignment: pw_widgets.CrossAxisAlignment.start,
      children: markdownBlocksToPdf(controller, fontSize, math: math, color: color, citations: citations, bibliography: bibliography),
    );

/// The PDF's own fonts for a font of [documentFonts] (they take the same room as the ones on screen); the usual one for null.
pw_widgets.TextStyle _segmentFont(String? font) => switch (font) {
      'Serif' => pw_widgets.TextStyle(
          font: pw_widgets.Font.times(),
          fontBold: pw_widgets.Font.timesBold(),
          fontItalic: pw_widgets.Font.timesItalic(),
          fontBoldItalic: pw_widgets.Font.timesBoldItalic()),
      'Mono' => pw_widgets.TextStyle(
          font: pw_widgets.Font.courier(),
          fontBold: pw_widgets.Font.courierBold(),
          fontItalic: pw_widgets.Font.courierOblique(),
          fontBoldItalic: pw_widgets.Font.courierBoldOblique()),
      'Sans' || 'DejaVu Sans' => pw_widgets.TextStyle(
          font: pw_widgets.Font.helvetica(),
          fontBold: pw_widgets.Font.helveticaBold(),
          fontItalic: pw_widgets.Font.helveticaOblique(),
          fontBoldItalic: pw_widgets.Font.helveticaBoldOblique()),
      _ => const pw_widgets.TextStyle(),
    };
