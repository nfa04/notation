import 'dart:typed_data';

import 'objects.dart';

bool isWs(int c) => c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;

bool isDelim(int c) =>
    c == 0x28 || // (
    c == 0x29 || // )
    c == 0x3C || // <
    c == 0x3E || // >
    c == 0x5B || // [
    c == 0x5D || // ]
    c == 0x7B || // {
    c == 0x7D || // }
    c == 0x2F || // /
    c == 0x25; // %

bool isDigit(int c) => c >= 0x30 && c <= 0x39;

bool isRegular(int c) => !isWs(c) && !isDelim(c);

int _hex(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

/// Index of [needle] in [d] starting at [from], or -1.
int indexOfAscii(Uint8List d, String needle, [int from = 0, int? to]) {
  final end = (to ?? d.length) - needle.length;
  final first = needle.codeUnitAt(0);
  for (var i = from; i <= end; i++) {
    if (d[i] != first) continue;
    var ok = true;
    for (var k = 1; k < needle.length; k++) {
      if (d[i + k] != needle.codeUnitAt(k)) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Index of the last occurrence of [needle] in [d], or -1.
int lastIndexOfAscii(Uint8List d, String needle) {
  for (var i = d.length - needle.length; i >= 0; i--) {
    var ok = true;
    for (var k = 0; k < needle.length; k++) {
      if (d[i + k] != needle.codeUnitAt(k)) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Resolves an indirect `/Length`. Return value should be an `int`.
typedef LengthResolver = Object? Function(PdfRef ref);

/// Parser for PDF objects (ISO 32000-1 §7.3) over a byte buffer.
class PdfParser {
  final Uint8List d;
  int pos;
  final LengthResolver? _resolveLength;

  PdfParser(this.d, [this.pos = 0, LengthResolver? resolveLength])
      : _resolveLength = resolveLength;

  bool startsWith(String s, [int? at]) {
    final p = at ?? pos;
    if (p < 0 || p + s.length > d.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (d[p + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// Skips whitespace and `%` comments.
  void skipWs() {
    final n = d.length;
    while (pos < n) {
      final c = d[pos];
      if (isWs(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < n && d[pos] != 10 && d[pos] != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  /// Reads an unsigned decimal integer (after optional whitespace).
  int readInt(String what) {
    skipWs();
    final start = pos;
    var v = 0;
    while (pos < d.length && isDigit(d[pos])) {
      v = v * 10 + (d[pos] - 0x30);
      pos++;
      if (pos - start > 15) {
        throw UnsupportedPdfException('$what too large at $start');
      }
    }
    if (pos == start) {
      throw UnsupportedPdfException('$what expected at $start');
    }
    return v;
  }

  /// Parses `N G obj <value>` at the current position.
  IndirectObject parseIndirect() {
    final n = readInt('object number');
    final g = readInt('generation number');
    skipWs();
    if (!startsWith('obj')) {
      throw UnsupportedPdfException('"obj" expected at $pos');
    }
    pos += 3;
    final v = parseObject();
    return IndirectObject(n, g, v);
  }

  /// Parses one object. Dictionaries followed by `stream` become [PdfStream].
  Object? parseObject() {
    skipWs();
    if (pos >= d.length) {
      throw UnsupportedPdfException('unexpected end of data');
    }
    final c = d[pos];
    if (c == 0x2F) return _parseName();
    if (c == 0x28) return _parseLiteralString();
    if (c == 0x3C) {
      if (pos + 1 < d.length && d[pos + 1] == 0x3C) return _parseDict();
      return _parseHexString();
    }
    if (c == 0x5B) return _parseArray();
    if (isDigit(c) || c == 0x2B || c == 0x2D || c == 0x2E) {
      return _parseNumberOrRef();
    }
    if (startsWith('true')) {
      pos += 4;
      return true;
    }
    if (startsWith('false')) {
      pos += 5;
      return false;
    }
    if (startsWith('null')) {
      pos += 4;
      return null;
    }
    throw UnsupportedPdfException('unexpected token at $pos');
  }

  PdfName _parseName() {
    pos++; // '/'
    final bytes = <int>[];
    while (pos < d.length && isRegular(d[pos])) {
      final c = d[pos];
      if (c == 0x23 &&
          pos + 2 < d.length &&
          _hex(d[pos + 1]) >= 0 &&
          _hex(d[pos + 2]) >= 0) {
        bytes.add(_hex(d[pos + 1]) * 16 + _hex(d[pos + 2]));
        pos += 3;
      } else {
        bytes.add(c);
        pos++;
      }
    }
    return PdfName(String.fromCharCodes(bytes));
  }

  PdfString _parseLiteralString() {
    pos++; // '('
    var depth = 1;
    final out = <int>[];
    final n = d.length;
    while (pos < n) {
      final c = d[pos];
      if (c == 0x5C) {
        pos++;
        if (pos >= n) break;
        final e = d[pos];
        switch (e) {
          case 0x6E:
            out.add(10);
            pos++;
            break;
          case 0x72:
            out.add(13);
            pos++;
            break;
          case 0x74:
            out.add(9);
            pos++;
            break;
          case 0x62:
            out.add(8);
            pos++;
            break;
          case 0x66:
            out.add(12);
            pos++;
            break;
          case 0x28:
          case 0x29:
          case 0x5C:
            out.add(e);
            pos++;
            break;
          case 13:
            pos++;
            if (pos < n && d[pos] == 10) pos++;
            break;
          case 10:
            pos++;
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = 0;
              var k = 0;
              while (k < 3 && pos < n && d[pos] >= 0x30 && d[pos] <= 0x37) {
                v = v * 8 + (d[pos] - 0x30);
                pos++;
                k++;
              }
              out.add(v & 0xFF);
            } else {
              out.add(e);
              pos++;
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.add(c);
        pos++;
      } else if (c == 0x29) {
        depth--;
        pos++;
        if (depth == 0) return PdfString(Uint8List.fromList(out));
        out.add(c);
      } else {
        out.add(c);
        pos++;
      }
    }
    throw UnsupportedPdfException('unterminated string');
  }

  PdfString _parseHexString() {
    pos++; // '<'
    final out = <int>[];
    int? hi;
    while (pos < d.length && d[pos] != 0x3E) {
      final h = _hex(d[pos]);
      pos++;
      if (h < 0) continue; // whitespace / junk
      if (hi == null) {
        hi = h;
      } else {
        out.add(hi * 16 + h);
        hi = null;
      }
    }
    if (pos >= d.length) {
      throw UnsupportedPdfException('unterminated hex string');
    }
    pos++; // '>'
    if (hi != null) out.add(hi * 16);
    return PdfString(Uint8List.fromList(out));
  }

  List<Object?> _parseArray() {
    pos++; // '['
    final arr = <Object?>[];
    while (true) {
      skipWs();
      if (pos >= d.length) throw UnsupportedPdfException('unterminated array');
      if (d[pos] == 0x5D) {
        pos++;
        return arr;
      }
      arr.add(parseObject());
    }
  }

  Object _parseNumberOrRef() {
    final start = pos;
    var p = pos;
    final n = d.length;
    final signed = d[p] == 0x2B || d[p] == 0x2D;
    if (signed) p++;
    var intDigits = 0;
    while (p < n && isDigit(d[p])) {
      p++;
      intDigits++;
    }
    var isReal = false;
    var fracDigits = 0;
    if (p < n && d[p] == 0x2E) {
      isReal = true;
      p++;
      while (p < n && isDigit(d[p])) {
        p++;
        fracDigits++;
      }
    }
    if (intDigits == 0 && fracDigits == 0) {
      throw UnsupportedPdfException('malformed number at $start');
    }
    final text = String.fromCharCodes(d.sublist(start, p));
    pos = p;
    if (isReal) return double.tryParse(text) ?? 0.0;
    final v = int.tryParse(text);
    if (v == null) throw UnsupportedPdfException('integer overflow at $start');
    if (!signed) {
      final gen = _tryRefTail();
      if (gen != null) return PdfRef(v, gen);
    }
    return v;
  }

  /// After an integer: tries to match `<ws> <digits> <ws> R`. Advances on success.
  int? _tryRefTail() {
    var p = pos;
    final n = d.length;
    var ws = 0;
    while (p < n && isWs(d[p])) {
      p++;
      ws++;
    }
    if (ws == 0) return null;
    var g = 0;
    var digits = 0;
    while (p < n && isDigit(d[p])) {
      g = g * 10 + (d[p] - 0x30);
      p++;
      digits++;
      if (digits > 7) return null;
    }
    if (digits == 0) return null;
    ws = 0;
    while (p < n && isWs(d[p])) {
      p++;
      ws++;
    }
    if (ws == 0) return null;
    if (p >= n || d[p] != 0x52) return null; // 'R'
    p++;
    if (p < n && isRegular(d[p])) return null;
    pos = p;
    return g;
  }

  Object _parseDict() {
    pos += 2; // '<<'
    final out = <String, Object?>{};
    while (true) {
      skipWs();
      if (pos + 1 < d.length && d[pos] == 0x3E && d[pos + 1] == 0x3E) {
        pos += 2;
        break;
      }
      if (pos >= d.length || d[pos] != 0x2F) {
        throw UnsupportedPdfException('dictionary key expected at $pos');
      }
      final key = _parseName().value;
      out[key] = parseObject();
    }

    // Is this dictionary the head of a stream?
    var p = pos;
    while (p < d.length && isWs(d[p])) {
      p++;
    }
    if (!startsWith('stream', p)) return out;
    p += 6;
    if (p < d.length && d[p] == 13) {
      p++;
      if (p < d.length && d[p] == 10) p++;
    } else if (p < d.length && d[p] == 10) {
      p++;
    } else {
      return out;
    }
    final start = p;

    Object? len = out['Length'];
    final resolver = _resolveLength;
    if (len is PdfRef && resolver != null) len = resolver(len);

    var endPos = -1;
    if (len is int && len >= 0 && start + len <= d.length) {
      var q = start + len;
      while (q < d.length && isWs(d[q])) {
        q++;
      }
      if (startsWith('endstream', q)) endPos = start + len;
    }
    if (endPos < 0) {
      // /Length missing or wrong: scan for the keyword like viewers do.
      final idx = indexOfAscii(d, 'endstream', start);
      if (idx < 0) throw UnsupportedPdfException('stream without endstream');
      endPos = idx;
      if (endPos - 2 >= start && d[endPos - 2] == 13 && d[endPos - 1] == 10) {
        endPos -= 2;
      } else if (endPos - 1 >= start &&
          (d[endPos - 1] == 10 || d[endPos - 1] == 13)) {
        endPos -= 1;
      }
    }
    pos = endPos;
    return PdfStream(out, Uint8List.fromList(d.sublist(start, endPos)));
  }
}
