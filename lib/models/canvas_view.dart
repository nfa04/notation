import 'dart:math' as math;
import 'dart:ui';

import 'canvas_models.dart';
import 'image_item.dart';

/// The side of the surface of a note that is an infinite canvas, in the units of a page (an A4 sheet is 800 across): some
/// hundred sheets each way. Everything on the canvas is on page 0 of the note and has its place on this surface.
const double canvasExtent = 100000;

/// Where a new canvas starts: the middle of the surface, so that there is room all round.
const Offset canvasOrigin = Offset(canvasExtent / 2, canvasExtent / 2);

/// The least height a text box is taken to have when the box was not pulled to a height (it is as tall as its text).
const double _boxHeight = 40;

/// The smallest rectangle that holds everything placed on a canvas, or null if there is nothing.
Rect? canvasContentBounds({
  Iterable<DrawingStroke> strokes = const [],
  Iterable<TextBoxWidgetModel> boxes = const [],
  Iterable<ImageItem> images = const [],
}) {
  double? left, top, right, bottom;
  void add(Rect r) {
    left = left == null ? r.left : math.min(left!, r.left);
    top = top == null ? r.top : math.min(top!, r.top);
    right = right == null ? r.right : math.max(right!, r.right);
    bottom = bottom == null ? r.bottom : math.max(bottom!, r.bottom);
  }

  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    var l = s.points.first.dx, t = s.points.first.dy, r = l, b = t;
    for (final p in s.points) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    add(Rect.fromLTRB(l, t, r, b).inflate(s.width / 2));
  }
  for (final b in boxes) {
    add(b.position & Size(b.size.width, math.max(b.size.height, _boxHeight)));
  }
  for (final m in images) {
    add(m.position & m.size);
  }
  if (left == null) return null;
  return Rect.fromLTRB(left!, top!, right!, bottom!);
}

/// The part of a canvas to show in a small picture of it (a card, a version in the history): the [bounds] of what is on it with
/// some room round it, at least the size of a small page, and with the proportions [aspect] (height over width) if given.
/// An empty canvas shows where it starts.
Rect canvasWindow(Rect? bounds, {double? aspect}) {
  var r = (bounds ?? (canvasOrigin & const Size(760, 520))).inflate(40);
  if (r.width < 400) r = Rect.fromCenter(center: r.center, width: 400, height: r.height);
  if (r.height < 300) r = Rect.fromCenter(center: r.center, width: r.width, height: 300);
  if (aspect != null) {
    final w = math.max(r.width, r.height / aspect);
    r = Rect.fromCenter(center: r.center, width: w, height: w * aspect);
  }
  return r;
}
