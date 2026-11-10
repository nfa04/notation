import '../models/rich_text.dart';

/// Writing formatted text (read from a Word document or a web page) as the written document's Markdown: bold, italic,
/// strikethrough, a yellow highlight, superscript, subscript and tracked changes as Markdown around the text, the rest (fonts,
/// sizes, colours...) as [TextSpanAttribute]s.

/// A piece of text with its formatting, before it is written.
class MdPiece {
  final String text;
  final bool bold, italic, strike;

  /// A tracked change: put in, taken out.
  final bool inserted, deleted;
  final Map<AttributeType, String?> attrs;
  MdPiece(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.inserted = false,
    this.deleted = false,
    this.attrs = const {},
  });

  MdPiece withText(String t) => MdPiece(t, bold: bold, italic: italic, strike: strike, inserted: inserted, deleted: deleted, attrs: attrs);

  bool sameLook(MdPiece o) =>
      bold == o.bold &&
      italic == o.italic &&
      strike == o.strike &&
      inserted == o.inserted &&
      deleted == o.deleted &&
      attrs.length == o.attrs.length &&
      attrs.entries.every((e) => o.attrs.containsKey(e.key) && o.attrs[e.key] == e.value);
}

/// A piece that is Markdown of its own (a picture, a footnote's mark, a comment and its marks): written as it is, never joined.
bool isRawPiece(MdPiece p) =>
    p.text.startsWith('![') || p.text.startsWith('[^') || p.text.startsWith('{==') || p.text == '==}' || p.text.startsWith('{>>');

class MdLinkPiece extends MdPiece {
  final String link;
  MdLinkPiece(MdPiece p, this.link)
    : super(p.text, bold: p.bold, italic: p.italic, strike: p.strike, inserted: p.inserted, deleted: p.deleted, attrs: p.attrs);

  @override
  MdPiece withText(String t) => MdLinkPiece(super.withText(t), link);
}

/// The highlights that are the usual yellow, written `==like this==`.
const _yellows = {'#FFF176', '#FFFF00'};

/// Writes [pieces]: those that look alike joined, bold and the like as Markdown around them (the spaces at their edges outside
/// the marks), the rest as spans.
void emitPieces(List<MdPiece> pieces, StringBuffer out, List<TextSpanAttribute> spans) {
  void write(String s) => out.write(s);
  final merged = <MdPiece>[];
  for (final x in pieces) {
    final last = merged.lastOrNull;
    if (last != null && x is! MdLinkPiece && last is! MdLinkPiece && last.sameLook(x) && !isRawPiece(x) && !isRawPiece(last)) {
      merged[merged.length - 1] = last.withText(last.text + x.text);
    } else {
      merged.add(x);
    }
  }
  for (final x in merged) {
    var text = x.text;
    final lead = RegExp(r'^\s*').stringMatch(text)!;
    final trail = text.trim().isEmpty ? '' : RegExp(r'\s*$').stringMatch(text)!;
    text = text.substring(lead.length, text.length - trail.length);
    write(lead);
    if (text.isEmpty) continue;
    // what Markdown has goes in Markdown: a yellow highlight, and raised or lowered text without spaces (`~x~` not next to the
    // `~~` of a strikethrough, which would read as one)
    final attrs = Map.of(x.attrs);
    final mark = attrs.containsKey(AttributeType.highlight) && (attrs[AttributeType.highlight] == null || _yellows.contains(attrs[AttributeType.highlight]!.toUpperCase()));
    if (mark) attrs.remove(AttributeType.highlight);
    final plain = !text.contains(RegExp(r'[\s^~]'));
    final raised = plain && attrs.containsKey(AttributeType.superscript);
    final lowered = plain && !x.strike && attrs.containsKey(AttributeType.subscript) && !raised;
    if (raised) attrs.remove(AttributeType.superscript);
    if (lowered) attrs.remove(AttributeType.subscript);
    final script = raised ? '^' : (lowered ? '~' : '');
    final open = '${x.inserted ? '{++' : ''}${x.deleted ? '{--' : ''}${x.strike ? '~~' : ''}${x.bold ? '**' : ''}${x.italic ? '*' : ''}${mark ? '==' : ''}$script';
    final close = '$script${mark ? '==' : ''}${x.italic ? '*' : ''}${x.bold ? '**' : ''}${x.strike ? '~~' : ''}${x.deleted ? '--}' : ''}${x.inserted ? '++}' : ''}';
    final link = x is MdLinkPiece ? x.link : null;
    write(link == null ? open : '[$open');
    final start = out.length;
    write(text);
    final end = out.length;
    write(link == null ? close : '$close]($link)');
    write(trail);
    for (final a in attrs.entries) {
      spans.add(TextSpanAttribute(start: start, end: end, type: a.key, value: a.value));
    }
  }
}
