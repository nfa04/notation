import 'dart:ui';

/// What a [PdfEditObject] is.
enum PdfObjectKind { text, path, image, other }

/// Something drawn on a PDF page that can be edited: a run of text, a picture, a line or shape.
class PdfEditObject {
  /// Its place among the page's objects; only good until the page is edited.
  final int index;

  /// The page objects it is made of: more than one for a line of text the PDF drew word by word (first is [index]).
  final List<int> parts;
  final PdfObjectKind kind;

  /// Where it is on the page as shown, in points from the top left (what the editor works in).
  final Rect rect;

  /// The text of a text run.
  final String? text;

  /// How big the text is on the page, in points.
  final double? fontSize;
  final String? fontName;

  /// The colour of the text as 0xAARRGGBB.
  final int? color;

  /// The line the text sits on, in points from the top of the page as shown.
  final double? baseline;

  /// The piece of a line that has most of its text: the one whose font and style the line is taken to be set in.
  final int styleIndex;

  /// The piece of a line that starts it (the leftmost): where the line begins.
  final int anchor;

  /// For each character of [text] (counted in code points) the page object it comes from, so that a character the user does
  /// not change is set again in the font it was in.
  final List<int>? charOwners;

  /// The lines drawn under and through the text (page objects that belong to it, moved and deleted with it).
  final List<int> underlines;
  final List<int> strikes;

  PdfEditObject({
    required this.index,
    List<int>? parts,
    required this.kind,
    required this.rect,
    this.text,
    this.fontSize,
    this.fontName,
    this.color,
    this.baseline,
    int? styleIndex,
    int? anchor,
    this.charOwners,
    this.underlines = const [],
    this.strikes = const [],
  })  : parts = parts ?? [index],
        styleIndex = styleIndex ?? index,
        anchor = anchor ?? index;

  PdfEditObject copyWith({List<int>? parts, Rect? rect, String? text, List<int>? charOwners, int? styleIndex, int? anchor, List<int>? underlines, List<int>? strikes, int? color}) => PdfEditObject(
        index: index,
        parts: parts ?? this.parts,
        kind: kind,
        rect: rect ?? this.rect,
        text: text ?? this.text,
        fontSize: fontSize,
        fontName: fontName,
        color: color ?? this.color,
        baseline: baseline,
        styleIndex: styleIndex ?? this.styleIndex,
        anchor: anchor ?? this.anchor,
        charOwners: charOwners ?? this.charOwners,
        underlines: underlines ?? this.underlines,
        strikes: strikes ?? this.strikes,
      );

  bool get underlined => underlines.isNotEmpty;
  bool get struckThrough => strikes.isNotEmpty;

  /// Every page object this is made of.
  List<int> get all => [...parts, ...underlines, ...strikes];
}

/// The PDF could not be opened for editing, or an edit could not be made.
class PdfEditException implements Exception {
  final String message;
  const PdfEditException(this.message);

  @override
  String toString() => message;
}

/// What kind of font a line of text is set in: enough to pick a stand-in of the same look and width. (The PDF's own font
/// program cannot be used: PDFium gives the letters the PDF uses, by glyph number and with no character map, or a
/// built-in font that has none either.)
class PdfFontInfo {
  final String name;
  final bool bold;
  final bool italic;
  final bool serif;
  final bool mono;

  const PdfFontInfo({required this.name, this.bold = false, this.italic = false, this.serif = false, this.mono = false});

  /// "sans", "serif" or "mono", then "-bold", "-italic" or "-bolditalic" when so: names the stand-in font.
  String get key => '${mono ? 'mono' : (serif ? 'serif' : 'sans')}${bold || italic ? '-' : ''}${bold ? 'bold' : ''}${italic ? 'italic' : ''}';
}
