import 'citation_style.dart';
import 'source.dart';

/// One thing a citation cites: a key, and what the writer says about the citation. All of these are written in a bracket,
/// Pandoc-style: `[see @smith2020, p. 42, emphasis added; -@doe2019]`.
class CiteRef {
  final String key;

  /// Where in the source (null: the source as a whole).
  final Locator? locator;

  /// Words before the citation ("see") and after it ("emphasis added").
  final String prefix;
  final String suffix;

  /// `-@key`: the text names the author already, so only the year is cited.
  final bool suppressAuthor;

  /// `@key [p. 4]` in running text, which reads as "Smith (2020, p. 4)" instead of "(Smith, 2020, p. 4)".
  final bool narrative;

  const CiteRef(this.key, {this.locator, this.prefix = '', this.suffix = '', this.suppressAuthor = false, this.narrative = false});

  /// As it is written in a text: an item of a bracket, or the narrative form.
  String write() {
    if (narrative) return '@$key${locator == null ? '' : ' [${locator!.text()}]'}';
    return '${prefix.isEmpty ? '' : '$prefix '}${suppressAuthor ? '-' : ''}@$key${locator == null ? '' : ', ${locator!.text()}'}${suffix.isEmpty ? '' : ', $suffix'}';
  }
}

/// One `[@key, p. 42; @other]` (or `@key` of running text) in a text.
class CitationMark {
  /// Where it is in the text, and how long.
  final int start;
  final int end;

  /// What it cites.
  final List<CiteRef> items;

  const CitationMark(this.start, this.end, this.items);
}

/// A key as the text spells it: letters, digits and `_ : . - /` (not a trailing dot or comma).
const _keyPattern = r'[A-Za-z0-9_](?:[A-Za-z0-9_:.\-/]*[A-Za-z0-9_])?';

/// The `@` that starts an item, with the `-` that leaves out the author; it follows a space or starts the item (so `me@x.org` is not one).
final _at = RegExp(r'(?:^|\s)(-?)@(?=[A-Za-z0-9_])');
final _item = RegExp('^($_keyPattern)\\s*(?:,\\s*|\\s+)?(.*?)\\s*\$');

/// The citation written in [inner], the text between the brackets: `see @smith2020, p. 42; @doe2019`. Null if it is not one.
List<CiteRef>? parseCitationItems(String inner) {
  if (!inner.contains('@')) return null;
  final out = <CiteRef>[];
  for (final part in inner.split(';')) {
    final at = _at.firstMatch(part);
    if (at == null) return null;
    final prefix = part.substring(0, at.start).trim();
    if (prefix.contains('[')) return null;
    final m = _item.firstMatch(part.substring(at.end));
    if (m == null) return null;
    final (locator, suffix) = Locator.parseWithSuffix(m.group(2)!);
    out.add(CiteRef(m.group(1)!, locator: locator, prefix: prefix, suffix: suffix, suppressAuthor: at.group(1) == '-'));
  }
  return out;
}

/// The bracket at [from] in [line], if a citation starts there: its end (just after the `]`) and what it cites. `[@a](url)` is a
/// link, not a citation.
(int, List<CiteRef>)? citationAt(String line, int from, int limit) {
  if (from + 1 >= limit || line[from] != '[') return null;
  final close = line.indexOf(']', from + 1);
  if (close < 0 || close >= limit) return null;
  if (close + 1 < line.length && line[close + 1] == '(') return null;
  final items = parseCitationItems(line.substring(from + 1, close));
  return items == null ? null : (close + 1, items);
}

final _narrativeKey = RegExp(_keyPattern);
final _narrativeLocator = RegExp(r'^\s?\[([^\]\[@]+)\](?!\()');

/// `@smith2020` or `@smith2020 [p. 4]` at [from] in [line] as part of a sentence: its end and what it cites. Null if there is none
/// (an `@` inside a word, an address or a link is not one). Whether the key is in the library is for the reader to decide: a
/// `@name` that is not a source stays as it was written.
(int, List<CiteRef>)? narrativeAt(String line, int from, int limit) {
  if (from >= limit || line[from] != '@') return null;
  if (from > 0 && !RegExp(r'[\s("“‘*_~>,;]').hasMatch(line[from - 1])) return null;
  final head = line.substring(0, limit);
  final m = _narrativeKey.matchAsPrefix(head, from + 1);
  if (m == null) return null;
  var end = m.end;
  Locator? locator;
  final tail = _narrativeLocator.firstMatch(head.substring(end));
  if (tail != null) {
    final (l, suffix) = Locator.parseWithSuffix(tail.group(1)!);
    if (l != null && suffix.isEmpty) {
      locator = l;
      end += tail.end;
    }
  }
  return (end, [CiteRef(m.group(0)!, locator: locator, narrative: true)]);
}

/// Every citation in [text], in order.
List<CitationMark> findCitations(String text) {
  final marks = <CitationMark>[];
  var offset = 0;
  var inFence = false;
  for (final line in text.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) inFence = !inFence;
    if (!inFence) {
      var i = 0;
      while (i < line.length) {
        final hit = line[i] == '[' ? citationAt(line, i, line.length) : (line[i] == '@' ? narrativeAt(line, i, line.length) : null);
        if (hit == null) {
          // the words of a link are not read for citations: `[see @a](url)`
          final close = line[i] == '[' ? line.indexOf(']', i + 1) : -1;
          i = close > i && close + 1 < line.length && line[close + 1] == '(' ? close + 1 : i + 1;
        } else {
          marks.add(CitationMark(offset + i, offset + hit.$1, hit.$2));
          i = hit.$1;
        }
      }
    }
    offset += line.length + 1;
  }
  return marks;
}

/// A text with its citations worked out for one style and one library: the numbers for numbered styles, what each citation
/// reads as, and the list of sources cited.
class CitationDocument {
  final CitationStyle style;
  final Map<String, CitationSource> library;

  /// The same library with the letters that tell apart works of one author and year, for the sources this text cites.
  late final Map<String, CitationSource> _resolved;

  /// The sources the text cites, in the order they come.
  final List<CitationSource> cited = [];

  /// The keys the text cites that the library does not have.
  final List<String> missing = [];

  final Map<String, int> _numbers = {};

  CitationDocument(this.style, this.library, String text) {
    for (final mark in findCitations(text)) {
      for (final ref in mark.items) {
        final key = ref.key;
        final s = library[key];
        if (s == null) {
          // (an `@name` in a sentence that is not a source is just text)
          if (!ref.narrative && !missing.contains(key)) missing.add(key);
        } else if (!_numbers.containsKey(key)) {
          cited.add(s);
          _numbers[key] = cited.length;
        }
      }
    }
    _tellApart();
  }

  bool get isEmpty => cited.isEmpty && missing.isEmpty;

  /// Gives works of the same authors and year a, b, c… in the order of their titles (the numbered styles have no use for them).
  void _tellApart() {
    _resolved = {...library};
    if (style.numeric) return;
    final groups = <String, List<CitationSource>>{};
    for (final s in cited) {
      // works that read as "Smith et al. 2020" in the text are told apart even when their other authors differ
      final people = s.authors.isNotEmpty ? s.authors : s.editors;
      final who = people.length >= style.etAlFrom ? '${people.first.family.toLowerCase()}|et al.' : people.map((p) => p.family.toLowerCase()).join('|');
      (groups['$who#${s.year}'] ??= []).add(s);
    }
    for (final group in groups.values.where((g) => g.length > 1)) {
      group.sort(style.compare);
      for (final (i, s) in group.indexed) {
        _resolved[s.id] = s.copyWith(yearSuffix: String.fromCharCode(97 + i % 26));
      }
    }
  }

  /// What `[@a; @b]` reads as in the text; an unknown key stays as written so that it can be seen and fixed.
  String inText(List<CiteRef> items) {
    if (items.length == 1 && items.single.narrative) {
      final r = items.single;
      final s = _resolved[r.key];
      return s == null ? '@${r.key}' : style.narrative(Cite(s, r.locator), _numbers);
    }
    if (items.any((i) => !library.containsKey(i.key))) return '[${items.map((i) => '@${i.key}').join('; ')}?]';
    return style.inText([for (final r in items) Cite(_resolved[r.key]!, r.locator, r.prefix, r.suffix, r.suppressAuthor)], _numbers);
  }

  /// The entries of the list of sources: numbered styles in the order of first use, the others in alphabetical order.
  List<String> bibliography() {
    if (style.numeric) return [for (final (i, s) in cited.indexed) style.entry(s, number: i + 1)];
    final sorted = [for (final s in cited) _resolved[s.id]!]..sort(style.compare);
    return [for (final s in sorted) style.entry(s)];
  }
}
