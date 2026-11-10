import 'dart:math' as math;
import 'dart:ui';

/// What a pen does on text, besides writing and dragging a selection: the gestures of Scribble on iPadOS and of handwriting on Android.
enum PenGestureKind {
  /// A zigzag over a word: the word is deleted.
  scratchOut,

  /// A loop round some text: it is selected.
  circle,

  /// A short stroke down between two letters: a space is put there, or the space that is there is taken away.
  splitOrJoin,
}

class PenGesture {
  final PenGestureKind kind;

  /// Where the pen went, as a box (the same place as the points: the screen).
  final Rect box;

  const PenGesture(this.kind, this.box);

  @override
  String toString() => 'PenGesture($kind, $box)';
}

/// What the pen drew along [path] (the points of one stroke, from the pen down to the pen up), if it is one of the gestures; null: it is
/// a drag, or a stroke of no meaning. [lineHeight] is the height of a line of text where the pen is, which is the measure of all of it:
/// a gesture is the size of a word, not of a page.
PenGesture? recognizePenGesture(List<Offset> path, double lineHeight) {
  if (path.length < 6 || lineHeight <= 0) return null;
  var box = Rect.fromPoints(path.first, path.first);
  var length = 0.0;
  for (var i = 0; i < path.length; i++) {
    box = box.expandToInclude(Rect.fromPoints(path[i], path[i]));
    if (i > 0) length += (path[i] - path[i - 1]).distance;
  }
  final w = box.width, h = box.height, big = math.max(w, h);
  if (big < lineHeight * 0.5 || big > lineHeight * 12) return null;

  // a zigzag: it turns round at least three times, each time after a good stretch, and keeps to a line or two
  if (w >= lineHeight * 0.8 && h <= lineHeight * 1.8 && length >= w * 3 && _turns(path, math.max(lineHeight * 0.4, 6.0)) >= 3) {
    return PenGesture(PenGestureKind.scratchOut, box);
  }
  // a loop: it ends where it began, and has gone most of the way round on the way
  final ends = (path.last - path.first).distance;
  if (w >= lineHeight * 0.8 && h >= lineHeight * 0.6 && h <= lineHeight * 4 && ends <= big * 0.3 && length >= (w + h) * 1.35 && length <= (w + h) * 3 && _winding(path).abs() >= 4.2) {
    return PenGesture(PenGestureKind.circle, box);
  }
  // a stroke down: narrow, about a line tall, straight
  if (w <= h * 0.3 && h >= lineHeight * 0.9 && h <= lineHeight * 2.2 && length <= h * 1.25) {
    return PenGesture(PenGestureKind.splitOrJoin, box);
  }
  return null;
}

/// How many times the path turned round across (to the other way along x) after going at least [amplitude] the one way.
int _turns(List<Offset> path, double amplitude) {
  var turns = 0;
  var extreme = path.first.dx;
  int? direction; // 1: going right, -1: going left
  for (final p in path) {
    final dx = p.dx - extreme;
    if (direction == null) {
      if (dx.abs() >= amplitude) {
        direction = dx > 0 ? 1 : -1;
        extreme = p.dx;
      }
    } else if (direction > 0) {
      if (p.dx > extreme) {
        extreme = p.dx;
      } else if (extreme - p.dx >= amplitude) {
        turns++;
        direction = -1;
        extreme = p.dx;
      }
    } else {
      if (p.dx < extreme) {
        extreme = p.dx;
      } else if (p.dx - extreme >= amplitude) {
        turns++;
        direction = 1;
        extreme = p.dx;
      }
    }
  }
  return turns;
}

/// The angle the path turned through, all in all (a full circle is 2 pi, to the one side or the other).
double _winding(List<Offset> path) {
  var total = 0.0;
  Offset? last;
  for (var i = 1; i < path.length; i++) {
    final d = path[i] - path[i - 1];
    if (d.distance < 1) continue;
    if (last != null) {
      var turn = math.atan2(d.dy, d.dx) - math.atan2(last.dy, last.dx);
      while (turn > math.pi) {
        turn -= 2 * math.pi;
      }
      while (turn < -math.pi) {
        turn += 2 * math.pi;
      }
      total += turn;
    }
    last = d;
  }
  return total;
}
