import 'dart:typed_data';

import 'objects.dart';
import 'parser.dart' show isDelim;

/// Formats a real number without exponent notation.
String formatReal(double v) {
  if (v.isNaN || v.isInfinite) return '0';
  var s = v.toStringAsFixed(5);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return (s.isEmpty || s == '-0') ? '0' : s;
}

void _writeNameBody(BytesBuilder b, String name) {
  for (final unit in name.codeUnits) {
    final c = unit & 0xFF;
    if (c < 0x21 || c > 0x7E || isDelim(c) || c == 0x23) {
      b.add('#${c.toRadixString(16).toUpperCase().padLeft(2, '0')}'.codeUnits);
    } else {
      b.addByte(c);
    }
  }
}

/// Writes a direct object (everything except streams, which need
/// [writeIndirect]).
void writeObject(BytesBuilder b, Object? o) {
  if (o == null) {
    b.add('null'.codeUnits);
  } else if (o is bool) {
    b.add((o ? 'true' : 'false').codeUnits);
  } else if (o is int) {
    b.add(o.toString().codeUnits);
  } else if (o is double) {
    b.add(formatReal(o).codeUnits);
  } else if (o is PdfName) {
    b.addByte(0x2F);
    _writeNameBody(b, o.value);
  } else if (o is PdfString) {
    b.addByte(0x3C);
    for (final byte in o.bytes) {
      b.add(byte.toRadixString(16).padLeft(2, '0').codeUnits);
    }
    b.addByte(0x3E);
  } else if (o is PdfRef) {
    b.add('${o.num} ${o.gen} R'.codeUnits);
  } else if (o is List) {
    b.addByte(0x5B);
    for (var i = 0; i < o.length; i++) {
      if (i > 0) b.addByte(0x20);
      writeObject(b, o[i]);
    }
    b.addByte(0x5D);
  } else if (o is Map) {
    b.add('<<'.codeUnits);
    o.forEach((k, v) {
      b.addByte(0x2F);
      _writeNameBody(b, k as String);
      b.addByte(0x20);
      writeObject(b, v);
      b.addByte(0x0A);
    });
    b.add('>>'.codeUnits);
  } else {
    throw ArgumentError('cannot serialize ${o.runtimeType}');
  }
}

/// Writes `N G obj ... endobj`, including stream data when [value] is a
/// [PdfStream]. `/Length` is always recomputed.
void writeIndirect(BytesBuilder b, int num, int gen, Object? value) {
  b.add('$num $gen obj\n'.codeUnits);
  if (value is PdfStream) {
    final dict = <String, Object?>{...value.dict};
    dict['Length'] = value.raw.length;
    writeObject(b, dict);
    b.add('\nstream\n'.codeUnits);
    b.add(value.raw);
    b.add('\nendstream'.codeUnits);
  } else {
    writeObject(b, value);
  }
  b.add('\nendobj\n'.codeUnits);
}
