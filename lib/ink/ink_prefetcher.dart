import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/canvas_models.dart';
import 'ink_clusters.dart';
import 'ink_recognizer.dart';
import 'math_service.dart';

/// What has been read of a cluster so far.
class InkReading {
  /// The cluster as text, once read.
  String? text;

  /// The cluster as LaTeX, once read (only for what looks like a formula, see [looksLikeMaths]).
  String? latex;

  /// Whether the formula reader was asked (and did not fail), so that it is not asked again for what it did not take.
  bool mathTried = false;

  /// Whether reading it failed (it is not tried again until the ink changes).
  bool failed = false;

  /// The other readings of the formula (see [InkRecognizer.recognizeAgain]), once asked for; null until then. Empty after a correction
  /// by the person: what they wrote is what it says.
  List<String>? others;
}

/// Reads handwriting ahead of time. While the note is being worked on, the strokes that lie close together are
/// grouped ([clusterStrokes]) and, after things have been quiet for a moment, each group whose ink changed is read in
/// the background, one at a time, with the handwriting reader and, where it looks like a formula, the formula reader.
/// When the person then selects that writing and asks for it as text or as a formula, it is there at once
/// ([lookupText], [lookupMath]).
///
/// Nothing is read while the person is drawing ([canRun]), and the readers are used one job at a time: a conversion
/// that is asked for goes through [exclusive], after the piece in progress.
class InkPrefetcher extends ChangeNotifier {
  /// The strokes of each page as they are now.
  final Map<int, List<DrawingStroke>> Function() strokes;

  /// Whether it is a good moment to read (nothing being drawn, the app on screen).
  final bool Function() canRun;

  /// How long things have to be quiet before reading starts.
  final Duration idle;

  /// How many clusters are read in one go; the rest follows after another quiet moment.
  final int perBurst;

  /// Whether a block is worth reading now (null: all are). The editor reads what is on or beside the page in view only.
  final bool Function(InkCluster block)? wanted;

  /// A rest after each piece read, so that the screen keeps up while the models work.
  final Duration pause;

  InkPrefetcher({
    required this.strokes,
    bool Function()? canRun,
    this.idle = const Duration(milliseconds: 2500),
    this.perBurst = 12,
    this.wanted,
    this.pause = Duration.zero,
  }) : canRun = canRun ?? (() => true);

  InkRecognizer? _text;
  InkRecognizer? _math;

  /// Whether a block of several lines is read line by line (to check a worked solution step by step).
  bool _rows = false;
  final Map<String, InkReading> _cache = {};
  Timer? _timer;
  bool _disposed = false;
  bool _dirty = false;
  bool _running = false;
  Future<void> _lock = Future.value();

  /// How many clusters were read (text or formula) since this started.
  int reads = 0;

  /// The readers to use ([text]: handwriting, [math]: formulas), null for none. A reader that is not installed is not used.
  ///
  /// [rows]: read each line of a block of writing on its own, so that a worked solution can be checked step by step.
  void configure({InkRecognizer? text, InkRecognizer? math, bool? rows}) {
    if (!identical(_math, math)) {
      _math?.removeListener(_mathChanged);
      math?.addListener(_mathChanged);
    }
    _text = text;
    _math = math;
    _readBy ??= _mathModelName();
    if (rows != null) _rows = rows;
    changed();
  }

  /// The blocks of writing as they are now with what has been read of each (the formula, once read). Lines when
  /// reading by [rows].
  List<({InkCluster block, String? text, String? latex})> readings() => [
        for (final c in _clusters()) (block: c, text: _cache[c.key]?.text, latex: _cache[c.key]?.latex),
      ];

  bool get _hasText => _text != null && _text!.status == HandwritingStatus.installed;
  bool get _hasMath => _math != null && _math!.status == HandwritingStatus.installed;

  /// Whether anything is set up to read.
  bool get active => _hasText || _hasMath;

  /// How many clusters are waiting to be read.
  int get waiting => _todo(_clusters()).length;

  /// The ink changed (or may have): a look at what is left to read comes after things have been quiet for [idle].
  void changed() {
    if (_disposed) return;
    _dirty = true;
    _timer?.cancel();
    if (!active) return;
    _timer = Timer(idle, _burst);
  }

  /// Which formula model the formulas in [_cache] were read by (the readings of the one before are of no use once the person
  /// switches to another).
  String? _readBy;

  String _mathModelName() => switch (_math) { final MathService m => m.model.name, _ => '' };

  void _mathChanged() {
    if (_disposed) return;
    if (_readBy != null && _mathModelName() != _readBy) changed();
  }

  List<InkCluster> _clusters() => [
        for (final e in strokes().entries)
          ...clusterStrokes(e.key, e.value, rows: _rows),
      ];

  bool _needsText(InkReading? r) => _hasText && (r == null || (r.text == null && !r.failed));

  bool _needsMath(InkCluster c, InkReading? r) {
    if (!_hasMath) return false;
    if (r != null && (r.latex != null || r.mathTried || r.failed)) return false;
    // with a text reader, the text has to be read first to tell whether it looks like maths
    if (_hasText) return r?.text != null && looksLikeMaths(c, text: r!.text);
    return true;
  }

  List<InkCluster> _todo(List<InkCluster> clusters) => [
        for (final c in clusters)
          if ((wanted?.call(c) ?? true) && (_needsText(_cache[c.key]) || _needsMath(c, _cache[c.key]))) c,
      ];

  Future<void> _burst() async {
    if (_disposed || _running) return;
    if (!canRun()) {
      // not now (the person is drawing): look again in a moment
      _timer = Timer(const Duration(milliseconds: 1500), _burst);
      return;
    }
    _running = true;
    try {
      _dirty = false;
      final by = _mathModelName();
      if (by != _readBy) {
        _readBy = by;
        for (final r in _cache.values) {
          r.latex = null;
          r.mathTried = false;
          r.others = null;
        }
      }
      final clusters = _clusters();
      // what is not on the page any more is forgotten
      final alive = {for (final c in clusters) c.key};
      _cache.removeWhere((k, _) => !alive.contains(k));
      var done = 0;
      for (final c in _todo(clusters)) {
        if (_disposed || _dirty || !canRun() || done >= (_rows ? math.min(perBurst, 4) : perBurst)) break;
        await exclusive(() => _read(c));
        done++;
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      }
    } finally {
      _running = false;
    }
    if (_disposed) return;
    // more to do (a burst has a limit, or the ink changed meanwhile): after another quiet moment
    if (_dirty || _todo(_clusters()).isNotEmpty) {
      _timer?.cancel();
      _timer = Timer(_dirty ? idle : const Duration(milliseconds: 400), _burst);
    }
  }

  Future<void> _read(InkCluster c) async {
    final r = _cache.putIfAbsent(c.key, InkReading.new);
    try {
      if (_needsText(r)) {
        r.text = (await _text!.recognize(c.strokes)).trim();
        reads++;
      }
      if (_needsMath(c, r)) {
        r.latex = (await _math!.recognize(c.strokes)).trim();
        r.mathTried = true;
        reads++;
      }
    } catch (e) {
      r.failed = true; // (the model cannot read this; not again until it changes)
      debugPrint('[ink] could not read a block of writing ahead of time: $e');
    }
    if (!_disposed) notifyListeners();
  }

  /// Runs [job] when the reader is free: after the piece being read now, and before the next one. For a conversion
  /// that was asked for.
  Future<T> exclusive<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        done.complete(await job());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  /// The clusters that [selection] is exactly made of (every stroke of each, and no stroke outside them); null when it
  /// cuts a cluster, has strokes that are in none, or has none.
  List<InkCluster>? _clustersOf(Iterable<DrawingStroke> selection) {
    final chosen = {for (final s in selection) if (isInkStroke(s)) s.id};
    if (chosen.isEmpty) return null;
    final whole = <InkCluster>[];
    final covered = <String>{};
    for (final c in _clusters()) {
      final inside = c.ids.where(chosen.contains).length;
      if (inside == 0) continue;
      if (inside != c.strokes.length) return null; // part of a block: not what was read
      whole.add(c);
      covered.addAll(c.ids);
    }
    return covered.length == chosen.length ? whole : null;
  }

  /// The text of [selection] if it has been read ahead of time, else null.
  String? lookupText(Iterable<DrawingStroke> selection) {
    final clusters = _clustersOf(selection);
    if (clusters == null) return null;
    final parts = <InkCluster, String>{};
    for (final c in clusters) {
      final t = _cache[c.key]?.text;
      if (t == null) return null;
      parts[c] = t;
    }
    // reading order: lines top to bottom, what is on a line left to right
    final lines = <List<InkCluster>>[];
    for (final c in parts.keys) {
      final line = lines.where((l) => onOneLine(l.first.bounds, c.bounds)).firstOrNull;
      line == null ? lines.add([c]) : line.add(c);
    }
    lines.sort((a, b) => a.first.bounds.top.compareTo(b.first.bounds.top));
    return [
      for (final line in lines) (line..sort((a, b) => a.bounds.left.compareTo(b.bounds.left))).map((c) => parts[c]).join(' '),
    ].join('\n');
  }

  /// The formula (LaTeX) of [selection] if it has been read ahead of time, else null. Only one block at a time.
  String? lookupMath(Iterable<DrawingStroke> selection) {
    final clusters = _clustersOf(selection);
    if (clusters == null || clusters.length != 1) return null;
    return _cache[clusters.single.key]?.latex;
  }

  /// Whether the text ([math]: the formula) of [selection] is ready.
  bool isReady(Iterable<DrawingStroke> selection, {bool math = false}) => (math ? lookupMath(selection) : lookupText(selection)) != null;

  /// The other readings of the block [key] that have been made (see [lookAgain]); empty when none have, or none differ.
  List<String> othersOf(String key) => _cache[key]?.others ?? const [];

  /// Whether the block [key] was looked at again (or is being).
  bool lookedAgain(String key) => _cache[key]?.others != null || _asking.contains(key);

  final Set<String> _asking = {};

  /// Reads the formula of the block [key] again, another way (a thinner and a thicker pen: see [InkRecognizer.recognizeAgain]), in the
  /// background, after the piece in progress and when it is not a bad moment (the person drawing). It is done once for a block; the
  /// listeners hear when the other readings are there. For a line that was marked wrong: the reading may be what is wrong.
  Future<void> lookAgain(String key) async {
    final math = _math;
    if (_disposed || math == null || !_hasMath || lookedAgain(key)) return;
    final r = _cache[key];
    final found = _clusters().where((c) => c.key == key);
    if (r == null || r.latex == null || found.isEmpty) return;
    if (!canRun()) {
      Timer(const Duration(milliseconds: 1500), () => lookAgain(key));
      return;
    }
    _asking.add(key);
    try {
      final others = await exclusive(() => math.recognizeAgain(found.first.strokes));
      // (the person may have corrected it, or the ink changed, while it was being read)
      if (!_disposed && identical(_cache[key], r) && r.others == null) r.others = others;
    } catch (e) {
      debugPrint('[ink] could not read a block of writing again: $e');
      if (identical(_cache[key], r) && r.others == null) r.others = const [];
    } finally {
      _asking.remove(key);
    }
    if (!_disposed) notifyListeners();
  }

  /// The person corrected what was read for the block [key] (the formula of a line the model misread): this is what it
  /// says from now on, until its strokes change.
  void correct(String key, String latex) {
    final r = _cache.putIfAbsent(key, InkReading.new);
    r.latex = latex.trim();
    r.mathTried = true;
    r.failed = false;
    r.others = const []; // (what they wrote is what it says)
    if (!_disposed) notifyListeners();
  }

  /// Keeps what a conversion that was asked for read, if [selection] is exactly one block.
  void remember(Iterable<DrawingStroke> selection, String value, {bool math = false}) {
    final clusters = _clustersOf(selection);
    if (clusters == null || clusters.length != 1 || value.trim().isEmpty) return;
    final r = _cache.putIfAbsent(clusters.single.key, InkReading.new);
    if (math) {
      r.latex = value.trim();
      r.mathTried = true;
    } else {
      r.text = value.trim();
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _math?.removeListener(_mathChanged);
    super.dispose();
  }
}
