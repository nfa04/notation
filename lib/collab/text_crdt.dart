import 'dart:collection';
import 'dart:math' as math;

import 'text_diff.dart';

/// The name of one character of a [TextCrdt]: when it was typed (a counter that every device moves past whatever it has seen) and
/// by which device (the device's name breaks a tie). No two characters have the same one, and a character keeps its name for ever.
class CharId implements Comparable<CharId> {
  final int ts;
  final String site;
  const CharId(this.ts, this.site);

  /// Before the first character.
  static const start = CharId(0, '');

  @override
  int compareTo(CharId o) => ts != o.ts ? ts.compareTo(o.ts) : site.compareTo(o.site);

  @override
  bool operator ==(Object other) => other is CharId && other.ts == ts && other.site == site;

  @override
  int get hashCode => Object.hash(ts, site);

  List<Object> toJson() => [ts, site];

  static CharId? fromJson(Object? json) {
    if (json is! List || json.length != 2) return null;
    final ts = json[0], site = json[1];
    if (ts is! int || site is! String || ts < 0 || ts > TextCrdt.maxClock || site.length > TextCrdt.maxSiteLength) return null;
    return CharId(ts, site);
  }

  @override
  String toString() => '$ts@$site';
}

class _Item {
  final int ts;
  final String site;
  final int parentTs;
  final String parentSite;
  int unit; // the UTF-16 code unit; 0 once deleted
  bool deleted = false;
  _Item? next;

  /// For a character typed again when the text was made again from another device's (see [TextCrdt.merge]): the character it is a copy
  /// of. Several devices may make a copy of the same character; only one of them stays (see [TextCrdt._dedupe]).
  CharId? copyOf;

  /// Deleted only because another copy of the same character stays ([copyOf]): it is still sent with its letter, so that every device
  /// finds the same copies, and nobody takes it as deleted by a person.
  bool dup = false;

  /// How many characters that are not deleted come before this one (worked out with the text, see [TextCrdt._visibleItems]).
  int before = 0;

  _Item(this.ts, this.site, this.parentTs, this.parentSite, this.unit);

  CharId get id => CharId(ts, site);

  bool isAfter(int otherTs, String otherSite) => ts != otherTs ? ts > otherTs : site.compareTo(otherSite) > 0;
}

/// Formatting of the characters from [start] to [end] (exclusive), as offsets in the text: what a screen shows. [type] is the kind of
/// formatting (bold, a colour), [value] what it is for kinds that have one.
class MarkSpan {
  final int start;
  final int end;
  final String type;
  final String? value;
  const MarkSpan(this.start, this.end, this.type, [this.value]);

  @override
  bool operator ==(Object other) => other is MarkSpan && other.start == start && other.end == end && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(start, end, type, value);

  @override
  String toString() => '$type${value == null ? '' : '=$value'}[$start,$end)';
}

/// A piece of formatting as it is kept: on the characters from [start] to the one before [end] (whichever way the text around them
/// moves; [end] is the character after the last one, or [TextCrdt.endOfText]), so that what is typed at its end has it too, as a
/// screen does it. [tag] names it: it is taken away by its name, and where two pieces give one kind of formatting two values, the one
/// with the later name wins.
class TextMark {
  final CharId tag;
  final CharId start;
  final CharId end;
  final String type;
  final String? value;
  const TextMark(this.tag, this.start, this.end, this.type, this.value);

  List<Object> toJson() => [tag.ts, tag.site, start.ts, start.site, end.ts, end.site, type, ?value];

  static TextMark? fromJson(Object? json) {
    if (json is! List || json.length < 7 || json.length > 8) return null;
    final tag = CharId.fromJson([json[0], json[1]]), start = CharId.fromJson([json[2], json[3]]), end = CharId.fromJson([json[4], json[5]]);
    final type = json[6], value = json.length == 8 ? json[7] : null;
    if (tag == null || start == null || end == null || tag.ts < 1 || tag.site.isEmpty || start.ts < 1) return null;
    if (type is! String || type.isEmpty || type.length > TextCrdt.maxMarkType) return null;
    if (value != null && (value is! String || value.length > TextCrdt.maxMarkValue)) return null;
    return TextMark(tag, start, end, type, value as String?);
  }
}

/// Numbers kept as sorted runs that do not touch: the names (of one device) of what was collected (see [TextCrdt.collect]).
class _Runs {
  final List<int> _from = [], _to = []; // [from, to)

  int get length => _from.length;

  /// The index of the last run that starts at or before [x], or -1.
  int _at(int x) {
    var lo = 0, hi = _from.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_from[mid] <= x) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  bool contains(int x) {
    final i = _at(x);
    return i >= 0 && x < _to[i];
  }

  void add(int from, int to) {
    if (to <= from) return;
    var i = _at(from);
    if (i >= 0 && _to[i] >= from) {
      // joins the run before (or lies in it)
      if (_to[i] >= to) return;
      _to[i] = to;
    } else {
      i++;
      _from.insert(i, from);
      _to.insert(i, to);
    }
    // the runs after it that it reaches now are a part of it
    while (i + 1 < _from.length && _from[i + 1] <= _to[i]) {
      if (_to[i + 1] > _to[i]) _to[i] = _to[i + 1];
      _from.removeAt(i + 1);
      _to.removeAt(i + 1);
    }
  }

  void addAll(_Runs o) {
    for (var k = 0; k < o._from.length; k++) {
      add(o._from[k], o._to[k]);
    }
  }

  Iterable<int> get all sync* {
    for (var k = 0; k < _from.length; k++) {
      for (var x = _from[k]; x < _to[k]; x++) {
        yield x;
      }
    }
  }

  /// As `[from, length, from, length, ...]`.
  List<int> toJson() => [for (var k = 0; k < _from.length; k++) ...[_from[k], _to[k] - _from[k]]];

  static _Runs? fromJson(Object? json, {int limit = TextCrdt.maxItems}) {
    if (json is! List || json.length.isOdd) return null;
    final r = _Runs();
    var total = 0;
    for (var k = 0; k < json.length; k += 2) {
      final a = json[k], n = json[k + 1];
      if (a is! int || n is! int || a < 1 || n < 1 || a + n > TextCrdt.maxClock) return null;
      total += n;
      if (total > limit) return null;
      r.add(a, a + n);
    }
    return r;
  }

  static Map<String, _Runs>? mapFromJson(Object? json) {
    if (json is! Map) return null;
    final out = <String, _Runs>{};
    var total = 0;
    for (final e in json.entries) {
      final site = e.key;
      if (site is! String || site.isEmpty || site.length > TextCrdt.maxSiteLength) return null;
      final runs = _Runs.fromJson(e.value, limit: TextCrdt.maxItems - total);
      if (runs == null) return null;
      for (var k = 0; k < runs._from.length; k++) {
        total += runs._to[k] - runs._from[k];
      }
      out[site] = runs;
    }
    return out;
  }
}

/// A fingerprint that every device works out the same from the same things (whatever the platform: no number gets past 2^53, and no
/// operation on bits is used, which a browser does differently).
class _Digest {
  int _a = 2166136261, _b = 374761393;

  static int _mix(int h, int v) {
    final x = (h + v) % 4294967296;
    return (x * 403 + (x % 256) * 16777216) % 4294967296; // x * (2^24 + 403), the prime of FNV, kept to 32 bits
  }

  void add(int v) {
    // in pieces of 16 bits (a number of [TextCrdt] has at most 44)
    var x = v < 0 ? -v * 2 + 1 : v * 2;
    do {
      final piece = x % 65536;
      _a = _mix(_a, piece + 1);
      _b = _mix(_b, piece * 7 + 13);
      x = x ~/ 65536;
    } while (x > 0);
  }

  void text(String s) {
    add(s.length);
    for (var k = 0; k < s.length; k++) {
      final u = s.codeUnitAt(k);
      _a = _mix(_a, u + 1);
      _b = _mix(_b, u * 7 + 13);
    }
  }

  int get value => _a * 2097152 + _b % 2097152;
}

/// What came of taking in changes from another device.
class MergeResult {
  /// Whether the text or its formatting is different now.
  final bool changed;

  /// Characters that could not be put in yet because the one they come after has not arrived (they are kept, and go in when it does).
  final int waiting;

  /// Whether something in the message was not what a device of this app sends (it is skipped, the rest is taken).
  final bool malformed;

  /// Whether the text here was made again from the one that came (see [TextCrdt.merge]).
  final bool rebased;

  /// Characters that came after one that was collected, and so have no place (from a device that was away while the others collected).
  final int lost;

  const MergeResult(this.changed, this.waiting, this.malformed, {this.rebased = false, this.lost = 0});
}

/// The text of a text box or of the written document, in a form that devices which change it at the same time (or while one of them
/// was away) can put together again, always to the same text, whatever order the changes reach them in, and however often.
///
/// Every character has a [CharId] and is put in after the character it was typed behind (a sequence of the kind called RGA); deleting
/// marks a character as gone and keeps its place, so that a change that refers to it still finds it. What one person typed stays in one
/// piece, and a person's words are never mixed letter by letter into the words of another.
///
/// The formatting is kept with it, as pieces on characters ([TextMark]): a piece is taken away by its name, so somebody who takes the
/// bold off a line takes away only what they saw, and what another made bold at the same time stays.
///
/// A device makes its changes with [replace] / [setText] and [setSpans], takes them out with [takeChanges] to send, and takes in those of
/// others with [merge]. [encode] is all of it, for a device that has nothing yet.
///
/// Deleted characters are kept until every device has seen them deleted: then they can be collected ([report], [collect]): see
/// `docs/architecture.md` for why that is safe, and what a device that was away does when it comes back.
class TextCrdt {
  /// The largest counter taken from another device (so that arithmetic on it never leaves the numbers a browser has).
  static const maxClock = 1 << 44;
  static const maxSiteLength = 64;

  /// How many characters (with the deleted ones) a text may have, and how many one message may bring.
  static const maxItems = 4 * 1024 * 1024;
  static const maxPerMessage = 8 * 1024 * 1024;

  /// How many pieces of formatting a text may have, and how long the name of a kind and a value may be.
  static const maxMarks = 1 << 16;
  static const maxMarkType = 40;
  static const maxMarkValue = 400;

  /// The end of a piece of formatting that goes to the end of the text.
  static const endOfText = CharId(0, '');

  /// How many deleted characters (and pieces of formatting taken away) a text has before they are worth collecting.
  static int collectAfter = 2000;

  final String site;
  int _clock;
  _Item _head = _Item(0, '', 0, '', 0);
  Map<String, Map<int, _Item>> _byId = {};
  int _count = 0;
  int _dead = 0;

  /// Characters whose parent is not here yet, by the parent's name.
  Map<CharId, List<_Item>> _waiting = {};
  int _waitingCount = 0;

  Set<CharId> _waitingIds = {};

  /// Deletions of characters that are not here yet.
  Set<CharId> _waitingDeletes = {};

  /// What was changed here since the last [takeChanges].
  List<_Item> _newItems = [];
  List<_Item> _newDeletes = [];

  /// The formatting: the pieces that are on, and the names of those that were taken away (so that a late copy does not bring one back).
  Map<CharId, TextMark> _marks = {};
  Set<CharId> _unmarked = {};
  List<TextMark> _newMarks = [];
  List<CharId> _newUnmarks = [];

  /// How often deleted characters were collected, what was collected (by device), and the last collection (as it is sent).
  int _epoch = 0;
  Map<String, _Runs> _gone = {};
  Map<String, Object?>? _lastCollection;
  bool _collectionToSend = false;

  /// The fingerprints this device said it is at (see [report]), the latest last.
  final List<int> _reported = [];

  /// Characters that were typed again under new names when the text was made again from another device's (see [merge]), by the old name.
  Map<CharId, CharId> _moved = {};

  /// Characters that came after one that was collected here (from a device that had not collected it): they have no place, and neither
  /// has anything typed after them. (Not sent: the device they come from types them again, see [merge].)
  Set<CharId> _lost = {};

  /// For each character of which there are copies ([_Item.copyOf]), by the name of the first: the one that stays.
  Map<CharId, _Item> _sameAs = {};

  List<_Item>? _visible;
  String? _text;
  List<MarkSpan>? _spans;

  TextCrdt(this.site, {int clock = 0}) : _clock = clock {
    _byId[''] = {0: _head};
  }

  /// A text that every device which starts from the same [text] (and [spans]) makes the same: the characters are by the device `~` and
  /// numbered from 1. Only for a text that all of them have (the note as it was when they joined, or the text of a device that does not
  /// merge); what is typed after is by the one who typed it.
  factory TextCrdt.shared(String site, String text, [List<MarkSpan> spans = const []]) {
    final c = TextCrdt(site);
    final tail = c._append(const CharId(0, ''), '~', 1, text);
    var n = tail == null ? 0 : tail.ts;
    final vis = c._visibleItems();
    for (final s in spans) {
      final a = s.start.clamp(0, vis.length), b = s.end.clamp(0, vis.length);
      if (a >= b || s.type.isEmpty || s.type.length > maxMarkType || (s.value?.length ?? 0) > maxMarkValue) continue;
      final tag = CharId(++n, '~');
      c._marks[tag] = TextMark(tag, vis[a].id, b >= vis.length ? endOfText : vis[b].id, s.type, s.value);
    }
    c._clock = n;
    c._newItems.clear();
    return c;
  }

  int get clock => _clock;

  /// How many characters are known, the deleted ones included.
  int get itemCount => _count;

  /// How many of them are deleted.
  int get deletedCount => _dead;

  /// How many characters wait for the one they come after.
  int get waiting => _waitingCount;

  /// How often deleted characters were collected.
  int get epoch => _epoch;

  /// How many pieces of formatting are on, and how many names of pieces that were taken away are kept.
  int get markCount => _marks.length;
  int get unmarkedCount => _unmarked.length;

  /// Whether there is anything not sent yet.
  bool get hasChanges => _newItems.isNotEmpty || _newDeletes.isNotEmpty || _newMarks.isNotEmpty || _newUnmarks.isNotEmpty || _collectionToSend;

  List<_Item> _visibleItems() {
    var v = _visible;
    if (v != null) return v;
    v = <_Item>[];
    for (var i = _head.next; i != null; i = i.next) {
      i.before = v.length;
      if (!i.deleted) v.add(i);
    }
    return _visible = v;
  }

  /// The text as it is.
  String get text {
    var t = _text;
    if (t != null) return t;
    t = String.fromCharCodes([for (final i in _visibleItems()) i.unit]);
    return _text = t;
  }

  int get length => _visibleItems().length;

  void _changed() {
    _visible = null;
    _text = null;
    _spans = null;
  }

  _Item? _find(int ts, String site) => _byId[site]?[ts];

  /// The character [id], also by the name it had before the text was made again.
  _Item? _findId(CharId id) {
    final i = _find(id.ts, id.site) ?? switch (_moved[id]) { final m? => _find(m.ts, m.site), _ => null };
    return i != null && i.dup ? _sameAs[i.copyOf ?? i.id] ?? i : i;
  }

  /// The character [root] or the copy of it that stays, if one is here.
  _Item? _member(CharId root) => _sameAs[root] ?? _find(root.ts, root.site);

  /// [it] was just put in: if it is a copy of a character that is here already (or the character that copies here were made of), only
  /// one of them stays - the one with the lowest name, on every device, whatever order they come in. If a person deleted any of them,
  /// all of them are deleted.
  void _dedupe(_Item it) {
    final root = it.copyOf ?? it.id;
    if (it.copyOf == null && !_sameAs.containsKey(root)) return;
    final other = _member(root);
    if (other == null || identical(other, it)) {
      _sameAs[root] = it;
      return;
    }
    final keep = other.id.compareTo(it.id) <= 0 ? other : it;
    final drop = identical(keep, other) ? it : other;
    _sameAs[root] = keep;
    if ((keep.deleted && !keep.dup) || (drop.deleted && !drop.dup)) {
      // (deleted by somebody: the character is gone, whichever copy they saw)
      for (final x in [keep, drop]) {
        if (!x.deleted) {
          _kill(x);
        } else if (x.dup) {
          x
            ..dup = false
            ..unit = 0;
        }
      }
    } else if (!drop.deleted) {
      _kill(drop, dup: true);
    }
  }

  /// A person deleted [it], a copy that was already out of the text (or the original of copies): the copy that stays goes too.
  void _deleteCopies(_Item it) {
    final root = it.copyOf ?? it.id;
    final kept = _sameAs[root];
    if (kept != null && !identical(kept, it) && !kept.deleted) _kill(kept);
  }

  bool _isGone(int ts, String site) => _gone[site]?.contains(ts) ?? false;

  void _goneAdd(String site, int ts) => (_gone[site] ??= _Runs()).add(ts, ts + 1);

  /// Puts [item] in after its parent (which must be here).
  void _link(_Item item, _Item parent) {
    var at = parent;
    // (what comes after the parent and was typed later - or is a part of what was - stays before the new character)
    while (at.next != null && at.next!.isAfter(item.ts, item.site)) {
      at = at.next!;
    }
    item.next = at.next;
    at.next = item;
    (_byId[item.site] ??= {})[item.ts] = item;
    _count++;
  }

  /// Puts in [text] as characters of [site] numbered from [from], one after the other, after [parent]. The last of them, or null.
  _Item? _append(CharId parent, String site, int from, String text) {
    var p = _find(parent.ts, parent.site)!;
    _Item? last;
    for (var k = 0; k < text.length; k++) {
      final item = _Item(from + k, site, p.ts, p.site, text.codeUnitAt(k));
      _link(item, p);
      _newItems.add(item);
      p = item;
      last = item;
    }
    if (last != null) _changed();
    return last;
  }

  void _kill(_Item item, {bool dup = false}) {
    item.deleted = true;
    item.dup = dup;
    if (!dup) item.unit = 0;
    _dead++;
  }

  // ---- changes made here

  /// Replaces [removed] characters from [start] by [put].
  void replace(int start, int removed, String put) {
    final vis = _visibleItems();
    assert(start >= 0 && removed >= 0 && start + removed <= vis.length);
    final parent = start == 0 ? CharId.start : vis[start - 1].id;
    for (var i = start; i < start + removed; i++) {
      final item = vis[i];
      _kill(item);
      _newDeletes.add(item);
    }
    _changed();
    if (put.isNotEmpty) {
      final from = _clock + 1;
      _append(parent, site, from, put);
      _clock += put.length;
    }
  }

  /// Makes the text [now], with as few changes as can be found. True when it was different.
  bool setText(String now) {
    final edits = diffText(text, now);
    for (final e in edits.reversed) {
      replace(e.start, e.removed, e.inserted);
    }
    return edits.isNotEmpty;
  }

  // ---- formatting

  /// The formatting as a screen shows it: for each kind, the stretches that have it, with their value (stretches of one kind do not
  /// overlap), in the order of the text.
  List<MarkSpan> get spans => _spans ??= _render(_marks.values);

  /// Where [m] is now, as offsets; null when a character it is on is not here (yet).
  (int, int)? _rangeOf(TextMark m) {
    _visibleItems();
    final s = _findId(m.start);
    if (s == null) return null;
    final int e;
    if (m.end == endOfText) {
      e = length;
    } else {
      final x = _findId(m.end);
      if (x == null) return null;
      e = x.before;
    }
    return (s.before, e);
  }

  List<MarkSpan> _render(Iterable<TextMark> marks) {
    final byType = <String, List<(int, int, String?, CharId)>>{};
    for (final m in marks) {
      final r = _rangeOf(m);
      if (r == null || r.$1 >= r.$2) continue;
      (byType[m.type] ??= []).add((r.$1, r.$2, m.value, m.tag));
    }
    final out = <MarkSpan>[];
    for (final type in byType.keys.toList()..sort()) {
      final pieces = byType[type]!..sort((a, b) => a.$4.compareTo(b.$4));
      out.addAll(_resolve(type, [for (var k = 0; k < pieces.length; k++) (pieces[k].$1, pieces[k].$2, pieces[k].$3, k)]));
    }
    out.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.type.compareTo(b.type));
    return out;
  }

  /// The stretches that have formatting [type], from [pieces] `(start, end, value, rank)` that may overlap: where they do, the piece
  /// with the highest rank gives the value. Stretches next to each other with the same value are one.
  static List<MarkSpan> _resolve(String type, List<(int, int, String?, int)> pieces) {
    if (pieces.isEmpty) return const [];
    final events = <(int, int, int)>[]; // (where, 0 = an end / 1 = a start, which piece)
    for (var k = 0; k < pieces.length; k++) {
      final p = pieces[k];
      if (p.$1 >= p.$2) continue;
      events
        ..add((p.$1, 1, k))
        ..add((p.$2, 0, k));
    }
    events.sort((a, b) => a.$1.compareTo(b.$1));
    final on = SplayTreeMap<int, int>(); // rank -> piece
    final out = <MarkSpan>[];
    var open = false;
    var from = 0;
    String? value;
    var i = 0;
    while (i < events.length) {
      final at = events[i].$1;
      while (i < events.length && events[i].$1 == at) {
        final (_, kind, k) = events[i];
        if (kind == 1) {
          on[pieces[k].$4] = k;
        } else {
          on.remove(pieces[k].$4);
        }
        i++;
      }
      final has = on.isNotEmpty;
      final v = has ? pieces[on[on.lastKey()]!].$3 : null;
      if (open && (!has || v != value)) {
        if (at > from) out.add(MarkSpan(from, at, type, value));
        open = false;
      }
      if (has && !open) {
        open = true;
        from = at;
        value = v;
      }
    }
    return out;
  }

  /// The value [spans] (of one kind, as [_resolve] makes them) give the character at [at]: whether there is one, and which.
  static (bool, String?) _valueAt(List<MarkSpan> spans, int at) {
    var lo = 0, hi = spans.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final s = spans[mid];
      if (at < s.start) {
        hi = mid - 1;
      } else if (at >= s.end) {
        lo = mid + 1;
      } else {
        return (true, s.value);
      }
    }
    return (false, null);
  }

  /// The stretches where [a] and [b] (of one kind) give a character another value: `(start, end, the value in a)`.
  static List<(int, int, bool, String?)> _differences(List<MarkSpan> a, List<MarkSpan> b) {
    final cuts = <int>{for (final s in a) ...[s.start, s.end], for (final s in b) ...[s.start, s.end]}.toList()..sort();
    final out = <(int, int, bool, String?)>[];
    for (var k = 0; k + 1 < cuts.length; k++) {
      final p = cuts[k], q = cuts[k + 1];
      final va = _valueAt(a, p), vb = _valueAt(b, p);
      if (va == vb) continue;
      if (out.isNotEmpty && out.last.$2 == p && out.last.$3 == va.$1 && out.last.$4 == va.$2) {
        out.last = (out.last.$1, q, va.$1, va.$2);
      } else {
        out.add((p, q, va.$1, va.$2));
      }
    }
    return out;
  }

  /// Makes the formatting what a screen shows: [spans] are as an editor keeps them (they may overlap; where two of one kind do, the later
  /// in the list wins). What is different is changed by taking away the pieces that are on it (they come back, as new pieces, where they
  /// were not changed) and putting new ones where it is wanted. True when anything was different.
  bool setSpans(List<MarkSpan> spans) {
    final n = length;
    final byType = <String, List<(int, int, String?, int)>>{};
    for (var k = 0; k < spans.length; k++) {
      final s = spans[k];
      final a = s.start.clamp(0, n), b = s.end.clamp(0, n);
      if (a >= b || s.type.isEmpty || s.type.length > maxMarkType || (s.value?.length ?? 0) > maxMarkValue) continue;
      (byType[s.type] ??= []).add((a, b, s.value, k));
    }
    final want = {for (final e in byType.entries) e.key: _resolve(e.key, e.value)};
    final have = <String, List<MarkSpan>>{};
    for (final s in this.spans) {
      (have[s.type] ??= []).add(s);
    }
    var changed = false;
    for (final type in {...want.keys, ...have.keys}) {
      final w = want[type] ?? const <MarkSpan>[], h = have[type] ?? const <MarkSpan>[];
      final differ = _differences(w, h);
      if (differ.isEmpty) continue;
      changed = true;
      for (final m in _marks.values.where((m) => m.type == type).toList()) {
        final r = _rangeOf(m);
        if (r == null || r.$1 >= r.$2) continue;
        if (differ.any((d) => r.$1 < d.$2 && r.$2 > d.$1)) _unmark(m.tag);
      }
      _spans = null;
      final left = [for (final s in this.spans) if (s.type == type) s];
      for (final (a, b, present, value) in _differences(w, left)) {
        if (present) _mark(a, b, type, value);
      }
    }
    return changed;
  }

  void _mark(int from, int to, String type, String? value) {
    final vis = _visibleItems();
    final tag = CharId(++_clock, site);
    final m = TextMark(tag, vis[from].id, to >= vis.length ? endOfText : vis[to].id, type, value);
    _marks[tag] = m;
    _newMarks.add(m);
    _spans = null;
  }

  void _unmark(CharId tag) {
    _marks.remove(tag);
    _spans = null;
    final k = _newMarks.indexWhere((m) => m.tag == tag);
    if (k >= 0) {
      _newMarks.removeAt(k); // (never sent: nobody has to be told)
      return;
    }
    _unmarked.add(tag);
    _newUnmarks.add(tag);
  }

  // ---- what goes over the wire

  /// The changes made here since the last call, ready to send; null when there are none. After a collection ([collect]) it is all of
  /// the text, with the collection.
  Map<String, Object?>? takeChanges() {
    if (_collectionToSend) {
      _clearNew();
      return encode();
    }
    if (!hasChanges) return null;
    final out = _encodeItems(_newItems, deletes: _newDeletes);
    final marks = [for (final m in _newMarks) if (identical(_marks[m.tag], m)) m.toJson()];
    if (marks.isNotEmpty) out['m'] = marks;
    if (_newUnmarks.isNotEmpty) out['u'] = _rangesOf(_newUnmarks);
    _clearNew();
    return out;
  }

  void _clearNew() {
    _newItems.clear();
    _newDeletes.clear();
    _newMarks.clear();
    _newUnmarks.clear();
    _collectionToSend = false;
  }

  /// All of the text (in the order of the text), with what was deleted, the formatting and what was collected, for a device that has none
  /// of it (or for one that may have lost some of the changes).
  Map<String, Object?> encode() {
    final all = <_Item>[for (var i = _head.next; i != null; i = i.next) i];
    final out = _encodeItems(all, inOrder: true);
    if (_marks.isNotEmpty) out['m'] = [for (final m in _marks.values) m.toJson()];
    if (_unmarked.isNotEmpty) out['u'] = _rangesOf(_unmarked);
    out['all'] = 1;
    if (_epoch > 0) {
      out['e'] = _epoch;
      out['gone'] = {for (final e in _gone.entries) e.key: e.value.toJson()};
      if (_lastCollection != null) out['g'] = _lastCollection;
    }
    return out;
  }

  static List<List<Object>> _rangesOf(Iterable<CharId> ids) {
    final sorted = ids.toList()..sort((a, b) => a.site != b.site ? a.site.compareTo(b.site) : a.ts.compareTo(b.ts));
    final ranges = <List<Object>>[];
    for (final d in sorted) {
      if (ranges.isNotEmpty) {
        final last = ranges.last;
        if (last[0] == d.site && (last[1] as int) + (last[2] as int) == d.ts) {
          last[2] = (last[2] as int) + 1;
          continue;
        }
      }
      ranges.add([d.site, d.ts, 1]);
    }
    return ranges;
  }

  /// Runs of characters that one device typed one after the other, as `[site, first number, parent number, parent site, text, deleted]`
  /// (what is deleted in a run as pairs of where in it and how long), and what was deleted without being sent as `[site, number, length]`.
  ///
  /// [inOrder]: [items] are all of the text, in its order. A character whose parent was collected is then sent as coming after the one
  /// before it: a device that builds the text from this alone, in this order, puts every character where it is here.
  Map<String, Object?> _encodeItems(List<_Item> items, {List<_Item> deletes = const [], bool inOrder = false}) {
    final parents = <(int, String)>[];
    for (var k = 0; k < items.length; k++) {
      final it = items[k];
      final real = it.parentTs == 0 || _find(it.parentTs, it.parentSite) != null;
      parents.add(real || !inOrder ? (it.parentTs, it.parentSite) : (k == 0 ? (0, '') : (items[k - 1].ts, items[k - 1].site)));
    }
    final runs = <List<Object?>>[];
    var i = 0;
    while (i < items.length) {
      final first = items[i];
      var j = i + 1;
      while (j < items.length &&
          items[j].site == first.site &&
          items[j].ts == items[j - 1].ts + 1 &&
          parents[j].$1 == items[j - 1].ts &&
          parents[j].$2 == first.site &&
          _copiesOnFrom(items[j - 1].copyOf, items[j].copyOf)) {
        j++;
      }
      final units = <int>[];
      final cut = <int>[];
      var from = -1;
      for (var k = i; k < j; k++) {
        final item = items[k];
        final gone = item.deleted && !item.dup;
        units.add(gone ? 0x20 : item.unit);
        if (gone) {
          if (from < 0) from = k - i;
        } else if (from >= 0) {
          cut
            ..add(from)
            ..add(k - i - from);
          from = -1;
        }
      }
      if (from >= 0) {
        cut
          ..add(from)
          ..add(j - i - from);
      }
      final copy = first.copyOf;
      runs.add([
        first.site,
        first.ts,
        parents[i].$1,
        parents[i].$2,
        String.fromCharCodes(units),
        if (cut.isNotEmpty || copy != null) cut,
        if (copy != null) copy.toJson(),
      ]);
      i = j;
    }
    final ranges = <List<Object>>[];
    for (final d in deletes) {
      if (ranges.isNotEmpty) {
        final last = ranges.last;
        if (last[0] == d.site && (last[1] as int) + (last[2] as int) == d.ts) {
          last[2] = (last[2] as int) + 1;
          continue;
        }
      }
      ranges.add([d.site, d.ts, 1]);
    }
    return {if (runs.isNotEmpty) 'r': runs, if (ranges.isNotEmpty) 'x': ranges};
  }

  static bool _copiesOnFrom(CharId? a, CharId? b) => a == null ? b == null : b != null && b.site == a.site && b.ts == a.ts + 1;

  bool get _isEmpty => _count == 0 && _marks.isEmpty && _unmarked.isEmpty && _waitingCount == 0 && _epoch == 0 && _gone.isEmpty;

  /// Takes in what [json] (as [takeChanges] and [encode] make it) says, from another device. Never throws for what a device sends: what
  /// is not right is skipped. Taking in the same thing twice, or in another order, changes nothing.
  ///
  /// All of a text that comes from a device that collected deleted characters this device has not collected yet: if this device had
  /// what was collected (it said so, see [report]), it collects them too; if not (it was away), the text here is made again from the one
  /// that came, and what was typed here and is not in it is typed into it again, as new changes to send.
  MergeResult merge(Object? json) {
    if (json is! Map) return const MergeResult(false, 0, true);
    final epoch = json['e'] ?? 0;
    if (json['all'] == 1 && epoch is int && epoch > 0) {
      final g = json['g'];
      if (_isEmpty) {
        // nothing here: all of it is taken as it is
        final gone = _Runs.mapFromJson(json['gone']);
        if (gone == null || epoch > maxClock) return const MergeResult(false, 0, true);
        _epoch = epoch;
        _gone = gone;
        _lastCollection = g is Map ? g.cast<String, Object?>() : null;
      } else if (epoch > _epoch) {
        final caughtUp = epoch == _epoch + 1 && g is Map && g['e'] == epoch && _collectAsWith(g);
        if (!caughtUp) return _rebase(json);
      } else if (epoch == _epoch && g is Map && g['h'] != _lastCollection?['h']) {
        // two devices collected apart from each other (the host was replaced while the link was down): one of the two texts is taken by
        // both, the same one on both sides (that of the higher fingerprint), and the other types what it has into it. Nothing of the text
        // that loses is taken here: its device does that.
        final theirs = g['h'], ours = _lastCollection?['h'];
        if (theirs is! int) return MergeResult(false, _waitingCount, true);
        if (ours is int && ours > theirs) return MergeResult(false, _waitingCount, false);
        return _rebase(json);
      }
    }
    return _mergeChanges(json);
  }

  MergeResult _mergeChanges(Map json) {
    var changed = false, bad = false;
    var lost = 0;
    var budget = maxPerMessage;
    final runs = json['r'];
    if (runs != null && runs is! List) bad = true;
    for (final run in runs is List ? runs : const []) {
      final parsed = _parseRun(run);
      if (parsed == null) {
        bad = true;
        continue;
      }
      budget -= parsed.text.length;
      if (budget < 0 || _count + _waitingCount + parsed.text.length > maxItems) {
        bad = true;
        break;
      }
      final r = _takeRun(parsed);
      if (r.$1) changed = true;
      lost += r.$2;
    }
    final ranges = json['x'];
    if (ranges != null && ranges is! List) bad = true;
    for (final r in ranges is List ? ranges : const []) {
      final parsed = _parseRange(r);
      if (parsed == null) {
        bad = true;
        continue;
      }
      for (var k = 0; k < parsed.$3; k++) {
        if (_delete(CharId(parsed.$2 + k, parsed.$1))) changed = true;
      }
    }
    final marks = json['m'];
    if (marks != null && marks is! List) bad = true;
    for (final j in marks is List ? marks : const []) {
      final m = TextMark.fromJson(j);
      if (m == null) {
        bad = true;
        continue;
      }
      if (m.tag.ts > _clock) _clock = m.tag.ts;
      if (_marks.containsKey(m.tag) || _unmarked.contains(m.tag) || _isGone(m.tag.ts, m.tag.site)) continue;
      if (_isGone(m.start.ts, m.start.site) || (m.end != endOfText && _isGone(m.end.ts, m.end.site))) {
        lost++;
        continue;
      }
      if (_marks.length >= maxMarks) {
        bad = true;
        break;
      }
      _marks[m.tag] = m;
      changed = true;
    }
    final unmarks = json['u'];
    if (unmarks != null && unmarks is! List) bad = true;
    for (final r in unmarks is List ? unmarks : const []) {
      final parsed = _parseRange(r);
      if (parsed == null) {
        bad = true;
        continue;
      }
      for (var k = 0; k < parsed.$3; k++) {
        final tag = CharId(parsed.$2 + k, parsed.$1);
        if (_isGone(tag.ts, tag.site)) continue;
        if (_marks.remove(tag) != null) changed = true;
        if (_unmarked.length < maxItems) _unmarked.add(tag);
      }
    }
    if (changed) _changed();
    return MergeResult(changed, _waitingCount, bad, lost: lost);
  }

  static (String, int, int)? _parseRange(Object? r) {
    if (r is! List || r.length != 3 || r[0] is! String || r[1] is! int || r[2] is! int) return null;
    final site = r[0] as String, ts = r[1] as int, len = r[2] as int;
    if (site.length > maxSiteLength || ts < 1 || ts > maxClock || len < 1 || len > maxPerMessage) return null;
    return (site, ts, len);
  }

  static ({String site, int ts, int parentTs, String parentSite, String text, List<int> gone, CharId? copyOf})? _parseRun(Object? run) {
    if (run is! List || run.length < 5 || run.length > 7) return null;
    final site = run[0], ts = run[1], pts = run[2], psite = run[3], text = run[4];
    if (site is! String || ts is! int || pts is! int || psite is! String || text is! String) return null;
    if (site.isEmpty || site.length > maxSiteLength || psite.length > maxSiteLength) return null;
    // (a parent is older than its character, except in all of a text after a collection: a character whose parent was collected comes
    // after the one before it in the text, which may be younger - see [_encodeItems])
    if (ts < 1 || ts + text.length > maxClock || pts < 0 || pts > maxClock || (pts == ts && psite == site) || text.isEmpty) return null;
    if ((pts == 0) != psite.isEmpty) return null; // (the start of the text is the only thing with number 0)
    final gone = <int>[];
    CharId? copyOf;
    if (run.length == 7) {
      copyOf = CharId.fromJson(run[6]);
      if (copyOf == null || copyOf.ts < 1 || copyOf.ts + text.length > maxClock || copyOf.site.isEmpty || copyOf.site.length > maxSiteLength) return null;
    }
    if (run.length >= 6) {
      final g = run[5];
      if (g is! List || g.length.isOdd) return null;
      for (var k = 0; k < g.length; k += 2) {
        final a = g[k], b = g[k + 1];
        if (a is! int || b is! int || a < 0 || b < 1 || a + b > text.length) return null;
        gone
          ..add(a)
          ..add(b);
      }
    }
    return (site: site, ts: ts, parentTs: pts, parentSite: psite, text: text, gone: gone, copyOf: copyOf);
  }

  /// Whether something changed, and how many characters have no place (they come after one that was collected).
  (bool, int) _takeRun(({String site, int ts, int parentTs, String parentSite, String text, List<int> gone, CharId? copyOf}) run) {
    var changed = false;
    var lost = 0;
    var parentTs = run.parentTs;
    var parentSite = run.parentSite;
    for (var k = 0; k < run.text.length; k++) {
      final ts = run.ts + k;
      if (ts > _clock) _clock = ts;
      final known = _find(ts, run.site) != null || _isGone(ts, run.site) || _lost.contains(CharId(ts, run.site));
      if (!known) {
        final item = _Item(ts, run.site, parentTs, parentSite, run.text.codeUnitAt(k));
        if (run.copyOf case final c?) item.copyOf = CharId(c.ts + k, c.site);
        final parent = _find(parentTs, parentSite);
        if (parent == null) {
          if (_isGone(parentTs, parentSite) || _lost.contains(CharId(parentTs, parentSite))) {
            lost += _loseWith(item.id);
          } else if (_waitingIds.add(item.id)) {
            (_waiting[CharId(parentTs, parentSite)] ??= []).add(item);
            _waitingCount++;
          }
        } else {
          changed = _put(item, parent) || changed;
        }
      }
      parentTs = ts;
      parentSite = run.site;
    }
    for (var g = 0; g < run.gone.length; g += 2) {
      for (var k = 0; k < run.gone[g + 1]; k++) {
        if (_delete(CharId(run.ts + run.gone[g] + k, run.site))) changed = true;
      }
    }
    return (changed, lost);
  }

  /// [id] has no place (see [_lost]), nor what waits for it: how many characters that is.
  int _loseWith(CharId id) {
    var n = 0;
    final stack = [id];
    while (stack.isNotEmpty) {
      final x = stack.removeLast();
      if (_lost.length < maxItems) _lost.add(x);
      n++;
      final kids = _waiting.remove(x);
      if (kids == null) continue;
      _waitingCount -= kids.length;
      for (final k in kids) {
        _waitingIds.remove(k.id);
        stack.add(k.id);
      }
    }
    return n;
  }

  /// Links [item], and then whatever waited for it (and for those).
  bool _put(_Item item, _Item parent) {
    final stack = <(_Item, _Item)>[(item, parent)];
    var any = false;
    while (stack.isNotEmpty) {
      final (it, p) = stack.removeLast();
      if (_find(it.ts, it.site) != null) continue;
      _waitingIds.remove(it.id);
      _link(it, p);
      any = true;
      if (_waitingDeletes.remove(it.id)) _kill(it);
      _dedupe(it);
      final kids = _waiting.remove(it.id);
      if (kids != null) {
        _waitingCount -= kids.length;
        for (final kid in kids) {
          stack.add((kid, it));
        }
      }
    }
    return any;
  }

  bool _delete(CharId id) {
    final item = _find(id.ts, id.site);
    if (item == null) {
      if (_isGone(id.ts, id.site)) return false;
      // (it may be among those that wait; or it comes later)
      if (_waitingDeletes.length >= maxItems) return false;
      _waitingDeletes.add(id);
      return false;
    }
    if (item.deleted && !item.dup) return false;
    if (item.dup) {
      item
        ..dup = false
        ..unit = 0;
    } else {
      _kill(item);
    }
    _deleteCopies(item);
    return true;
  }

  // ---- collecting what was deleted

  /// Whether there is enough deleted (characters, and names of formatting taken away) to be worth collecting.
  bool get worthCollecting => _dead + _unmarked.length >= collectAfter;

  /// Whether this device can say where it is (or collect): nothing waits, and nothing made here is unsent.
  bool get _settled => _waitingCount == 0 && !hasChanges;

  /// A fingerprint of all of it (the characters with their places, the deleted ones too, and the formatting): two devices with the same
  /// one have the same text, built the same way.
  int digest() {
    final d = _Digest()..add(_epoch);
    for (var i = _head.next; i != null; i = i.next) {
      d
        ..add(i.ts)
        ..text(i.site)
        ..add(i.deleted ? 1 : 0);
    }
    d.add(-1);
    final marks = _marks.values.toList()..sort((a, b) => a.tag.compareTo(b.tag));
    for (final m in marks) {
      d
        ..add(m.tag.ts)
        ..text(m.tag.site)
        ..add(m.start.ts)
        ..text(m.start.site)
        ..add(m.end.ts)
        ..text(m.end.site)
        ..text(m.type)
        ..text(m.value ?? '\u0000');
    }
    d.add(-2);
    for (final t in _unmarked.toList()..sort()) {
      d
        ..add(t.ts)
        ..text(t.site);
    }
    return d.value;
  }

  /// What a guest tells the host when there is enough to collect and nothing of its own is unsent: the fingerprint of the text here
  /// ([digest]). The device remembers that it was at that point. Null when there is nothing to say.
  int? report() {
    if (!worthCollecting || !_settled) return null;
    final h = digest();
    _reported.remove(h);
    _reported.add(h);
    if (_reported.length > 32) _reported.removeAt(0);
    return h;
  }

  /// Collects what was deleted, if there is enough of it and every other device said it is where this one is ([digests]: what each
  /// reported last). Called by the device that every change passes through (the host): the next [takeChanges] is all of the text, with
  /// what was collected, for the others to do the same. True when it collected.
  ///
  /// It is safe because every device was at the same point: whatever any of them does from then on comes after it, and nobody will put
  /// a character after one that was deleted then. A device that was away, or that is not at that point, is not asked: see [merge].
  bool collect(Iterable<int?> digests) {
    if (!worthCollecting || !_settled) return false;
    final h = digest();
    if (digests.any((d) => d != h)) return false;
    final doomed = <_Item>{for (var i = _head.next; i != null; i = i.next) if (i.deleted) i};
    final tags = _unmarked.toList();
    final collected = <String, _Runs>{};
    for (final it in doomed) {
      (collected[it.site] ??= _Runs()).add(it.ts, it.ts + 1);
    }
    for (final t in tags) {
      (collected[t.site] ??= _Runs()).add(t.ts, t.ts + 1);
    }
    _remove(doomed, tags);
    _epoch++;
    _lastCollection = {'e': _epoch, 'h': h, 's': {for (final e in collected.entries) e.key: e.value.toJson()}};
    _reported.clear();
    _collectionToSend = true;
    return true;
  }

  /// Collects what [g] (the last collection of the device all of it came from) says was collected, if this device was where that one was
  /// then. False when it was not (and nothing was changed).
  bool _collectAsWith(Map g) {
    final h = g['h'];
    if (h is! int || !(_reported.contains(h) || (_waitingCount == 0 && digest() == h))) return false;
    final s = _Runs.mapFromJson(g['s']);
    if (s == null) return false;
    final doomed = <_Item>{};
    final tags = <CharId>[];
    for (final e in s.entries) {
      for (final ts in e.value.all) {
        final item = _find(ts, e.key);
        final id = CharId(ts, e.key);
        if (item != null) {
          if (!item.deleted) return false; // (alive here: this device was not where the other was)
          doomed.add(item);
        } else if (_unmarked.contains(id)) {
          tags.add(id);
        } else if (!_isGone(ts, e.key)) {
          return false;
        }
      }
    }
    _remove(doomed, tags);
    _epoch = g['e'] as int;
    _lastCollection = g.cast<String, Object?>();
    _reported.clear();
    return true;
  }

  /// Takes [doomed] (deleted characters) and [tags] (names of formatting that was taken away) out for good. Formatting that is on a
  /// character that goes is moved to the next one that stays, which is the same place (a character typed later never comes between
  /// them: it would have to come after one of those that went, which nobody can see any more); formatting that is on nothing then goes.
  void _remove(Set<_Item> doomed, List<CharId> tags) {
    final next = <CharId, CharId>{};
    final pending = <CharId>[];
    var prev = _head;
    var i = _head.next;
    while (i != null) {
      final after = i.next;
      if (doomed.contains(i)) {
        pending.add(i.id);
      } else {
        for (final p in pending) {
          next[p] = i.id;
        }
        pending.clear();
        prev.next = i;
        prev = i;
      }
      i = after;
    }
    prev.next = null;
    for (final p in pending) {
      next[p] = endOfText;
    }
    for (final it in doomed) {
      _byId[it.site]?.remove(it.ts);
      _goneAdd(it.site, it.ts);
    }
    _count -= doomed.length;
    _dead -= doomed.length;
    for (final t in tags) {
      _unmarked.remove(t);
      _goneAdd(t.site, t.ts);
    }
    for (final m in _marks.values.toList()) {
      final s = next[m.start] ?? m.start, e = next[m.end] ?? m.end;
      if (s == m.start && e == m.end) continue;
      if (s == e || s == endOfText) {
        _marks.remove(m.tag);
        _goneAdd(m.tag.site, m.tag.ts);
      } else {
        _marks[m.tag] = TextMark(m.tag, s, e, m.type, m.value);
      }
    }
    _waitingDeletes.removeWhere((id) => _isGone(id.ts, id.site));
    _sameAs.removeWhere((root, kept) => doomed.contains(kept));
    _changed();
  }

  /// Makes the text again from [json] (all of a text, from a device that collected what this one cannot): what is here and not there
  /// (typed while away, or not yet sent) is typed into it again where it was, deletions it does not have are made again, and the same
  /// for the formatting. All of that is sent as changes of this device.
  MergeResult _rebase(Map json) {
    final fresh = TextCrdt(site, clock: _clock);
    final taken = fresh.merge(json);
    if (taken.malformed && fresh._count == 0) return MergeResult(false, _waitingCount, true);
    fresh._clearNew();
    final moved = <CharId, CharId>{};
    var after = CharId.start;
    final run = <int>[];
    final runIds = <CharId>[];
    final runRoots = <CharId>[];
    void flush() {
      if (runIds.isEmpty) return;
      final at = fresh.offsetsOf([after]).first;
      fresh.replace(at, 0, String.fromCharCodes(run));
      final vis = fresh._visibleItems();
      for (var k = 0; k < runIds.length; k++) {
        final copy = vis[at + k];
        moved[runIds[k]] = copy.id;
        // (another device may type the same characters again into the same text: see [_dedupe])
        copy.copyOf = runRoots[k];
        fresh._sameAs[runRoots[k]] = copy;
      }
      after = vis[at + runIds.length - 1].id;
      run.clear();
      runIds.clear();
      runRoots.clear();
    }

    final deletes = <CharId>[];
    for (var i = _head.next; i != null; i = i.next) {
      final root = i.copyOf ?? i.id;
      final there = fresh._find(i.ts, i.site) ?? fresh._sameAs[root] ?? (i.copyOf == null ? null : fresh._find(root.ts, root.site));
      if (there != null) {
        flush();
        after = there.id;
        if (there.id != i.id) moved[i.id] = there.id;
        if (i.deleted && !i.dup && !there.deleted) deletes.add(there.id);
        continue;
      }
      if (i.deleted || fresh._isGone(i.ts, i.site) || fresh._isGone(root.ts, root.site)) continue;
      run.add(i.unit);
      runIds.add(i.id);
      runRoots.add(root);
    }
    flush();
    for (final id in deletes) {
      final it = fresh._find(id.ts, id.site)!;
      fresh._visibleItems();
      if (!it.deleted) fresh.replace(it.before, 1, '');
    }
    for (final m in _marks.values) {
      if (fresh._marks.containsKey(m.tag) || fresh._unmarked.contains(m.tag) || fresh._isGone(m.tag.ts, m.tag.site)) continue;
      final s = moved[m.start] ?? m.start, e = moved[m.end] ?? m.end;
      if (fresh._find(s.ts, s.site) == null || (e != endOfText && fresh._find(e.ts, e.site) == null)) continue;
      final tag = s == m.start && e == m.end ? m.tag : CharId(++fresh._clock, site);
      final mark = TextMark(tag, s, e, m.type, m.value);
      fresh._marks[tag] = mark;
      fresh._newMarks.add(mark);
    }
    for (final tag in _unmarked) {
      if (fresh._marks.remove(tag) != null) {
        fresh._unmarked.add(tag);
        fresh._newUnmarks.add(tag);
      }
    }
    return _become(fresh, moved, taken);
  }

  /// Makes the text again from [json] (all of a text), from a device that does not share any of this one's history: the host app was
  /// started again from the saved note, and its texts are made anew, under its own names. Taking it in by the names of the characters
  /// would put both texts in, one after the other; it is taken by comparing the texts instead. What is the same in both is theirs, what
  /// is only here is typed into it again (as copies of the characters here: several devices that do the same make one copy, see
  /// [_dedupe]), what is only there is deleted. The formatting is that of the text here. All of that is sent as changes of this device.
  MergeResult adoptUnrelated(Object? json) {
    if (json is! Map) return MergeResult(false, _waitingCount, true);
    final fresh = TextCrdt(site, clock: _clock);
    final taken = fresh.merge(json);
    if (taken.malformed && fresh._count == 0) return MergeResult(false, _waitingCount, true);
    fresh._clearNew();
    final ours = _visibleItems();
    final mine = spans;
    final moved = <CharId, CharId>{};
    final edits = diffText(fresh.text, text);
    // the characters that are the same, by where they are in both
    final theirs = fresh._visibleItems();
    var i = 0, j = 0;
    void same(int upTo) {
      while (i < upTo) {
        moved[ours[j].id] = theirs[i].id;
        i++;
        j++;
      }
    }

    final at = <int>[];
    for (final e in edits) {
      same(e.start);
      at.add(j);
      i += e.removed;
      j += e.inserted.length;
    }
    same(theirs.length);
    for (var k = edits.length - 1; k >= 0; k--) {
      final e = edits[k];
      fresh.replace(e.start, e.removed, e.inserted);
      final vis = fresh._visibleItems();
      for (var n = 0; n < e.inserted.length; n++) {
        final copy = vis[e.start + n], original = ours[at[k] + n];
        final root = original.copyOf ?? original.id;
        copy.copyOf = root;
        fresh._sameAs[root] = copy;
        moved[original.id] = copy.id;
      }
    }
    fresh.setSpans(mine);
    return _become(fresh, moved, taken);
  }

  /// Takes the text of [fresh] as this one's ([moved]: where characters of this one are in it, by their old names).
  MergeResult _become(TextCrdt fresh, Map<CharId, CharId> moved, MergeResult taken) {
    final oldText = text, oldSpans = spans;
    _clock = math.max(_clock, fresh._clock);
    _head = fresh._head;
    _byId = fresh._byId;
    _count = fresh._count;
    _dead = fresh._dead;
    _waiting = fresh._waiting;
    _waitingCount = fresh._waitingCount;
    _waitingIds = fresh._waitingIds;
    _waitingDeletes = fresh._waitingDeletes;
    _newItems = fresh._newItems;
    _newDeletes = fresh._newDeletes;
    _marks = fresh._marks;
    _sameAs = fresh._sameAs;
    _lost = fresh._lost;
    _unmarked = fresh._unmarked;
    _newMarks = fresh._newMarks;
    _newUnmarks = fresh._newUnmarks;
    _epoch = fresh._epoch;
    _gone = fresh._gone;
    _lastCollection = fresh._lastCollection;
    _collectionToSend = false;
    _reported.clear();
    _moved = moved;
    _changed();
    final changed = text != oldText || !_sameSpans(spans, oldSpans);
    return MergeResult(changed, _waitingCount, taken.malformed, rebased: true, lost: taken.lost);
  }

  static bool _sameSpans(List<MarkSpan> a, List<MarkSpan> b) {
    if (a.length != b.length) return false;
    for (var k = 0; k < a.length; k++) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  // ---- places in the text that stay where they are while the text changes around them

  /// What is at [offsets] (positions between characters, 0 to [length]) as names: each is the character before it (the start of the text
  /// for 0), which does not move away when others write.
  List<CharId> placesAt(List<int> offsets) {
    final vis = _visibleItems();
    return [for (final o in offsets) o <= 0 || vis.isEmpty ? CharId.start : vis[(o > vis.length ? vis.length : o) - 1].id];
  }

  /// Where the places [ids] (from [placesAt], or [startOf] / [endOf] of characters that may be gone since) are now.
  List<int> offsetsOf(List<CharId> ids) {
    final n = _visibleItems().length;
    return [
      for (final id in ids)
        if (id == CharId.start) 0 else switch (_findId(id)) { final i? => i.deleted ? i.before : i.before + 1, null => n },
    ];
  }

  /// The names of the characters at [offsets] (each must be below [length]).
  List<CharId> charactersAt(List<int> offsets) {
    final vis = _visibleItems();
    return [for (final o in offsets) vis[o].id];
  }

  /// Where the characters [ids] start now (a deleted one: where it was), and where they end.
  ({List<int> starts, List<int> ends}) rangesOf(List<CharId> startIds, List<CharId> endIds) {
    final n = _visibleItems().length;
    return (
      starts: [for (final id in startIds) _findId(id)?.before ?? n],
      ends: [for (final id in endIds) switch (_findId(id)) { final i? => i.before + (i.deleted ? 0 : 1), null => n }],
    );
  }

  // ---- whole texts from a device that does not merge (an older version of the app)

  /// Takes in [now], all of a text from a device that does not merge texts, which it made from [baseText] (a text this one gave it or
  /// had from it, [baseIds] the names of its characters): what that device changed is changed here too, where those characters are now,
  /// and what others wrote meanwhile stays. The names of the characters of [now], as they are here.
  List<CharId> applyWhole(String baseText, List<CharId> baseIds, String now) {
    assert(baseIds.length == baseText.length);
    final edits = diffText(baseText, now);
    final inserted = <int, List<CharId>>{};
    for (var k = edits.length - 1; k >= 0; k--) {
      final e = edits[k];
      for (var x = e.start; x < e.start + e.removed; x++) {
        final it = _findId(baseIds[x]);
        if (it != null && !it.deleted) {
          _kill(it);
          _newDeletes.add(it);
          _deleteCopies(it);
        }
      }
      _changed();
      if (e.inserted.isEmpty) continue;
      final at = e.start == 0 ? 0 : offsetsOf([baseIds[e.start - 1]]).first;
      replace(at, 0, e.inserted);
      final vis = _visibleItems();
      inserted[k] = [for (var n = 0; n < e.inserted.length; n++) vis[at + n].id];
    }
    final ids = <CharId>[];
    var p = 0;
    for (var k = 0; k < edits.length; k++) {
      final e = edits[k];
      while (p < e.start) {
        ids.add(baseIds[p++]);
      }
      ids.addAll(inserted[k] ?? const []);
      p = e.start + e.removed;
    }
    while (p < baseIds.length) {
      ids.add(baseIds[p++]);
    }
    return ids;
  }

  /// [spans] of a text whose characters are [ids] (see [applyWhole]), where those characters are now.
  List<MarkSpan> spansOn(List<CharId> ids, List<MarkSpan> spans) {
    _visibleItems();
    final out = <MarkSpan>[];
    for (final s in spans) {
      int? from, to;
      for (var k = s.start.clamp(0, ids.length); k < s.end.clamp(0, ids.length); k++) {
        final it = _findId(ids[k]);
        if (it == null || it.deleted) continue;
        from ??= it.before;
        to = it.before + 1;
      }
      if (from != null && to != null && to > from) out.add(MarkSpan(from, to, s.type, s.value));
    }
    return out;
  }

  /// A copy (for the tests, and for a device that must try something without touching its text).
  TextCrdt copyAs(String site) {
    final c = TextCrdt(site, clock: _clock);
    c.merge(encode());
    c._clearNew();
    return c;
  }
}
