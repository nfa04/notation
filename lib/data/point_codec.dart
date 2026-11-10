import 'dart:typed_data';
import 'dart:ui';

/// Packs stroke points as little-endian float32 x,y pairs for the
/// `strokes.points` column (8 bytes per point).
Uint8List encodePoints(List<Offset> points) {
  final data = ByteData(points.length * 8);
  for (var i = 0; i < points.length; i++) {
    data.setFloat32(i * 8, points[i].dx, Endian.little);
    data.setFloat32(i * 8 + 4, points[i].dy, Endian.little);
  }
  return data.buffer.asUint8List();
}

List<Offset> decodePoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i + 8 <= bytes.length; i += 8)
      Offset(data.getFloat32(i, Endian.little), data.getFloat32(i + 4, Endian.little)),
  ];
}
