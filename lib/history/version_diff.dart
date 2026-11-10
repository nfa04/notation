import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import '../collab/note_delta.dart';
import '../collab/replica.dart';
import '../data/note_data.dart';
import '../models/canvas_models.dart';
import '../models/image_item.dart';
import '../models/pdf_models.dart';

/// The most numbers the table of [matchLines] has (64 MB).
const _tableLimit = 16000000;

/// For each line of [b], the line of [a] it stayed from (the longest run of lines in the same order), or -1.
List<int> matchLines(List<String> a, List<String> b) {
  final out = List<int>.filled(b.length, -1);
  var lo = 0;
  while (lo < a.length && lo < b.length && a[lo] == b[lo]) {
    out[lo] = lo;
    lo++;
  }
  var ea = a.length, eb = b.length;
  while (ea > lo && eb > lo && a[ea - 1] == b[eb - 1]) {
    ea--;
    eb--;
    out[eb] = ea;
  }
  final n = ea - lo, m = eb - lo;
  if (n == 0 || m == 0) return out;
  // (the table is n * m numbers: for a long text that was written over, the lines are matched in order one by one instead, which finds
  // fewer of them but costs no memory)
  if (n * m > _tableLimit) {
    final where = <String, List<int>>{};
    for (var i = n - 1; i >= 0; i--) {
      (where[a[lo + i]] ??= []).add(i);
    }
    var next = 0;
    for (var j = 0; j < m; j++) {
      final spots = where[b[lo + j]];
      if (spots == null) continue;
      while (spots.isNotEmpty && spots.last < next) {
        spots.removeLast();
      }
      if (spots.isEmpty) continue;
      next = spots.removeLast();
      out[lo + j] = lo + next;
      next++;
    }
    return out;
  }
  final width = m + 1;
  final table = Int32List((n + 1) * width);
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      table[i * width + j] = a[lo + i] == b[lo + j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[lo + i] == b[lo + j]) {
      out[lo + j] = lo + i;
      i++;
      j++;
    } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}

/// How a thing differs between two versions of a note.
enum ChangeKind { added, removed, changed }

/// One thing that differs between two states of a note, and where it is.
class ElementChange {
  final ChangeKind change;
  final ElementKind kind;
  final String id;
  final int page;

  /// Where it is on its page (in the page space of the editor). For a removed thing, where it was.
  final Rect rect;

  /// The thing as it was (null if it was added) and as it is (null if it was removed): a [DrawingStroke],
  /// [TextBoxWidgetModel], [ImageItem] or [PdfHighlight].
  final Object? older, newer;

  const ElementChange(this.change, this.kind, this.id, this.page, this.rect, {this.older, this.newer});

  /// Who made it (null if not known): the same whether it was added, changed or removed.
  String? get author => authorOf(newer ?? older);

  /// The author of a stroke, text box, picture or highlight.
  static String? authorOf(Object? item) => switch (item) {
        DrawingStroke s => s.author,
        TextBoxWidgetModel b => b.author,
        ImageItem m => m.author,
        PdfHighlight h => h.author,
        _ => null,
      };
}

/// What differs between an [older] and a [newer] state of a note: what was added, removed and changed on the pages,
/// and which of the note's own fields (title, page setup, written document) changed.
class VersionDiff {
  final List<ElementChange> elements;

  /// The fields of the note that changed: `title`, `setup`, `doc`.
  final Set<String> fields;

  /// Lines of the written document that are new, and lines that are gone (a line that was changed is one of each).
  final int linesAdded, linesRemoved;

  VersionDiff(this.elements, this.fields, {this.linesAdded = 0, this.linesRemoved = 0});

  bool get isEmpty => elements.isEmpty && fields.isEmpty;

  /// The things that moved to another page: they are in the list as gone from the one page and new on the other, and count as one
  /// change, not as one removed and one added.
  late final Set<String> _moved = () {
    final added = {for (final e in elements) if (e.change == ChangeKind.added) '${e.kind.name}:${e.id}'};
    return {for (final e in elements) if (e.change == ChangeKind.removed && added.contains('${e.kind.name}:${e.id}')) '${e.kind.name}:${e.id}'};
  }();

  /// The things that count as [kind] (what moved to another page is one change).
  Iterable<ElementChange> _counted(ChangeKind kind) sync* {
    for (final e in elements) {
      final moved = _moved.contains('${e.kind.name}:${e.id}');
      if (moved) {
        if (e.change == ChangeKind.added && kind == ChangeKind.changed) yield e;
      } else if (e.change == kind) {
        yield e;
      }
    }
  }

  int count(ChangeKind kind) => _counted(kind).length;

  /// How many things of [kind] each person added, removed or changed (null: not known).
  Map<String?, int> byAuthor(ChangeKind kind) {
    final out = <String?, int>{};
    for (final e in _counted(kind)) {
      out[e.author] = (out[e.author] ?? 0) + 1;
    }
    return out;
  }

  /// How many of each sort of thing (drawings, text boxes, pictures, highlights) were added, removed or changed.
  Map<ElementKind, int> byKind(ChangeKind kind) {
    final out = <ElementKind, int>{};
    for (final e in _counted(kind)) {
      out[e.kind] = (out[e.kind] ?? 0) + 1;
    }
    return out;
  }

  List<ElementChange> onPage(int page) => [for (final e in elements) if (e.page == page) e];

  static VersionDiff between(NoteData older, NoteData newer) {
    final before = Replica.elementsOf(older), after = Replica.elementsOf(newer);
    final digestsBefore = NoteDelta.digests(older), digestsAfter = NoteDelta.digests(newer);
    final placesBefore = placesOf(older), placesAfter = placesOf(newer);
    final elements = <ElementChange>[];
    final fields = <String>{};
    for (final e in after.entries) {
      final kind = e.value.kind;
      if (kind == ElementKind.note) {
        if (digestsBefore[e.key] != digestsAfter[e.key]) fields.add(e.value.id);
        continue;
      }
      final place = placesAfter[e.key];
      if (place == null) continue;
      final old = placesBefore[e.key];
      if (!before.containsKey(e.key) || old == null) {
        elements.add(ElementChange(ChangeKind.added, kind, e.value.id, place.page, place.rect, newer: place.item));
      } else if (digestsBefore[e.key] != digestsAfter[e.key]) {
        if (old.page != place.page) {
          // moved to another page: gone from the one, new on the other
          elements.add(ElementChange(ChangeKind.removed, kind, e.value.id, old.page, old.rect, older: old.item));
          elements.add(ElementChange(ChangeKind.added, kind, e.value.id, place.page, place.rect, newer: place.item));
        } else {
          // where it is now and where it was
          elements.add(ElementChange(ChangeKind.changed, kind, e.value.id, place.page, place.rect.expandToInclude(old.rect), older: old.item, newer: place.item));
        }
      }
    }
    for (final e in before.entries) {
      if (e.value.kind == ElementKind.note || after.containsKey(e.key)) continue;
      final place = placesBefore[e.key];
      if (place != null) elements.add(ElementChange(ChangeKind.removed, e.value.kind, e.value.id, place.page, place.rect, older: place.item));
    }
    // the written document, by line
    List<String> lines(String t) => t.isEmpty ? <String>[] : t.split('\n');
    final a = lines(older.documentText), b = lines(newer.documentText);
    final kept = matchLines(a, b);
    final stayed = kept.where((i) => i >= 0).length;
    return VersionDiff(elements, fields, linesAdded: b.length - stayed, linesRemoved: a.length - stayed);
  }

  /// Where each thing of [note] is: its page, the rectangle it takes, and the thing itself (by `kind:id`).
  static Map<String, ({int page, Rect rect, Object item})> placesOf(NoteData note) {
    final out = <String, ({int page, Rect rect, Object item})>{};
    note.strokes.forEach((page, list) {
      for (final s in list) {
        if (s.points.length < 2) continue;
        var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
        for (final pt in s.points) {
          l = min(l, pt.dx);
          t = min(t, pt.dy);
          r = max(r, pt.dx);
          b = max(b, pt.dy);
        }
        out[Replica.keyOf(ElementKind.stroke, s.id)] = (page: page, rect: Rect.fromLTRB(l, t, r, b).inflate(s.width / 2 + 2), item: s);
      }
    });
    note.textBoxes.forEach((page, list) {
      for (final box in list) {
        final size = Size(box.size.width, max(box.size.height, 40));
        out[Replica.keyOf(ElementKind.box, box.id)] = (page: page, rect: box.position & size, item: box);
      }
    });
    note.images.forEach((page, list) {
      for (final m in list) {
        out[Replica.keyOf(ElementKind.image, m.id)] = (page: page, rect: m.position & m.size, item: m);
      }
    });
    note.highlights.forEach((page, list) {
      for (final h in list) {
        out[Replica.keyOf(ElementKind.mark, h.id)] = (page: page, rect: h.rect, item: h);
      }
    });
    return out;
  }
}

/// Who added what in a note: how many things each person put in it, and a colour for each of them.
class NoteAuthors {
  /// The people in the note by the number of things they added (the one with the most first), each as the author
  /// string they are stored under ([Author]); not those without one ([unknown] counts those).
  final List<({String name, int count})> people;

  /// How many things have no author (made before names were kept, or by someone who had none).
  final int unknown;

  const NoteAuthors(this.people, this.unknown);

  static NoteAuthors of(NoteData note) {
    final counts = <String, int>{};
    var unknown = 0;
    void add(String? a) {
      if (a == null) {
        unknown++;
      } else {
        counts[a] = (counts[a] ?? 0) + 1;
      }
    }

    for (final list in note.strokes.values) {
      for (final s in list) {
        if (s.points.length >= 2) add(s.author);
      }
    }
    for (final list in note.textBoxes.values) {
      for (final b in list) {
        add(b.author);
      }
    }
    for (final list in note.images.values) {
      for (final m in list) {
        add(m.author);
      }
    }
    for (final list in note.highlights.values) {
      for (final h in list) {
        add(h.author);
      }
    }
    final people = [for (final e in counts.entries) (name: e.key, count: e.value)]..sort((a, b) {
        final c = b.count.compareTo(a.count);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
    return NoteAuthors(people, unknown);
  }

  static const _palette = [
    Color(0xFF1E88E5),
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFFFB8C00),
    Color(0xFF8E24AA),
    Color(0xFF00ACC1),
    Color(0xFFD81B60),
    Color(0xFF6D4C41),
  ];

  /// The author strings in [note] (not the empty ones).
  static Set<String> keysOf(NoteData note) => {for (final p in of(note).people) p.name};

  /// The colour of [name] among the people of [everyone] (by their place in alphabetical order, so that two people
  /// never share one while there are fewer than eight); grey for no name.
  static Color colorOf(String? name, Iterable<String> everyone) {
    if (name == null) return const Color(0xFF757575);
    final sorted = everyone.toSet().toList()..sort();
    final i = sorted.indexOf(name);
    return _palette[(i < 0 ? name.hashCode.abs() : i) % _palette.length];
  }
}
