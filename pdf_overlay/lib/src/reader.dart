import 'dart:math' as math;
import 'dart:typed_data';

import 'filters.dart';
import 'objects.dart';
import 'parser.dart';

/// One cross-reference entry.
///
/// * type 0: free object
/// * type 1: in use, at byte offset [a], generation [b]
/// * type 2: in use, compressed inside object stream number [a] (at index [b],
///   which we do not rely on: the object stream's own index is searched)
class XrefEntry {
  final int type;
  final int a;
  final int b;
  const XrefEntry(this.type, this.a, this.b);
}

/// A leaf of the page tree together with its inheritable attributes
/// (`Resources`, `MediaBox`, `CropBox`, `Rotate`) already folded in.
class PdfPage {
  final PdfRef ref;
  final PdfDict node;
  final PdfDict inherited;
  PdfPage(this.ref, this.node, this.inherited);
}

class _Section {
  final PdfDict trailer;
  final bool isStream;
  _Section(this.trailer, this.isStream);
}

class _XrefStreamData {
  final Map<int, XrefEntry> entries;
  final PdfDict dict;
  _XrefStreamData(this.entries, this.dict);
}

class _ObjStm {
  final Uint8List data;
  final int first;
  final Map<int, int> offsets;
  _ObjStm(this.data, this.first, this.offsets);
}

/// Read-only access to the structure of a PDF file.
///
/// Understands classic xref tables, xref streams, hybrid files, `/Prev` chains,
/// object streams and Flate streams. Throws [UnsupportedPdfException] for
/// encrypted files and for files whose cross-reference data is damaged (we
/// refuse to guess; callers should fall back to another strategy).
class PdfReader implements Resolver {
  final Uint8List data;

  /// Merged cross-reference data, newest definition wins.
  final Map<int, XrefEntry> xref = <int, XrefEntry>{};

  /// Trailer of the newest cross-reference section.
  PdfDict trailer = <String, Object?>{};

  /// Whether the newest cross-reference section is an xref stream.
  bool lastSectionIsStream = false;

  /// Byte offset the final `startxref` points at.
  int startXref = 0;

  final Map<int, Object?> _cache = <int, Object?>{};
  final Set<int> _loading = <int>{};
  final Map<int, _ObjStm> _objStms = <int, _ObjStm>{};

  PdfReader(this.data) {
    _open();
  }

  void _open() {
    final limit = math.min(1024, data.length);
    final head = indexOfAscii(data, '%PDF-', 0, limit);
    if (head < 0) throw UnsupportedPdfException('not a PDF file');
    if (head != 0) {
      throw UnsupportedPdfException('data before the %PDF- header');
    }

    final sx = lastIndexOfAscii(data, 'startxref');
    if (sx < 0) throw UnsupportedPdfException('no startxref');
    startXref = PdfParser(data, sx + 9).readInt('startxref offset');

    final seen = <int>{};
    int? pos = startXref;
    var isFirst = true;
    while (pos != null) {
      if (pos >= data.length || !seen.add(pos)) {
        throw UnsupportedPdfException('invalid cross-reference chain');
      }
      final section = _readSection(pos);
      if (isFirst) {
        trailer = section.trailer;
        lastSectionIsStream = section.isStream;
        isFirst = false;
      }
      final prev = section.trailer['Prev'];
      pos = prev is int ? prev : (prev is double ? prev.toInt() : null);
    }

    if (trailer.containsKey('Encrypt')) {
      throw UnsupportedPdfException('encrypted PDF');
    }
    if (trailer['Root'] is! PdfRef) {
      throw UnsupportedPdfException('trailer has no /Root');
    }
  }

  void _merge(Map<int, XrefEntry> entries) {
    entries.forEach((k, v) {
      xref.putIfAbsent(k, () => v);
    });
  }

  _Section _readSection(int pos) {
    final p = PdfParser(data, pos);
    p.skipWs();
    if (p.startsWith('xref')) {
      p.pos += 4;
      final entries = <int, XrefEntry>{};
      while (true) {
        p.skipWs();
        if (p.startsWith('trailer')) {
          p.pos += 7;
          break;
        }
        final start = p.readInt('xref subsection start');
        final count = p.readInt('xref subsection size');
        for (var k = 0; k < count; k++) {
          final off = p.readInt('xref offset');
          final gen = p.readInt('xref generation');
          p.skipWs();
          if (p.pos >= data.length) {
            throw UnsupportedPdfException('truncated xref table');
          }
          final t = data[p.pos];
          p.pos++;
          if (t == 0x6E) {
            entries[start + k] = XrefEntry(1, off, gen);
          } else if (t == 0x66) {
            entries[start + k] = XrefEntry(0, 0, gen);
          } else {
            throw UnsupportedPdfException('bad xref entry type');
          }
        }
      }
      final tr = p.parseObject();
      if (tr is! Map<String, Object?>) {
        throw UnsupportedPdfException('malformed trailer');
      }
      _merge(entries);
      // Hybrid-reference file: entries from the xref stream rank below the
      // table's own entries but above everything older.
      final xs = tr['XRefStm'];
      if (xs is int) _merge(_readXrefStream(xs).entries);
      return _Section(tr, false);
    }
    final res = _readXrefStream(pos);
    _merge(res.entries);
    return _Section(res.dict, true);
  }

  static int _be(Uint8List b, int off, int width) {
    var v = 0;
    for (var i = 0; i < width; i++) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }

  _XrefStreamData _readXrefStream(int pos) {
    final ind = PdfParser(data, pos).parseIndirect();
    final stm = ind.value;
    if (stm is! PdfStream || stm.dict['Type'] != const PdfName('XRef')) {
      throw UnsupportedPdfException('cross-reference stream expected');
    }
    final bytes = decodeStream(stm, this);

    final wRaw = stm.dict['W'];
    if (wRaw is! List || wRaw.length != 3) {
      throw UnsupportedPdfException('bad /W in xref stream');
    }
    final w = <int>[for (final x in wRaw) x as int];

    final indexRaw = stm.dict['Index'];
    final List<int> index;
    if (indexRaw is List) {
      index = <int>[for (final x in indexRaw) x as int];
    } else {
      index = <int>[0, stm.dict['Size'] as int];
    }

    final rowLen = w[0] + w[1] + w[2];
    final entries = <int, XrefEntry>{};
    var p = 0;
    for (var s = 0; s + 1 < index.length; s += 2) {
      for (var k = 0; k < index[s + 1]; k++) {
        if (p + rowLen > bytes.length) {
          throw UnsupportedPdfException('truncated xref stream');
        }
        final type = w[0] == 0 ? 1 : _be(bytes, p, w[0]);
        final f2 = _be(bytes, p + w[0], w[1]);
        final f3 = _be(bytes, p + w[0] + w[1], w[2]);
        p += rowLen;
        entries[index[s] + k] = XrefEntry(type, f2, f3);
      }
    }
    return _XrefStreamData(entries, stm.dict);
  }

  /// Loads object [num] (null if free or unknown).
  Object? getObject(int num) {
    if (_cache.containsKey(num)) return _cache[num];
    if (!_loading.add(num)) {
      throw UnsupportedPdfException('circular reference through object $num');
    }
    try {
      final e = xref[num];
      Object? obj;
      if (e == null || e.type == 0) {
        obj = null;
      } else if (e.type == 1) {
        final ind =
            PdfParser(data, e.a, (ref) => getObject(ref.num)).parseIndirect();
        if (ind.num != num) {
          throw UnsupportedPdfException(
              'xref entry for object $num points at object ${ind.num}');
        }
        obj = ind.value;
      } else {
        obj = _fromObjStm(e.a, num);
      }
      _cache[num] = obj;
      return obj;
    } finally {
      _loading.remove(num);
    }
  }

  Object? _fromObjStm(int stmNum, int num) {
    var os = _objStms[stmNum];
    if (os == null) {
      final stm = getObject(stmNum);
      if (stm is! PdfStream) {
        throw UnsupportedPdfException('object stream $stmNum missing');
      }
      final bytes = decodeStream(stm, this);
      final n = resolve(stm.dict['N']);
      final first = resolve(stm.dict['First']);
      if (n is! int || first is! int) {
        throw UnsupportedPdfException('bad object stream header');
      }
      final hp = PdfParser(bytes, 0);
      final offs = <int, int>{};
      for (var i = 0; i < n; i++) {
        final on = hp.parseObject();
        final oo = hp.parseObject();
        if (on is! int || oo is! int) {
          throw UnsupportedPdfException('bad object stream index');
        }
        offs[on] = oo;
      }
      os = _ObjStm(bytes, first, offs);
      _objStms[stmNum] = os;
    }
    final off = os.offsets[num];
    if (off == null) {
      throw UnsupportedPdfException(
          'object $num not found in object stream $stmNum');
    }
    return PdfParser(os.data, os.first + off).parseObject();
  }

  /// Follows references until a direct object is reached.
  @override
  Object? resolve(Object? o) {
    for (var i = 0; i < 32; i++) {
      if (o is! PdfRef) return o;
      o = getObject(o.num);
    }
    throw UnsupportedPdfException('reference loop');
  }

  /// All pages in document order, with inherited attributes folded in.
  List<PdfPage> pages() {
    final root = resolve(trailer['Root']);
    if (root is! Map<String, Object?>) {
      throw UnsupportedPdfException('/Root is not a dictionary');
    }
    final out = <PdfPage>[];
    final visited = <int>{};

    void walk(Object? ref, PdfDict inherited) {
      if (ref is PdfRef && !visited.add(ref.num)) {
        throw UnsupportedPdfException('page tree contains a loop');
      }
      final node = resolve(ref);
      if (node is! Map<String, Object?>) {
        throw UnsupportedPdfException('page tree node is not a dictionary');
      }
      final next = <String, Object?>{...inherited};
      for (final k in const ['Resources', 'MediaBox', 'CropBox', 'Rotate']) {
        if (node.containsKey(k)) next[k] = node[k];
      }
      if (node.containsKey('Kids') && node['Type'] != const PdfName('Page')) {
        final kids = resolve(node['Kids']);
        if (kids is! List) {
          throw UnsupportedPdfException('/Kids is not an array');
        }
        for (final kid in kids) {
          walk(kid, next);
        }
      } else {
        if (ref is! PdfRef) {
          throw UnsupportedPdfException('page object is not indirect');
        }
        out.add(PdfPage(ref, node, next));
      }
    }

    walk(root['Pages'], <String, Object?>{});
    return out;
  }

  List<double>? _box(PdfPage page, String key) {
    final v = resolve(page.inherited[key]);
    if (v is! List || v.length != 4) return null;
    final n = <double>[];
    for (final e in v) {
      final x = resolve(e);
      if (x is! num) return null;
      n.add(x.toDouble());
    }
    return <double>[
      math.min(n[0], n[2]),
      math.min(n[1], n[3]),
      math.max(n[0], n[2]),
      math.max(n[1], n[3]),
    ];
  }

  /// The region a viewer shows, in default user space:
  /// CropBox clipped to MediaBox (MediaBox if there is no usable CropBox).
  List<double> visibleBox(PdfPage page) {
    final media = _box(page, 'MediaBox') ?? <double>[0, 0, 612, 792];
    final crop = _box(page, 'CropBox');
    if (crop == null) return media;
    final b = <double>[
      math.max(media[0], crop[0]),
      math.max(media[1], crop[1]),
      math.min(media[2], crop[2]),
      math.min(media[3], crop[3]),
    ];
    return (b[2] > b[0] && b[3] > b[1]) ? b : media;
  }

  /// Page rotation in degrees clockwise: 0, 90, 180 or 270.
  int rotation(PdfPage page) {
    final r = resolve(page.inherited['Rotate']);
    var deg = r is num ? r.toInt() : 0;
    deg = ((deg % 360) + 360) % 360;
    return deg % 90 == 0 ? deg : 0;
  }
}
