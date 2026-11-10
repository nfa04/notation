import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw_widgets;

import '../citations/citation_document.dart';
import '../l10n/language.dart';
import '../models/page_format.dart';
import '../models/rich_text.dart';
import 'markdown_formatting.dart' show settledText;
import 'markdown_parser.dart';
import 'markdown_pdf.dart';
import 'math_images.dart';

/// The written document as files for other programs: a PDF cut into pages (with what the document says its pages have at the top
/// and the bottom), a Word document, a web page, Markdown and plain text. The text is the document's Markdown; [attributes] are
/// the fonts, sizes and colours picked for its words.

/// How the pages of the document are: the paper, the margins (in the editor's page units, [PageFormat.a4Units] across an A4
/// sheet) and the title and date the top and bottom of the pages may show.
class DocumentPages {
  final PageFormat format;
  final bool landscape;
  final double marginLeft, marginRight, marginTop, marginBottom;
  final String title;
  final DateTime date;

  const DocumentPages({
    this.format = PageFormat.a4,
    this.landscape = false,
    this.marginLeft = 56,
    this.marginRight = 56,
    this.marginTop = 56,
    this.marginBottom = 56,
    this.title = '',
    required this.date,
  });

  double get width => format.widthUnits(landscape: landscape);
  double get height => width * format.aspect(landscape: landscape);
  double get textWidth => width - marginLeft - marginRight;

  /// The millimetres one page unit is.
  double get mmPerUnit => (landscape ? format.widthMm * format.ratio : format.widthMm) / width;
}

/// [template] (a header or footer) with `{title}`, `{date}`, and with [page] and [pages] (null: left as they are, for a program that
/// numbers the pages itself) put in.
String fillPageText(String template, DocumentPages pages, {int? page, int? pages_}) {
  var s = template.replaceAll('{title}', pages.title).replaceAll('{date}', '${pages.date.day}.${pages.date.month}.${pages.date.year}');
  if (page != null) s = s.replaceAll('{page}', '$page');
  if (pages_ != null) s = s.replaceAll('{pages}', '$pages_');
  return s;
}

// ---- PDF

/// The document as a PDF cut into pages of [pages]' paper, `\pagebreak` starting a new one; the header and footer written in the
/// document are on every page, with `{page}` and `{pages}` numbered.
Future<Uint8List> documentPdf(
  RichInlineTextController controller,
  DocumentPages pages, {
  double fontSize = 16,
  MathImages math = MathImages.empty,
  CitationDocument? citations,
  Map<String, Uint8List> pictures = const {},
}) async {
  final settings = documentSettings(parseMarkdown(controller.text));
  final small = pw_widgets.TextStyle(fontSize: fontSize * 0.75, color: pw.PdfColors.grey700);
  pw_widgets.Widget? edge(String? template, pw_widgets.Context context, {required bool top}) {
    if (template == null || template.trim().isEmpty) return null;
    return pw_widgets.Container(
      alignment: pw_widgets.Alignment.center,
      margin: top ? pw_widgets.EdgeInsets.only(bottom: fontSize) : pw_widgets.EdgeInsets.only(top: fontSize),
      child: pw_widgets.Text(fillPageText(template, pages, page: context.pageNumber, pages_: context.pagesCount), style: small),
    );
  }

  final doc = pw_widgets.Document(title: pages.title.isEmpty ? null : pages.title);
  doc.addPage(pw_widgets.MultiPage(
    pageFormat: pw.PdfPageFormat(pages.width, pages.height,
        marginLeft: pages.marginLeft, marginRight: pages.marginRight, marginTop: pages.marginTop * 0.6, marginBottom: pages.marginBottom * 0.6),
    maxPages: 1000,
    header: settings['header'] == null ? null : (context) => edge(settings['header'], context, top: true) ?? pw_widgets.SizedBox(),
    footer: settings['footer'] == null ? null : (context) => edge(settings['footer'], context, top: false) ?? pw_widgets.SizedBox(),
    build: (context) => markdownBlocksToPdf(controller, fontSize,
        math: math, citations: citations, bibliography: true, pictures: pictures, maxPictureWidth: pages.textWidth),
  ));
  return doc.save();
}

// ---- plain text and Markdown

/// What a run reads as without its formatting.
String _plainRun(MdRun r, Map<String, int> notes, CitationDocument? cites, [Map<String, String> refs = const {}]) {
  if (r.ref != null) return refs[r.ref] ?? r.ref!;
  if (r.footnote != null) return '[${notes[r.footnote] ?? r.footnote}]';
  if (r.image != null) return '[${tr('Picture')}${r.text.isEmpty ? '' : ': ${r.text}'}]';
  if (r.cite != null && cites != null) return cites.inText(r.cite!);
  return r.text;
}

/// The document as plain text: the Markdown taken away, lists and tables kept readable, a page break as a form feed.
String documentPlainText(String text, {CitationDocument? citations}) {
  // (as it reads with its tracked changes accepted, without its comments)
  final blocks = parseMarkdown(settledText(text));
  final notes = footnoteNumbers(blocks);
  final refs = crossReferences(blocks, figure: tr('Figure'), table: tr('Table'));
  final captions = captionNumbers(blocks);
  String line(List<MdRun> runs) => runs.map((r) => _plainRun(r, notes, citations, refs)).join();
  final out = <String>[];
  for (final b in blocks) {
    final indent = '  ' * b.depth;
    switch (b.type) {
      case MdBlockType.setting:
        continue;
      case MdBlockType.heading || MdBlockType.paragraph:
        out.add(line(b.runs));
      case MdBlockType.caption:
        out.add('${captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table'))}${line(b.runs)}');
      case MdBlockType.bullet:
        out.add('$indent• ${line(b.runs)}');
      case MdBlockType.numbered:
        out.add('$indent${b.level}. ${line(b.runs)}');
      case MdBlockType.task:
        out.add('$indent[${b.checked ? 'x' : ' '}] ${line(b.runs)}');
      case MdBlockType.quote:
        out.add('    ${line(b.runs)}');
      case MdBlockType.rule:
        out.add('—' * 20);
      case MdBlockType.pageBreak:
        out.add('\f');
      case MdBlockType.math:
        out.add(b.runs.single.text);
      case MdBlockType.code:
        out.add(b.code);
      case MdBlockType.table:
        for (final row in b.rows) {
          out.add(row.map(line).join('\t'));
        }
      case MdBlockType.footnote:
        out.add('[${notes[b.label] ?? b.label}] ${line(b.runs)}');
      case MdBlockType.toc:
        out.add(tr('Contents'));
        for (final (level, title, _) in tocEntries(blocks)) {
          out.add('${'  ' * (level - 1)}$title');
        }
      case MdBlockType.bibliography:
        if (citations != null && citations.cited.isNotEmpty) {
          out
            ..add(tr('References'))
            ..addAll(citations.bibliography());
        }
    }
  }
  return out.join('\n');
}

/// The document as Markdown other programs read: the app's own layout tokens taken out.
String documentMarkdown(String text) => withoutParagraphFormats(text);

// ---- HTML

String _esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);
String _attr(String s) => const HtmlEscape(HtmlEscapeMode.attribute).convert(s);

/// The CSS font family for a font of [documentFonts].
String _cssFont(String font) => switch (font) {
      'Serif' => "'Liberation Serif', 'Times New Roman', serif",
      'Mono' => "'Liberation Mono', 'Courier New', monospace",
      'DejaVu Sans' => "'DejaVu Sans', sans-serif",
      _ => "'Liberation Sans', Arial, Helvetica, sans-serif",
    };

String _hex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The document as a web page of its own (pictures in it, as data).
String documentHtml(String text, List<TextSpanAttribute> attributes,
    {String title = '', CitationDocument? citations, Map<String, Uint8List> pictures = const {}}) {
  final blocks = parseMarkdown(text);
  final notes = footnoteNumbers(blocks);
  final refs = crossReferences(blocks, figure: tr('Figure'), table: tr('Table'));
  final captions = captionNumbers(blocks);
  String runs(List<MdRun> list) {
    final b = StringBuffer();
    for (final r in list) {
      if (r.ref != null) {
        b.write('<a href="#${_attr(r.ref!)}">${_esc(refs[r.ref] ?? r.ref!)}</a>');
      } else if (r.comment) {
        b.write('<span class="comment" title="${_attr(r.text)}">💬</span>');
      } else if (r.footnote != null) {
        final n = notes[r.footnote] ?? r.footnote;
        b.write('<sup><a href="#fn-$n" id="ref-$n">$n</a></sup>');
      } else if (r.image != null) {
        final bytes = pictures[r.image];
        final src = bytes != null ? 'data:${_mimeOf(bytes)};base64,${base64Encode(bytes)}' : r.image!;
        b.write('<img src="${_attr(src)}" alt="${_attr(r.text)}"${r.imageWidth != null ? ' width="${r.imageWidth!.round()}"' : ''} style="max-width:100%">');
      } else if (r.math) {
        b.write('<code class="math">${_esc(r.text)}</code>');
      } else if (r.cite != null && citations != null) {
        b.write(_esc(citations.inText(r.cite!)));
      } else {
        for (final s in segmentsOf(r, attributes)) {
          var t = _esc(s.text);
          final css = [
            if (s.font != null) 'font-family:${_cssFont(s.font!)}',
            if (s.size != null) 'font-size:${(s.size! * 100).round()}%',
            if (s.color != null) 'color:${_hex(s.color!)}',
            if (s.highlight || s.highlightColor != null) 'background:${_hex(s.highlightColor ?? 0xFFFFF176)}',
          ];
          if (s.code) t = '<code>$t</code>';
          if (s.bold) t = '<strong>$t</strong>';
          if (s.italic) t = '<em>$t</em>';
          if (s.underline) t = '<u>$t</u>';
          if (s.strike) t = '<s>$t</s>';
          if (s.superscript) t = '<sup>$t</sup>';
          if (s.subscript) t = '<sub>$t</sub>';
          if (css.isNotEmpty) t = '<span style="${_attr(css.join(';'))}">$t</span>';
          if (r.link != null && !r.link!.startsWith('note:')) t = '<a href="${_attr(r.link!)}">$t</a>';
          if (r.commented) t = '<mark>$t</mark>';
          if (r.inserted) t = '<ins>$t</ins>';
          if (r.deleted) t = '<del>$t</del>';
          b.write(t);
        }
      }
    }
    return b.toString();
  }

  String para(MdBlock b) {
    final f = b.format;
    final css = [
      if (f.align != 'left') 'text-align:${f.align}',
      if (f.indent > 0) 'margin-left:${f.indent * 2}em',
      if (f.spacing != 1.0) 'line-height:${1.5 * f.spacing}',
    ];
    return css.isEmpty ? '' : ' style="${css.join(';')}"';
  }

  final body = StringBuffer();
  String? list; // the list being written (`ul`, `ol`)
  void closeList() {
    if (list != null) body.writeln('</$list>');
    list = null;
  }

  for (final b in blocks) {
    final wants = switch (b.type) { MdBlockType.bullet || MdBlockType.task => 'ul', MdBlockType.numbered => 'ol', _ => null };
    if (wants != list) {
      closeList();
      if (wants != null) {
        body.writeln(wants == 'ol' ? '<ol start="${b.level}">' : '<ul>');
        list = wants;
      }
    }
    final p = para(b);
    switch (b.type) {
      case MdBlockType.setting:
        break;
      case MdBlockType.heading:
        final id = b.markup.where((m) => m.kind == MdMarkupKind.anchor).firstOrNull?.id;
        body.writeln('<h${b.level}${id == null ? '' : ' id="${_attr(id)}"'}$p>${runs(b.runs)}</h${b.level}>');
      case MdBlockType.caption:
        final id = b.markup.where((m) => m.kind == MdMarkupKind.anchor).firstOrNull?.id;
        body.writeln('<p class="caption"${id == null ? '' : ' id="${_attr(id)}"'}><strong>${_esc(captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table')))}</strong>${runs(b.runs)}</p>');
      case MdBlockType.paragraph:
        body.writeln(b.runs.isEmpty ? '' : '<p$p>${runs(b.runs)}</p>');
      case MdBlockType.bullet || MdBlockType.numbered:
        body.writeln('<li$p${b.depth > 0 ? ' style="margin-left:${b.depth * 1.5}em"' : ''}>${runs(b.runs)}</li>');
      case MdBlockType.task:
        body.writeln('<li class="task"$p><input type="checkbox" disabled${b.checked ? ' checked' : ''}> ${runs(b.runs)}</li>');
      case MdBlockType.quote:
        body.writeln('<blockquote$p>${runs(b.runs)}</blockquote>');
      case MdBlockType.rule:
        body.writeln('<hr>');
      case MdBlockType.pageBreak:
        body.writeln('<div style="page-break-after:always"></div>');
      case MdBlockType.math:
        body.writeln('<p class="math">\\[${_esc(b.runs.single.text)}\\]</p>');
      case MdBlockType.code:
        body.writeln('<pre><code${b.lang.isEmpty ? '' : ' class="language-${_attr(b.lang)}"'}>${_esc(b.code)}</code></pre>');
      case MdBlockType.table:
        body.writeln('<table>');
        for (var r = 0; r < b.rows.length; r++) {
          final cell = r == 0 ? 'th' : 'td';
          body.writeln('<tr>${[
            for (var c = 0; c < b.rows[r].length; c++)
              '<$cell${c < b.aligns.length && b.aligns[c].isNotEmpty ? ' style="text-align:${b.aligns[c]}"' : ''}>${runs(b.rows[r][c])}</$cell>'
          ].join()}</tr>');
        }
        body.writeln('</table>');
      case MdBlockType.footnote:
        final n = notes[b.label] ?? b.label;
        body.writeln('<p class="footnote" id="fn-$n"><a href="#ref-$n">$n.</a> ${runs(b.runs)}</p>');
      case MdBlockType.toc:
        body.writeln('<nav class="toc"><h2>${_esc(tr('Contents'))}</h2><ul>');
        for (final (level, title, _) in tocEntries(blocks)) {
          body.writeln('<li style="margin-left:${(level - 1) * 1.5}em">${_esc(title)}</li>');
        }
        body.writeln('</ul></nav>');
      case MdBlockType.bibliography:
        if (citations != null && citations.cited.isNotEmpty) {
          body.writeln('<h2>${_esc(tr('References'))}</h2>');
          for (final e in citations.bibliography()) {
            body.writeln('<p class="reference">${_esc(e)}</p>');
          }
        }
    }
  }
  closeList();
  return '''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(title)}</title>
<style>
${(int.tryParse(documentSettings(blocks)['columns']?.trim() ?? '') ?? 1) > 1 ? 'main { column-count: ${documentSettings(blocks)['columns']!.trim()}; column-gap: 2em; }' : ''}
${_cssStyles(documentStyles(blocks))}
body { font-family: ${_cssFont('Sans')}; font-size: 12pt; line-height: 1.5; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #222; }
blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 1em; color: #555; font-style: italic; }
pre { background: #f4f4f4; padding: .8em; overflow-x: auto; }
code { font-family: ${_cssFont('Mono')}; }
table { border-collapse: collapse; } th, td { border: 1px solid #aaa; padding: .2em .5em; } th { background: #eee; }
li.task { list-style: none; }
ins { color: #2e7d32; } del { color: #c62828; } mark { background: #ffe082; } .comment { cursor: help; }
p.footnote { font-size: 85%; }
p.caption { font-size: 90%; font-style: italic; text-align: center; }
</style>
</head>
<body>
<main>
$body</main>
</body>
</html>
''';
}

/// CSS for the named styles of a document.
String _cssStyles(Map<String, NamedStyle> named) => [
      for (final e in named.entries)
        if (!e.value.isEmpty)
          '${e.key == 'body' ? 'p, li, blockquote' : e.key} { ${[
            if (e.value.font != null) 'font-family: ${_cssFont(e.value.font!)}',
            if (e.value.size != null) 'font-size: ${e.value.size}pt',
            if (e.value.color != null) 'color: ${_hex(e.value.color!)}',
          ].join('; ')} }',
    ].join('\n');

String _mimeOf(Uint8List bytes) {
  if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
  if (bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49) return 'image/gif';
  return 'image/png';
}

/// The size in pixels of a PNG or JPEG picture (null: neither, or it cannot be read).
(int, int)? pictureSize(Uint8List b) {
  if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
    int u32(int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    return (u32(16), u32(20));
  }
  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      final len = (b[i + 2] << 8) | b[i + 3];
      // the frame header (any SOF but the colour-table and arithmetic-coding markers) has the size
      if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
        return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
      }
      i += 2 + len;
    }
  }
  return null;
}

// ---- Word

String _x(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// The Word font for a font of [documentFonts].
String _wordFont(String font) => switch (font) {
      'Serif' => 'Times New Roman',
      'Mono' => 'Courier New',
      'DejaVu Sans' => 'DejaVu Sans',
      _ => 'Arial',
    };

String _wordHex(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// The document as a Word file (.docx): headings, lists, tables, the fonts, sizes and colours, the layout of the paragraphs,
/// footnotes as Word's own, the header and footer with page numbers, pictures, and a table of contents Word fills in when the file
/// is opened.
Uint8List documentDocx(String text, List<TextSpanAttribute> attributes, DocumentPages pages,
    {CitationDocument? citations, Map<String, Uint8List> pictures = const {}}) {
  final blocks = parseMarkdown(text);
  final notes = footnoteNumbers(blocks);
  final settings = documentSettings(blocks);
  final refs = crossReferences(blocks, figure: tr('Figure'), table: tr('Table'));
  final captions = captionNumbers(blocks);
  final rels = <String>[]; // relationships of the document, after the fixed ones
  final media = <String, Uint8List>{};
  final mediaIds = <String, String>{}; // picture target -> relationship id
  var nextRel = 10;
  String rel(String type, String target, {bool external = false}) {
    final id = 'rId${nextRel++}';
    rels.add('<Relationship Id="$id" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/$type" '
        'Target="${_x(target)}"${external ? ' TargetMode="External"' : ''}/>');
    return id;
  }

  // units -> EMU (English metric units: 36000 to a millimetre) and twips (1440 to an inch)
  int emu(double units) => (units * pages.mmPerUnit * 36000).round();
  int twips(double units) => (units * pages.mmPerUnit / 25.4 * 1440).round();
  var drawing = 0;

  String runXml(String body, {MdSegment? s, bool bold = false, bool italic = false, String? style}) {
    final p = StringBuffer();
    if (style != null) p.write('<w:rStyle w:val="$style"/>');
    final font = s?.code == true ? 'Mono' : s?.font;
    if (font != null) {
      final f = _x(_wordFont(font));
      p.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="$f"/>');
    }
    if (bold || s?.bold == true) p.write('<w:b/>');
    if (italic || s?.italic == true) p.write('<w:i/>');
    if (s?.strike == true) p.write('<w:strike/>');
    if (s?.color != null) p.write('<w:color w:val="${_wordHex(s!.color!)}"/>');
    if (s?.size != null) p.write('<w:sz w:val="${(s!.size! * documentPointSize * 2).round()}"/>');
    if (s?.underline == true) p.write('<w:u w:val="single"/>');
    if (s != null && (s.highlight || s.highlightColor != null)) {
      p.write('<w:shd w:val="clear" w:color="auto" w:fill="${_wordHex(s.highlightColor ?? 0xFFFFF176)}"/>');
    } else if (s?.code == true) {
      p.write('<w:shd w:val="clear" w:color="auto" w:fill="EEEEEE"/>');
    }
    if (s?.superscript == true) p.write('<w:vertAlign w:val="superscript"/>');
    if (s?.subscript == true) p.write('<w:vertAlign w:val="subscript"/>');
    return '<w:r>${p.isEmpty ? '' : '<w:rPr>$p</w:rPr>'}$body</w:r>';
  }

  String t(String s) => '<w:t xml:space="preserve">${_x(s)}</w:t>';

  String picture(MdRun r) {
    final bytes = pictures[r.image];
    if (bytes == null) return runXml(t('[${r.text.isEmpty ? tr('Picture') : r.text}]'));
    final id = mediaIds[r.image!] ??= () {
      final ext = _mimeOf(bytes) == 'image/jpeg' ? 'jpeg' : (_mimeOf(bytes) == 'image/gif' ? 'gif' : 'png');
      final name = 'image${media.length + 1}.$ext';
      media[name] = bytes;
      return rel('image', 'media/$name');
    }();
    final (pw0, ph0) = pictureSize(bytes) ?? (400, 300);
    var w = r.imageWidth ?? pw0.toDouble();
    if (w > pages.textWidth) w = pages.textWidth;
    final h = w * ph0 / pw0;
    drawing++;
    return '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="${emu(w)}" cy="${emu(h)}"/>'
        '<wp:docPr id="$drawing" name="Picture $drawing" descr="${_x(r.text)}"/>'
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:nvPicPr><pic:cNvPr id="$drawing" name="Picture $drawing"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$id"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${emu(w)}" cy="${emu(h)}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
  }

  final comments = <String>[];
  var changeId = 0;
  final stamp = '${pages.date.toUtc().toIso8601String().split('.').first}Z';
  /// [xml] (runs) marked as a tracked change of [r], if it is one.
  String tracked(MdRun r, String xml) {
    if (r.inserted) return '<w:ins w:id="${changeId++}" w:author="Notation" w:date="$stamp">$xml</w:ins>';
    if (r.deleted) {
      return '<w:del w:id="${changeId++}" w:author="Notation" w:date="$stamp">${xml.replaceAll('<w:t xml:space="preserve">', '<w:delText xml:space="preserve">').replaceAll('</w:t>', '</w:delText>')}</w:del>';
    }
    return xml;
  }

  void docxRunInto(MdRun r, StringBuffer out, bool bold) {
    if (r.ref != null) {
      out.write(runXml(t(refs[r.ref] ?? r.ref!), bold: bold || r.bold, italic: r.italic));
    } else if (r.footnote != null) {
      final n = notes[r.footnote];
      out.write(n == null ? runXml(t('[^${r.footnote}]')) : '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="$n"/></w:r>');
    } else if (r.image != null) {
      out.write(picture(r));
    } else if (r.math) {
      out.write(runXml(t(r.text), italic: true));
    } else if (r.cite != null && citations != null) {
      out.write(runXml(t(citations.inText(r.cite!)), bold: bold || r.bold, italic: r.italic));
    } else {
      final segs = [for (final s in segmentsOf(r, attributes)) runXml(t(s.text), s: s, bold: bold)];
      if (r.link != null && (r.link!.startsWith('http') || r.link!.startsWith('mailto:'))) {
        final id = rel('hyperlink', r.link!, external: true);
        out.write('<w:hyperlink r:id="$id">${segs.map((x) => x.replaceFirst('<w:r>', '<w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>').replaceFirst('</w:rPr><w:rPr>', '')).join()}</w:hyperlink>');
      } else {
        out.writeAll(segs);
      }
    }
  }

  String runs(List<MdRun> list, {bool bold = false}) {
    final out = <String>[];
    int? commentFrom; // where the text the next comment is on starts
    for (final r in list) {
      if (r.comment) {
        final id = comments.length;
        comments.add(r.text);
        final from = '<w:commentRangeStart w:id="$id"/>';
        commentFrom == null ? out.add(from) : out.insert(commentFrom, from);
        out.add('<w:commentRangeEnd w:id="$id"/><w:r><w:rPr><w:rStyle w:val="CommentReference"/></w:rPr><w:commentReference w:id="$id"/></w:r>');
        commentFrom = null;
        continue;
      }
      if (r.commented) {
        commentFrom ??= out.length;
      } else {
        commentFrom = null;
      }
      final piece = StringBuffer();
      docxRunInto(r, piece, bold);
      out.add(tracked(r, piece.toString()));
    }
    return out.join();
  }

  String pPr(MdBlock b, {String? style, String extra = ''}) {
    final f = b.format;
    final p = StringBuffer();
    if (style != null) p.write('<w:pStyle w:val="$style"/>');
    p.write(extra);
    if (f.spacing != 1.0) p.write('<w:spacing w:line="${(360 * f.spacing).round()}" w:lineRule="auto"/>');
    if (f.indent > 0) p.write('<w:ind w:left="${twips(f.indent * 32)}"/>');
    if (f.align != 'left') p.write('<w:jc w:val="${f.align == 'justify' ? 'both' : f.align}"/>');
    return p.isEmpty ? '' : '<w:pPr>$p</w:pPr>';
  }

  final body = StringBuffer();
  final nums = <String>[]; // the numbered lists, each counting from its own start
  var inNumbered = false;
  for (final b in blocks) {
    if (b.type != MdBlockType.numbered) inNumbered = false;
    switch (b.type) {
      case MdBlockType.setting || MdBlockType.footnote:
        break;
      case MdBlockType.heading:
        body.write('<w:p>${pPr(b, style: 'Heading${b.level}')}${runs(b.runs)}</w:p>');
      case MdBlockType.paragraph:
        body.write('<w:p>${pPr(b)}${runs(b.runs)}</w:p>');
      case MdBlockType.caption:
        body.write('<w:p>${pPr(b, style: 'Caption')}${runXml(t(captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table'))), bold: true)}${runs(b.runs)}</w:p>');
      case MdBlockType.bullet:
        body.write('<w:p>${pPr(b, style: 'ListParagraph', extra: '<w:numPr><w:ilvl w:val="${b.depth.clamp(0, 8)}"/><w:numId w:val="1"/></w:numPr>')}${runs(b.runs)}</w:p>');
      case MdBlockType.numbered:
        if (!inNumbered) {
          nums.add('<w:num w:numId="${nums.length + 2}"><w:abstractNumId w:val="2"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="${b.level}"/></w:lvlOverride></w:num>');
          inNumbered = true;
        }
        body.write('<w:p>${pPr(b, style: 'ListParagraph', extra: '<w:numPr><w:ilvl w:val="${b.depth.clamp(0, 8)}"/><w:numId w:val="${nums.length + 1}"/></w:numPr>')}${runs(b.runs)}</w:p>');
      case MdBlockType.task:
        body.write('<w:p>${pPr(b, extra: b.depth > 0 ? '<w:ind w:left="${twips(b.depth * 24.0)}"/>' : '')}${runXml(t(b.checked ? '☒ ' : '☐ '))}${runs(b.runs)}</w:p>');
      case MdBlockType.quote:
        body.write('<w:p>${pPr(b, style: 'Quote')}${runs(b.runs)}</w:p>');
      case MdBlockType.rule:
        body.write('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="AAAAAA"/></w:pBdr></w:pPr></w:p>');
      case MdBlockType.pageBreak:
        body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      case MdBlockType.math:
        body.write('<w:p><w:pPr><w:jc w:val="center"/></w:pPr>${runXml(t(b.runs.single.text), italic: true)}</w:p>');
      case MdBlockType.code:
        for (final line in b.code.split('\n')) {
          body.write('<w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr>${runXml(t(line))}</w:p>');
        }
      case MdBlockType.table:
        final cols = b.rows.isEmpty ? 1 : b.rows.first.length;
        final cw = twips(pages.textWidth) ~/ cols;
        body.write('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/>'
            '<w:tblBorders>${['top', 'left', 'bottom', 'right', 'insideH', 'insideV'].map((e) => '<w:$e w:val="single" w:sz="4" w:space="0" w:color="999999"/>').join()}</w:tblBorders>'
            '</w:tblPr><w:tblGrid>${'<w:gridCol w:w="$cw"/>' * cols}</w:tblGrid>');
        for (var r = 0; r < b.rows.length; r++) {
          body.write('<w:tr>');
          for (var c = 0; c < b.rows[r].length; c++) {
            final align = c < b.aligns.length ? b.aligns[c] : '';
            body.write('<w:tc><w:tcPr><w:tcW w:w="$cw" w:type="dxa"/>${r == 0 ? '<w:shd w:val="clear" w:color="auto" w:fill="EEEEEE"/>' : ''}</w:tcPr>'
                '<w:p>${align.isEmpty || align == 'left' ? '' : '<w:pPr><w:jc w:val="$align"/></w:pPr>'}${runs(b.rows[r][c], bold: r == 0)}</w:p></w:tc>');
          }
          body.write('</w:tr>');
        }
        body.write('</w:tbl><w:p/>');
      case MdBlockType.toc:
        body.write('<w:p><w:pPr><w:pStyle w:val="TOCHeading"/></w:pPr>${runXml(t(tr('Contents')))}</w:p>'
            '<w:p><w:fldSimple w:instr=" TOC \\o &quot;1-6&quot; \\h \\z \\u "><w:r><w:t>${_x(tr('The table of contents is filled in when the file is opened.'))}</w:t></w:r></w:fldSimple></w:p>');
      case MdBlockType.bibliography:
        if (citations != null && citations.cited.isNotEmpty) {
          body.write('<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>${runXml(t(tr('References')))}</w:p>');
          for (final e in citations.bibliography()) {
            body.write('<w:p><w:pPr><w:ind w:left="720" w:hanging="720"/></w:pPr>${runXml(t(e))}</w:p>');
          }
        }
    }
  }
  // the list of sources under the text when the text has no place of its own for it
  if (citations != null && citations.cited.isNotEmpty && !blocks.any((b) => b.type == MdBlockType.bibliography)) {
    body.write('<w:p/><w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>${runXml(t(tr('References')))}</w:p>');
    for (final e in citations.bibliography()) {
      body.write('<w:p><w:pPr><w:ind w:left="720" w:hanging="720"/></w:pPr>${runXml(t(e))}</w:p>');
    }
  }

  // footnotes: Word's own, numbered by Word in the order they are referred to (as they are here)
  final footnoteXml = StringBuffer();
  for (final b in blocks) {
    if (b.type != MdBlockType.footnote) continue;
    final n = notes[b.label];
    if (n == null) continue;
    footnoteXml.write('<w:footnote w:id="$n"><w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>'
        '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>${runXml(t(' '))}${runs(b.runs)}</w:p></w:footnote>');
  }

  // the header and the footer, `{page}` and `{pages}` as Word's page fields
  String edgeXml(String tag, String template) {
    final filled = fillPageText(template, pages);
    final parts = filled.split(RegExp(r'(?=\{page\})|(?<=\{page\})|(?=\{pages\})|(?<=\{pages\})'));
    final inner = parts.map((p) => switch (p) {
          '{page}' => '<w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t></w:r></w:fldSimple>',
          '{pages}' => '<w:fldSimple w:instr=" NUMPAGES "><w:r><w:t>1</w:t></w:r></w:fldSimple>',
          _ => p.isEmpty ? '' : runXml(t(p)),
        });
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:$tag $_wordNamespaces><w:p><w:pPr><w:jc w:val="center"/></w:pPr>${inner.join()}</w:p></w:$tag>';
  }

  final edges = <String, String>{};
  final sectRefs = StringBuffer();
  for (final (key, tag) in const [('header', 'hdr'), ('footer', 'ftr')]) {
    final template = settings[key];
    if (template == null || template.trim().isEmpty) continue;
    final name = '${key}1.xml';
    edges[name] = edgeXml(tag, template);
    final id = rel(key, name);
    sectRefs.write('<w:${key}Reference w:type="default" r:id="$id"/>');
  }

  if (comments.isNotEmpty) rel('comments', 'comments.xml');
  final pageW = twips(pages.width), pageH = twips(pages.height);
  final columns = (int.tryParse(settings['columns']?.trim() ?? '') ?? 1).clamp(1, 4);
  final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document $_wordNamespaces><w:body>$body'
      '<w:sectPr>$sectRefs${columns > 1 ? '<w:cols w:num="$columns" w:space="720"/>' : ''}<w:pgSz w:w="$pageW" w:h="$pageH"${pages.landscape ? ' w:orient="landscape"' : ''}/>'
      '<w:pgMar w:top="${twips(pages.marginTop)}" w:right="${twips(pages.marginRight)}" w:bottom="${twips(pages.marginBottom)}" '
      'w:left="${twips(pages.marginLeft)}" w:header="${twips(pages.marginTop / 2)}" w:footer="${twips(pages.marginBottom / 2)}" w:gutter="0"/>'
      '</w:sectPr></w:body></w:document>';

  final archive = Archive();
  void add(String name, String content) => archive.add(ArchiveFile.bytes(name, utf8.encode(content)));
  add('[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
      '<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>'
      '<Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>'
      '${comments.isNotEmpty ? '<Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>' : ''}'
      '${edges.containsKey('header1.xml') ? '<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>' : ''}'
      '${edges.containsKey('footer1.xml') ? '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>' : ''}'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '</Types>');
  add('_rels/.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '</Relationships>');
  add('docProps/core.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>${_x(pages.title)}</dc:title></cp:coreProperties>');
  add('word/_rels/document.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>'
      '<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>'
      '${rels.join()}</Relationships>');
  add('word/document.xml', document);
  add('word/styles.xml', _wordStylesWith(documentStyles(blocks)));
  add('word/numbering.xml', _wordNumbering(nums));
  add('word/settings.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:settings $_wordNamespaces><w:updateFields w:val="true"/>'
      '<w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr></w:settings>');
  add('word/footnotes.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:footnotes $_wordNamespaces>'
      '<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>'
      '<w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>'
      '$footnoteXml</w:footnotes>');
  for (final e in edges.entries) {
    add('word/${e.key}', e.value);
  }
  if (comments.isNotEmpty) {
    add('word/comments.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:comments $_wordNamespaces>'
        '${[for (var i = 0; i < comments.length; i++) '<w:comment w:id="$i" w:author="Notation" w:initials="UN" w:date="$stamp"><w:p><w:r><w:t xml:space="preserve">${_x(comments[i])}</w:t></w:r></w:p></w:comment>'].join()}'
        '</w:comments>');
  }
  for (final m in media.entries) {
    archive.add(ArchiveFile.bytes('word/media/${m.key}', m.value));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

const _wordNamespaces = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"';

String _wordNumbering(List<String> nums) {
  const bullets = ['•', '◦', '▪'];
  String levels(bool numbered) => [
        for (var l = 0; l < 9; l++)
          '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="${numbered ? 'decimal' : 'bullet'}"/>'
              '<w:lvlText w:val="${numbered ? '%${l + 1}.' : bullets[l % 3]}"/><w:lvlJc w:val="left"/>'
              '<w:pPr><w:ind w:left="${720 * (l + 1)}" w:hanging="360"/></w:pPr></w:lvl>',
      ].join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering $_wordNamespaces>'
      '<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>${levels(false)}</w:abstractNum>'
      '<w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="hybridMultilevel"/>${levels(true)}</w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>${nums.join()}</w:numbering>';
}

/// The styles of the Word document, with the document's named styles in place of the usual looks.
String _wordStylesWith(Map<String, NamedStyle> named) {
  var xml = _wordStyles;
  String rPr(NamedStyle s, {required bool bold, required int half}) {
    final font = s.font == null ? '' : '<w:rFonts w:ascii="${_x(_wordFont(s.font!))}" w:hAnsi="${_x(_wordFont(s.font!))}" w:cs="${_x(_wordFont(s.font!))}"/>';
    final size = s.size == null ? half : (s.size! * 2).round();
    final color = s.color == null ? '' : '<w:color w:val="${_wordHex(s.color!)}"/>';
    return '<w:rPr>$font${bold ? '<w:b/>' : ''}$color<w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr>';
  }

  final body = named['body'];
  if (body != null && !body.isEmpty) {
    xml = xml.replaceFirst('<w:name w:val="Normal"/><w:qFormat/></w:style>',
        '<w:name w:val="Normal"/><w:qFormat/>${rPr(body, bold: false, half: (documentPointSize * 2).round())}</w:style>');
  }
  for (var level = 1; level <= 6; level++) {
    final s = named['h$level'];
    if (s == null || s.isEmpty) continue;
    final half = (documentPointSize * 2 * headingScale(level)).round();
    xml = xml.replaceFirst('<w:rPr><w:b/><w:sz w:val="$half"/><w:szCs w:val="$half"/></w:rPr></w:style>',
        '${rPr(s, bold: true, half: half)}</w:style>');
  }
  return xml;
}

final String _wordStyles = () {
  String heading(int level) {
    final half = (documentPointSize * 2 * headingScale(level)).round();
    return '<w:style w:type="paragraph" w:styleId="Heading$level"><w:name w:val="heading $level"/><w:basedOn w:val="Normal"/>'
        '<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="120" w:after="60"/><w:outlineLvl w:val="${level - 1}"/></w:pPr>'
        '<w:rPr><w:b/><w:sz w:val="$half"/><w:szCs w:val="$half"/></w:rPr></w:style>';
  }

  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles $_wordNamespaces>'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial" w:eastAsia="Arial"/>'
      '<w:sz w:val="${(documentPointSize * 2).round()}"/><w:szCs w:val="${(documentPointSize * 2).round()}"/></w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
      '${[for (var l = 1; l <= 6; l++) heading(l)].join()}'
      '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="BBBBBB"/></w:pBdr><w:ind w:left="360"/></w:pPr>'
      '<w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/><w:spacing w:line="240" w:lineRule="auto"/></w:pPr>'
      '<w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/></w:style>'
      '<w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Heading1"/><w:next w:val="Normal"/></w:style>'
      '<w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="20"/></w:rPr></w:style>'
      '<w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:i/><w:sz w:val="20"/></w:rPr></w:style>'
      '<w:style w:type="character" w:styleId="CommentReference"><w:name w:val="annotation reference"/><w:rPr><w:sz w:val="16"/></w:rPr></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>'
      '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/></w:style>'
      '</w:styles>';
}();
