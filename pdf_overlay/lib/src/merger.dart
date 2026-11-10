import 'dart:math' as math;
import 'dart:typed_data';

import 'comment.dart';
import 'filters.dart';
import 'objects.dart';
import 'reader.dart';
import 'serializer.dart';

/// Merges [overlay] (a PDF whose pages hold the annotations, drawn in the
/// coordinate space the *viewer displays*) onto [original] and returns the
/// combined file.
///
/// Page `k` of the overlay is placed on page `targetPages[k]` of the original
/// (zero-based). Without [targetPages], overlay page `k` goes onto original
/// page `k`. The overlay page should have the size of the displayed page
/// (after `/Rotate` and `/CropBox`); it is scaled to fit if it does not.
///
/// How it works: the output is [original] byte for byte, followed by an
/// *incremental update*: the overlay page becomes a Form XObject that the target
/// page draws after its own content (the page's `/Contents` gets a stream before
/// and a stream after the original ones). The original content streams are not
/// rewritten, so text stays selectable and the file only grows by the size of
/// the overlay.
///
/// The overlay is part of the page, not an annotation: every viewer shows it,
/// including those that leave annotations out (Android's built-in renderer, for
/// one).
///
/// Throws [UnsupportedPdfException] for encrypted PDFs and for files whose
/// structure cannot be read reliably; fall back to another strategy then.
/// Throws [ArgumentError] / [RangeError] for bad [targetPages].
///
/// With [comments], each becomes a comment of the PDF (a Highlight annotation
/// with a note), on its page. [overlay] may then be null: only the comments
/// are added.
Uint8List mergeOverlay(
  Uint8List original,
  Uint8List? overlay, {
  List<int>? targetPages,
  List<PdfComment> comments = const [],
}) {
  final src = _guard(() => PdfReader(original));
  final ov = overlay == null ? null : _guard(() => PdfReader(overlay));
  final pages = _guard(() => src.pages());
  final overlayPages = ov == null ? <PdfPage>[] : _guard(() => ov.pages());

  final targets =
      targetPages ?? List<int>.generate(overlayPages.length, (i) => i);
  if (targets.length != overlayPages.length) {
    throw ArgumentError.value(
        targets.length,
        'targetPages',
        'must have one entry per overlay page (${overlayPages.length})');
  }
  for (final t in targets) {
    if (t < 0 || t >= pages.length) {
      throw RangeError.range(t, 0, pages.length - 1, 'targetPages');
    }
  }
  for (final c in comments) {
    if (c.page < 0 || c.page >= pages.length) {
      throw RangeError.range(c.page, 0, pages.length - 1, 'comments');
    }
  }

  return _guard(
      () => _Merger(src, ov, original, pages, overlayPages, targets, comments).run());
}

/// Converts unexpected parser failures (bad casts, range errors, ...) on odd
/// files into [UnsupportedPdfException] so callers have a single thing to catch.
T _guard<T>(T Function() f) {
  try {
    return f();
  } on UnsupportedPdfException {
    rethrow;
  } catch (e) {
    throw UnsupportedPdfException('malformed or unsupported PDF structure ($e)');
  }
}

class _Modified {
  final int gen;
  final PdfDict node;
  _Modified(this.gen, this.node);
}

class _Merger {
  final PdfReader src;
  final PdfReader? _ov;
  PdfReader get ov => _ov!; // (only used while there are overlay pages)
  final List<PdfComment> comments;
  final Uint8List original;
  final List<PdfPage> pages;
  final List<PdfPage> overlayPages;
  final List<int> targets;

  final Map<int, Object?> newObjs = <int, Object?>{};
  final Map<int, int> mapping = <int, int>{};
  int nextNum = 0;

  _Merger(this.src, this._ov, this.original, this.pages, this.overlayPages,
      this.targets, this.comments);

  int _alloc() => nextNum++;

  /// Copies [v] from the overlay file into the new objects, renumbering
  /// references. Each overlay object is imported once, so fonts and graphics
  /// states shared between overlay pages stay shared.
  Object? _import(Object? v) {
    if (v is PdfRef) {
      var m = mapping[v.num];
      if (m == null) {
        m = _alloc();
        mapping[v.num] = m; // set before recursing: breaks reference cycles
        newObjs[m] = _import(ov.getObject(v.num));
      }
      return PdfRef(m, 0);
    }
    if (v is PdfStream) {
      final d = <String, Object?>{};
      v.dict.forEach((k, x) {
        if (k != 'Length') d[k] = _import(x);
      });
      return PdfStream(d, v.raw);
    }
    if (v is Map) {
      final d = <String, Object?>{};
      v.forEach((k, x) {
        d[k as String] = _import(x);
      });
      return d;
    }
    if (v is List) {
      return <Object?>[for (final x in v) _import(x)];
    }
    return v;
  }

  /// A place in the page's own space, from one in display space (points from the top
  /// left of what the viewer shows).
  (double, double) _toPage(PdfPage page, double dx, double dy) {
    final box = src.visibleBox(page);
    final bw = box[2] - box[0], bh = box[3] - box[1];
    switch (src.rotation(page)) {
      case 90:
        return (box[0] + dy, box[1] + dx);
      case 180:
        return (box[0] + bw - dx, box[1] + dy);
      case 270:
        return (box[0] + bw - dy, box[1] + bh - dx);
      default:
        return (box[0] + dx, box[3] - dy);
    }
  }

  /// A text for a PDF: UTF-16 with its byte order mark, which every viewer reads.
  static PdfString _text(String s) {
    final bytes = <int>[0xFE, 0xFF];
    for (final unit in s.codeUnits) {
      bytes..add(unit >> 8)..add(unit & 0xFF);
    }
    return PdfString(Uint8List.fromList(bytes));
  }

  void _addComment(PdfComment c, Map<int, List<PdfRef>> annotsFor) {
    final page = pages[c.page];
    final quads = <Object?>[];
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final r in c.rects) {
      // the four corners of a mark, top left, top right, bottom left, bottom right (the order every viewer reads)
      for (final (dx, dy) in [(r[0], r[1]), (r[2], r[1]), (r[0], r[3]), (r[2], r[3])]) {
        final (x, y) = _toPage(page, dx, dy);
        quads..add(x)..add(y);
        minX = math.min(minX, x);
        minY = math.min(minY, y);
        maxX = math.max(maxX, x);
        maxY = math.max(maxY, y);
      }
    }
    if (quads.isEmpty) return;
    final annotNum = _alloc();
    final noteNum = _alloc();
    final popupNum = _alloc();
    final has = c.contents.isNotEmpty;
    newObjs[annotNum] = <String, Object?>{
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Highlight'),
      'Rect': <Object?>[minX, minY, maxX, maxY],
      'QuadPoints': quads,
      'C': <Object?>[...c.color],
      'CA': c.opacity,
      'F': 4, // print
      if (has) 'Contents': _text(c.contents),
      if (c.author.isNotEmpty) 'T': _text(c.author),
    };
    if (has) {
      // Many viewers (Evince among them) show the text of a comment only for a note
      // icon, never for a highlight; so the text is on a note next to the first mark too.
      final top = _toPage(page, c.rects.first[2], c.rects.first[1]);
      final nx = top.$1 + 2, ny = top.$2 - 18;
      newObjs[noteNum] = <String, Object?>{
        'Type': const PdfName('Annot'),
        'Subtype': const PdfName('Text'),
        'Rect': <Object?>[nx, ny, nx + 18, ny + 18],
        'Name': const PdfName('Comment'),
        'C': <Object?>[...c.color],
        'F': 28, // print, no zoom, no rotate
        'Contents': _text(c.contents),
        if (c.author.isNotEmpty) 'T': _text(c.author),
        'Popup': PdfRef(popupNum, 0),
      };
      newObjs[popupNum] = <String, Object?>{
        'Type': const PdfName('Annot'),
        'Subtype': const PdfName('Popup'),
        'Rect': <Object?>[nx + 22, ny - 100, nx + 242, ny + 18],
        'Parent': PdfRef(noteNum, 0),
        'Open': false,
        'F': 28,
      };
    } else {
      newObjs.remove(noteNum);
      newObjs.remove(popupNum);
    }
    final list = annotsFor.putIfAbsent(c.page, () => <PdfRef>[]);
    list.add(PdfRef(annotNum, 0));
    if (has) list..add(PdfRef(noteNum, 0))..add(PdfRef(popupNum, 0));
  }

  Uint8List run() {
    var size = 0;
    final declared = src.resolve(src.trailer['Size']);
    if (declared is int) size = declared;
    for (final n in src.xref.keys) {
      if (n + 1 > size) size = n + 1;
    }
    nextNum = size;

    // ---- 1. turn each overlay page into a Form XObject drawn by the target page
    final drawsFor = <int, List<({PdfRef form, List<double> cm})>>{};
    for (var k = 0; k < overlayPages.length; k++) {
      final opage = overlayPages[k];
      final box = ov.visibleBox(opage);

      // content: pass a single stream through untouched, else concatenate
      final contents = ov.resolve(opage.node['Contents']);
      final streams = <PdfStream>[];
      if (contents is List) {
        for (final c in contents) {
          final s = ov.resolve(c);
          if (s is PdfStream) streams.add(s);
        }
      } else if (contents is PdfStream) {
        streams.add(contents);
      }

      final form = <String, Object?>{
        'Type': const PdfName('XObject'),
        'Subtype': const PdfName('Form'),
        'FormType': 1,
        'BBox': <Object?>[box[0], box[1], box[2], box[3]],
      };
      final res = opage.inherited['Resources'];
      form['Resources'] = res == null ? <String, Object?>{} : _import(res);

      final Uint8List body;
      if (streams.length == 1) {
        final s = streams.first;
        for (final key in const ['Filter', 'DecodeParms']) {
          if (s.dict.containsKey(key)) form[key] = _import(s.dict[key]);
        }
        body = s.raw;
      } else {
        final bb = BytesBuilder();
        for (var i = 0; i < streams.length; i++) {
          if (i > 0) bb.addByte(10);
          bb.add(decodeStream(streams[i], ov));
        }
        body = bb.toBytes();
      }

      // The overlay is drawn in display space. The annotation lives in
      // unrotated page space and is rotated *with* the page, so pre-rotate the
      // form the opposite way (counter-clockwise by /Rotate).
      final t = targets[k];
      final page = pages[t];
      final rot = src.rotation(page);
      if (rot != 0) {
        final c = rot == 180 ? -1 : 0;
        final s = rot == 90 ? 1 : (rot == 270 ? -1 : 0);
        form['Matrix'] = <Object?>[c, s, -s, c, 0, 0];
      }

      final formNum = _alloc();
      newObjs[formNum] = PdfStream(form, body);

      // Where the form lands: its box (after the rotation above) is stretched
      // over the visible area of the page, as a viewer does for an annotation.
      final rect = src.visibleBox(page);
      final corners = <List<double>>[
        [box[0], box[1]],
        [box[2], box[1]],
        [box[2], box[3]],
        [box[0], box[3]],
      ];
      final c = rot == 180 ? -1.0 : 0.0;
      final sn = rot == 90 ? 1.0 : (rot == 270 ? -1.0 : 0.0);
      final turned = rot == 0
          ? corners
          : [for (final p in corners) [c * p[0] - sn * p[1], sn * p[0] + c * p[1]]];
      final minX = turned.map((p) => p[0]).reduce(math.min);
      final maxX = turned.map((p) => p[0]).reduce(math.max);
      final minY = turned.map((p) => p[1]).reduce(math.min);
      final maxY = turned.map((p) => p[1]).reduce(math.max);
      final sx = maxX > minX ? (rect[2] - rect[0]) / (maxX - minX) : 1.0;
      final sy = maxY > minY ? (rect[3] - rect[1]) / (maxY - minY) : 1.0;
      drawsFor.putIfAbsent(t, () => []).add((
        form: PdfRef(formNum, 0),
        cm: [sx, 0, 0, sy, rect[0] - minX * sx, rect[1] - minY * sy],
      ));
    }

    // ---- 1b. comments: a Highlight annotation with a note, and its pop-up, each
    final annotsFor = <int, List<PdfRef>>{};
    for (final c in comments) {
      _addComment(c, annotsFor);
    }

    // ---- 2. new version of every touched page dictionary
    final modified = <int, _Modified>{};
    final touched = {...drawsFor.keys, ...annotsFor.keys}.toList()..sort();
    for (final t in touched) {
      final draws = drawsFor[t] ?? const <({PdfRef form, List<double> cm})>[];
      final page = pages[t];
      final node = <String, Object?>{...page.node};

      if (draws.isNotEmpty) {
      // the page's resources (own or inherited) plus the overlay forms
      final baseResources = src.resolve(page.inherited['Resources']);
      if (baseResources != null && baseResources is! Map) {
        throw UnsupportedPdfException('/Resources is not a dictionary');
      }
      final resources = <String, Object?>{...?(baseResources as Map<String, Object?>?)};
      final baseForms = src.resolve(resources['XObject']);
      if (baseForms != null && baseForms is! Map) {
        throw UnsupportedPdfException('/XObject is not a dictionary');
      }
      final forms = <String, Object?>{...?(baseForms as Map<String, Object?>?)};
      final drawing = StringBuffer('Q\n'); // closes the q before the page's own content
      for (var i = 0; i < draws.length; i++) {
        var name = 'UniOverlay$i';
        while (forms.containsKey(name)) {
          name = '_$name';
        }
        forms[name] = draws[i].form;
        drawing.write('q ${draws[i].cm.map(formatReal).join(' ')} cm /$name Do Q\n');
      }
      resources['XObject'] = forms;
      node['Resources'] = resources;

      // a stream before the page's own content and one after: the page is drawn
      // in the state the overlay expects whatever the page leaves behind
      final existing = node['Contents'];
      final contents = <Object?>[];
      if (existing is List) {
        contents.addAll(existing);
      } else if (existing != null) {
        final resolved = src.resolve(existing);
        if (resolved is List) {
          contents.addAll(resolved);
        } else {
          contents.add(existing);
        }
      }
      final openNum = _alloc();
      newObjs[openNum] = PdfStream(<String, Object?>{}, Uint8List.fromList('q\n'.codeUnits));
      final closeNum = _alloc();
      newObjs[closeNum] = PdfStream(<String, Object?>{}, Uint8List.fromList(drawing.toString().codeUnits));
      node['Contents'] = <Object?>[PdfRef(openNum, 0), ...contents, PdfRef(closeNum, 0)];
      }

      final newAnnots = annotsFor[t];
      if (newAnnots != null) {
        final existing = src.resolve(node['Annots']);
        if (existing != null && existing is! List) {
          throw UnsupportedPdfException('/Annots is not an array');
        }
        node['Annots'] = <Object?>[...?(existing as List?), ...newAnnots];
      }
      modified[page.ref.num] = _Modified(page.ref.gen, node);
    }

    // ---- 3. append everything as an incremental update
    final out = BytesBuilder();
    out.add(original);
    if (original.isEmpty || original.last != 10) out.addByte(10);

    final offsetOf = <int, int>{};
    final genOf = <int, int>{};

    final newNums = newObjs.keys.toList()..sort();
    for (final n in newNums) {
      offsetOf[n] = out.length;
      genOf[n] = 0;
      writeIndirect(out, n, 0, newObjs[n]);
    }
    final modNums = modified.keys.toList()..sort();
    for (final n in modNums) {
      final m = modified[n]!;
      offsetOf[n] = out.length;
      genOf[n] = m.gen;
      writeIndirect(out, n, m.gen, m.node);
    }

    var newSize = nextNum;
    final trailer = <String, Object?>{'Root': src.trailer['Root']};
    for (final key in const ['Info', 'ID']) {
      if (src.trailer.containsKey(key)) trailer[key] = src.trailer[key];
    }
    trailer['Prev'] = src.startXref;

    if (!src.lastSectionIsStream) {
      // classic table (the original's newest section is a table too)
      final xrefPos = out.length;
      out.add('xref\n'.codeUnits);
      for (final run in _runs(offsetOf.keys.toList()..sort())) {
        out.add('${run.first} ${run.length}\n'.codeUnits);
        for (final n in run) {
          final off = offsetOf[n]!.toString().padLeft(10, '0');
          final gen = genOf[n]!.toString().padLeft(5, '0');
          out.add('$off $gen n \n'.codeUnits);
        }
      }
      trailer['Size'] = newSize;
      out.add('trailer\n'.codeUnits);
      writeObject(out, trailer);
      out.add('\nstartxref\n$xrefPos\n%%EOF\n'.codeUnits);
    } else {
      // xref stream (the original uses xref streams, so we do too)
      final xrefNum = newSize;
      newSize += 1;
      final xrefPos = out.length;
      offsetOf[xrefNum] = xrefPos;
      genOf[xrefNum] = 0;

      final rows = BytesBuilder();
      final index = <Object?>[];
      for (final run in _runs(offsetOf.keys.toList()..sort())) {
        index
          ..add(run.first)
          ..add(run.length);
        for (final n in run) {
          final off = offsetOf[n]!;
          if (off > 0xFFFFFFFF) {
            throw UnsupportedPdfException('file larger than 4 GiB');
          }
          final gen = math.min(genOf[n]!, 0xFFFF);
          rows.add(<int>[
            1,
            (off >> 24) & 0xFF,
            (off >> 16) & 0xFF,
            (off >> 8) & 0xFF,
            off & 0xFF,
            (gen >> 8) & 0xFF,
            gen & 0xFF,
          ]);
        }
      }
      final dict = <String, Object?>{
        'Type': const PdfName('XRef'),
        'Size': newSize,
        'W': <Object?>[1, 4, 2],
        'Index': index,
        ...trailer,
      };
      writeIndirect(out, xrefNum, 0, PdfStream(dict, rows.toBytes()));
      out.add('startxref\n$xrefPos\n%%EOF\n'.codeUnits);
    }
    return out.toBytes();
  }

  /// Groups sorted numbers into runs of consecutive numbers.
  static List<List<int>> _runs(List<int> sorted) {
    final runs = <List<int>>[];
    for (final n in sorted) {
      if (runs.isNotEmpty && runs.last.last == n - 1) {
        runs.last.add(n);
      } else {
        runs.add(<int>[n]);
      }
    }
    return runs;
  }
}
