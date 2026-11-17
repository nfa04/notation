import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/note_text_repository.dart' show InkRead;
import '../l10n/language.dart';
import '../models/canvas_models.dart';
import '../search/search_query.dart';
import 'ink_prefetcher.dart';
import 'ink_recognizer.dart';

/// Reads the writing of one open note in the background, for what asks for it: the automation that reads ahead (so that a selection
/// is converted at once), the tool that checks worked maths line by line, and the index that lets the search find handwriting.
/// It owns the [InkPrefetcher] that does the reading and the timer that keeps the index; the editor tells it about its
/// surroundings (what is drawn, which page is in view, whether it is a quiet moment) and is told when readings arrive.
class NoteInkReader {
  final String noteId;
  final InkRecognizer? handwriting;
  final InkRecognizer? math;

  /// How long things have to be quiet before reading starts.
  final Duration idle;

  /// The strokes of each page as they are now.
  final Map<int, List<DrawingStroke>> Function() strokes;

  /// The page in view (the first of those that are shown).
  final int Function() visiblePage;

  /// Whether it is a good moment to read: the note is open, nothing is being drawn and the app is on screen.
  final bool Function() isQuiet;

  /// Whether the note is still open in its editor.
  final bool Function() isOpen;

  /// Whether the note is locked (a locked note keeps nothing readable in the open).
  final bool Function() isLocked;

  /// Completes when the note has been loaded and its strokes can be read.
  final Future<void> Function() ready;

  /// Whether the writing is to be read for the search: the tool is on, there is a reader and the person did not switch it off.
  final Future<bool> Function() indexWanted;

  /// Keeps what was read of the writing: [read] are added, and what is not among [alive] is dropped.
  final Future<void> Function(String noteId, List<InkText> read, Set<String> alive) saveIndex;

  /// Keeps what was read that is not for the search (formulas, conversions of selections), in place of what was kept before.
  final Future<void> Function(String noteId, List<InkRead> reads) saveReads;

  /// What was kept of the readings of the note: the text of blocks (by the key of the block of strokes) and the other readings.
  final Future<({Map<String, String> texts, Map<String, String> unsure, List<InkRead> reads})> Function(String noteId) loadSaved;

  /// Whether this device reads the writing in the background. False for a guest of a live session: the host reads, and what it read
  /// arrives by [takeShared]. (A person's own maths check, switched on here, still reads here.)
  final bool Function() readsHere;

  /// Gives the others in a live session what was read ([shareNew] says what); null when there is no session to tell.
  final void Function(Map<String, Object?> readings)? share;

  /// Told when readings arrived (or the work changed): the editor shows which selections are ready and marks checked maths.
  final void Function() onProgress;

  NoteInkReader({
    required this.noteId,
    required this.handwriting,
    required this.math,
    required this.idle,
    required this.strokes,
    required this.visiblePage,
    required this.isQuiet,
    required this.isOpen,
    required this.isLocked,
    required this.ready,
    required this.indexWanted,
    required this.saveIndex,
    required this.saveReads,
    required this.loadSaved,
    required this.onProgress,
    this.readsHere = _always,
    this.share,
  });

  static bool _always() => true;

  /// How many blocks of writing are still to be read (for the chip that says the writing is being read).
  final pending = ValueNotifier<int>(0);

  /// The reader of the background work; null until something asked for it.
  InkPrefetcher? prefetcher;

  /// What was asked of it by the automations that read ahead, and whether worked maths is being checked line by line.
  bool prepText = false, prepMath = false, checkOn = false;

  /// Whether the writing is read as it is written, for the search.
  bool indexInk = false;
  Timer? _indexTimer;

  /// An automation asks for the writing ([text]) and the formulas ([math]) to be read ahead; says what came of it.
  Future<String> prepare({required bool text, required bool math}) async {
    prepText |= text;
    prepMath |= math;
    final problem = await start();
    return problem ?? tr('Reading the writing ahead of time while the note is open');
  }

  /// Sets the background reader up for what is asked of it (read ahead, check the maths, index for the search); says why not when
  /// it cannot.
  Future<String?> start() async {
    final hw = prepText || checkOn || indexInk ? handwriting : null;
    final formulas = prepMath || checkOn ? math : null;
    if (hw == null && formulas == null) {
      prefetcher?.configure(text: null, math: null, rows: false);
      return tr('The handwriting and formula readers are switched off (see Settings)');
    }
    final installed = (hw?.status == HandwritingStatus.installed) || (formulas?.status == HandwritingStatus.installed);
    if (!installed) return tr('The models are not installed (see Settings)');
    await ready();
    if (!isOpen()) return tr('The note was not open');
    final reader = _ensure();
    reader.configure(text: hw, math: formulas, rows: checkOn);
    return null;
  }

  InkPrefetcher _ensure() => prefetcher ??= InkPrefetcher(
        strokes: strokes,
        canRun: () => (readsHere() || checkOn) && isQuiet(),
        idle: idle,
        // (only the page in view and its neighbours; a rest after each piece so that the screen keeps up)
        // (all of it when the writing is read for the search)
        wanted: (c) => indexInk || (c.page - visiblePage()).abs() <= 1,
        order: (c) => (c.page - visiblePage()).abs(), // (the page in view first, then those around it)
        pause: idle < const Duration(seconds: 1) ? Duration.zero : const Duration(milliseconds: 250),
      )
        ..holding = _loadingKept
        ..onPending = ((n) => pending.value = n)
        ..addListener(_progressed);

  /// What the handwriting of this note said when it was read before is there again, before anything asks for it: a selection is
  /// converted at once, and nothing that was read is read twice. Works without a reader being set up (no model is needed to look up).
  Future<void> restore() => _restoring ??= _restore();
  Future<void>? _restoring;

  /// Whether what was read before is being loaded: nothing is read meanwhile, or it would be read twice.
  bool _loadingKept = false;

  Future<void> _restore() async {
    // (no reader at all, the AI or the handwriting being off: nothing here could use what was read, so the database is not asked)
    if (isLocked() || (handwriting == null && math == null)) return;
    _loadingKept = true;
    prefetcher?.holding = true;
    try {
      await ready();
      if (!isOpen() || isLocked()) return;
      await _load();
    } finally {
      _loadingKept = false;
      prefetcher?.release();
    }
  }

  Future<void> _load() async {
    try {
      // (the prefetcher is there from now on, so that a conversion that is asked for is remembered too)
      final reader = _ensure();
      final saved = await loadSaved(noteId);
      if (!isOpen()) return;
      _keptTexts.addAll(saved.texts);
      _keptUnsure.addAll(saved.unsure);
      _keptReads = _signature(saved.reads);
      reader.seed(
        texts: saved.texts,
        unsure: saved.unsure,
        formulas: {for (final r in saved.reads) if (r.ids.isEmpty && r.latex != null) r.key: r.latex!},
        picked: {for (final r in saved.reads) if (r.ids.isNotEmpty) r.key: (ids: r.ids.split(',').toSet(), text: r.text, latex: r.latex)},
      );
    } catch (e) {
      debugPrint('[ink] could not load the kept readings: $e');
    }
  }

  /// What is in the database now (the text of blocks by key, and the other readings), so that the same is not written again.
  final Map<String, String> _keptTexts = {};

  /// The words of those texts that the reader was unsure of (by block key).
  final Map<String, String> _keptUnsure = {};
  String _keptReads = '';

  static String _signature(Iterable<InkRead> reads) => (reads.map((r) => '${r.key}\u0000${r.ids}\u0000${r.text}\u0000${r.latex}\u0000${r.place}').toList()..sort()).join('\u0001');

  /// Starts reading the writing for the search, unless the person switched that off (in the settings).
  Future<void> startIndex() async {
    if (!await indexWanted()) return;
    if (!isOpen()) return;
    indexInk = true;
    await start();
  }

  /// Writes what was read of the writing into the database: the text of the blocks where the search looks (see `ink_text`), by
  /// block also while the maths check reads by rows, and the formulas and conversions beside it (`ink_reads`), so that the note
  /// opened again reads nothing that was read before.
  Future<void> saveReadings() async {
    _indexTimer?.cancel();
    _shareNew();
    final reader = prefetcher;
    // (a locked note keeps nothing in the open)
    if (reader == null || isLocked()) return;
    final keep = reader.toKeep();
    final texts = {for (final t in keep.texts) t.block.key: t.text};
    final reads = {
      for (final e in keep.formulas.entries) e.key: (key: e.key, ids: '', text: null, latex: e.value, place: keep.places[e.key]),
      for (final e in keep.picked.entries) e.key: (key: e.key, ids: (e.value.ids.toList()..sort()).join(','), text: e.value.text, latex: e.value.latex, place: null),
    }.values.toList();
    // (nothing new to keep, nothing dropped)
    final sameTexts = texts.length == _keptTexts.length &&
        texts.entries.every((e) => _keptTexts[e.key] == e.value && (keep.unsure[e.key] ?? '') == (_keptUnsure[e.key] ?? ''));
    final signature = _signature(reads);
    try {
      if (!sameTexts) {
        await saveIndex(noteId, [for (final t in keep.texts) InkText(key: t.block.key, page: t.block.page, text: t.text, bounds: t.block.bounds, unsure: keep.unsure[t.block.key] ?? '')], keep.blocks);
        _keptTexts
          ..clear()
          ..addAll(texts);
        _keptUnsure
          ..clear()
          ..addAll(keep.unsure);
      }
      if (signature != _keptReads) {
        await saveReads(noteId, reads);
        _keptReads = signature;
      }
    } catch (e) {
      debugPrint('[ink] could not keep the readings: $e');
    }
  }

  /// What was last given to the others, by key: only what is new or different goes out the next time.
  final Map<String, String> _sentTexts = {}, _sentUnsure = {}, _sentFormulas = {};

  /// The others know nothing of it (somebody joined, or this device became the one that reads): everything goes out the next time.
  void shareAgain() {
    _sentTexts.clear();
    _sentUnsure.clear();
    _sentFormulas.clear();
    _saveSoon();
  }

  /// Tells the others what was read since they were last told (in pieces, so that no message is huge).
  void _shareNew() {
    final send = share;
    final reader = prefetcher;
    if (send == null || reader == null || !readsHere() || isLocked()) return;
    final keep = reader.toKeep();
    final texts = <String, String>{}, unsure = <String, String>{}, formulas = <String, String>{};
    for (final t in keep.texts) {
      if (_sentTexts[t.block.key] != t.text) texts[t.block.key] = t.text;
    }
    for (final e in keep.unsure.entries) {
      if (_sentUnsure[e.key] != e.value) unsure[e.key] = e.value;
    }
    for (final e in keep.formulas.entries) {
      if (_sentFormulas[e.key] != e.value) formulas[e.key] = e.value;
    }
    if (texts.isEmpty && unsure.isEmpty && formulas.isEmpty) return;
    _sentTexts.addAll(texts);
    _sentUnsure.addAll(unsure);
    _sentFormulas.addAll(formulas);
    final keys = {...texts.keys, ...unsure.keys, ...formulas.keys}.toList();
    for (var i = 0; i < keys.length; i += _sharePiece) {
      final part = keys.skip(i).take(_sharePiece).toSet();
      send({
        'texts': {for (final k in part) if (texts.containsKey(k)) k: texts[k]},
        'unsure': {for (final k in part) if (unsure.containsKey(k)) k: unsure[k]},
        'formulas': {for (final k in part) if (formulas.containsKey(k)) k: formulas[k]},
      });
    }
  }

  static const _sharePiece = 200;

  /// Takes what the host read (see [share]): it is there as if it had been read here, and kept like it. Nothing read here is replaced.
  /// [readings] comes from another device: only what is a text by a key is taken.
  void takeShared(Map<String, Object?> readings) {
    if (!isOpen() || isLocked() || (handwriting == null && math == null)) return;
    Map<String, String> strings(Object? m) {
      if (m is! Map || m.length > _sharePiece * 2) return const {};
      return {
        for (final e in m.entries)
          if (e.key is String && e.value is String && (e.value as String).length < 200000 && (e.key as String).length < 100) e.key as String: e.value as String,
      };
    }

    final texts = strings(readings['texts']), unsure = strings(readings['unsure']), formulas = strings(readings['formulas']);
    if (texts.isEmpty && unsure.isEmpty && formulas.isEmpty) return;
    _ensure().seed(texts: texts, unsure: unsure, formulas: formulas);
  }

  /// Keeps what was read of the writing soon after the readings change.
  void _saveSoon() {
    _indexTimer?.cancel();
    _indexTimer = Timer(const Duration(seconds: 2), saveReadings);
  }

  void _progressed() {
    if (!isOpen()) return;
    _saveSoon();
    onProgress();
  }

  /// The note is closed: what was read is kept, and the reading stops.
  void dispose() {
    _indexTimer?.cancel();
    unawaited(saveReadings());
    prefetcher?.dispose();
    pending.dispose();
  }
}
