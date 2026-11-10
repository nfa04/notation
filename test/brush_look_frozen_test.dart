import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/canvas_models.dart';

/// A line that has everything a brush looks at: bends, a pressure for every point, a long run and a short one.
DrawingStroke sampleStroke(String id, double width, {bool short = false}) {
  if (short) {
    return DrawingStroke(id: id, color: const Color(0xFF000000), width: width, points: const [Offset(10, 10), Offset(14, 12)]);
  }
  final points = [for (var i = 0; i < 90; i++) Offset(20.0 + i * 3.7, 80 + 35 * math.sin(i / 7) + (i % 5)) ];
  return DrawingStroke(
    id: id,
    color: const Color(0xFF000000),
    width: width,
    points: points,
    pressures: [for (var i = 0; i < points.length; i++) 40 + (i * 37) % 200],
  );
}

String _n(double v) => v.toStringAsFixed(3);

/// Everything a brush makes of a line, as one text: the pieces of the outline, the layers with their opacity, and the soft layers.
/// ([shape] is a BrushShape; it is read without its type so that the same text can be made of any version of the class.)
String lookOf(dynamic shape) {
  if (shape == null) return 'none';
  final b = StringBuffer();
  void outline(Outline o) {
    for (final piece in o.pieces) {
      switch (piece) {
        case OutlinePolygon(:final points):
          b.write('P${points.length}:');
          for (final p in points) {
            b.write('${_n(p.dx)},${_n(p.dy)};');
          }
        case OutlineOval(:final rect):
          b.write('O${_n(rect.left)},${_n(rect.top)},${_n(rect.right)},${_n(rect.bottom)};');
        case OutlineRibbon(:final points, :final half):
          b.write('R${points.length}:');
          for (var i = 0; i < points.length; i++) {
            b.write('${_n(points[i].dx)},${_n(points[i].dy)},${_n(half[i])};');
          }
      }
    }
  }

  void path(Path p) {
    final r = p.getBounds();
    var length = 0.0;
    for (final m in p.computeMetrics()) {
      length += m.length;
    }
    b.write('path ${_n(r.left)},${_n(r.top)},${_n(r.right)},${_n(r.bottom)} len ${length.toStringAsFixed(1)};');
  }

  b.write('filled ${shape.filled} opacity ${_n(shape.opacity as double)}|');
  // (what was added after the first brushes is written only where it is used, so that the text of a brush that does not use it is as it was)
  if (shape.multiply == true) b.write('multiply|');
  outline(shape.outline as Outline);
  for (final l in shape.layers as List) {
    b.write('|layer ${_n(l.opacity as double)}:');
    if ((l.lightness as double) != 0 || (l.hue as double) != 0) b.write('tint ${_n(l.lightness as double)},${_n(l.hue as double)}:');
    outline(l.outline as Outline);
  }
  final soft = shape.soft;
  if (soft != null) {
    for (final l in soft.blurred as List) {
      b.write('|blur ${_n(l.opacity as double)} ${_n(l.blur as double)} ');
      path(l.path as Path);
    }
    for (final l in soft.crisp as List) {
      b.write('|crisp ${_n(l.opacity as double)} ');
      path(l.path as Path);
    }
    for (final l in soft.grain as List) {
      b.write('|grain ${_n(l.opacity as double)} ');
      path(l.path as Path);
    }
  }
  return b.toString();
}

/// A short fingerprint of a text (FNV-1a, 32 bits twice).
String fingerprint(String text) {
  var a = 0x811C9DC5, b = 0x01000193 ^ 0xA5A5A5A5;
  for (final u in text.codeUnits) {
    a = ((a ^ u) * 0x01000193) & 0xFFFFFFFF;
    b = ((b ^ u) * 0x85EBCA6B) & 0xFFFFFFFF;
  }
  return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
}

/// What the brushes the app came with make of the sample lines, as a fingerprint for each.
Map<String, String> currentLooks() {
  final out = <String, String>{};
  for (final brush in [Brushes.roller, ...Brushes.creative]) {
    for (final (name, stroke) in [
      ('wide', sampleStroke('look-a', 14)),
      ('thin', sampleStroke('look-b', 4)),
      ('short', sampleStroke('look-c', 8, short: true)),
    ]) {
      out['${brush.id} $name'] = fingerprint(lookOf(brush.shape(stroke)));
    }
  }
  return out;
}

/// The fingerprints of the brushes as they were before brushes could be designed. They must never change: a note drawn with the
/// roller or the charcoal has to look the same in every version of the app.
const frozenLooks = <String, String>{
  'roller wide': '5025ef35f14e6102',
  'roller thin': '5e0c5959aa31ad0e',
  'roller short': '2a163a66dc2ec17b',
  'pencil wide': '14532909452c2822',
  'pencil thin': '91a07e67499bb97c',
  'pencil short': '1dd70aad06ee9538',
  'fountain wide': '1ce20ac6fbf79737',
  'fountain thin': 'fdabfebb438e0c1e',
  'fountain short': 'e5268587b788d032',
  'calligraphy wide': 'c67228bec20df279',
  'calligraphy thin': '2161406cc16fd6a3',
  'calligraphy short': '103bac0075bb26e7',
  'marker wide': '8020be10ad3bfd5d',
  'marker thin': '9f11cb3a52ce90eb',
  'marker short': '7225763d01039ab4',
  'charcoal wide': '6443933f0c32fdca',
  'charcoal thin': '71fb6239db0affc0',
  'charcoal short': '4cce3e2a0122f26d',
  'airbrush wide': '3912f529cfae3300',
  'airbrush thin': '044036e52e065ec2',
  'airbrush short': '0c4e2768cad260ef',
  'watercolour wide': '4cffea5e7606c90b',
  'watercolour thin': '15aca1ce9e417e1f',
  'watercolour short': 'feafb1c86daaa865',
};

void main() {
  test('the brushes the app came with look exactly as they always did', () {
    final now = currentLooks();
    expect(now.keys.toSet(), frozenLooks.keys.toSet());
    for (final e in frozenLooks.entries) {
      expect(now[e.key], e.value, reason: e.key);
    }
  });
}
