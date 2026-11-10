import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/rich_text.dart';
import 'docx_import.dart' show DocxImport;
import 'markdown_parser.dart';
import 'markdown_writer.dart';

/// Formatted text from a web page or another program (the HTML it puts on the clipboard) as the written document's Markdown and
/// formatting: headings, paragraphs and their alignment, lists, quotes, code, tables, links, pictures on the web, rules; bold,
/// italic, strikethrough as Markdown; fonts, sizes, colours, highlights, underline, raised and lowered text as spans.
DocxImport importHtml(String html) {
  final doc = html_parser.parse(html);
  final w = _HtmlWriter();
  w.blocks(doc.body ?? doc.documentElement!);
  w.endParagraph();
  var text = w.out.toString();
  // (no more than one empty line in a row, none at the ends)
  final spans = w.spans;
  while (text.endsWith('\n')) {
    text = text.substring(0, text.length - 1);
  }
  var lead = 0;
  while (lead < text.length && text[lead] == '\n') {
    lead++;
  }
  return DocxImport(text.substring(lead), [
    for (final s in spans)
      if (s.end - lead > 0 && s.start - lead < text.length - lead) s.moved((s.start - lead).clamp(0, text.length - lead), (s.end - lead).clamp(0, text.length - lead)),
  ]);
}

/// How text looks where it is in the page.
class _Look {
  final bool bold, italic, strike, code;
  final Map<AttributeType, String?> attrs;
  final String? link;
  const _Look({this.bold = false, this.italic = false, this.strike = false, this.code = false, this.attrs = const {}, this.link});

  _Look copyWith({bool? bold, bool? italic, bool? strike, bool? code, Map<AttributeType, String?>? attrs, String? link}) => _Look(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        strike: strike ?? this.strike,
        code: code ?? this.code,
        attrs: attrs ?? this.attrs,
        link: link ?? this.link,
      );
}

/// A CSS colour as `#RRGGBB` (null: none, or white/black/transparent that are only the usual look).
String? _cssColor(String? v, {bool background = false}) {
  if (v == null) return null;
  v = v.trim().toLowerCase();
  String? hex;
  final rgb = RegExp(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?').firstMatch(v);
  if (rgb != null) {
    if (rgb.group(4) != null && double.parse(rgb.group(4)!) == 0) return null;
    hex = [1, 2, 3].map((i) => int.parse(rgb.group(i)!).clamp(0, 255).toRadixString(16).padLeft(2, '0')).join();
  } else if (RegExp(r'^#[0-9a-f]{6}$').hasMatch(v)) {
    hex = v.substring(1);
  } else if (RegExp(r'^#[0-9a-f]{3}$').hasMatch(v)) {
    hex = v.substring(1).split('').map((c) => '$c$c').join();
  } else {
    hex = const {'red': 'ff0000', 'green': '008000', 'blue': '0000ff', 'yellow': 'ffff00', 'orange': 'ffa500', 'purple': '800080', 'gray': '808080', 'grey': '808080'}[v];
  }
  if (hex == null) return null;
  if (background ? hex == 'ffffff' : hex == '000000') return null;
  return '#${hex.toUpperCase()}';
}

/// The font of [documentFonts] closest to a CSS font family (null: the usual one).
String? _cssFont(String? v) {
  if (v == null) return null;
  final f = v.toLowerCase();
  if (RegExp('mono|courier|consolas|menlo').hasMatch(f)) return 'Mono';
  if (RegExp(r'times|georgia|garamond|cambria|(^|[\s,"])serif').hasMatch(f) && !f.startsWith('sans')) return 'Serif';
  return null;
}

/// A CSS font size in points (null: none, or the usual one).
String? _cssSize(String? v) {
  if (v == null) return null;
  final m = RegExp(r'([\d.]+)\s*(pt|px|em|rem|%)?').firstMatch(v.trim());
  if (m == null) return null;
  final n = double.tryParse(m.group(1)!);
  if (n == null) return null;
  final pt = switch (m.group(2)) { 'px' => n * 0.75, 'em' || 'rem' => n * documentPointSize, '%' => n / 100 * documentPointSize, _ => n };
  final round = pt.round();
  return (round - documentPointSize).abs() < 1 || round < 5 || round > 96 ? null : '$round';
}

Map<String, String> _styleOf(dom.Element e) => {
      for (final part in (e.attributes['style'] ?? '').split(';'))
        if (part.contains(':')) part.substring(0, part.indexOf(':')).trim().toLowerCase(): part.substring(part.indexOf(':') + 1).trim(),
    };

class _HtmlWriter {
  final out = StringBuffer();
  final spans = <TextSpanAttribute>[];
  final _pieces = <MdPiece>[];
  String _prefix = '';
  final _lists = <(bool numbered, int count)>[];

  /// Writes what is gathered as one paragraph.
  void endParagraph() {
    final hasText = _pieces.any((p) => p.text.trim().isNotEmpty);
    if (!hasText && _prefix.isEmpty) {
      _pieces.clear();
      return;
    }
    if (out.isNotEmpty && !out.toString().endsWith('\n')) out.write('\n');
    out.write(_prefix);
    // (white space in HTML is one space; none at the start of a paragraph)
    final cleaned = <MdPiece>[];
    for (final p in _pieces) {
      var t = p.text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
      if (cleaned.isEmpty || cleaned.last.text.endsWith(' ') || cleaned.last.text.endsWith('\n')) t = t.trimLeft();
      cleaned.add(p.withText(t));
    }
    if (cleaned.isNotEmpty) cleaned[cleaned.length - 1] = cleaned.last.withText(cleaned.last.text.trimRight());
    emitPieces(cleaned.where((p) => p.text.isNotEmpty).toList(), out, spans);
    out.write('\n');
    _pieces.clear();
    _prefix = '';
  }

  void line(String s) {
    endParagraph();
    out.write('$s\n');
  }

  void blocks(dom.Node node, {_Look look = const _Look()}) {
    for (final n in node.nodes) {
      if (n is dom.Text) {
        _pieces.add(_piece(n.text, look));
        continue;
      }
      if (n is! dom.Element) continue;
      final tag = n.localName ?? '';
      if (const {'script', 'style', 'head', 'title', 'meta', 'template', 'noscript'}.contains(tag)) continue;
      final css = _styleOf(n);
      var l = look;
      // the look of the text, from the tag and its style
      final weight = css['font-weight'];
      if (tag == 'b' || tag == 'strong' || weight == 'bold' || (int.tryParse(weight ?? '') ?? 0) >= 600) l = l.copyWith(bold: true);
      if (weight == 'normal' || weight == '400') l = l.copyWith(bold: false);
      if (tag == 'i' || tag == 'em' || css['font-style'] == 'italic') l = l.copyWith(italic: true);
      final deco = '${css['text-decoration'] ?? ''} ${css['text-decoration-line'] ?? ''}';
      if (tag == 's' || tag == 'strike' || tag == 'del' || deco.contains('line-through')) l = l.copyWith(strike: true);
      final attrs = Map.of(l.attrs);
      if (tag == 'u' || tag == 'ins' || deco.contains('underline')) attrs[AttributeType.underline] = null;
      if (tag == 'sup' || css['vertical-align'] == 'super') attrs[AttributeType.superscript] = null;
      if (tag == 'sub' || css['vertical-align'] == 'sub') attrs[AttributeType.subscript] = null;
      if (tag == 'mark') attrs[AttributeType.highlight] = '#FFF176';
      if (_cssColor(css['color']) case final c?) attrs[AttributeType.color] = c;
      if (_cssColor(css['background-color'] ?? css['background'], background: true) case final c?) attrs[AttributeType.highlight] = c;
      if (_cssFont(css['font-family']) case final f?) attrs[AttributeType.font] = f;
      if (_cssSize(css['font-size']) case final s?) attrs[AttributeType.size] = s;
      if (tag == 'font') {
        if (_cssColor(n.attributes['color']) case final c?) attrs[AttributeType.color] = c;
        if (_cssFont(n.attributes['face']) case final f?) attrs[AttributeType.font] = f;
      }
      l = l.copyWith(attrs: attrs);
      if (tag == 'code' || tag == 'kbd' || tag == 'samp') l = l.copyWith(code: true);

      switch (tag) {
        case 'br':
          if (_lists.isEmpty && !_prefix.startsWith('>')) {
            endParagraph();
          } else {
            _pieces.add(MdPiece(' '));
          }
        case 'hr':
          line('---');
        case 'img':
          final src = n.attributes['src'] ?? '';
          if (src.startsWith('http')) {
            final alt = (n.attributes['alt'] ?? '').replaceAll(RegExp(r'[\[\]|]'), '');
            final width = int.tryParse(n.attributes['width'] ?? '');
            _pieces.add(MdPiece('![$alt${width == null ? '' : '|$width'}]($src)'));
          }
        case 'a':
          final href = n.attributes['href'];
          blocks(n, look: href == null || href.startsWith('#') || href.startsWith('javascript:') ? l : l.copyWith(link: href));
        case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
          endParagraph();
          _prefix = '${_alignToken(css)}${'#' * int.parse(tag.substring(1))} ';
          blocks(n, look: l.copyWith(bold: false));
          endParagraph();
        case 'p' || 'div' || 'section' || 'article' || 'header' || 'footer' || 'main' || 'figure' || 'figcaption' || 'address' || 'dt' || 'dd':
          final inItem = _lists.isNotEmpty && _pieces.isEmpty && _prefix.isNotEmpty;
          if (!inItem) {
            endParagraph();
            _prefix = _alignToken(css);
          }
          blocks(n, look: l);
          if (!inItem) endParagraph();
        case 'blockquote':
          endParagraph();
          _prefix = '> ';
          blocks(n, look: l);
          endParagraph();
        case 'pre':
          endParagraph();
          out.write('```\n${n.text.replaceAll(RegExp(r'\n+$'), '')}\n```\n');
        case 'ul' || 'ol':
          endParagraph();
          _lists.add((tag == 'ol', int.tryParse(n.attributes['start'] ?? '') ?? 1));
          blocks(n, look: l);
          endParagraph();
          _lists.removeLast();
        case 'li':
          endParagraph();
          final depth = _lists.length - 1;
          final (numbered, count) = _lists.isEmpty ? (false, 1) : _lists.last;
          if (_lists.isNotEmpty) _lists[_lists.length - 1] = (numbered, count + 1);
          final checkbox = n.querySelector('input[type=checkbox]');
          _prefix = '${'  ' * (depth < 0 ? 0 : depth)}${numbered ? '$count.' : '-'} ${checkbox == null ? '' : (checkbox.attributes.containsKey('checked') ? '[x] ' : '[ ] ')}';
          blocks(n, look: l);
          endParagraph();
        case 'table':
          endParagraph();
          _table(n);
        case 'input':
          break;
        default:
          blocks(n, look: l);
      }
    }
  }

  String _alignToken(Map<String, String> css) {
    final f = ParagraphFormat(align: switch (css['text-align']) { 'center' => 'center', 'right' || 'end' => 'right', 'justify' => 'justify', _ => 'left' });
    return f.token;
  }

  MdPiece _piece(String text, _Look l) {
    final p = MdPiece(text, bold: l.bold, italic: l.italic, strike: l.strike, attrs: l.attrs);
    if (l.code && text.trim().isNotEmpty) return MdPiece('`${text.trim()}`');
    return l.link == null ? p : MdLinkPiece(p, l.link!);
  }

  void _table(dom.Element table) {
    final rows = <List<String>>[];
    for (final tr in table.querySelectorAll('tr')) {
      rows.add([for (final c in tr.children.where((c) => c.localName == 'td' || c.localName == 'th')) c.text.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll('|', r'\|')]);
    }
    rows.removeWhere((r) => r.isEmpty);
    if (rows.isEmpty) return;
    final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    for (final r in rows) {
      while (r.length < width) {
        r.add('');
      }
    }
    out.write('| ${rows.first.join(' | ')} |\n|${List.filled(width, ' --- ').join('|')}|\n');
    for (final r in rows.skip(1)) {
      out.write('| ${r.join(' | ')} |\n');
    }
  }
}
