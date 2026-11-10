import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/draw_shapes.dart';
import 'package:notes/extensions/extension_host.dart';

List<List<double>> points(List<Map<String, Object?>> lines) => (lines.single['points']! as List).cast<List<double>>();

void main() {
  test('a rectangle, a triangle and a diamond are closed lines around their box', () {
    expect(points(shapeStrokes({'type': 'rectangle', 'x': 10, 'y': 20, 'width': 100, 'height': 50})), [
      [10, 20],
      [110, 20],
      [110, 70],
      [10, 70],
      [10, 20],
    ]);
    final triangle = points(shapeStrokes({'type': 'triangle', 'x': 0, 'y': 0, 'width': 10, 'height': 10}));
    expect(triangle.first, triangle.last);
    expect(triangle[0], [5, 0]);
    final diamond = points(shapeStrokes({'type': 'diamond', 'x': 0, 'y': 0, 'width': 10, 'height': 20}));
    expect(diamond.sublist(0, 4), [
      [5, 0],
      [10, 10],
      [5, 20],
      [0, 10],
    ]);
  });

  test('an ellipse touches the four sides of its box and closes', () {
    final p = points(shapeStrokes({'type': 'ellipse', 'x': 0, 'y': 0, 'width': 100, 'height': 40}));
    expect(p.first, p.last);
    expect(p.map((q) => q[0]).reduce((a, b) => a < b ? a : b), closeTo(0, 0.01));
    expect(p.map((q) => q[0]).reduce((a, b) => a > b ? a : b), closeTo(100, 0.01));
    expect(p.map((q) => q[1]).reduce((a, b) => a > b ? a : b), closeTo(40, 0.01));
  });

  test('an arrow is the line and a head at its end; the look is passed on', () {
    final lines = shapeStrokes({'type': 'arrow', 'x': 0, 'y': 0, 'x2': 100, 'y2': 0, 'color': '#ff0000', 'lineWidth': 4, 'dash': 'dashed'});
    final p = points(lines);
    expect(p[0], [0, 0]);
    expect(p[1], [100, 0]);
    expect(p[3], [100, 0], reason: 'back to the tip before the second wing');
    expect(p[2][0], lessThan(100), reason: 'the wings lean back');
    expect(p[2][1], isNot(p[4][1]), reason: 'one on each side');
    expect(lines.single['color'], '#ff0000');
    expect(lines.single['width'], 4);
    expect(lines.single['dash'], 'dashed');
  });

  test('what is not right says so', () {
    String why(Map<String, Object?> o) {
      try {
        shapeStrokes(o);
      } on ExtensionError catch (e) {
        return e.message;
      }
      return 'fine';
    }

    expect(why({'type': 'star', 'x': 0, 'y': 0}), contains('rectangle, ellipse'));
    expect(why({'type': 'rectangle', 'x': 0, 'y': 0, 'width': 0, 'height': 5}), contains('more than 0'));
    expect(why({'type': 'rectangle', 'x': 'left', 'y': 0, 'width': 5, 'height': 5}), contains('"x" has to be a number'));
    expect(why({'type': 'line', 'x': 1, 'y': 1, 'x2': 1, 'y2': 1}), contains('no length'));
    expect(why({'type': 'line', 'x': 0, 'y': 0, 'x2': 1, 'y2': 1, 'fill': '#fff'}), contains('cannot be filled'));
    expect(why({'type': 'ellipse', 'x': 0, 'y': 0, 'width': 5, 'height': 5, 'lineWidth': 0}), contains('0.1 to 300'));
    expect(why({'type': 'ellipse', 'x': 1e9, 'y': 0, 'width': 5, 'height': 5}), contains('out of range'));
  });
}
