import 'dart:typed_data';
import 'dart:ui';

/// The colour of the pixel at [x], [y] of a picture read as straight (not premultiplied) RGBA bytes, [width] pixels a row, as it
/// looks laid on [ground]: a see-through pixel shows the ground through it, the way the screen showed it. Null outside the picture
/// or where nothing at all was painted (nothing is there to pick).
Color? colorAtPixel(ByteData rgba, int width, int height, int x, int y, {Color ground = const Color(0xFFFFFFFF)}) {
  if (x < 0 || y < 0 || x >= width || y >= height) return null;
  final i = (y * width + x) * 4;
  if (i + 3 >= rgba.lengthInBytes) return null;
  final a = rgba.getUint8(i + 3);
  if (a == 0) return null;
  int over(int c, double g) => (c * a / 255 + g * 255 * (1 - a / 255)).round().clamp(0, 255);
  return Color.fromARGB(255, over(rgba.getUint8(i), ground.r), over(rgba.getUint8(i + 1), ground.g), over(rgba.getUint8(i + 2), ground.b));
}
