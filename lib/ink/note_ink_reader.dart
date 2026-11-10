import 'dart:async';

import 'package:flutter/foundation.dart';

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

  /// What was kept of the readings of the note (by the key of the block of strokes); empty when nothing was.
  final Future<Map<String, String>> Function(String noteId) loadSaved;

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
    required this.loadSaved,
    required this.onProgress,
  });

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
        canRun: isQuiet,
        idle: idle,
        // (only the page in view and its neighbours; a rest after each piece so that the screen keeps up)
        // (all of it when the writing is read for the search)
        wanted: (c) => indexInk || (c.page - visiblePage()).abs() <= 1,
        pause: idle < const Duration(seconds: 1) ? Duration.zero : const Duration(milliseconds: 250),
      )..addListener(_progressed);

  /// What the handwriting of this note said when it was read before is there again, before anything asks for it: a selection is
  /// converted at once, and nothing that was read is read twice. Works without a reader being set up (no model is needed to look up).
  Future<void> restore() async {
    if (isLocked()) return;
    await ready();
    if (!isOpen() || isLocked()) return;
    try {
      // (the prefetcher is there from now on, so that a conversion that is asked for is remembered too)
      final reader = _ensure();
      final saved = await loadSaved(noteId);
      if (saved.isEmpty || !isOpen()) return;
      _kept.addAll(saved);
      reader.seed(saved);
    } catch (e) {
      debugPrint('[ink] could not load the kept readings: $e');
    }
  }

  /// What is in the database now (key to text), so that the same readings are not written again.
  final Map<String, String> _kept = {};

  /// Starts reading the writing for the search, unless the person switched that off (in the settings).
  Future<void> startIndex() async {
    if (!await indexWanted()) return;
    if (!isOpen()) return;
    indexInk = true;
    await start();
  }

  /// Writes what was read of the writing into the database, where the search looks (see `ink_text`).
  Future<void> saveReadings() async {
    _indexTimer?.cancel();
    final reader = prefetcher;
    // (line by line readings are of another kind of block; a locked note keeps nothing in the open)
    if (reader == null || checkOn || isLocked()) return;
    final blocks = reader.readings();
    // (nothing new to keep, nothing dropped)
    final now = {for (final r in blocks) if (r.text != null) r.block.key: r.text!};
    if (now.length == _kept.length && now.entries.every((e) => _kept[e.key] == e.value) && _kept.keys.every(now.containsKey)) return;
    try {
      await saveIndex(
        noteId,
        [for (final r in blocks) if (r.text != null) InkText(key: r.block.key, page: r.block.page, text: r.text!, bounds: r.block.bounds)],
        {for (final r in blocks) r.block.key},
      );
      _kept
        ..clear()
        ..addAll(now);
    } catch (e) {
      debugPrint('[ink] could not keep the readings for the search: $e');
    }
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
  }
}
