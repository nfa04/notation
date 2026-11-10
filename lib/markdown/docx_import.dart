import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive;
import 'package:xml/xml.dart';

import '../data/safe_zip.dart';
import '../models/rich_text.dart';
import 'markdown_parser.dart';
import 'markdown_writer.dart';

/// A Word document (.docx) read into the written document: its text as the document's Markdown (headings, lists, quotes, tables,
/// links, footnotes, page breaks, the header and footer, a table of contents as `[toc]`), bold, italic and strikethrough as Markdown,
/// and the fonts, sizes, colours, highlights, underlines and raised or lowered text as [spans].
class DocxImport {
  final String text;
  final List<TextSpanAttribute> spans;
  const DocxImport(this.text, this.spans);
}

/// Reads the Word document in [bytes]. [keepPicture] keeps a picture of it (its bytes and type) and gives the target to write for
/// it (null: the picture is left out). Throws a [FormatException] when [bytes] is no Word document.
Future<DocxImport> importDocx(Uint8List bytes, {Future<String?> Function(Uint8List bytes, String ext)? keepPicture}) async {
  final Archive zip;
  try {
    zip = decodeZipLimited(bytes);
  } on ArchiveTooBigException {
    throw const FormatException('This Word document is too big to read.');
  } catch (_) {
    throw const FormatException('This is not a Word document (.docx).');
  }
  XmlDocument? part(String name) {
    final f = zip.findFile(name);
    if (f == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(f.content as List<int>, allowMalformed: true));
    } on XmlException {
      return null;
    }
  }

  final document = part('word/document.xml');
  if (document == null) throw const FormatException('This is not a Word document (.docx).');
  final reader = _DocxReader(
    rels: _relationships(part('word/_rels/document.xml.rels')),
    styles: _styles(part('word/styles.xml')),
    numbering: _numbering(part('word/numbering.xml')),
    zip: zip,
    keepPicture: keepPicture,
  );
  final notes = <String, XmlElement>{
    for (final f in part('word/footnotes.xml')?.rootElement.childElements ?? const <XmlElement>[])
      if (f.name.local == 'footnote' && f.getAttribute('w:type') == null) ?f.getAttribute('w:id'): f,
  };
  reader.footnotes = notes;
  reader.comments = {
    for (final c in part('word/comments.xml')?.rootElement.childElements ?? const <XmlElement>[])
      if (c.name.local == 'comment')
        ?c.getAttribute('w:id'): c.findAllElements('w:t').map((t) => t.innerText).join(),
  };

  final body = document.rootElement.childElements.where((e) => e.name.local == 'body').firstOrNull;
  // header and footer of the (first) section
  final sect = body?.childElements.where((e) => e.name.local == 'sectPr').firstOrNull;
  for (final ref in sect?.childElements ?? const <XmlElement>[]) {
    final kind = ref.name.local == 'headerReference' ? 'header' : (ref.name.local == 'footerReference' ? 'footer' : null);
    if (kind == null || (ref.getAttribute('w:type') ?? 'default') != 'default') continue;
    final target = reader.rels[ref.getAttribute('r:id')];
    final xml = target == null ? null : part('word/${target.replaceFirst(RegExp(r'^/?word/'), '')}');
    if (xml == null) continue;
    final line = await reader.plainOf(xml.rootElement);
    if (line.trim().isNotEmpty) reader.settings[kind] = line.trim();
  }
  for (final e in body?.childElements ?? const <XmlElement>[]) {
    if (e.name.local == 'p') {
      await reader.paragraph(e);
    } else if (e.name.local == 'tbl') {
      await reader.table(e);
    } else if (e.name.local == 'sdt') {
      // a content control: a table of contents Word made is one
      final content = e.childElements.where((c) => c.name.local == 'sdtContent').firstOrNull;
      final isToc = e.findAllElements('w:docPartGallery').any((g) => (g.getAttribute('w:val') ?? '').contains('Table of Contents'));
      if (isToc) {
        reader.line('[toc]');
      } else {
        for (final c in content?.childElements ?? const <XmlElement>[]) {
          if (c.name.local == 'p') await reader.paragraph(c);
          if (c.name.local == 'tbl') await reader.table(c);
        }
      }
    }
  }
  // the footnotes the text refers to, after it
  final used = reader.usedNotes;
  if (used.isNotEmpty && !reader.out.toString().endsWith('\n\n')) reader.line('');
  for (final id in used) {
    final note = notes[id];
    if (note == null) continue;
    reader.lineStart('[^$id]: ');
    var first = true;
    for (final p in note.childElements.where((c) => c.name.local == 'p')) {
      if (!first) reader.write(' ');
      first = false;
      await reader.runsOf(p, footnote: true);
    }
    reader.endLine();
  }
  final head = [
    for (final e in reader.settings.entries) '[${e.key}]: ${e.value}',
  ];
  var text = reader.out.toString();
  if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
  if (head.isEmpty) return DocxImport(text, reader.spans);
  final prefix = '${head.join('\n')}\n\n';
  return DocxImport('$prefix$text', [for (final s in reader.spans) s.moved(s.start + prefix.length, s.end + prefix.length)]);
}

Map<String, String> _relationships(XmlDocument? xml) => {
      for (final r in xml?.rootElement.childElements ?? const <XmlElement>[])
        ?r.getAttribute('Id'): r.getAttribute('Target') ?? '',
    };

/// What each paragraph style is here: a heading level (1-6), `quote`, `code`, `title`.
Map<String, String> _styles(XmlDocument? xml) {
  final out = <String, String>{};
  for (final s in xml?.rootElement.childElements ?? const <XmlElement>[]) {
    if (s.name.local != 'style') continue;
    final id = s.getAttribute('w:styleId');
    if (id == null) continue;
    final name = (s.childElements.where((c) => c.name.local == 'name').firstOrNull?.getAttribute('w:val') ?? id).toLowerCase();
    final heading = RegExp(r'^heading ?([1-6])$').firstMatch(name);
    final outline = s.findAllElements('w:outlineLvl').firstOrNull?.getAttribute('w:val');
    if (heading != null) {
      out[id] = heading.group(1)!;
    } else if (name == 'title') {
      out[id] = '1';
    } else if (name == 'subtitle') {
      out[id] = '2';
    } else if (name.contains('quote')) {
      out[id] = 'quote';
    } else if (name.contains('code') || name.contains('source') || name == 'html preformatted') {
      out[id] = 'code';
    } else if (int.tryParse(outline ?? '') case final l? when l < 6) {
      out[id] = '${l + 1}';
    }
  }
  return out;
}

/// For each list (`numId`) and level: whether it is numbered (else it has bullets).
Map<String, Map<int, bool>> _numbering(XmlDocument? xml) {
  final abstract = <String, Map<int, bool>>{};
  final root = xml?.rootElement;
  for (final a in root?.childElements ?? const <XmlElement>[]) {
    if (a.name.local != 'abstractNum') continue;
    abstract[a.getAttribute('w:abstractNumId') ?? ''] = {
      for (final l in a.childElements.where((c) => c.name.local == 'lvl'))
        int.tryParse(l.getAttribute('w:ilvl') ?? '') ?? 0:
            (l.childElements.where((c) => c.name.local == 'numFmt').firstOrNull?.getAttribute('w:val') ?? 'bullet') != 'bullet',
    };
  }
  return {
    for (final n in root?.childElements ?? const <XmlElement>[])
      if (n.name.local == 'num')
        n.getAttribute('w:numId') ?? '':
            abstract[n.childElements.where((c) => c.name.local == 'abstractNumId').firstOrNull?.getAttribute('w:val')] ?? const {},
  };
}

String? _val(XmlElement? e) => e?.getAttribute('w:val');
XmlElement? _child(XmlElement? e, String local) => e?.childElements.where((c) => c.name.local == local).firstOrNull;

/// Whether a toggle like `<w:b/>` is on (`w:val="0"` or `false` is off).
bool _on(XmlElement? e) => e != null && !const ['0', 'false', 'off'].contains(_val(e));

/// The font of [documentFonts] closest to a Word font (null: the usual one).
String? _fontOf(String? word) {
  if (word == null) return null;
  final w = word.toLowerCase();
  if (RegExp('courier|consolas|mono|menlo|lucida console|source code').hasMatch(w)) return 'Mono';
  if (RegExp('times|georgia|cambria|garamond|serif|book antiqua|palatino|minion|baskerville').hasMatch(w) && !w.contains('sans')) return 'Serif';
  if (w.contains('dejavu')) return 'DejaVu Sans';
  return null;
}

const _highlights = {
  'yellow': '#FFF176', 'green': '#A5D6A7', 'cyan': '#80DEEA', 'magenta': '#F48FB1', 'blue': '#90CAF9', 'red': '#EF9A9A',
  'darkYellow': '#FFCC80', 'lightGray': '#E0E0E0', 'darkGray': '#BDBDBD',
};

class _DocxReader {
  final Map<String, String> rels;
  final Map<String, String> styles;
  final Map<String, Map<int, bool>> numbering;
  final Archive zip;
  final Future<String?> Function(Uint8List bytes, String ext)? keepPicture;
  Map<String, XmlElement> footnotes = const {};

  /// What each comment says, by its id.
  Map<String, String> comments = const {};

  final out = StringBuffer();
  final spans = <TextSpanAttribute>[];
  final settings = <String, String>{};
  final usedNotes = <String>[];
  final Map<String, List<int>> _counters = {}; // per list: the number of each level

  _DocxReader({required this.rels, required this.styles, required this.numbering, required this.zip, this.keepPicture});

  void write(String s) => out.write(s);
  void lineStart(String prefix) => out.write(prefix);
  void endLine() => out.write('\n');
  void line(String s) => out.write('$s\n');

  bool _inCode = false;

  Future<void> paragraph(XmlElement p) async {
    final pPr = _child(p, 'pPr');
    final style = styles[_val(_child(pPr, 'pStyle'))];
    if (style == 'code') {
      if (!_inCode) line('```');
      _inCode = true;
      line(await plainOf(p));
      return;
    }
    if (_inCode) {
      line('```');
      _inCode = false;
    }
    // the layout of the paragraph
    final jc = _val(_child(pPr, 'jc'));
    final align = switch (jc) { 'center' => 'center', 'right' || 'end' => 'right', 'both' || 'distribute' => 'justify', _ => 'left' };
    final numPr = _child(pPr, 'numPr');
    final ind = _child(pPr, 'ind');
    final left = int.tryParse(ind?.getAttribute('w:left') ?? ind?.getAttribute('w:start') ?? '') ?? 0;
    final indent = numPr == null ? (left / 720).round().clamp(0, 8) : 0;
    final line_ = int.tryParse(_child(pPr, 'spacing')?.getAttribute('w:line') ?? '');
    final rule = _child(pPr, 'spacing')?.getAttribute('w:lineRule') ?? 'auto';
    // (the document's usual line is Word's 1.5 lines, 360)
    var spacing = 1.0;
    if (line_ != null && rule == 'auto' && line_ > 380) spacing = (line_ / 360 * 20).round() / 20;
    final format = ParagraphFormat(align: align, indent: indent, spacing: spacing > 4 ? 4 : spacing);
    // what kind of paragraph
    var prefix = '';
    final level = int.tryParse(style ?? '');
    if (level != null) {
      prefix = '${'#' * level} ';
    } else if (style == 'quote') {
      prefix = '> ';
    } else if (numPr != null) {
      final id = _val(_child(numPr, 'numId')) ?? '';
      final ilvl = int.tryParse(_val(_child(numPr, 'ilvl')) ?? '') ?? 0;
      if (id != '0') {
        final numbered = numbering[id]?[ilvl] ?? false;
        final counts = _counters.putIfAbsent(id, () => List.filled(9, 0));
        final l = ilvl.clamp(0, 8);
        counts[l]++;
        for (var k = l + 1; k < 9; k++) {
          counts[k] = 0;
        }
        prefix = '${'  ' * l}${numbered ? '${counts[l]}.' : '-'} ';
      }
    }
    final start = out.length;
    write(format.token);
    write(prefix);
    final before = out.length;
    final broke = await runsOf(p);
    // a paragraph of only a page break is a page break of its own
    if (broke && out.length == before) {
      final s = out.toString().substring(0, start);
      out
        ..clear()
        ..write(s);
      line('\\pagebreak');
      return;
    }
    endLine();
    if (broke) line('\\pagebreak');
  }

  Future<void> table(XmlElement tbl) async {
    if (_inCode) {
      line('```');
      _inCode = false;
    }
    final rows = <List<String>>[];
    for (final tr in tbl.childElements.where((e) => e.name.local == 'tr')) {
      rows.add([
        for (final tc in tr.childElements.where((e) => e.name.local == 'tc'))
          (await Future.wait(tc.childElements.where((e) => e.name.local == 'p').map(plainOf))).join(' ').trim().replaceAll('|', r'\|'),
      ]);
    }
    if (rows.isEmpty) return;
    final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    for (final r in rows) {
      while (r.length < width) {
        r.add('');
      }
    }
    line('| ${rows.first.join(' | ')} |');
    line('|${List.filled(width, '---').join('|')}|');
    for (final r in rows.skip(1)) {
      line('| ${r.join(' | ')} |');
    }
  }

  /// The text of [e] without formatting (fields as `{page}`, `{pages}`).
  Future<String> plainOf(XmlElement e) async {
    final b = StringBuffer();
    var field = '';
    var skipping = false;
    for (final x in e.descendantElements) {
      switch (x.name.local) {
        case 't' when !skipping:
          b.write(x.innerText);
        case 'tab' when !skipping:
          b.write('\t');
        case 'p' when b.isNotEmpty && e.name.local != 'p':
          b.write(' ');
        case 'fldSimple':
          final instr = (x.getAttribute('w:instr') ?? '').trim().split(RegExp(r'\s+')).first.toUpperCase();
          if (instr == 'PAGE') b.write('{page}');
          if (instr == 'NUMPAGES') b.write('{pages}');
        case 'fldChar':
          final kind = x.getAttribute('w:fldCharType');
          if (kind == 'begin') field = '';
          if (kind == 'separate') {
            final instr = field.trim().split(RegExp(r'\s+')).first.toUpperCase();
            if (instr == 'PAGE' || instr == 'NUMPAGES') {
              b.write(instr == 'PAGE' ? '{page}' : '{pages}');
              skipping = true;
            }
          }
          if (kind == 'end') skipping = false;
        case 'instrText':
          field += x.innerText;
      }
    }
    // (the text of a simple field is its last shown value: written once only)
    return b.toString().replaceAll(RegExp(r'\{page\}\d+'), '{page}').replaceAll(RegExp(r'\{pages\}\d+'), '{pages}');
  }

  /// Writes the runs of [p] (in links and fields too). True when it has a page break.
  Future<bool> runsOf(XmlElement p, {bool footnote = false}) async {
    final pieces = <MdPiece>[];
    var broke = false;
    var skipping = false;
    var field = '';

    Future<void> walk(XmlElement parent, {String? link, bool ins = false, bool del = false}) async {
      MdPiece mark(MdPiece p) => ins || del
          ? (p is MdLinkPiece
              ? MdLinkPiece(MdPiece(p.text, bold: p.bold, italic: p.italic, strike: p.strike, inserted: ins, deleted: del, attrs: p.attrs), p.link)
              : MdPiece(p.text, bold: p.bold, italic: p.italic, strike: p.strike, inserted: ins, deleted: del, attrs: p.attrs))
          : p;
      for (final e in parent.childElements) {
        switch (e.name.local) {
          case 'r':
            final rPr = _child(e, 'rPr');
            for (final c in e.childElements) {
              switch (c.name.local) {
                case 'fldChar':
                  final kind = c.getAttribute('w:fldCharType');
                  if (kind == 'begin') field = '';
                  if (kind == 'separate') {
                    final instr = field.trim().split(RegExp(r'\s+')).first.toUpperCase();
                    if (instr == 'TOC') {
                      skipping = true;
                      pieces.add(MdPiece('\u0000toc'));
                    } else if (instr == 'PAGE' || instr == 'NUMPAGES') {
                      pieces.add(MdPiece(instr == 'PAGE' ? '{page}' : '{pages}'));
                      skipping = true;
                    }
                  }
                  if (kind == 'end') skipping = false;
                case 'instrText':
                  field += c.innerText;
                case 't' || 'delText' when !skipping:
                  pieces.add(mark(_pieceOf(c.innerText, rPr, link: link)));
                case 'commentReference':
                  final said = comments[c.getAttribute('w:id')];
                  if (said != null && said.trim().isNotEmpty) pieces.add(MdPiece('{>>${said.trim().replaceAll('<<}', '<< }')}<<}'));
                case 'tab' when !skipping:
                  pieces.add(_pieceOf('\t', rPr));
                case 'br' when !skipping:
                  if (c.getAttribute('w:type') == 'page') {
                    broke = true;
                  } else {
                    pieces.add(_pieceOf(' ', rPr));
                  }
                case 'footnoteReference' when !footnote:
                  final id = c.getAttribute('w:id');
                  if (id != null && footnotes.containsKey(id)) {
                    if (!usedNotes.contains(id)) usedNotes.add(id);
                    pieces.add(MdPiece('[^$id]'));
                  }
                case 'drawing' || 'pict' when !skipping:
                  final blip = c.findAllElements('a:blip').firstOrNull ?? c.findAllElements('v:imagedata').firstOrNull;
                  final id = blip?.getAttribute('r:embed') ?? blip?.getAttribute('r:id');
                  final target = id == null ? null : rels[id];
                  final extent = c.findAllElements('wp:extent').firstOrNull;
                  final cx = int.tryParse(extent?.getAttribute('cx') ?? '');
                  final file = target == null ? null : zip.findFile('word/${target.replaceFirst(RegExp(r'^/?word/'), '')}');
                  if (file != null && keepPicture != null) {
                    final ext = target!.split('.').last.toLowerCase();
                    final kept = await keepPicture!(Uint8List.fromList(file.content as List<int>), ext == 'jpg' ? 'jpeg' : ext);
                    if (kept != null) {
                      final alt = c.findAllElements('wp:docPr').firstOrNull?.getAttribute('descr') ?? '';
                      // EMU -> page units (an A4 page is 800 across its 210 mm)
                      final width = cx == null ? null : (cx / 36000 / (210 / 800)).round();
                      pieces.add(MdPiece('![${alt.replaceAll(RegExp(r'[\[\]|]'), '')}${width == null ? '' : '|$width'}]($kept)'));
                    }
                  }
              }
            }
          case 'hyperlink':
            final target = rels[e.getAttribute('r:id')];
            await walk(e, link: target, ins: ins, del: del);
          case 'ins':
            await walk(e, link: link, ins: true, del: del);
          case 'del':
            await walk(e, link: link, ins: ins, del: true);
          case 'commentRangeStart' when comments.containsKey(e.getAttribute('w:id')):
            pieces.add(MdPiece('{=='));
          case 'commentRangeEnd' when comments.containsKey(e.getAttribute('w:id')):
            pieces.add(MdPiece('==}'));
          case 'fldSimple':
            final instr = (e.getAttribute('w:instr') ?? '').trim().split(RegExp(r'\s+'));
            final name = instr.first.toUpperCase();
            if (name == 'TOC') {
              pieces.add(MdPiece('\u0000toc'));
            } else if (name == 'PAGE') {
              pieces.add(MdPiece('{page}'));
            } else if (name == 'NUMPAGES') {
              pieces.add(MdPiece('{pages}'));
            } else if (name == 'HYPERLINK' && instr.length > 1) {
              await walk(e, link: instr[1].replaceAll('"', ''));
            } else {
              await walk(e);
            }
          case 'smartTag' || 'customXml' || 'sdt' || 'sdtContent':
            await walk(e, link: link, ins: ins, del: del);
        }
      }
    }

    await walk(p);
    // (a footnote's text starts after the space Word puts after its number)
    if (footnote && out.toString().endsWith(': ')) {
      while (pieces.isNotEmpty && pieces.first.text.trim().isEmpty) {
        pieces.removeAt(0);
      }
      if (pieces.isNotEmpty) {
        final f = pieces.first;
        pieces[0] = f.withText(f.text.trimLeft());
      }
    }
    if (pieces.any((x) => x.text == '\u0000toc')) {
      write('[toc]');
      return broke;
    }
    _emit(pieces);
    return broke;
  }

  MdPiece _pieceOf(String text, XmlElement? rPr, {String? link}) {
    if (rPr == null && link == null) return MdPiece(text);
    final attrs = <AttributeType, String?>{};
    final font = _fontOf(_child(rPr, 'rFonts')?.getAttribute('w:ascii') ?? _child(rPr, 'rFonts')?.getAttribute('w:hAnsi'));
    if (font != null) attrs[AttributeType.font] = font;
    final sz = int.tryParse(_val(_child(rPr, 'sz')) ?? '');
    if (sz != null && sz != (documentPointSize * 2).round()) attrs[AttributeType.size] = '${(sz / 2).round()}';
    final color = _val(_child(rPr, 'color'));
    if (color != null && RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(color) && color != '000000') attrs[AttributeType.color] = '#${color.toUpperCase()}';
    final highlight = _highlights[_val(_child(rPr, 'highlight'))];
    final shd = _child(rPr, 'shd')?.getAttribute('w:fill');
    if (highlight != null) {
      attrs[AttributeType.highlight] = highlight;
    } else if (shd != null && RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(shd) && shd.toUpperCase() != 'FFFFFF') {
      attrs[AttributeType.highlight] = '#${shd.toUpperCase()}';
    }
    final u = _val(_child(rPr, 'u'));
    if (_child(rPr, 'u') != null && u != 'none' && link == null) attrs[AttributeType.underline] = null;
    final vert = _val(_child(rPr, 'vertAlign'));
    if (vert == 'superscript') attrs[AttributeType.superscript] = null;
    if (vert == 'subscript') attrs[AttributeType.subscript] = null;
    final piece = MdPiece(text,
        bold: _on(_child(rPr, 'b')), italic: _on(_child(rPr, 'i')), strike: _on(_child(rPr, 'strike')) || _on(_child(rPr, 'dstrike')), attrs: attrs);
    return link == null ? piece : MdLinkPiece(piece, link);
  }

  void _emit(List<MdPiece> pieces) => emitPieces(pieces, out, spans);

}

