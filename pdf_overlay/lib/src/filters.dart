import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'objects.dart';

/// Something that can follow indirect references.
abstract class Resolver {
  Object? resolve(Object? o);
}

/// Decodes a stream's data. Only `FlateDecode` (with optional PNG predictors) is
/// supported, which covers xref streams, object streams and the content
/// streams written by common PDF generators. Anything else throws
/// [UnsupportedPdfException].
Uint8List decodeStream(PdfStream s, Resolver r) {
  final f = r.resolve(s.dict['Filter']);
  if (f == null) return s.raw;
  final parmsRaw = r.resolve(s.dict['DecodeParms']);
  final filters = f is List ? f : <Object?>[f];

  var data = s.raw;
  for (var i = 0; i < filters.length; i++) {
    final name = r.resolve(filters[i]);
    Object? pr = parmsRaw is List
        ? (i < parmsRaw.length ? parmsRaw[i] : null)
        : parmsRaw;
    pr = r.resolve(pr);
    final parms = <String, Object?>{};
    if (pr is Map) {
      pr.forEach((k, v) {
        parms[k as String] = r.resolve(v);
      });
    }
    if (name is! PdfName ||
        (name.value != 'FlateDecode' && name.value != 'Fl')) {
      throw UnsupportedPdfException('unsupported stream filter $name');
    }
    data = _undoPredictor(_inflate(data), parms);
  }
  return data;
}

Uint8List _inflate(Uint8List data) {
  try {
    return ZLibDecoder().decodeBytes(data);
  } catch (e) {
    throw UnsupportedPdfException('cannot inflate stream ($e)');
  }
}

int _asInt(Object? v, int fallback) => v is int ? v : fallback;

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

Uint8List _undoPredictor(Uint8List data, Map<String, Object?> parms) {
  final pred = _asInt(parms['Predictor'], 1);
  if (pred == 1) return data;
  if (pred < 10) throw UnsupportedPdfException('TIFF predictor $pred');

  final cols = _asInt(parms['Columns'], 1);
  final colors = _asInt(parms['Colors'], 1);
  final bpc = _asInt(parms['BitsPerComponent'], 8);
  final rowLen = (colors * bpc * cols + 7) ~/ 8;
  final bpp = math.max(1, (colors * bpc + 7) ~/ 8);
  final rows = (data.length + rowLen) ~/ (rowLen + 1);
  final out = Uint8List(rows * rowLen);

  for (var r = 0; r < rows; r++) {
    final src = r * (rowLen + 1);
    final tag = data[src];
    final dst = r * rowLen;
    for (var i = 0; i < rowLen; i++) {
      final si = src + 1 + i;
      final x = si < data.length ? data[si] : 0;
      final a = i >= bpp ? out[dst + i - bpp] : 0;
      final b = r > 0 ? out[dst - rowLen + i] : 0;
      final c = (r > 0 && i >= bpp) ? out[dst - rowLen + i - bpp] : 0;
      int v;
      switch (tag) {
        case 1:
          v = x + a;
          break;
        case 2:
          v = x + b;
          break;
        case 3:
          v = x + ((a + b) >> 1);
          break;
        case 4:
          v = x + _paeth(a, b, c);
          break;
        default:
          v = x;
      }
      out[dst + i] = v & 0xFF;
    }
  }
  return out;
}
