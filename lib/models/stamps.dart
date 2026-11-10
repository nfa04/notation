import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:path/path.dart' as p;

import '../data/note_file.dart';
import 'canvas_models.dart';

/// A drawing kept to be put on pages again and again: a symbol, a logo, a flourish, a stick figure. Its lines are placed with the
/// top left of the box around them at (0, 0).
class Stamp {
  final String id;
  final String name;
  final List<DrawingStroke> strokes;

  const Stamp(this.id, this.name, this.strokes);

  /// The box around the lines.
  Rect get bounds {
    Rect? r;
    for (final s in strokes) {
      for (final pt in s.points) {
        r = r == null ? Rect.fromPoints(pt, pt) : r.expandToInclude(Rect.fromPoints(pt, pt));
      }
    }
    return r ?? Rect.zero;
  }

  /// New lines of the stamp, as big as it was drawn times [scale], with the top left of its box at [topLeft]. (Each call makes new
  /// lines with new ids, so that a stamp put twice is two drawings.) The width of a line is scaled with it.
  List<DrawingStroke> placed(Offset topLeft, {double scale = 1, String? author, String layer = baseLayerId}) {
    return [
      for (final s in strokes)
        () {
          final copy = s.copyAt(Offset.zero, author: author);
          for (var i = 0; i < copy.points.length; i++) {
            copy.points[i] = copy.points[i] * scale + topLeft;
          }
          copy.width = math.max(0.5, s.width * scale);
          copy.layer = layer;
          return copy;
        }(),
    ];
  }

  /// A stamp of [lines] (copied, moved to the corner, and with no links to items), named [name].
  factory Stamp.of(String id, String name, Iterable<DrawingStroke> lines) {
    final copies = [for (final s in lines) if (s.points.length >= 2) s.copyAt(Offset.zero)];
    Rect? box;
    for (final s in copies) {
      for (final pt in s.points) {
        box = box == null ? Rect.fromPoints(pt, pt) : box.expandToInclude(Rect.fromPoints(pt, pt));
      }
    }
    final shift = box == null ? Offset.zero : -box.topLeft;
    return Stamp(id, name, [
      for (final s in copies)
        s
          ..layer = baseLayerId
          ..points.replaceRange(0, s.points.length, [for (final pt in s.points) pt + shift]),
    ]);
  }
}

/// The stamps, kept in a file of the folder the app keeps its files in.
class StampLibrary {
  final Future<Directory> Function() _folder;

  StampLibrary(this._folder);

  Future<File> _file() async => File(p.join((await _folder()).path, 'stamps.json'));

  /// The stamps, the oldest first; a file that cannot be read is no stamps.
  Future<List<Stamp>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString()) as List;
      return [
        for (final e in list)
          if (e is Map && e['id'] is String && e['data'] is String)
            Stamp(e['id'] as String, e['name'] is String ? e['name'] as String : '', decodeStrokes(base64Decode(e['data'] as String))[0] ?? const []),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Stamp> stamps) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final text = jsonEncode([
      for (final s in stamps) {'id': s.id, 'name': s.name, 'data': base64Encode(encodeStrokes({0: s.strokes}))},
    ]);
    await File('${file.path}.part').writeAsString(text, flush: true);
    await File('${file.path}.part').rename(file.path);
  }

  Future<void> add(Stamp stamp) async => _save([...await load(), stamp]);

  Future<void> remove(String id) async => _save([for (final s in await load()) if (s.id != id) s]);

  Future<void> rename(String id, String name) async => _save([for (final s in await load()) s.id == id ? Stamp(s.id, name, s.strokes) : s]);
}
