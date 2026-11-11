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

  /// What the writing says as text: what the text reader made of it, except that when that is nothing but formulas (`$...$`) the
  /// formula reader's reading is put in their place. It reads handwritten maths far better (on 200 real formulas 8 % of the
  /// characters wrong against 29 %); a line with words and a formula in it stays as the text reader read it, since the strokes of
  /// the formula alone are not known.
  String? get bestText {
    final t = text, l = latex;
    if (t == null || l == null || l.isEmpty || !onlyMaths(t)) return t;
    return '\$$l\$';
  }
}

/// Whether [text] is only formulas in dollar signs (with spaces and signs of punctuation between them), as the text reader writes
/// maths it takes for maths.
bool onlyMaths(String text) {
  final t = text.trim();
  if (!t.contains(r'$')) return false;
  final rest = t.replaceAll(RegExp(r'\$\$[^$]+\$\$|\$[^$]+\$'), '');
  return !rest.contains(RegExp(r'[\p{L}\p{N}$]', unicode: true));
}

/// What a conversion of a selection that is not a whole block read, and the strokes it was.
class _Picked {
  final Set<String> ids;
  String? text, latex;
  _Picked(this.ids);
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

  /// Which blocks come first (lower first; null: in the order of the pages). The editor reads the page in view first.
  final int Function(InkCluster block)? order;

  InkPrefetcher({
    required this.strokes,
    bool Function()? canRun,
    this.idle = const Duration(milliseconds: 2500),
    this.perBurst = 12,
    this.wanted,
    this.pause = Duration.zero,
    this.order,
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

  /// Told how many clusters are still to be read, when a burst starts and after each piece (0 when all is read).
  void Function(int waiting)? onPending;

  /// Whether reading waits (what was read at an earlier time is being loaded, see [seed]); [release] lets it go on.
  bool holding = false;

  void release() {
    if (!holding) return;
    holding = false;
    changed();
  }

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
        for (final c in _clusters()) (block: c, text: _cache[c.key]?.bestText, latex: _cache[c.key]?.latex),
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
    _stampsChecked.clear(); // (a stroke may have been moved or changed in place: the next grouping looks at the stamps)
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

  List<InkCluster> _clusters() => _rows ? _rowClusters() : _blocks();

  /// The clusters of each page, grouped again only where a page changed.
  final _pages = PageClusters();

  /// The kinds of grouping (by block: false, by rows: true) whose strokes were checked to the stamp since the ink last [changed].
  final Set<bool> _stampsChecked = {};

  List<InkCluster> _grouped(bool rows) {
    final pages = strokes();
    _pages.keepOnly(pages.keys);
    final stamps = _stampsChecked.add(rows);
    return [
      for (final e in pages.entries) ..._pages.of(e.key, e.value, rows: rows, stamps: stamps),
    ];
  }

  List<InkCluster> _blocks() => _grouped(false);

  List<InkCluster> _rowClusters() => _grouped(true);

  /// The rows of [rows] that [block] is made of, top to bottom; null when they do not make it up exactly.
  static List<InkCluster>? _rowsOf(InkCluster block, List<InkCluster> rows) {
    final ids = block.ids;
    final parts = [for (final r in rows) if (r.page == block.page && ids.containsAll(r.ids)) r];
    if (parts.isEmpty || parts.fold(0, (n, r) => n + r.strokes.length) != block.strokes.length) return null;
    return parts..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  }

  bool _needsText(InkReading? r) => _hasText && (r == null || (r.text == null && !r.failed));

  bool _needsMath(InkCluster c, InkReading? r) {
    if (!_hasMath) return false;
    if (r != null && (r.latex != null || r.mathTried || r.failed)) return false;
    // with a text reader, the text has to be read first to tell whether it looks like maths
    if (_hasText) return r?.text != null && (onlyMaths(r!.text!) || looksLikeMaths(c, text: r.text));
    return true;
  }

  List<InkCluster> _todo(List<InkCluster> clusters) {
    final todo = [
      for (final c in clusters)
        if ((wanted?.call(c) ?? true) && (_needsText(_cache[c.key]) || _needsMath(c, _cache[c.key]))) c,
    ];
    final by = order;
    if (by == null) return todo;
    final rank = {for (final c in todo) c: by(c)};
    mergeSort(todo, compare: (a, b) => rank[a]!.compareTo(rank[b]!)); // (stable: top to bottom within a page)
    return todo;
  }

  /// A lone stroke that is flat (a bar, a dash, a line under something) says nothing to a reader: it is taken as read, with no text,
  /// and no model is woken for it (2.7 s of the reader on a desktop for "---").
  static bool _nothingToRead(InkCluster c) => c.strokes.length == 1 && c.bounds.height < 0.25 * c.bounds.width && c.bounds.height < 12;

  Future<void> _burst() async {
    if (_disposed || _running || holding) return; // (holding: [release] starts it)
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
        _keptMath.clear(); // (read by the other model)
        for (final p in _picked.values) {
          p.latex = null;
        }
      }
      final clusters = _clusters();
      // what is not on the page any more is forgotten
      final alive = {for (final c in clusters) c.key};
      _cache.removeWhere((k, _) => !alive.contains(k));
      _forgetPicked();
      _useKept(clusters);
      var done = 0;
      final todo = _todo(clusters);
      onPending?.call(todo.length);
      for (final c in todo) {
        if (_disposed || _dirty || !canRun() || done >= (_rows ? math.min(perBurst, 4) : perBurst)) break;
        await exclusive(() => _read(c));
        done++;
        if (!_disposed) onPending?.call(todo.length - done);
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
    if (_nothingToRead(c)) {
      r.text ??= '';
      r.mathTried = true;
      if (!_disposed) notifyListeners();
      return;
    }
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

  /// The text of [selection] if it has been read ahead of time (or converted before), else null.
  String? lookupText(Iterable<DrawingStroke> selection) {
    final picked = _picked[_selectionKey(selection)]?.text;
    if (picked != null) return picked;
    final clusters = _clustersOf(selection);
    if (clusters == null) return null;
    final parts = <InkCluster, String>{};
    for (final c in clusters) {
      final t = _cache[c.key]?.bestText;
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
    final picked = _picked[_selectionKey(selection)]?.latex;
    if (picked != null) return picked;
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

  // ---- what was read at an earlier time, and what is kept of it ----

  /// The text of blocks (by their key) read at an earlier time: kept by block, as the search has it, also while the maths check
  /// reads by rows (a block's text is then given to its rows, line by line).
  final Map<String, String> _kept = {};

  /// Formulas read at an earlier time, by the key of what was read (a block, or a row of the maths check).
  final Map<String, String> _keptMath = {};

  /// What conversions of selections that are not whole blocks read (by the key of the selected strokes).
  final Map<String, _Picked> _picked = {};

  /// Takes readings that were kept from an earlier time: [texts] of blocks, [formulas] of blocks or rows, [picked] conversions of
  /// selections (key to the ids of their strokes, the text and the formula). Each is named by the key of its strokes, which names
  /// them exactly: it is there at once, as if it had just been read, and is not read again. What was read here is not replaced.
  void seed({
    Map<String, String> texts = const {},
    Map<String, String> formulas = const {},
    Map<String, ({Set<String> ids, String? text, String? latex})> picked = const {},
  }) {
    if (_disposed) return;
    _kept.addAll(texts);
    _keptMath.addAll(formulas);
    for (final e in picked.entries) {
      final p = _picked.putIfAbsent(e.key, () => _Picked(e.value.ids));
      p.text ??= e.value.text;
      p.latex ??= e.value.latex;
    }
    if (_useKept(_clusters())) notifyListeners();
  }

  /// Gives [clusters] that have not been read what was kept of them; says whether any got something.
  bool _useKept(List<InkCluster> clusters) {
    if (_kept.isEmpty && _keptMath.isEmpty) return false;
    var any = false;
    for (final c in clusters) {
      final text = _kept[c.key], latex = _keptMath[c.key];
      if (text == null && latex == null) continue;
      final r = _cache.putIfAbsent(c.key, InkReading.new);
      if (r.text == null && text != null) {
        r.text = text;
        r.failed = false;
        any = true;
      }
      if (r.latex == null && latex != null) {
        r.latex = latex;
        r.mathTried = true;
        any = true;
      }
    }
    if (!_rows || _kept.isEmpty || clusters.every((c) => _cache[c.key]?.text != null)) return any;
    // rows: a block's text, one line to a row, when the lines of the text are as many as its rows
    for (final block in _blocks()) {
      final text = _kept[block.key];
      if (text == null) continue;
      final rows = _rowsOf(block, clusters);
      final lines = text.split('\n');
      if (rows == null || rows.length != lines.length) continue;
      for (var i = 0; i < rows.length; i++) {
        final r = _cache.putIfAbsent(rows[i].key, InkReading.new);
        if (r.text != null) continue;
        r.text = lines[i].trim();
        any = true;
      }
    }
    return any;
  }

  /// What is to be kept of the readings now: the text of each block that has been read (by block, for the search; while the maths
  /// check reads by rows, a block whose rows are all read has their text, a line to a row) and the keys of all blocks; the
  /// formulas read and the conversions of selections whose strokes are all still there as they were.
  ({List<({InkCluster block, String text})> texts, Set<String> blocks, Map<String, String> formulas, Map<String, ({Set<String> ids, String? text, String? latex})> picked}) toKeep() {
    final blocks = _blocks();
    final List<({InkCluster block, String text})> texts;
    if (!_rows) {
      texts = [for (final b in blocks) if (_cache[b.key]?.text case final t?) (block: b, text: t)];
    } else {
      final rows = _rowClusters();
      texts = [];
      for (final b in blocks) {
        final parts = _rowsOf(b, rows);
        final read = parts == null ? null : [for (final r in parts) _cache[r.key]?.text];
        final text = read != null && !read.contains(null) ? read.map((t) => t!.replaceAll('\n', ' ')).join('\n') : _kept[b.key];
        if (text != null) texts.add((block: b, text: text));
      }
    }
    _forgetPicked();
    return (
      texts: texts,
      blocks: {for (final b in blocks) b.key},
      formulas: {for (final c in _rows ? _rowClusters() : blocks) c.key: ?_cache[c.key]?.latex},
      picked: {
        for (final e in _picked.entries)
          if (e.value.text != null || e.value.latex != null) e.key: (ids: e.value.ids, text: e.value.text, latex: e.value.latex),
      },
    );
  }

  /// The key of the writing of [selection] (its strokes that can be handwriting).
  static String _selectionKey(Iterable<DrawingStroke> selection) => InkCluster.keyOf(selection.where(isInkStroke));

  /// Drops the conversions of selections whose strokes are gone or have changed.
  void _forgetPicked() {
    if (_picked.isEmpty) return;
    final now = {for (final e in strokes().entries) for (final s in e.value) s.id: s};
    _picked.removeWhere((key, p) => !p.ids.every(now.containsKey) || InkCluster.keyOf([for (final id in p.ids) now[id]!]) != key);
  }

  /// Keeps what a conversion that was asked for read: for the block when [selection] is exactly one, else for the selection itself
  /// (the same strokes selected again are not read again).
  void remember(Iterable<DrawingStroke> selection, String value, {bool math = false}) {
    if (value.trim().isEmpty) return;
    final clusters = _clustersOf(selection);
    if (clusters != null && clusters.length == 1) {
      final r = _cache.putIfAbsent(clusters.single.key, InkReading.new);
      if (math) {
        r.latex = value.trim();
        r.mathTried = true;
      } else {
        r.text = value.trim();
      }
    } else {
      final ink = selection.where(isInkStroke).toList();
      if (ink.isEmpty) return;
      final p = _picked.putIfAbsent(InkCluster.keyOf(ink), () => _Picked({for (final s in ink) s.id}));
      math ? p.latex = value.trim() : p.text = value.trim();
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
