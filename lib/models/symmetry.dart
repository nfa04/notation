import 'dart:math' as math;
import 'dart:ui';

/// What a line is repeated as while drawing.
enum SymmetryKind {
  off('Off'),
  leftRight('Mirror left and right'),
  upDown('Mirror up and down'),
  both('Mirror both ways'),
  radial('Around the centre'),
  kaleidoscope('Around the centre, mirrored');

  final String label;
  const SymmetryKind(this.label);
}

/// Drawing with a mirror or around a centre: every line is drawn again, turned or mirrored, on the same page (as lines of their
/// own, which are then all there is: nothing about them says they were symmetrical).
class Symmetry {
  /// The fewest and most turns of a drawing around the centre.
  static const fewest = 3, most = 12;

  static const off = Symmetry(SymmetryKind.off);

  final SymmetryKind kind;

  /// For [SymmetryKind.radial] and [SymmetryKind.kaleidoscope]: how many times the drawing is repeated around the centre.
  final int turns;

  const Symmetry(this.kind, {this.turns = 6});

  bool get isOff => kind == SymmetryKind.off;

  /// Whether the choice of [turns] means anything.
  bool get hasTurns => kind == SymmetryKind.radial || kind == SymmetryKind.kaleidoscope;

  Symmetry withTurns(int n) => Symmetry(kind, turns: n.clamp(fewest, most));

  /// How many lines are made besides the one drawn.
  int get copies {
    final n = turns.clamp(fewest, most);
    return switch (kind) {
      SymmetryKind.off => 0,
      SymmetryKind.leftRight || SymmetryKind.upDown => 1,
      SymmetryKind.both => 3,
      SymmetryKind.radial => n - 1,
      SymmetryKind.kaleidoscope => 2 * n - 1,
    };
  }

  /// Where each repeated point of [p] goes, about the [centre], one function for each copy of the line.
  List<Offset Function(Offset)> transforms(Offset centre) {
    Offset mirrorX(Offset p) => Offset(2 * centre.dx - p.dx, p.dy);
    Offset mirrorY(Offset p) => Offset(p.dx, 2 * centre.dy - p.dy);
    Offset turn(Offset p, double angle) {
      final d = p - centre;
      final c = math.cos(angle), s = math.sin(angle);
      return centre + Offset(d.dx * c - d.dy * s, d.dx * s + d.dy * c);
    }

    final n = turns.clamp(fewest, most);
    return switch (kind) {
      SymmetryKind.off => const [],
      SymmetryKind.leftRight => [mirrorX],
      SymmetryKind.upDown => [mirrorY],
      SymmetryKind.both => [mirrorX, mirrorY, (p) => mirrorX(mirrorY(p))],
      SymmetryKind.radial => [for (var i = 1; i < n; i++) (p) => turn(p, 2 * math.pi * i / n)],
      SymmetryKind.kaleidoscope => [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) (p) => turn(p, 2 * math.pi * i / n),
            (p) => turn(mirrorX(p), 2 * math.pi * i / n),
          ],
        ],
    };
  }

  /// The lines of the guide drawn on the page: for each, from where to where (the page is [size]).
  List<(Offset, Offset)> guides(Offset centre, Size size) {
    final reach = math.sqrt(size.width * size.width + size.height * size.height);
    (Offset, Offset) through(double angle) => (centre - Offset(math.cos(angle), math.sin(angle)) * reach, centre + Offset(math.cos(angle), math.sin(angle)) * reach);
    final n = turns.clamp(fewest, most);
    return switch (kind) {
      SymmetryKind.off => const [],
      SymmetryKind.leftRight => [through(math.pi / 2)],
      SymmetryKind.upDown => [through(0)],
      SymmetryKind.both => [through(math.pi / 2), through(0)],
      SymmetryKind.radial => [for (var i = 0; i < n; i++) (centre, centre + Offset(math.cos(2 * math.pi * i / n - math.pi / 2), math.sin(2 * math.pi * i / n - math.pi / 2)) * reach)],
      SymmetryKind.kaleidoscope => [through(math.pi / 2), for (var i = 0; i < n; i++) (centre, centre + Offset(math.cos(2 * math.pi * i / n - math.pi / 2), math.sin(2 * math.pi * i / n - math.pi / 2)) * reach)],
    };
  }

  @override
  bool operator ==(Object other) => other is Symmetry && other.kind == kind && other.turns == turns;

  @override
  int get hashCode => Object.hash(kind, turns);
}
