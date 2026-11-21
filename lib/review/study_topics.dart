import 'dart:math' as math;

import '../ai/ai_prompt.dart';
import '../ai/text_provider.dart';
import '../l10n/language.dart';
import 'study_material.dart';
import 'study_schedule.dart';

/// The words of each page of a note that were read (zero-based page -> text): the text of its PDF and of its handwriting.
typedef PageTextReader = Future<Map<int, String>> Function(String noteId);

/// A part as the model cut it: its pages (zero-based, inclusive) and its name.
typedef TopicPart = ({int from, int to, String name});

/// How many pages one request shows the model, and about how many characters of their text in all (enough for a small model on the
/// device; a part does not go across two requests unless both ends have the same name).
const _pagesPerRequest = 40;
const _charsPerRequest = 6000;

/// A page counts as read when it has at least this much text.
const _readChars = 15;

/// The request that cuts [pages] (zero-based page numbers, each with the start of its text) into parts of one topic each, of at most
/// [maxPages] pages. The model is asked for cuts and names only: the parts are checked to follow each other and cover every page
/// ([parseTopicSplit]).
AiPrompt topicSplitPrompt(List<({int page, String text})> pages, {required int maxPages}) {
  final lines = StringBuffer();
  for (final p in pages) {
    lines.writeln('Page ${p.page + 1}: ${p.text.isEmpty ? '(no text)' : p.text}');
  }
  return AiPrompt(
    system: 'You divide study material into parts. You are given the pages of a document in order, each with the start of its text. '
        'Cut the pages into parts so that each part is about one topic and pages that belong together stay together; a part has '
        'between 1 and $maxPages pages. Keep the order of the pages: the parts follow each other and together cover every page once. '
        'Give each part a short name of 2 to 5 words that says what it is about, in the language of the pages, as a chapter of a book '
        'would be named (a noun phrase, no quotation marks). Answer with one line per part, exactly "first page-last page | name", '
        'and nothing else.',
    user: lines.toString().trimRight(),
    exact: true,
  );
}

/// The parts in a model's [reply] for the pages [first] to [last] (zero-based; the reply counts from 1), made to follow each other and
/// cover every page once: a gap goes to the part before it, an overlap to the part that came first, and a part longer than [maxPages] is
/// cut evenly. Null when no part could be read.
List<TopicPart>? parseTopicSplit(String reply, int first, int last, {required int maxPages}) {
  final found = <TopicPart>[];
  final range = RegExp(r'^\s*[*\-#]*\s*(?:pages?\s*)?(\d+)\s*(?:[-–—]|to)\s*(\d+)\s*[|:]\s*(.+?)\s*$', caseSensitive: false);
  final single = RegExp(r'^\s*[*\-#]*\s*(?:page\s*)?(\d+)\s*[|:]\s*(.+?)\s*$', caseSensitive: false);
  for (final line in reply.split('\n')) {
    final m = range.firstMatch(line);
    final s = m == null ? single.firstMatch(line) : null;
    if (m == null && s == null) continue;
    final from = int.parse((m ?? s)![1]!) - 1;
    final to = m != null ? int.parse(m[2]!) - 1 : from;
    final name = _name(m != null ? m[3]! : s![2]!);
    if (name == null || to < from || to < first || from > last) continue;
    found.add((from: math.max(from, first), to: math.min(to, last), name: name));
  }
  if (found.isEmpty) return null;
  found.sort((a, b) => a.from.compareTo(b.from));
  final out = <TopicPart>[];
  for (final p in found) {
    final from = out.isEmpty ? first : out.last.to + 1;
    if (out.isNotEmpty && p.from > from) {
      // (a gap: the pages go to the part before)
      out[out.length - 1] = (from: out.last.from, to: p.from - 1, name: out.last.name);
    }
    final start = out.isEmpty ? first : out.last.to + 1;
    if (p.to < start) continue; // (all of it was in the part before)
    out.add((from: start, to: p.to, name: p.name));
  }
  out[out.length - 1] = (from: out.last.from, to: last, name: out.last.name);
  return [for (final p in out) ..._cut(p, maxPages)];
}

String? _name(String raw) {
  var name = raw.replaceAll(RegExp(r'''["“”„'`*_]+'''), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  name = name.replaceFirst(RegExp(r'[.;:,]+$'), '');
  if (name.isEmpty || name.length > 60 || name.split(' ').length > 8) return null;
  return name;
}

/// [p] in even parts of at most [maxPages] pages ("name (1)", "name (2)", ...).
List<TopicPart> _cut(TopicPart p, int maxPages) {
  final pages = p.to - p.from + 1;
  if (pages <= maxPages) return [p];
  final n = (pages / maxPages).ceil();
  return [
    for (var i = 0; i < n; i++) (from: p.from + (i * pages / n).round(), to: p.from + ((i + 1) * pages / n).round() - 1, name: '${p.name} (${i + 1})'),
  ];
}

/// The runs of [units] of the note [noteId] that are cut by page number only ([StudyUnit.plain]) and follow each other, in order.
List<List<StudyUnit>> plainRuns(List<StudyUnit> units, String noteId) {
  final out = <List<StudyUnit>>[];
  for (final u in units) {
    if (u.noteId != noteId || !u.plain || !u.hasPages) continue;
    if (out.isNotEmpty && out.last.last.toPage! + 1 == u.fromPage) {
      out.last.add(u);
    } else {
      out.add([u]);
    }
  }
  return out;
}

/// Cuts the material that has nothing to cut it by (handwritten pages without headings, a scanned PDF without a table of contents) by
/// its topics, with an AI model: the model is shown the start of each page's text and says where a new topic begins and what each part
/// is called. Only where the person asks for it; the plan itself is made without a model.
class StudyTopicSplitter {
  final PageTextReader pageTexts;

  /// The model to ask (null: none), and whether the AI features are on.
  final TextModelProvider? Function() model;
  final bool Function() enabled;

  StudyTopicSplitter({required this.pageTexts, required this.model, required this.enabled});

  /// Whether a model can be asked now.
  bool get ready => enabled() && model()?.state == ProviderState.ready;

  /// Whether the note [noteId] has parts in [units] that are cut by page number only.
  static bool canSplit(List<StudyUnit> units, String noteId) => plainRuns(units, noteId).any((r) => r.last.toPage! > r.first.fromPage!);

  /// [units] with the runs of pages of [noteId] cut by topic, and [progress] carried over to the new parts page by page (with the
  /// difficulty and whether each is studied). Runs whose pages were not read (too little text) stay as they are; when none was read,
  /// or the model cannot be asked or its answer cannot be read, a [StateError] says why. With [cancel] cancelled, what was cut so far
  /// is kept.
  Future<({List<StudyUnit> units, Map<String, UnitProgress> progress})> split(
    List<StudyUnit> units,
    Map<String, UnitProgress> progress,
    String noteId, {
    AiCancel? cancel,
    void Function(double done)? onProgress,
  }) async {
    final provider = model();
    if (provider == null || !ready) throw StateError(tr('No AI model is ready.'));
    final runs = plainRuns(units, noteId).where((r) => r.last.toPage! > r.first.fromPage!).toList();
    if (runs.isEmpty) return (units: units, progress: progress);
    final texts = await pageTexts(noteId);
    bool read(int page) => (texts[page]?.trim().length ?? 0) >= _readChars;
    final readable = [
      for (final r in runs)
        if (_pagesOf(r).where(read).length >= 0.6 * _pagesOf(r).length) r,
    ];
    if (readable.isEmpty) {
      throw StateError(tr('There is too little text on these pages to tell their topics: their handwriting or their PDF may not have been read yet.'));
    }
    final total = readable.fold<int>(0, (n, r) => n + _pagesOf(r).length);
    var done = 0;
    var outUnits = units;
    var outProgress = progress;
    for (final run in readable) {
      if (cancel?.cancelled ?? false) break;
      final perPage = run.fold<int>(0, (n, u) => n + u.minutes) / _pagesOf(run).length;
      final maxPages = 3 * math.max<int>(1, (30 / perPage).round());
      final pages = _pagesOf(run);
      final parts = <TopicPart>[];
      for (var at = 0; at < pages.length; at += _pagesPerRequest) {
        if (cancel?.cancelled ?? false) break;
        final batch = pages.skip(at).take(_pagesPerRequest).toList();
        final chars = (_charsPerRequest / batch.length).floor().clamp(80, 500).toInt();
        final shown = [for (final p in batch) (page: p, text: _start(texts[p] ?? '', chars))];
        final reply = await provider.complete(topicSplitPrompt(shown, maxPages: maxPages), maxTokens: 30 * (batch.length ~/ 2 + 2) + 60, cancel: cancel);
        if (cancel?.cancelled ?? false) break;
        final got = parseTopicSplit(reply, batch.first, batch.last, maxPages: maxPages);
        if (got == null) throw StateError(tr('The answer of the model could not be read.'));
        // (a topic that goes on into the next request is one part when both ends have its name)
        if (parts.isNotEmpty && parts.last.name.toLowerCase() == got.first.name.toLowerCase() && got.first.to - parts.last.from < maxPages) {
          parts[parts.length - 1] = (from: parts.last.from, to: got.first.to, name: parts.last.name);
          parts.addAll(got.skip(1));
        } else {
          parts.addAll(got);
        }
        done += batch.length;
        onProgress?.call(done / total);
      }
      if (parts.isEmpty || parts.last.to != pages.last) break; // (cancelled within the run: it stays as it was)
      final fresh = [for (final p in parts) _unitOf(noteId, p, run)];
      outProgress = carryProgress(run, fresh, outProgress);
      final at = outUnits.indexWhere((u) => u.id == run.first.id);
      final gone = {for (final u in run) u.id};
      outUnits = [...outUnits.take(at).where((u) => !gone.contains(u.id)), ...fresh, ...outUnits.skip(at).where((u) => !gone.contains(u.id))];
    }
    return (units: outUnits, progress: outProgress);
  }

  static List<int> _pagesOf(List<StudyUnit> run) => [for (var p = run.first.fromPage!; p <= run.last.toPage!; p++) p];

  static String _start(String text, int chars) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= chars ? t : '${t.substring(0, chars)}…';
  }
}

/// The unit of the part [p] of a run of pages that was [run]: its time is what its pages took in the run, and its difficulty and whether
/// it is studied are those of most of its pages.
StudyUnit _unitOf(String noteId, TopicPart p, List<StudyUnit> run) {
  var minutes = 0.0;
  final byDifficulty = <Difficulty, int>{};
  var on = 0, off = 0;
  for (var page = p.from; page <= p.to; page++) {
    final u = run.firstWhere((u) => page >= u.fromPage! && page <= u.toPage!, orElse: () => run.last);
    minutes += u.minutes / u.pageCount;
    byDifficulty[u.difficulty] = (byDifficulty[u.difficulty] ?? 0) + 1;
    u.included ? on++ : off++;
  }
  final difficulty = byDifficulty.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  return StudyUnit(
    id: '$noteId#p${p.from}',
    noteId: noteId,
    title: p.name,
    fromPage: p.from,
    toPage: p.to,
    minutes: math.max(2, minutes.round()),
    difficulty: difficulty,
    included: on >= off,
  );
}

/// [progress] with the progress of the units [old] given to the units [fresh] that cover the same pages, page by page (the progress of
/// [old] is taken out).
Map<String, UnitProgress> carryProgress(List<StudyUnit> old, List<StudyUnit> fresh, Map<String, UnitProgress> progress) {
  final out = {...progress}..removeWhere((id, _) => old.any((u) => u.id == id));
  for (final f in fresh) {
    var learned = 0.0, reviewed = 0.0;
    for (var page = f.fromPage!; page <= f.toPage!; page++) {
      final u = old.where((u) => page >= u.fromPage! && page <= u.toPage!).firstOrNull;
      final p = u == null ? null : progress[u.id];
      learned += p?.learned ?? 0;
      reviewed += p?.reviewed ?? 0;
    }
    if (learned > 0 || reviewed > 0) out[f.id] = (learned: learned / f.pageCount, reviewed: reviewed / f.pageCount);
  }
  return out;
}
