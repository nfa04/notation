import 'dart:typed_data';

/// Which characters a TrueType font has a glyph for (read from its character map), so that text is only set in a font that can show it.
class TtfCoverage {
  final List<(int, int)> _ranges; // (first, last), sorted

  TtfCoverage._(this._ranges);

  bool covers(int codePoint) {
    var lo = 0;
    var hi = _ranges.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final (first, last) = _ranges[mid];
      if (codePoint < first) {
        hi = mid - 1;
      } else if (codePoint > last) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  bool coversAll(String text) => text.runes.every((c) => c < 0x20 || covers(c));

  /// Reads [font]; a coverage of nothing if it has no character map this reads.
  factory TtfCoverage.of(Uint8List font) {
    try {
      return TtfCoverage._(_read(ByteData.sublistView(font)));
    } catch (_) {
      return TtfCoverage._(const []);
    }
  }

  static List<(int, int)> _read(ByteData d) {
    final tables = d.getUint16(4);
    var cmap = -1;
    for (var i = 0; i < tables; i++) {
      final at = 12 + i * 16;
      if (String.fromCharCodes([for (var k = 0; k < 4; k++) d.getUint8(at + k)]) == 'cmap') cmap = d.getUint32(at + 8);
    }
    if (cmap < 0) return const [];
    // the Unicode subtable: full range (format 12) if there is one, else the basic one (format 4)
    int? best;
    var bestRank = -1;
    final subtables = d.getUint16(cmap + 2);
    for (var i = 0; i < subtables; i++) {
      final platform = d.getUint16(cmap + 4 + i * 8);
      final encoding = d.getUint16(cmap + 4 + i * 8 + 2);
      final offset = cmap + d.getUint32(cmap + 4 + i * 8 + 4);
      final format = d.getUint16(offset);
      final unicode = platform == 0 || platform == 3 && (encoding == 1 || encoding == 10);
      if (!unicode || (format != 4 && format != 12)) continue;
      final rank = format == 12 ? 2 : 1;
      if (rank > bestRank) {
        bestRank = rank;
        best = offset;
      }
    }
    if (best == null) return const [];
    final ranges = <(int, int)>[];
    if (d.getUint16(best) == 12) {
      final groups = d.getUint32(best + 12);
      for (var g = 0; g < groups; g++) {
        final at = best + 16 + g * 12;
        ranges.add((d.getUint32(at), d.getUint32(at + 4)));
      }
    } else {
      final segments = d.getUint16(best + 6) ~/ 2;
      final ends = best + 14;
      final starts = ends + segments * 2 + 2;
      final deltas = starts + segments * 2;
      final offsets = deltas + segments * 2;
      for (var s = 0; s < segments; s++) {
        final end = d.getUint16(ends + s * 2);
        final start = d.getUint16(starts + s * 2);
        if (start == 0xFFFF) continue;
        final rangeOffset = d.getUint16(offsets + s * 2);
        if (rangeOffset == 0) {
          // a range of consecutive glyphs: all there unless the delta maps one to glyph 0 (none)
          ranges.add((start, end));
        } else {
          // glyph ids in a table: a character is there where its entry is not 0
          int? runStart;
          for (var c = start; c <= end; c++) {
            final at = offsets + s * 2 + rangeOffset + (c - start) * 2;
            final has = at + 1 < d.lengthInBytes && d.getUint16(at) != 0;
            if (has && runStart == null) runStart = c;
            if (!has && runStart != null) {
              ranges.add((runStart, c - 1));
              runStart = null;
            }
          }
          if (runStart != null) ranges.add((runStart, end));
        }
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    return ranges;
  }
}
