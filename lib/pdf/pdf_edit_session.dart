import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'pdf_edit_types.dart';
import 'pdfium_backend.dart';
import 'ttf_coverage.dart';

/// Edits what a PDF really contains (its text, pictures and shapes) through PDFium's page objects, unlike the overlay the
/// editor draws on top of a page. The edited file is written whole by [save].
///
/// Synchronous, on whatever [PdfiumBackend] it is given, and only to be used where that backend may be called; [close] when done.
class PdfEditSession {
  final PdfiumBackend _b;
  final int _doc;
  final _pages = <int, _OpenPage>{};
  final _dirty = <int>{};
  final _fonts = <int>[];
  final _fallbackFonts = <String, int>{};
  bool _closed = false;

  /// TrueType fonts to set text in when the PDF's own font lacks the characters, by [PdfFontInfo.key] (without: the PDF standard Helvetica).
  final Map<String, Uint8List> _fallbackFontBytes;

  PdfEditSession._(this._b, this._doc, this._fallbackFontBytes);

  /// Opens [bytes] on [backend].
  /// Throws a [PdfEditException] for a PDF that is damaged or needs a password.
  static PdfEditSession open(PdfiumBackend backend, Uint8List bytes, {Map<String, Uint8List> fallbackFonts = const {}}) {
    final doc = backend.loadDocument(bytes);
    if (doc == 0) {
      throw PdfEditException(backend.lastLoadNeededPassword ? 'This PDF is protected with a password.' : 'This PDF could not be opened for editing.');
    }
    return PdfEditSession._(backend, doc, fallbackFonts);
  }

  int get pageCount => _b.pageCount(_doc);

  _OpenPage _page(int pageIndex) {
    return _pages.putIfAbsent(pageIndex, () {
      final page = _b.loadPage(_doc, pageIndex);
      if (page == 0) throw PdfEditException('Page ${pageIndex + 1} could not be read.');
      return _OpenPage(page, _b.loadTextPage(page), _b.pageWidth(page), _b.pageHeight(page));
    });
  }

  // Page space (origin bottom left, before rotation and cropping) to the page as shown (origin top left): PDFium
  // converts to whole device units, so the page is asked for in hundredths of a point.
  static const _res = 100;

  Offset _toShown(_OpenPage pg, double x, double y) {
    final (dx, dy) = _b.pageToDevice(pg.page, (pg.width * _res).round(), (pg.height * _res).round(), x, y);
    return Offset(dx / _res, dy / _res);
  }

  Offset _toPage(_OpenPage pg, Offset shown) {
    final (x, y) = _b.deviceToPage(pg.page, (pg.width * _res).round(), (pg.height * _res).round(), (shown.dx * _res).round(), (shown.dy * _res).round());
    return Offset(x, y);
  }

  Rect? _boundsShown(_OpenPage pg, int object) {
    final f = _b.bounds(object);
    if (f == null) return null;
    // left, bottom, right, top
    final a = _toShown(pg, f[0], f[1]);
    final b = _toShown(pg, f[2], f[3]);
    return Rect.fromPoints(a, b);
  }

  /// Size of page [pageIndex] as shown, in points.
  Size pageSize(int pageIndex) {
    final pg = _page(pageIndex);
    return Size(pg.width, pg.height);
  }

  /// What can be edited on page [pageIndex], bottom-most first. Text nobody can see (the hidden layer of a scan that
  /// was run through text recognition) is left out.
  List<PdfEditObject> objects(int pageIndex) {
    final pg = _page(pageIndex);
    if (_dirty.contains(pageIndex)) {
      // the text index of the page was made before the edits: made again so that it reads what is there now
      _b.closeTextPage(pg.text);
      pg.text = _b.loadTextPage(pg.page);
    }
    final result = <PdfEditObject>[];
    final count = _b.countObjects(pg.page);
    for (var i = 0; i < count; i++) {
      final object = _b.getObject(pg.page, i);
      final rect = _boundsShown(pg, object);
      if (rect == null) continue;
      final type = _b.objectType(object);
      if (type == PdfiumBackend.objectText) {
        if (_b.isInvisibleText(object)) continue;
        final text = _textOf(pg, object);
        if (text.trim().isEmpty) continue;
        result.add(PdfEditObject(
            index: i,
            kind: PdfObjectKind.text,
            rect: rect,
            text: text,
            fontSize: _fontSize(object),
            fontName: _b.fontName(_b.fontOf(object)),
            color: _fillColor(object),
            baseline: _baselineOf(pg, object, rect)));
      } else {
        final kind = switch (type) {
          PdfiumBackend.objectPath => PdfObjectKind.path,
          PdfiumBackend.objectImage => PdfObjectKind.image,
          _ => PdfObjectKind.other,
        };
        result.add(PdfEditObject(index: i, kind: kind, rect: rect));
      }
    }
    return _withDecorations(_lines(pg, result));
  }

  /// Joins the pieces of text on one line of the page into the line they read as: the same baseline and size, touching or
  /// overlapping (a font the PDF falls back on for a sign is a piece of its own, set inside the gap the line leaves for it).
  List<PdfEditObject> _lines(_OpenPage pg, List<PdfEditObject> objects) {
    final texts = [for (final o in objects) if (o.kind == PdfObjectKind.text) o];
    final parent = List<int>.generate(texts.length, (i) => i);
    int find(int i) {
      while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
      }
      return i;
    }

    for (var i = 0; i < texts.length; i++) {
      for (var j = i + 1; j < texts.length; j++) {
        if (_sameLine(texts[i], texts[j])) parent[find(j)] = find(i);
      }
    }
    final groups = <int, List<PdfEditObject>>{};
    for (var i = 0; i < texts.length; i++) {
      groups.putIfAbsent(find(i), () => []).add(texts[i]);
    }
    final lineAt = <int, PdfEditObject>{}; // (by the lowest piece, where the line is in the stacking order)
    for (final members in groups.values) {
      members.sort((a, b) => a.index.compareTo(b.index));
      lineAt[members.first.index] = members.length == 1 ? _singleLine(members.first) : _mergeLine(pg, members);
    }
    return [
      for (final o in objects)
        if (o.kind != PdfObjectKind.text) o else if (lineAt[o.index] != null) lineAt[o.index]!,
    ];
  }

  PdfEditObject _singleLine(PdfEditObject o) {
    final text = o.text!.trim();
    return o.copyWith(text: text, charOwners: List<int>.filled(text.runes.length, o.index));
  }

  bool _sameLine(PdfEditObject a, PdfEditObject b) {
    final size = math.max(a.fontSize!, b.fontSize!);
    if ((a.fontSize! - b.fontSize!).abs() > size * 0.1) return false;
    if ((a.baseline! - b.baseline!).abs() > size * 0.25) return false;
    return b.rect.left - a.rect.right < size * 0.9 && a.rect.left - b.rect.right < size * 0.9;
  }

  PdfEditObject _mergeLine(_OpenPage pg, List<PdfEditObject> members) {
    final anchor = members.reduce((a, b) => a.rect.left <= b.rect.left ? a : b);
    final style = members.reduce((a, b) => b.text!.trim().length > a.text!.trim().length ? b : a);
    final rect = members.map((m) => m.rect).reduce((a, b) => a.expandToInclude(b));
    final (text, owners) = _lineText(pg, members);
    return PdfEditObject(
      index: members.first.index,
      parts: [for (final m in members) m.index],
      kind: PdfObjectKind.text,
      rect: rect,
      text: text,
      charOwners: owners,
      fontSize: style.fontSize,
      fontName: style.fontName,
      color: anchor.color,
      baseline: anchor.baseline,
      styleIndex: style.index,
      anchor: anchor.index,
    );
  }

  /// What the pieces of a line say together, in the order it is read, and for each character the piece it is from: left to right
  /// by where each character is (a piece set inside the gap of another is read where it is). Between pieces, words are apart
  /// where the characters are.
  (String, List<int>) _lineText(_OpenPage pg, List<PdfEditObject> members) {
    final pieces = {for (final m in members) _b.getObject(pg.page, m.index): m.index};
    final raw = <(double, double, int, int)>[]; // left, right, UTF-16 unit, piece (in the order the page has them)
    final count = _b.countChars(pg.text);
    for (var i = 0; i < count; i++) {
      final owner = pieces[_b.charObject(pg.text, i)];
      if (owner == null) continue;
      final unicode = _b.charUnicode(pg.text, i);
      if (unicode == 0 || unicode == 0xFFFE || unicode == 0xFFFF || unicode == 0x0A || unicode == 0x0D) continue;
      final box = _b.charBox(pg.text, i); // left, right, bottom, top
      if (box == null) continue;
      final from = _toShown(pg, box[0], box[2]);
      final to = _toShown(pg, box[1], box[3]);
      raw.add((math.min(from.dx, to.dx), math.max(from.dx, to.dx), unicode, owner));
    }
    if (raw.isEmpty) {
      final text = members.map((m) => m.text!.trim()).join(' ');
      return (text, List<int>.filled(text.runes.length, members.first.index));
    }
    // (the two halves of a character above U+FFFF are one character)
    final chars = <(double, double, int, int)>[];
    for (var i = 0; i < raw.length; i++) {
      final (left, right, unit, owner) = raw[i];
      if (unit >= 0xD800 && unit < 0xDC00 && i + 1 < raw.length && raw[i + 1].$3 >= 0xDC00 && raw[i + 1].$3 < 0xE000) {
        final low = raw[++i].$3;
        chars.add((left, math.max(right, raw[i].$2), 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), owner));
      } else {
        chars.add((left, right, unit, owner));
      }
    }
    final order = List<int>.generate(chars.length, (i) => i)
      ..sort((x, y) => chars[x].$1 != chars[y].$1 ? chars[x].$1.compareTo(chars[y].$1) : x.compareTo(y));
    final size = members.first.fontSize ?? 12;
    final text = <int>[];
    final owners = <int>[];
    void add(int c, int owner) {
      if (c == 0x20 && (text.isEmpty || text.last == 0x20)) return; // (no spaces at the start, none twice)
      text.add(c);
      owners.add(owner);
    }

    double? end;
    int? previous;
    for (final i in order) {
      final (left, right, c, owner) = chars[i];
      // (a space between pieces is where they are apart; inside a piece the PDF has its own spaces)
      if (end != null && owner != previous && left - end > size * 0.2) add(0x20, owner);
      add(c, owner);
      end = end == null ? right : math.max(end, right);
      previous = owner;
    }
    while (text.isNotEmpty && text.last == 0x20) {
      text.removeLast();
      owners.removeLast();
    }
    return (String.fromCharCodes(text), owners);
  }

  /// Lines drawn under or through a piece of text belong to it: they are taken out of the list and put with the text.
  List<PdfEditObject> _withDecorations(List<PdfEditObject> objects) {
    final taken = <int>{};
    final withLines = <int, PdfEditObject>{};
    for (final o in objects) {
      if (o.kind != PdfObjectKind.text) continue;
      final size = o.fontSize!;
      final under = <int>[];
      final strike = <int>[];
      for (final d in objects) {
        if (d.kind != PdfObjectKind.path || taken.contains(d.index)) continue;
        final r = d.rect;
        if (r.height > math.max(2.0, size * 0.12)) continue; // (a line is thin)
        if (r.width < o.rect.width * 0.6 || r.left < o.rect.left - size * 0.3 || r.right > o.rect.right + size * 0.3) continue;
        final y = r.center.dy;
        if (y >= o.rect.bottom - size * 0.15 && y <= o.rect.bottom + size * 0.4) {
          under.add(d.index);
        } else if (y >= o.rect.top + o.rect.height * 0.3 && y <= o.rect.top + o.rect.height * 0.65) {
          strike.add(d.index);
        }
      }
      if (under.isEmpty && strike.isEmpty) continue;
      taken.addAll([...under, ...strike]);
      withLines[o.index] = o.copyWith(underlines: under, strikes: strike);
    }
    return [
      for (final o in objects)
        if (!taken.contains(o.index)) withLines[o.index] ?? o,
    ];
  }

  String _textOf(_OpenPage pg, int object) => _b.textOf(object, pg.text);

  /// How big the text of [object] is on the page: the font size the PDF sets, times the scale of the text's own matrix.
  double _fontSize(int object) {
    final size = _b.fontSize(object);
    if (size == null) return 0;
    final m = _b.matrix(object);
    final scale = m == null ? 1.0 : math.sqrt(m[2] * m[2] + m[3] * m[3]);
    return size * (scale > 0 ? scale : 1);
  }

  int _fillColor(int object) => _b.fillColor(object) ?? 0xFF000000;

  String _fontName(int font) => font == 0 ? '' : _b.fontName(font);

  /// The line [object] sits on, from the page's top: where its text matrix puts it, if that is about where the text is.
  double _baselineOf(_OpenPage pg, int object, Rect rect) {
    final m = _b.matrix(object);
    if (m != null) {
      final y = _toShown(pg, m[4], m[5]).dy;
      final size = _fontSize(object);
      if (y >= rect.top - size * 0.1 && y <= rect.bottom + size * 0.1) return y;
    }
    return rect.bottom - _fontSize(object) * 0.2;
  }

  /// Whether the font [object] is set in can show every character of [text]. A font the PDF carries is almost always only the
  /// letters it uses: those of the text, and of any other text of the page in that font, are the ones it surely has. A font the
  /// PDF only names (the standard ones) comes from the viewer, with the Latin letters.
  bool _fontCanShow(_OpenPage pg, int object, String old, String text) {
    final font = _b.fontOf(object);
    if (!_b.fontIsEmbedded(font)) {
      return text.runes.every((c) => c < 0x100 && (c >= 0x20 && c < 0x7F || c >= 0xA0));
    }
    final name = _fontName(font);
    final have = old.runes.toSet();
    final count = _b.countObjects(pg.page);
    for (var i = 0; i < count; i++) {
      final other = _b.getObject(pg.page, i);
      if (_b.objectType(other) != PdfiumBackend.objectText || _fontName(_b.fontOf(other)) != name) continue;
      have.addAll(_textOf(pg, other).runes);
    }
    return text.runes.every(have.contains);
  }

  /// Puts [text] in place of the text of [line]. A line of one piece stays as it is, in the PDF's own font, when that can show the
  /// new text. Otherwise the line is set again, a run at a time: each character in the PDF's own font if that has it, else in a
  /// stand-in font ([family], "sans", "serif" or "mono", says which, and [sizeFactor] sets it bigger or smaller to take the room
  /// the old text took), signs from the symbols font. With [uniform] the whole line is set in the stand-in font, none of it in the PDF's
  /// own font (for a text that has nothing left of the old one, where letters of two fonts would differ in size and look). A [PdfEditException] says when a character cannot be shown at all.
  void setText(int pageIndex, PdfEditObject line, String text, {String? family, double sizeFactor = 1, bool uniform = false}) {
    final pg = _page(pageIndex);
    final parts = [for (final i in line.parts) _b.getObject(pg.page, i)];
    if (parts.any((o) => o == 0 || _b.objectType(o) != PdfiumBackend.objectText)) throw const PdfEditException('That is not text.');
    final old = line.text ?? '';
    if (text.trim() == old) return;
    if (text.trim().isEmpty) {
      removeObject(pageIndex, line);
      return;
    }
    final astral = text.runes.any((c) => c > 0xFFFF) || old.runes.any((c) => c > 0xFFFF);
    // (a character above U+FFFF cannot be written back by PDFium through its Unicode: such a line is set again by character codes)
    // (a space is no glyph of a font that only has the letters a document used: set in it, it takes no room and the words run together,
    // so such a line is set again, a word at a time, with gaps)
    if (parts.length == 1 && !astral && _fontCanShow(pg, parts.first, old, text) &&
        (!text.contains(' ') || _spaceHasWidth(pg, _b.fontOf(parts.first)))) {
      _removeDecorations(pg, line);
      if (!_b.setText(parts.first, text)) throw const PdfEditException('The text could not be changed.');
      final rect = _boundsShown(pg, parts.first);
      if (rect != null) _decorate(pg, rect, line.fontSize ?? 12, _fillColor(parts.first), underline: line.underlined, strike: line.struckThrough);
    } else {
      _setAgain(pg, line, text, family: family, sizeFactor: sizeFactor, useOriginal: !uniform, underline: line.underlined, strike: line.struckThrough);
    }
    _dirty.add(pageIndex);
  }

  /// Changes how [line] looks: its colour, bold, italic, underline and strikethrough (what is null stays as it is). Bold and
  /// italic set the line again in the stand-in fonts of that look.
  void formatText(int pageIndex, PdfEditObject line, {int? color, bool? bold, bool? italic, bool? underline, bool? strikethrough}) {
    final pg = _page(pageIndex);
    final parts = [for (final i in line.parts) _b.getObject(pg.page, i)];
    if (parts.any((o) => o == 0 || _b.objectType(o) != PdfiumBackend.objectText)) throw const PdfEditException('That is not text.');
    final wantUnder = underline ?? line.underlined;
    final wantStrike = strikethrough ?? line.struckThrough;
    final shown = color ?? line.color ?? 0xFF000000;
    if (bold != null || italic != null) {
      _setAgain(pg, line, line.text ?? '', bold: bold, italic: italic, useOriginal: false, color: shown, underline: wantUnder, strike: wantStrike);
    } else {
      _removeDecorations(pg, line);
      if (color != null) {
        for (final o in parts) {
          _b.setFillColor(o, color);
        }
      }
      _decorate(pg, line.rect, line.fontSize ?? 12, shown, underline: wantUnder, strike: wantStrike);
    }
    _dirty.add(pageIndex);
  }

  /// Takes the lines under and through [line] off the page.
  void _removeDecorations(_OpenPage pg, PdfEditObject line) {
    for (final d in [...line.underlines, ...line.strikes].map((i) => _b.getObject(pg.page, i)).where((o) => o != 0).toList()) {
      if (_b.removeObject(pg.page, d)) _b.destroyObject(d);
    }
  }

  void _decorate(_OpenPage pg, Rect rect, double size, int color, {required bool underline, required bool strike}) {
    final thickness = math.max(0.6, size / 16);
    void line(double top) {
      final a = _toPage(pg, Offset(rect.left, top));
      final b = _toPage(pg, Offset(rect.right, top + thickness));
      final object = _b.createFilledRect(math.min(a.dx, b.dx), math.min(a.dy, b.dy), (a.dx - b.dx).abs(), (a.dy - b.dy).abs(), color);
      _b.insertObject(pg.page, object);
    }

    if (underline) line(rect.bottom + size * 0.04);
    if (strike) line(rect.top + rect.height * 0.55 - thickness / 2);
  }

  /// Sets [text] again as [line]'s text, a run at a time, where the line was (same place in the page's stacking order). What the
  /// user left as it was (the start and end both texts share) is set in the font it was in, by the character codes of that font if
  /// it is above U+FFFF. What is new goes in the PDF's own font if that has the character, else in the stand-in font of the same
  /// kind, weight and slant (as [family], [bold] and [italic] say, else as the line's font is), else in the symbols font. A line
  /// the PDF stored in several pieces becomes the runs. With [useOriginal] false everything is in the stand-ins (for bold, italic).
  void _setAgain(_OpenPage pg, PdfEditObject line, String text,
      {String? family, double sizeFactor = 1, bool? bold, bool? italic, bool useOriginal = true, int? color, required bool underline, required bool strike}) {
    // (the old pieces by what they are, not where they are: putting the new ones in shifts the places)
    final old = [for (final i in line.all) _b.getObject(pg.page, i),].where((o) => o != 0).toList();
    final anchor = _b.getObject(pg.page, line.anchor);
    final dominant = _b.getObject(pg.page, line.styleIndex);
    final dominantFont = _b.fontOf(dominant);
    final info = _infoOf(dominantFont);
    final kind = family ?? (info.mono ? 'mono' : (info.serif ? 'serif' : 'sans'));
    final isBold = bold ?? info.bold;
    final isItalic = italic ?? info.italic;
    final look = '${isBold || isItalic ? '-' : ''}${isBold ? 'bold' : ''}${isItalic ? 'italic' : ''}';
    final standIn = kind == 'dejavu' ? 'symbols$look' : '$kind$look';
    final symbols = 'symbols$look';


    // the fonts the PDF's own text is in: one per piece of the line (slot 0 is the one most of it is in)
    final slotFonts = <int>[dominantFont];
    final slotOfPiece = <int, int>{line.styleIndex: 0};
    for (final i in line.parts) {
      if (slotOfPiece.containsKey(i)) continue;
      final font = _b.fontOf(_b.getObject(pg.page, i));
      final known = slotFonts.indexOf(font);
      slotOfPiece[i] = known >= 0 ? known : slotFonts.length;
      if (known < 0) slotFonts.add(font);
    }
    final has = useOriginal ? [for (final f in slotFonts) _glyphsOf(pg, f)] : const <bool Function(int)>[];
    final codes = <int, Map<int, int>>{};
    Map<int, int> codesOf(int slot) => codes.putIfAbsent(slot, () => _codesOf(pg, slotFonts[slot]));

    // what the user left as it was: the start and the end the old and the new text share, with the pieces they were in
    final oldRunes = (line.text ?? '').runes.toList();
    final runes = text.runes.toList();
    final owners = line.charOwners ?? List<int>.filled(oldRunes.length, line.index);
    var start = 0;
    while (useOriginal && start < oldRunes.length && start < runes.length && oldRunes[start] == runes[start]) {
      start++;
    }
    var end = 0;
    while (useOriginal && end < oldRunes.length - start && end < runes.length - start && oldRunes[oldRunes.length - 1 - end] == runes[runes.length - 1 - end]) {
      end++;
    }

    // which font shows each character: 1 the stand-in, 2 the symbols font, else 10 + 2 * slot of the PDF's own fonts (+ 1 when it
    // has to be set by character codes, above U+FFFF); spaces go with what is before them
    bool space(int c) => c == 0x20 || c == 0xA0 || c == 0x09;
    final choice = List<int?>.filled(runes.length, null);
    final cannot = <String>{};
    int own(int slot, int c) => 10 + 2 * slot + (c > 0xFFFF ? 1 : 0);
    for (var i = 0; i < runes.length; i++) {
      final c = runes[i];
      if (space(c)) continue;
      final kept = i < start ? owners[i] : (i >= runes.length - end ? owners[oldRunes.length - (runes.length - i)] : -1);
      final keptSlot = kept >= 0 ? slotOfPiece[kept] : null;
      // (a colour emoji font draws pictures by glyph number: its characters cannot be set again)
      if (keptSlot != null && !_isPictureFont(slotFonts[keptSlot]) && (c <= 0xFFFF || codesOf(keptSlot).containsKey(c))) {
        choice[i] = own(keptSlot, c);
      } else if (has.isNotEmpty && !_isPictureFont(slotFonts[0]) && has[0](c) && (c <= 0xFFFF || codesOf(0).containsKey(c))) {
        choice[i] = own(0, c);
      } else if (_covers(standIn, c)) {
        choice[i] = 1;
      } else if (_covers(symbols, c)) {
        choice[i] = 2;
      } else {
        cannot.add(String.fromCharCode(c));
      }
    }
    if (cannot.isNotEmpty) throw PdfEditException('These characters cannot be shown: ${cannot.take(6).join(' ')}');
    var previous = choice.firstWhere((c) => c != null, orElse: () => 1)!;
    for (var i = 0; i < choice.length; i++) {
      choice[i] ??= previous;
      previous = choice[i]!;
    }
    // runs of one font; the spaces a run ends in start the next one (the end of a run is where the next begins, and the
    // measure of a run leaves out the spaces it ends in)
    final runs = <(int, String)>[];
    var current = StringBuffer();
    var runFont = choice.isEmpty ? 1 : choice.first!;
    for (var i = 0; i < runes.length; i++) {
      if (choice[i] != runFont) {
        final body = current.toString();
        final trimmed = body.trimRight();
        runs.add((runFont, trimmed));
        current = StringBuffer(body.substring(trimmed.length));
        runFont = choice[i]!;
      }
      current.write(String.fromCharCode(runes[i]));
    }
    runs.add((runFont, current.toString()));


    // where the line starts and how it is set: the leftmost piece
    double a = 1, b = 0, c = 0, d = 1, e, f;
    final anchorMatrix = _b.matrix(anchor);
    if (anchorMatrix != null) {
      a = anchorMatrix[0];
      b = anchorMatrix[1];
      c = anchorMatrix[2];
      d = anchorMatrix[3];
      e = anchorMatrix[4];
      f = anchorMatrix[5];
    } else {
      final at = _toPage(pg, Offset(line.rect.left, line.baseline ?? line.rect.bottom));
      e = at.dx;
      f = at.dy;
    }
    final argb = color ?? _fillColor(anchor);
    final size = _fontSize(anchor) / _matrixScale(anchor);
    final length = math.sqrt(a * a + b * b);
    final dx = length == 0 ? 1.0 : a / length;
    final dy = length == 0 ? 0.0 : b / length;

    final made = <int>[];
    var shift = 0.0;
    var at = line.index;
    try {
      for (final (font, run) in runs) {
        if (run.isEmpty) continue;
        final isOwn = font >= 10;
        final slot = isOwn ? (font - 10) ~/ 2 : 0;
        final handle = isOwn ? slotFonts[slot] : _loadFallback(font == 1 ? standIn : symbols);
        final runSize = isOwn ? size : size * sizeFactor;
        // (a run set by character codes is set a word at a time, and a space is a gap: the code a font has for its space is not
        // known, and the space of a subset may be a glyph that is not there)
        final pieces = isOwn && ( font.isOdd || !_spaceHasWidth(pg, handle)) ? run.split(' ') : [run];
        for (var w = 0; w < pieces.length; w++) {
          final piece = pieces[w];
          if (w > 0) shift += runSize * 0.3;
          if (piece.isEmpty) continue;
          final object = _b.createTextObject(_doc, handle, runSize);
          if (object == 0) throw const PdfEditException('The text could not be changed.');
          final ok = isOwn && font.isOdd ? _b.setCharcodes(object, [for (final c in piece.runes) codesOf(slot)[c]!]) : _b.setText(object, piece);
          if (!ok) {
            _b.destroyObject(object);
            throw const PdfEditException('The text could not be changed.');
          }
          _b.setMatrix(object, [a, b, c, d, e + shift * dx, f + shift * dy]);
          _b.setFillColor(object, argb);
          _b.insertObjectAt(pg.page, object, at++);
          made.add(object);
          // the next piece starts where this one ends (its bounds stop a little short of the full advance)
          final box = _b.bounds(object);
          if (box != null) {
            final end = dx.abs() >= dy.abs() ? (dx >= 0 ? box[2] - e : e - box[0]) : (dy >= 0 ? box[3] - f : f - box[1]);
            shift = end + runSize * 0.03;
          }
        }
      }
    } on PdfEditException {
      for (final o in made) {
        if (_b.removeObject(pg.page, o)) _b.destroyObject(o);
      }
      rethrow;
    }
    // only now the old pieces go (the new text holds on to the PDF's own fonts)
    for (final o in old) {
      if (_b.removeObject(pg.page, o)) _b.destroyObject(o);
    }
    if (underline || strike) {
      Rect? all;
      for (final o in made) {
        final r = _boundsShown(pg, o);
        if (r != null) all = all == null ? r : all.expandToInclude(r);
      }
      if (all != null) _decorate(pg, all, line.fontSize ?? 12, argb, underline: underline, strike: strike);
    }
  }

  final _codeMaps = <int, Map<int, int>>{};

  /// The character code the PDF's own font [font] shows each character with, found by asking the font what every code stands
  /// for (a probe of each of the codes 1 to 255, read back). Characters above U+FFFF, which PDFium cannot write back by their
  /// Unicode, are set by these codes.
  Map<int, int> _codesOf(_OpenPage pg, int font) {
    final cached = _codeMaps[font];
    if (cached != null) return cached;
    final map = <int, int>{};
    // (a batch at a time, each probe on a row of its own: the text of the page puts what is on one row together)
    const rows = 24;
    for (var first = 1; first < 256; first += rows) {
      final probes = <(int, int)>[];
      for (var c = first; c < math.min(first + rows, 256); c++) {
        final probe = _b.createTextObject(_doc, font, 10);
        if (probe == 0) continue;
        if (!_b.setCharcodes(probe, [c])) {
          _b.destroyObject(probe);
          continue;
        }
        _b.setMatrix(probe, [1, 0, 0, 1, 40.0, 40.0 + 30 * (c - first)]);
        _b.insertObject(pg.page, probe);
        probes.add((c, probe));
      }
      _b.closeTextPage(pg.text);
      pg.text = _b.loadTextPage(pg.page);
      for (final (c, probe) in probes) {
        final text = _textOf(pg, probe);
        if (text.runes.length == 1) map.putIfAbsent(text.runes.first, () => c);
      }
      for (final (_, probe) in probes) {
        if (_b.removeObject(pg.page, probe)) _b.destroyObject(probe);
      }
    }
    _b.closeTextPage(pg.text);
    pg.text = _b.loadTextPage(pg.page);
    return _codeMaps[font] = map;
  }

  final _spaceWidths = <int, bool>{};

  /// Whether a space set in the PDF's own font [font] takes room. A font the PDF only names has one. In an embedded subset (what TeX
  /// makes) the space is often a gap between words and no glyph, so the font draws it with no width: found by setting "l l" and "ll"
  /// and seeing whether the first is wider.
  bool _spaceHasWidth(_OpenPage pg, int font) {
    final known = _spaceWidths[font];
    if (known != null) return known;
    if (!_b.fontIsEmbedded(font)) return _spaceWidths[font] = true;
    double? width(String text) {
      final probe = _b.createTextObject(_doc, font, 10);
      if (probe == 0) return null;
      try {
        if (!_b.setText(probe, text)) return null;
        _b.insertObject(pg.page, probe);
        final box = _b.bounds(probe);
        return box == null ? null : box[2] - box[0];
      } finally {
        if (_b.removeObject(pg.page, probe)) _b.destroyObject(probe);
      }
    }

    final spaced = width('l l');
    final tight = width('ll');
    return _spaceWidths[font] =
        spaced != null && tight != null && spaced - tight > 1;
  }

  bool _isPictureFont(int font) => RegExp('emoji', caseSensitive: false).hasMatch(_fontName(font));

  /// A test of whether the PDF's font [font] has a glyph for a character: the characters of the page's text in that
  /// font (a font the PDF carries has the letters it uses and no others), or for a font the PDF only names, the Latin ones.
  bool Function(int) _glyphsOf(_OpenPage pg, int font) {
    if (!_b.fontIsEmbedded(font)) return (c) => c < 0x100 && (c >= 0x20 && c < 0x7F || c >= 0xA0);
    final name = _fontName(font);
    final have = <int>{};
    final count = _b.countObjects(pg.page);
    for (var i = 0; i < count; i++) {
      final other = _b.getObject(pg.page, i);
      if (_b.objectType(other) != PdfiumBackend.objectText || _fontName(_b.fontOf(other)) != name) continue;
      have.addAll(_textOf(pg, other).runes);
    }
    return have.contains;
  }

  /// The scale of the text matrix of [object] (what [_fontSize] has multiplied the font size by).
  double _matrixScale(int object) {
    final m = _b.matrix(object);
    if (m == null) return 1;
    final scale = math.sqrt(m[2] * m[2] + m[3] * m[3]);
    return scale > 0 ? scale : 1;
  }

  final _coverage = <String, TtfCoverage>{};

  /// The stand-in of the look [key] names that is there (else the plain one of its kind, else any sans).
  String? _resolve(String key) {
    for (final k in [key, key.split('-').first, 'sans']) {
      if (_fallbackFontBytes.containsKey(k)) return k;
    }
    return null;
  }

  bool _covers(String key, int c) {
    final k = _resolve(key);
    if (k == null) return false;
    return _coverage.putIfAbsent(k, () => TtfCoverage.of(_fallbackFontBytes[k]!)).covers(c);
  }

  /// The stand-in font [key] names, loaded into the PDF (once).
  int _loadFallback(String key) {
    final k = _resolve(key);
    final cached = k == null ? null : _fallbackFonts[k];
    if (cached != null) return cached;
    if (k != null) {
      final font = _b.loadTrueTypeFont(_doc, _fallbackFontBytes[k]!);
      if (font != 0) {
        _fonts.add(font);
        return _fallbackFonts[k] = font;
      }
    }
    final standard = _fallbackFonts['standard'];
    if (standard != null) return standard;
    final font = _b.loadStandardFont(_doc, 'Helvetica');
    if (font == 0) throw const PdfEditException('The text could not be changed.');
    _fonts.add(font);
    return _fallbackFonts['standard'] = font;
  }

  /// The kind of font [line] is set in.
  PdfFontInfo fontInfo(int pageIndex, PdfEditObject line) {
    final pg = _page(pageIndex);
    return _infoOf(_b.fontOf(_b.getObject(pg.page, line.styleIndex)));
  }

  PdfFontInfo _infoOf(int font) {
    final name = _fontName(font);
    final flags = _b.fontFlags(font);
    final lower = name.toLowerCase();
    return PdfFontInfo(
      name: name,
      bold: flags & 0x40000 != 0 || _b.fontWeight(font) >= 600 || lower.contains('bold') || lower.contains('black'),
      italic: flags & 0x40 != 0 || lower.contains('italic') || lower.contains('oblique'),
      serif: flags & 0x2 != 0 || lower.contains('times') || lower.contains('serif') && !lower.contains('sans'),
      mono: flags & 0x1 != 0 || lower.contains('courier') || lower.contains('mono'),
    );
  }

  List<int> _partsOf(_OpenPage pg, PdfEditObject o) => [for (final i in o.all) _b.getObject(pg.page, i),].where((p) => p != 0).toList();

  /// Takes [object] off page [pageIndex].
  void removeObject(int pageIndex, PdfEditObject object) {
    final pg = _page(pageIndex);
    for (final part in _partsOf(pg, object)) {
      if (_b.removeObject(pg.page, part)) _b.destroyObject(part);
    }
    _dirty.add(pageIndex);
  }

  /// Moves [object] of page [pageIndex] by [delta] points on the page as shown.
  void moveObject(int pageIndex, PdfEditObject object, Offset delta) {
    final pg = _page(pageIndex);
    final from = _toPage(pg, const Offset(100, 100));
    final to = _toPage(pg, const Offset(100, 100) + delta);
    for (final part in _partsOf(pg, object)) {
      _b.transform(part, 1, 0, 0, 1, to.dx - from.dx, to.dy - from.dy);
    }
    _dirty.add(pageIndex);
  }

  /// Fits [object] of page [pageIndex] to [to], a rectangle of the page as shown: stretched, shrunk and moved from where it is
  /// ([PdfEditObject.rect]). The page may be turned or cropped; the maths is done on the page as shown and brought back.
  void resizeObject(int pageIndex, PdfEditObject object, Rect to) {
    final from = object.rect;
    if (from.width <= 0 || from.height <= 0 || to.width <= 0.5 || to.height <= 0.5) return;
    final pg = _page(pageIndex);
    // the page's own units to the page as shown: o + x * ex + y * ey
    final o = _toShown(pg, 0, 0);
    final ex = _toShown(pg, 1, 0) - o;
    final ey = _toShown(pg, 0, 1) - o;
    final det = ex.dx * ey.dy - ey.dx * ex.dy;
    if (det.abs() < 1e-9) return;
    final sx = to.width / from.width;
    final sy = to.height / from.height;
    // shown' = to.topLeft + S * (shown - from.topLeft); page' = P^-1 (shown')
    final l00 = (ey.dy * sx * ex.dx - ey.dx * sy * ex.dy) / det;
    final l01 = (ey.dy * sx * ey.dx - ey.dx * sy * ey.dy) / det;
    final l10 = (-ex.dy * sx * ex.dx + ex.dx * sy * ex.dy) / det;
    final l11 = (-ex.dy * sx * ey.dx + ex.dx * sy * ey.dy) / det;
    final tx = o.dx * (sx - 1) - sx * from.left + to.left;
    final ty = o.dy * (sy - 1) - sy * from.top + to.top;
    final e = (ey.dy * tx - ey.dx * ty) / det;
    final f = (-ex.dy * tx + ex.dx * ty) / det;
    for (final part in _partsOf(pg, object)) {
      _b.transform(part, l00, l10, l01, l11, e, f);
    }
    _dirty.add(pageIndex);
  }

  /// Turns [object] of page [pageIndex] by [degrees] clockwise (as shown) about the middle of its box.
  void rotateObject(int pageIndex, PdfEditObject object, double degrees) {
    final pg = _page(pageIndex);
    final o = _toShown(pg, 0, 0);
    final ex = _toShown(pg, 1, 0) - o;
    final ey = _toShown(pg, 0, 1) - o;
    final det = ex.dx * ey.dy - ey.dx * ex.dy;
    if (det.abs() < 1e-9) return;
    final c = object.rect.center;
    final r = degrees * math.pi / 180;
    final cs = math.cos(r), sn = math.sin(r);
    // shown' = c + R (shown - c) with y pointing down, so a positive angle turns clockwise
    Offset turn(Offset v) => Offset(cs * v.dx - sn * v.dy, sn * v.dx + cs * v.dy);
    // page' = P^-1 (shown'), shown = o + P page, P = [ex ey]
    Offset back(Offset v) => Offset((ey.dy * v.dx - ey.dx * v.dy) / det, (-ex.dy * v.dx + ex.dx * v.dy) / det);
    final lx = back(turn(ex)); // where the page's x unit goes
    final ly = back(turn(ey));
    final t = back(c + turn(o - c) - o);
    for (final part in _partsOf(pg, object)) {
      _b.transform(part, lx.dx, lx.dy, ly.dx, ly.dy, t.dx, t.dy);
    }
    _dirty.add(pageIndex);
  }

  /// Gives the PDF the pages [order] says: each the index of a page there is (at most once; the ones left out are deleted), or
  /// null for a new blank page of [blank] points.
  void arrange(List<int?> order, Size blank) {
    final count = pageCount;
    // (the pages open are about to move)
    for (final pg in _pages.values) {
      _b.closeTextPage(pg.text);
      _b.closePage(pg.page);
    }
    _pages.clear();
    _dirty.clear();
    final kept = {for (final i in order) ?i};
    if (kept.length != order.whereType<int>().length || kept.any((i) => i < 0 || i >= count)) throw const PdfEditException('The pages could not be arranged.');
    for (var i = count - 1; i >= 0; i--) {
      if (!kept.contains(i)) _b.deletePage(_doc, i);
    }
    // (what is left is in its old order: where each is now)
    final left = [for (var i = 0; i < count; i++) if (kept.contains(i)) i];
    final now = {for (var n = 0; n < left.length; n++) left[n]: n};
    final wanted = [for (final i in order) if (i != null) now[i]!];
    if (!_isInOrder(wanted)) {
      if (!_b.movePagesToFront(_doc, wanted)) throw const PdfEditException('The pages could not be moved.');
    }
    for (var n = 0; n < order.length; n++) {
      if (order[n] != null) continue;
      final page = _b.newPage(_doc, n, blank.width, blank.height);
      if (page == 0) throw const PdfEditException('A page could not be added.');
      _b.closePage(page);
    }
  }

  static bool _isInOrder(List<int> indices) {
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] != i) return false;
    }
    return true;
  }

  /// The edited PDF.
  Uint8List save() {
    for (final i in _dirty) {
      _b.generateContent(_page(i).page);
    }
    final bytes = _b.save(_doc);
    if (bytes == null) throw const PdfEditException('The PDF could not be saved.');
    return bytes;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final pg in _pages.values) {
      _b.closeTextPage(pg.text);
      _b.closePage(pg.page);
    }
    _pages.clear();
    for (final font in _fonts) {
      _b.closeFont(font);
    }
    _b.closeDocument(_doc);
  }
}

class _OpenPage {
  final int page;
  int text;
  final double width;
  final double height;
  _OpenPage(this.page, this.text, this.width, this.height);
}
