import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show kIsWeb;

/// What to look for: plain text or a regular expression, with the usual switches.
class SearchQuery {
  final String text;
  final bool regex;
  final bool caseSensitive;
  final bool wholeWord;

  const SearchQuery(this.text, {this.regex = false, this.caseSensitive = false, this.wholeWord = false});

  bool get isEmpty => text.isEmpty;

  /// Why the pattern cannot be used (a regular expression that is not valid), or null.
  String? get problem {
    if (!regex || text.isEmpty) return null;
    try {
      RegExp(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// The pattern to find it with; null for an empty or a broken query.
  RegExp? get pattern {
    if (text.isEmpty || problem != null) return null;
    var source = regex ? text : RegExp.escape(text);
    if (wholeWord) source = r'(?<![\p{L}\p{N}_])(?:' + source + r')(?![\p{L}\p{N}_])';
    return RegExp(source, caseSensitive: caseSensitive, multiLine: true, unicode: true);
  }

  /// The places in [text] that match, without the empty ones, at most [limit].
  List<MatchRange> find(String text, {int limit = 1000}) {
    final p = pattern;
    if (p == null) return const [];
    final found = <MatchRange>[];
    for (final m in p.allMatches(text)) {
      if (m.end == m.start) continue;
      found.add(MatchRange(m.start, m.end));
      if (found.length >= limit) break;
    }
    return found;
  }

  /// What the match [r] of [text] becomes when it is replaced by [template]. In a regular expression `$1` to `$99` are the groups of
  /// the match, `$&` all of it and `$$` a dollar; otherwise the template is used as it is. Null if [r] is no longer a match of the
  /// query in [text] (the text has changed since it was found).
  String? replacement(String template, String text, MatchRange r) {
    if (r.start < 0 || r.end > text.length) return null;
    final m = pattern?.matchAsPrefix(text, r.start);
    if (m == null || m.end != r.end) return null;
    if (!regex) return template;
    return template.replaceAllMapped(RegExp(r'\$(\$|&|\d{1,2})'), (t) {
      final what = t.group(1)!;
      if (what == r'$') return r'$';
      if (what == '&') return m.group(0)!;
      final n = int.parse(what);
      if (n >= 1 && n <= m.groupCount) return m.group(n) ?? '';
      // (a group the pattern does not have stays as written; "$12" is "$1" and a 2 when there is no 12th group)
      if (what.length == 2) {
        final first = int.parse(what[0]);
        if (first >= 1 && first <= m.groupCount) return '${m.group(first) ?? ''}${what[1]}';
      }
      return t.group(0)!;
    });
  }

  Map<String, Object?> toJson() => {'text': text, 'regex': regex, 'case': caseSensitive, 'word': wholeWord};

  static SearchQuery fromJson(Map<Object?, Object?> j) =>
      SearchQuery('${j['text']}', regex: j['regex'] == true, caseSensitive: j['case'] == true, wholeWord: j['word'] == true);
}

/// A stretch of a text, [start] to [end].
class MatchRange {
  final int start;
  final int end;
  const MatchRange(this.start, this.end);

  @override
  bool operator ==(Object other) => other is MatchRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Where a piece of searchable text comes from.
enum SearchPlace { title, pdfName, document, textBox, pdfText, handwriting }

/// What the handwriting reader made of one block of pen strokes: where it lies on [page] and what it says.
class InkText {
  final String key;
  final int page;
  final String text;
  final Rect bounds;

  /// The words of [text] the reader was unsure of, separated by spaces (empty: none, or not known).
  final String unsure;
  const InkText({required this.key, required this.page, required this.text, required this.bounds, this.unsure = ''});
}

/// A piece of text of a note to look in.
class SearchSource {
  final String noteId;
  final SearchPlace place;

  /// The page it is on (0-based), or -1 if it is not on one.
  final int page;
  final String text;

  const SearchSource(this.noteId, this.place, this.text, {this.page = -1});
}

/// One match, with a little of what is around it.
class SearchHit {
  final String noteId;
  final SearchPlace place;
  final int page;
  final String before;
  final String match;
  final String after;

  const SearchHit({required this.noteId, required this.place, required this.page, required this.before, required this.match, required this.after});

  List<Object?> _pack() => [noteId, place.index, page, before, match, after];
  static SearchHit _unpack(List<Object?> l) =>
      SearchHit(noteId: l[0] as String, place: SearchPlace.values[l[1] as int], page: l[2] as int, before: l[3] as String, match: l[4] as String, after: l[5] as String);
}

/// What a search found: hits (the first [perNote] of each note, [total] in all) and whether it stopped early.
class SearchResults {
  final List<SearchHit> hits;
  final Map<String, int> countByNote;
  final bool cutOff;
  const SearchResults(this.hits, this.countByNote, {this.cutOff = false});

  int get total => countByNote.values.fold(0, (a, b) => a + b);
}

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

/// Looks for [query] in [sources], keeping [perNote] hits of each note and [overall] hits in all.
SearchResults searchNow(SearchQuery query, Iterable<SearchSource> sources, {int perNote = 30, int overall = 1500, int context = 36}) {
  final hits = <SearchHit>[];
  final counts = <String, int>{};
  final kept = <String, int>{};
  var cut = false;
  for (final s in sources) {
    final ranges = query.find(s.text);
    if (ranges.isEmpty) continue;
    counts[s.noteId] = (counts[s.noteId] ?? 0) + ranges.length;
    for (final r in ranges) {
      if (hits.length >= overall) {
        cut = true;
        break;
      }
      if ((kept[s.noteId] ?? 0) >= perNote) break;
      kept[s.noteId] = (kept[s.noteId] ?? 0) + 1;
      final from = r.start - context < 0 ? 0 : r.start - context;
      final to = r.end + context > s.text.length ? s.text.length : r.end + context;
      hits.add(SearchHit(
        noteId: s.noteId,
        place: s.place,
        page: s.page,
        before: (from > 0 ? '…' : '') + _oneLine(s.text.substring(from, r.start)),
        match: _oneLine(s.text.substring(r.start, r.end)),
        after: _oneLine(s.text.substring(r.end, to)) + (to < s.text.length ? '…' : ''),
      ));
    }
  }
  return SearchResults(hits, counts, cutOff: cut);
}

/// Thrown when a search took longer than it was allowed to (a regular expression that backtracks without end).
class SearchTooSlow implements Exception {
  const SearchTooSlow();
}

/// [searchNow] on an isolate of its own, so that nothing a pattern does can hold up the screen; ended if it takes longer than
/// [timeout]. [cancel] ends it early.
class RunningSearch {
  final Future<SearchResults> results;
  final void Function() cancel;
  RunningSearch(this.results, this.cancel);

  static RunningSearch start(SearchQuery query, List<SearchSource> sources, {Duration timeout = const Duration(seconds: 10), int perNote = 30}) {
    if (kIsWeb) {
      // the web has no isolates: the search runs here, after the screen had a turn (it cannot be stopped half-way, only ignored)
      var cancelled = false;
      final results = Future<void>.delayed(Duration.zero).then((_) {
        if (cancelled) throw const _Cancelled();
        return searchNow(query, sources, perNote: perNote);
      });
      return RunningSearch(results, () => cancelled = true);
    }
    final inbox = ReceivePort();
    final done = Completer<SearchResults>();
    Isolate? isolate;
    Timer? timer;

    void finish() {
      timer?.cancel();
      inbox.close();
      isolate?.kill(priority: Isolate.immediate);
    }

    void cancel() {
      if (!done.isCompleted) done.completeError(const _Cancelled());
      finish();
    }

    final packed = [for (final s in sources) [s.noteId, s.place.index, s.page, s.text]];
    final request = [inbox.sendPort, query.toJson(), packed, perNote];
    timer = Timer(timeout, () {
      if (!done.isCompleted) done.completeError(const SearchTooSlow());
      finish();
    });
    inbox.listen((m) {
      if (done.isCompleted) return;
      if (m is List && m.length == 3) {
        final hits = [for (final h in m[0] as List) SearchHit._unpack((h as List).cast<Object?>())];
        done.complete(SearchResults(hits, (m[1] as Map).cast<String, int>(), cutOff: m[2] as bool));
      } else {
        done.completeError(StateError('The search failed.'));
      }
      finish();
    });
    Isolate.spawn(_work, request).then((i) {
      isolate = i;
      if (done.isCompleted) i.kill(priority: Isolate.immediate);
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
      finish();
    });
    return RunningSearch(done.future, cancel);
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Whether [e] is what a cancelled search throws.
bool searchWasCancelled(Object e) => e is _Cancelled;

void _work(List<Object?> request) {
  final out = request[0] as SendPort;
  try {
    final query = SearchQuery.fromJson((request[1] as Map).cast<Object?, Object?>());
    final sources = [
      for (final s in request[2] as List) SearchSource((s as List)[0] as String, SearchPlace.values[s[1] as int], s[3] as String, page: s[2] as int),
    ];
    final r = searchNow(query, sources, perNote: request[3] as int);
    out.send([[for (final h in r.hits) h._pack()], r.countByNote, r.cutOff]);
  } catch (e) {
    out.send('$e');
  }
}

/// The matches of [query] in each of [texts] (in the same order), found on an isolate of its own and given up on after [timeout]
/// (throws [SearchTooSlow]).
Future<List<List<MatchRange>>> findInTexts(SearchQuery query, List<String> texts, {Duration timeout = const Duration(seconds: 8), int limit = 2000}) async {
  if (query.pattern == null) return [for (final _ in texts) const <MatchRange>[]];
  if (kIsWeb) {
    // (no isolates on the web: found here)
    await Future<void>.delayed(Duration.zero);
    var left = limit;
    final all = <List<MatchRange>>[];
    for (final t in texts) {
      final found = left > 0 ? query.find(t, limit: left).toList() : const <MatchRange>[];
      left -= found.length;
      all.add(found);
    }
    return all;
  }
  final inbox = ReceivePort();
  final done = Completer<List<List<MatchRange>>>();
  Isolate? isolate;
  final timer = Timer(timeout, () {
    if (!done.isCompleted) done.completeError(const SearchTooSlow());
  });
  inbox.listen((m) {
    if (done.isCompleted) return;
    if (m is List) {
      done.complete([
        for (final l in m) [for (var i = 0; i < (l as List).length; i += 2) MatchRange(l[i] as int, l[i + 1] as int)],
      ]);
    } else {
      done.completeError(StateError('$m'));
    }
  });
  try {
    isolate = await Isolate.spawn(_findWork, [inbox.sendPort, query.toJson(), texts, limit]);
    return await done.future;
  } finally {
    timer.cancel();
    inbox.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

void _findWork(List<Object?> request) {
  final out = request[0] as SendPort;
  try {
    final query = SearchQuery.fromJson((request[1] as Map).cast<Object?, Object?>());
    var left = request[3] as int;
    final all = <List<int>>[];
    for (final t in (request[2] as List).cast<String>()) {
      final flat = <int>[];
      if (left > 0) {
        for (final r in query.find(t, limit: left)) {
          flat..add(r.start)..add(r.end);
          left--;
        }
      }
      all.add(flat);
    }
    out.send(all);
  } catch (e) {
    out.send('$e');
  }
}
