import 'dart:math' as math;

import '../l10n/language.dart';

/// How hard a part of the material is, as the person says it when the plan is made: it sets how long the part is given at first. What
/// the sessions show later (done or missed) is what the plan goes by after that.
enum Difficulty {
  easy(0.7),
  medium(1),
  hard(1.5);

  const Difficulty(this.factor);

  /// How much longer than the plain reading time the part takes.
  final double factor;

  static Difficulty byName(Object? name) => values.where((d) => d.name == name).firstOrNull ?? medium;
}

/// Minutes to work through one page of a PDF (reading it and writing down what matters).
const minutesPerPdfPage = 4.0;

/// Minutes for one handwritten page of a notebook.
const minutesPerNotebookPage = 3.0;

/// Words a minute when a typed text is studied (slower than reading for pleasure: it is read to be remembered).
const studyWordsPerMinute = 100;

/// A going-over of a part later on takes this share of the time it was first learnt in.
const reviewShare = 0.35;

/// A part of the material: a chapter of a PDF (from its table of contents), a section of the written document (from its headings) or
/// a run of pages of a notebook or of a PDF that has no table of contents. It is what a session's work is made of.
class StudyUnit {
  /// Stable within its plan (the note and the place in it).
  final String id;
  final String noteId;
  final String title;

  /// The pages (zero-based, inclusive) it covers; null for a section of the written document.
  final int? fromPage, toPage;

  /// How long it takes to work through once at a medium pace.
  final int minutes;
  final Difficulty difficulty;

  /// Taken into the plan (the person can leave a part out).
  final bool included;

  /// A run of pages cut by their number alone (its title is its pages): the material had nothing to cut it by, and it may be cut by its
  /// topics instead (see study_topics.dart).
  final bool plain;

  const StudyUnit({
    required this.id,
    required this.noteId,
    required this.title,
    this.fromPage,
    this.toPage,
    required this.minutes,
    this.difficulty = Difficulty.medium,
    this.included = true,
    this.plain = false,
  });

  bool get hasPages => fromPage != null && toPage != null;

  int get pageCount => hasPages ? toPage! - fromPage! + 1 : 0;

  /// Minutes the first going-through is given.
  int get learnMinutes => math.max(5, (minutes * difficulty.factor).round());

  /// Minutes the later going-over is given.
  int get reviewMinutes => math.max(5, (learnMinutes * reviewShare).round());

  StudyUnit copyWith({Difficulty? difficulty, bool? included}) => StudyUnit(
        id: id,
        noteId: noteId,
        title: title,
        fromPage: fromPage,
        toPage: toPage,
        minutes: minutes,
        difficulty: difficulty ?? this.difficulty,
        included: included ?? this.included,
        plain: plain,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'note': noteId,
        'title': title,
        if (fromPage != null) 'from': fromPage,
        if (toPage != null) 'to': toPage,
        'min': minutes,
        'diff': difficulty.name,
        if (!included) 'off': true,
        if (plain) 'plain': true,
      };

  static StudyUnit? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['note'] is! String) return null;
    final from = (j['from'] as num?)?.toInt(), to = (j['to'] as num?)?.toInt();
    final title = (j['title'] as String?) ?? '';
    return StudyUnit(
      id: j['id'] as String,
      noteId: j['note'] as String,
      title: title,
      fromPage: from,
      toPage: to,
      // (kept before this was: a title that is its pages)
      plain: j['plain'] == true || from != null && to != null && title == pagesTitle(from, to),
      minutes: math.max(1, (j['min'] as num?)?.toInt() ?? 10),
      difficulty: Difficulty.byName(j['diff']),
      included: j['off'] != true,
    );
  }

  @override
  String toString() => 'StudyUnit($title, ${hasPages ? 'pp. ${fromPage! + 1}-${toPage! + 1}, ' : ''}$minutes min)';
}

/// A heading with the page (zero-based) it starts on: a line of a PDF's table of contents.
typedef PageHeading = ({String title, int level, int page});

/// The level of the headings that cut the material into parts: the top level, or the one under it when the top level has fewer than
/// three headings (a book whose only top heading is its title, or a course in two halves).
int _cutLevel(Iterable<int> levels) {
  final all = levels.toList();
  if (all.isEmpty) return 1;
  final top = all.reduce(math.min);
  if (all.where((l) => l == top).length >= 3) return top;
  final next = all.where((l) => l > top);
  if (next.isEmpty) return top;
  final second = next.reduce(math.min);
  return all.where((l) => l <= second).length >= 3 ? second : top;
}

/// The parts of a PDF of [pageCount] pages from its table of contents: one per heading of the level that cuts it best (see [_cutLevel]),
/// from its page to the page before the next one. Headings that start on the same page are one part. Pages before the first heading are a
/// part of their own when there are at least three of them (fewer: a title page and the contents, which are not studied). Null when there
/// is no table of contents to go by (then the pages are cut evenly, see [unitsFromPages]).
List<StudyUnit>? unitsFromOutline(String noteId, List<PageHeading> outline, int pageCount, {int idFrom = 0}) {
  if (pageCount <= 0) return null;
  final valid = [for (final h in outline) if (h.page >= 0 && h.page < pageCount && h.title.trim().isNotEmpty) h];
  if (valid.length < 2) return null;
  final level = _cutLevel(valid.map((h) => h.level));
  final cuts = <({String title, int page})>[];
  for (final h in valid.where((h) => h.level <= level)) {
    if (cuts.isNotEmpty && cuts.last.page == h.page) {
      cuts[cuts.length - 1] = (title: '${cuts.last.title}, ${h.title.trim()}', page: h.page);
    } else if (cuts.isEmpty || h.page > cuts.last.page) {
      cuts.add((title: h.title.trim(), page: h.page));
    }
  }
  if (cuts.length < 2) return null;
  final out = <StudyUnit>[];
  var n = idFrom;
  if (cuts.first.page >= 3) {
    out.add(_pagesUnit(noteId, n++, 0, cuts.first.page - 1, minutesPerPdfPage));
  }
  for (var i = 0; i < cuts.length; i++) {
    final from = cuts[i].page, to = i + 1 < cuts.length ? cuts[i + 1].page - 1 : pageCount - 1;
    out.add(StudyUnit(id: '$noteId#${n++}', noteId: noteId, title: cuts[i].title, fromPage: from, toPage: to, minutes: math.max(2, ((to - from + 1) * minutesPerPdfPage).round())));
  }
  return out;
}

/// What a run of pages (zero-based, inclusive) is called.
String pagesTitle(int from, int to) => from == to ? tr('Page {n}', {'n': from + 1}) : tr('Pages {from}-{to}', {'from': from + 1, 'to': to + 1});

StudyUnit _pagesUnit(String noteId, int n, int from, int to, double perPage) => StudyUnit(
      id: '$noteId#$n',
      noteId: noteId,
      title: pagesTitle(from, to),
      fromPage: from,
      toPage: to,
      minutes: math.max(2, ((to - from + 1) * perPage).round()),
      plain: true,
    );

/// [pageCount] pages cut into even runs of about [pagesPerUnit] (the last run takes a short rest instead of leaving a page or two alone).
List<StudyUnit> unitsFromPages(String noteId, int pageCount, {double perPage = minutesPerPdfPage, int? pagesPerUnit, int idFrom = 0}) {
  if (pageCount <= 0) return const [];
  final size = pagesPerUnit ?? math.max(1, (30 / perPage).round()); // about half an hour each
  final count = math.max(1, (pageCount / size).round());
  final out = <StudyUnit>[];
  for (var i = 0; i < count; i++) {
    final from = (i * pageCount / count).round(), to = ((i + 1) * pageCount / count).round() - 1;
    if (to >= from) out.add(_pagesUnit(noteId, idFrom + i, from, to, perPage));
  }
  return out;
}

final _headingLine = RegExp(r'^(?:\{(?:align|indent|spacing)=[^}\n]*\})? {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$');
final _fenceLine = RegExp(r'^ {0,3}(```|~~~)');
final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

int _words(String text) => _word.allMatches(text).length;

/// How many words [text] has.
int wordCount(String text) => _words(text);

List<({int line, int level, String title})> _headsOf(List<String> lines) {
  final heads = <({int line, int level, String title})>[];
  var inCode = false;
  for (var i = 0; i < lines.length; i++) {
    if (_fenceLine.hasMatch(lines[i])) {
      inCode = !inCode;
      continue;
    }
    if (inCode) continue;
    final m = _headingLine.firstMatch(lines[i]);
    if (m == null) continue;
    final title = m.group(2)!.replaceAll(RegExp(r'[*_`]'), '').trim();
    if (title.isNotEmpty) heads.add((line: i, level: m.group(1)!.length, title: title));
  }
  return heads;
}

/// The text of the part [title] of a written document, as [unitsFromText] cut it: the words under the heading of that name (up to the
/// next heading that cuts), the words before the first heading (any other name), or one of the even parts ("name (2/3)") of a long text
/// without headings. The whole text when nothing fits.
String textOfSection(String text, String title) {
  final lines = text.split('\n');
  final heads = _headsOf(lines);
  final part = RegExp(r'^(.*) \((\d+)/(\d+)\)$').firstMatch(title);
  if (heads.isEmpty) {
    if (part == null) return text;
    final words = text.split(RegExp(r'\s+'));
    final n = int.parse(part[3]!), i = int.parse(part[2]!) - 1;
    if (n < 1 || i < 0 || i >= n) return text;
    return words.sublist(i * words.length ~/ n, (i + 1) * words.length ~/ n).join(' ');
  }
  final level = _cutLevel(heads.map((h) => h.level));
  final cuts = [for (final h in heads) if (h.level <= level) h];
  for (var i = 0; i < cuts.length; i++) {
    if (cuts[i].title != title) continue;
    final end = i + 1 < cuts.length ? cuts[i + 1].line : lines.length;
    return lines.sublist(cuts[i].line + 1, end).join('\n');
  }
  final before = lines.sublist(0, cuts.first.line).join('\n');
  return before.trim().isEmpty ? text : before;
}

/// The sections of a written document by its headings (of the level that cuts it best), each as long as its words take to study. Text
/// before the first heading is a section of its own ([lead] is what it is called) when it has at least 50 words. A document without
/// headings is one section ([lead]), or several of about half an hour each when it is long. Empty when there is nothing to study.
List<StudyUnit> unitsFromText(String noteId, String text, {String? lead, int idFrom = 0}) {
  lead ??= tr('Introduction');
  final lines = text.split('\n');
  final heads = _headsOf(lines);
  int minutesOf(int words) => math.max(2, (words / studyWordsPerMinute).round());
  var n = idFrom;
  final out = <StudyUnit>[];
  if (heads.isEmpty) {
    final words = _words(text);
    if (words < 20) return const [];
    // a long text without headings: even parts of about half an hour
    final parts = math.max(1, (words / (studyWordsPerMinute * 30)).round());
    if (parts == 1) return [StudyUnit(id: '$noteId#$n', noteId: noteId, title: lead, minutes: minutesOf(words))];
    return [
      for (var i = 0; i < parts; i++) StudyUnit(id: '$noteId#${n + i}', noteId: noteId, title: '$lead (${i + 1}/$parts)', minutes: minutesOf(words ~/ parts)),
    ];
  }
  final level = _cutLevel(heads.map((h) => h.level));
  final cuts = [for (final h in heads) if (h.level <= level) h];
  final before = _words(lines.sublist(0, cuts.first.line).join('\n'));
  if (before >= 50) out.add(StudyUnit(id: '$noteId#${n++}', noteId: noteId, title: lead, minutes: minutesOf(before)));
  for (var i = 0; i < cuts.length; i++) {
    final end = i + 1 < cuts.length ? cuts[i + 1].line : lines.length;
    final words = _words(lines.sublist(cuts[i].line + 1, end).join('\n'));
    if (words < 5) continue; // a heading with nothing under it
    out.add(StudyUnit(id: '$noteId#${n++}', noteId: noteId, title: cuts[i].title, minutes: minutesOf(words)));
  }
  return out;
}

/// What can be read about a note without opening it, to cut it into parts.
class NoteShape {
  final String noteId;
  final String title;

  /// Pages of its PDF (0: none).
  final int pdfPages;

  /// The table of contents of the PDF (page numbers are the note's).
  final List<PageHeading> pdfOutline;

  /// Notebook pages that have something on them beyond the PDF (handwriting, text boxes, pictures).
  final int notebookPages;

  /// The written document.
  final String documentText;

  final bool locked;

  const NoteShape({required this.noteId, this.title = '', this.pdfPages = 0, this.pdfOutline = const [], this.notebookPages = 0, this.documentText = '', this.locked = false});
}

/// The parts of a note: the chapters of its PDF (by its table of contents, else runs of pages), the sections of its written document, and
/// its notebook pages in runs. A locked note gives none (nothing of it is read).
List<StudyUnit> unitsOfNote(NoteShape note) {
  if (note.locked) return const [];
  final out = <StudyUnit>[];
  if (note.pdfPages > 0) {
    out.addAll(unitsFromOutline(note.noteId, note.pdfOutline, note.pdfPages) ?? unitsFromPages(note.noteId, note.pdfPages));
  }
  out.addAll(unitsFromText(note.noteId, note.documentText, lead: note.title.trim().isEmpty ? null : note.title.trim(), idFrom: out.length));
  // handwriting on pages of its own (a PDF's pages that were written on are counted with the PDF)
  final extra = note.notebookPages - note.pdfPages;
  if (extra > 0 && !(note.pdfPages == 0 && out.isNotEmpty && note.notebookPages <= 1)) {
    final start = note.pdfPages;
    for (final u in unitsFromPages(note.noteId, extra, perPage: minutesPerNotebookPage, idFrom: out.length)) {
      out.add(StudyUnit(
        id: u.id,
        noteId: u.noteId,
        title: pagesTitle(u.fromPage! + start, u.toPage! + start),
        fromPage: u.fromPage! + start,
        toPage: u.toPage! + start,
        minutes: u.minutes,
        plain: true,
      ));
    }
  }
  return out;
}
