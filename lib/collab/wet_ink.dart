import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../data/point_codec.dart';
import '../models/canvas_models.dart';

/// A line that somebody is drawing right now ("wet ink"): the others see it grow as the pen moves, long before it is finished and
/// becomes a part of the note. Nothing of it is kept: when the finished line comes (as an ordinary change of the note), or the
/// person stops drawing it, or nothing more of it comes for [WetBook.staleAfter], it is gone.
class WetStroke {
  final String id;

  /// The device of the person who draws it.
  final String site;
  int page;
  final DrawingStroke stroke;

  /// Whether the pen was lifted (the finished line follows as a change of the note).
  bool ended = false;

  /// Points are missing in the middle (a message was lost): what comes on is not added until the whole line comes again.
  bool broken = false;

  DateTime touched;

  /// Goes up when the points were not added to but made again (a shape being drawn: a new rectangle each time the pen moves).
  int revision = 0;
  int _known = 0;
  Offset? _lastAt;

  WetStroke(this.id, this.site, this.page, this.stroke, this.touched);

  /// Looks whether the points of the line (drawn here) were added to, or made again since the last look.
  void _look() {
    final p = stroke.points;
    if (p.length < _known || (_known > 0 && p[_known - 1] != _lastAt)) revision++;
    _known = p.length;
    _lastAt = p.isEmpty ? null : p.last;
  }

  int get length => stroke.points.length;
}

/// The lines being drawn: by this device, and by others as they came in. A device that passes messages on (the host) sends each of
/// the others what it has of them, at the pace of its link ([WetLane]).
class WetBook extends ChangeNotifier {
  /// A line nothing more comes of for this long is taken away (the link of whoever drew it is gone, or the end was lost).
  static Duration staleAfter = const Duration(seconds: 5);

  /// A line whose pen was lifted is taken away when its finished form comes, or after this.
  static Duration endedFor = const Duration(seconds: 3);

  /// What one line may have, and how many lines may be in the book at once (whatever another device sends).
  static const maxPoints = 50000;
  static const maxStrokes = 64;
  static const maxIdLength = 200;

  final DateTime Function() _now;
  WetBook({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Map<String, WetStroke> _strokes = {};

  /// Lines that were finished (or dropped) not long ago: a late message about one of them does not bring it back.
  final List<String> _done = [];
  final Set<String> _doneSet = {};

  Iterable<WetStroke> get all => _strokes.values;
  WetStroke? operator [](String id) => _strokes[id];
  bool get isEmpty => _strokes.isEmpty;

  /// The lines on [page] that are not this device's own (those are drawn by the editor itself).
  List<DrawingStroke> on(int page, {String? except}) => [
        for (final w in _strokes.values)
          if (w.page == page && w.site != except && w.stroke.points.length >= 2) w.stroke,
      ];

  void _forget(String id) {
    if (_doneSet.add(id)) {
      _done.add(id);
      if (_done.length > 512) _doneSet.remove(_done.removeAt(0));
    }
  }

  // ---- the line drawn here

  /// The person here draws [stroke] on [page] (called as often as the pen moves: the points are those of the stroke itself).
  void drawing(String site, int page, DrawingStroke stroke) {
    final w = _strokes[stroke.id];
    if (w == null) {
      if (_doneSet.contains(stroke.id)) return;
      _strokes[stroke.id] = WetStroke(stroke.id, site, page, stroke, _now()).._look();
    } else {
      w
        ..page = page
        ..touched = _now()
        .._look();
    }
  }

  /// The pen was lifted from the line [id]: [kept] it is (the finished line follows), or not (a tap, a line that was undone).
  void ended(String id, {required bool kept}) {
    final w = _strokes[id];
    if (w == null) return;
    w
      ..ended = true
      ..touched = _now()
      .._look(); // (the end of a line can change it: a stabilised line is brought up to the pen)
    // (the others are told by the lanes; the line stays in the book until its finished form is sent, or for [endedFor])
    _dropped[id] = !kept;
  }

  /// Whether the line, as it ended, was dropped (not kept).
  final Map<String, bool> _dropped = {};
  bool droppedOf(String id) => _dropped[id] ?? false;

  /// The finished line [id] arrived (or the person here sent it): its wet form goes.
  bool finished(String id) {
    _forget(id);
    _dropped.remove(id);
    final had = _strokes.remove(id) != null;
    if (had) notifyListeners();
    return had;
  }

  // ---- lines drawn elsewhere

  /// The most lines one message may be about.
  static const maxPerMessage = 256;

  /// Takes in a message about lines being drawn on other devices (sent by [WetLane]: one line, or several in `all`). False when it
  /// changed nothing (or was not one). With [from], only lines drawn on that device are taken (a guest speaks only for its own); lines
  /// of [self] (this device: the editor draws them, from the very points that are in the book) never are.
  bool take(Map<String, Object?> m, {String? from, String? self}) {
    final all = m['all'];
    if (all is List) {
      var changed = false;
      for (final e in all.take(maxPerMessage)) {
        if (e is Map && _takeOne(e.cast<String, Object?>(), from, self)) changed = true;
      }
      return changed;
    }
    return _takeOne(m, from, self);
  }

  bool _takeOne(Map<String, Object?> m, String? onlyFrom, String? self) {
    final id = m['i'], site = m['s'], page = m['p'], from = m['f'], pts = m['pts'];
    if ((onlyFrom != null && site != onlyFrom) || (self != null && site == self)) return false;
    if (id is! String || id.isEmpty || id.length > maxIdLength || site is! String || site.length > 64) return false;
    if (page is! int || page < 0 || page > 1000000 || from is! int || from < 0 || from > maxPoints || pts is! String) return false;
    if (_doneSet.contains(id)) return false;
    var w = _strokes[id];
    if (m['x'] == 2) {
      // the person did not keep it
      if (w != null && w.site == site) {
        _strokes.remove(id);
        _forget(id);
        notifyListeners();
      }
      return w != null;
    }
    final List<Offset> points;
    try {
      if (pts.length > maxPoints * 12) return false;
      points = decodePoints(base64Decode(pts));
    } on FormatException {
      return false;
    } on Object {
      return false;
    }
    Uint8List? pressures;
    final pr = m['pr'];
    if (pr is String && pr.length <= maxPoints * 2) {
      try {
        pressures = base64Decode(pr);
      } on FormatException {
        pressures = null;
      }
    }
    if (w == null) {
      if (_strokes.length >= maxStrokes) return false;
      final color = m['c'], width = m['w'];
      if (color is! int || width is! num) return false;
      final stroke = DrawingStroke(
        id: id,
        color: Color(color),
        width: width.toDouble().clamp(0.1, 500.0),
        points: [],
        brush: m['b'] is String && (m['b'] as String).length < 200 ? m['b'] as String : penBrushId,
        dash: StrokeDash.byIndex(m['d'] is int ? m['d'] as int : null),
      );
      w = _strokes[id] = WetStroke(id, site, page, stroke, _now())..broken = from > 0;
    } else if (w.site != site) {
      return false; // (only whoever draws a line says how it goes on)
    }
    w
      ..page = page
      ..touched = _now();
    final have = w.stroke.points;
    var changed = false;
    final revision = m['r'] is int ? m['r'] as int : 0;
    if (revision < w.revision) return false; // (about points that were made again since)
    if (revision > w.revision) {
      // the points were made again: only the whole line can be shown
      w.revision = revision;
      if (from != 0) {
        w.broken = true;
        return false;
      }
    } else if (from == 0 && points.length < have.length && !w.broken) {
      return false; // (an old copy of the whole line, come late: there is more of it here)
    }
    if (from == 0) {
      // the whole line (the first message, or one that makes up for what was lost)
      have
        ..clear()
        ..addAll(points);
      w.stroke.pressures = pressures != null && pressures.length == points.length ? List.of(pressures) : null;
      w.broken = false;
      changed = true;
    } else if (!w.broken && from <= have.length && from + points.length > have.length) {
      final skip = have.length - from;
      have.addAll(points.skip(skip));
      final p = w.stroke.pressures;
      if (p != null) {
        if (pressures != null && pressures.length == points.length) {
          p.addAll(pressures.skip(skip));
        } else {
          w.stroke.pressures = null;
        }
      }
      changed = true;
    } else if (from > have.length) {
      w.broken = true; // (wait for the whole line)
    }
    if (have.length > maxPoints) {
      _strokes.remove(id);
      changed = true;
    }
    if (m['x'] == 1) {
      w.ended = true;
    }
    if (changed) notifyListeners();
    return changed;
  }

  /// A line of this device that nothing more happened to for this long counts as ended and kept (the screen that drew it never said
  /// so: it went away, or another tool took over in the middle of the line).
  static Duration abandonedAfter = const Duration(seconds: 30);

  /// Takes away lines that are stale. A line of this device ([self]) is left alone while it is being drawn (the pen may rest); once it
  /// ended, it goes like the others. Gives the lines of this device that were given up on (see [abandonedAfter]).
  List<String> expire(String self) {
    final now = _now();
    final gone = [
      for (final w in _strokes.values)
        if ((w.site != self || w.ended) && now.difference(w.touched) > (w.ended ? endedFor : staleAfter)) w.id,
    ];
    for (final id in gone) {
      _strokes.remove(id);
      _dropped.remove(id);
      _forget(id);
    }
    final abandoned = [
      for (final w in _strokes.values)
        if (w.site == self && !w.ended && now.difference(w.touched) > abandonedAfter) w.id,
    ];
    for (final id in abandoned) {
      ended(id, kept: true);
    }
    if (gone.isNotEmpty) notifyListeners();
    return abandoned;
  }

  /// Takes away the lines that [site] draws (it left).
  void dropSite(String site) {
    final gone = [for (final w in _strokes.values) if (w.site == site) w.id];
    for (final id in gone) {
      _strokes.remove(id);
    }
    if (gone.isNotEmpty) notifyListeners();
  }
}

/// What one link (to the host, or from the host to one guest) has been sent of the lines in a [WetBook]: each message carries what
/// is new since the last, and a new one goes only when the link took the last (a slow link gets fewer, bigger messages, never a pile
/// of old ones). A link that is new, or was made again, gets each line whole.
class WetLane {
  final Map<String, int> _sent = {};
  final Map<String, int> _revision = {};
  final Set<String> _endSent = {};
  bool busy = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// The least time between two messages on this link (longer for a poor one).
  Duration gap;

  WetLane({this.gap = Duration.zero});

  /// The next message for this link about one of the lines of [book] (but those of [except], who drew them; or only those of [only]),
  /// or null when it has all of it.
  Map<String, Object?>? next(WetBook book, {String? except, String? only, DateTime? now}) {
    final at = now ?? DateTime.now();
    if (busy || at.difference(_last) < gap) return null;
    _forgetGone(book);
    for (final w in book.all) {
      final m = _entry(book, w, except: except, only: only);
      if (m != null) {
        _last = at;
        return m;
      }
    }
    return null;
  }

  /// One message for this link with what is new of every line of [book] that has something new (as [next] picks them): lines drawn at
  /// the same time (a line and its mirror images, two people) all grow at once, however slow the link. A message of one line is as
  /// [next] makes it; several go as `{'t': 'wet', 'all': [...]}`.
  Map<String, Object?>? batch(WetBook book, {String? except, String? only, DateTime? now}) {
    final at = now ?? DateTime.now();
    if (busy || at.difference(_last) < gap) return null;
    _forgetGone(book);
    final all = [
      for (final w in book.all) ?_entry(book, w, except: except, only: only),
    ];
    if (all.isEmpty) return null;
    _last = at;
    return all.length == 1 ? all.single : {'t': 'wet', 'all': all};
  }

  /// (lines that are gone from the book are forgotten here too)
  void _forgetGone(WetBook book) {
    _sent.removeWhere((id, _) => book[id] == null);
    _revision.removeWhere((id, _) => book[id] == null);
    _endSent.removeWhere((id) => book[id] == null);
  }

  /// What is new of [w] for this link (and counts it as sent), or null.
  Map<String, Object?>? _entry(WetBook book, WetStroke w, {String? except, String? only}) {
    if (w.site == except || (only != null && w.site != only) || w.broken) return null;
    final remade = (_revision[w.id] ?? 0) != w.revision;
    final sent = remade ? 0 : (_sent[w.id] ?? 0);
    final have = w.length;
    final ending = w.ended && !_endSent.contains(w.id);
    if (have <= sent && !ending && !remade) return null;
    if (have < 2 && !ending) return null; // (one point shows nothing yet)
    final dropped = book.droppedOf(w.id);
    final from = sent > have ? 0 : sent;
    final pts = w.stroke.points.sublist(from);
    final pr = w.stroke.pressures;
    _sent[w.id] = have;
    _revision[w.id] = w.revision;
    if (w.ended) _endSent.add(w.id);
    return {
      't': 'wet',
      'i': w.id,
      's': w.site,
      'p': w.page,
      'f': from,
      if (w.revision > 0) 'r': w.revision,
      'pts': base64Encode(encodePoints(pts)),
      if (pr != null && pr.length == have) 'pr': base64Encode(Uint8List.fromList(pr.sublist(from))),
      'c': w.stroke.color.toARGB32(),
      'w': w.stroke.width,
      if (w.stroke.brush != penBrushId) 'b': w.stroke.brush,
      if (w.stroke.dash != StrokeDash.solid) 'd': w.stroke.dash.index,
      if (w.ended) 'x': dropped ? 2 : 1,
    };
  }

  /// Whether this link was sent the end of the line [id].
  bool endSent(String id) => _endSent.contains(id);

  /// The link was made again: everything goes again, whole.
  void reset() {
    _sent.clear();
    _revision.clear();
    _endSent.clear();
    busy = false;
  }
}
