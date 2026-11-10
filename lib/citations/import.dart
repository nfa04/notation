import 'dart:convert';

import 'source.dart';

/// Reading a file of references from another reference manager: BibTeX (`.bib`), RIS (`.ris`) or CSL-JSON (`.json`).
/// [importReferences] decides by what the text looks like. Sources come out with the key they had, or none (empty id) when the
/// format has none; the library gives those a key.
List<CitationSource> importReferences(String text) {
  final t = text.trimLeft().replaceFirst('\uFEFF', '');
  if (t.startsWith('[') || t.startsWith('{')) return parseCslJson(t);
  if (RegExp(r'^TY\s{1,2}-', multiLine: true).hasMatch(t)) return parseRis(t);
  return parseBibtex(t);
}

/// CSL-JSON: an array of items, or one item.
List<CitationSource> parseCslJson(String text) {
  final data = jsonDecode(text);
  final items = data is List ? data : [data];
  return [
    for (final item in items)
      if (item is Map<String, dynamic>) CitationSource.fromJson(item),
  ];
}

const _accents = {
  '"a': 'ä', '"o': 'ö', '"u': 'ü', '"A': 'Ä', '"O': 'Ö', '"U': 'Ü', '"e': 'ë', '"i': 'ï',
  "'a": 'á', "'e": 'é', "'i": 'í', "'o": 'ó', "'u": 'ú', "'A": 'Á', "'E": 'É', "'O": 'Ó', "'U": 'Ú',
  '`a': 'à', '`e': 'è', '`i': 'ì', '`o': 'ò', '`u': 'ù',
  '^a': 'â', '^e': 'ê', '^i': 'î', '^o': 'ô', '^u': 'û',
  '~n': 'ñ', '~a': 'ã', '~o': 'õ', '~N': 'Ñ',
  'cc': 'ç', 'cC': 'Ç', 'vs': 'š', 'vS': 'Š', 'vc': 'č', 'vC': 'Č', 'vz': 'ž', 'vZ': 'Ž',
};

/// BibTeX field text as plain text: `{\"u}` becomes ü, the braces that keep capitals are dropped, `--` becomes an en dash.
String cleanLatex(String s) {
  var out = s;
  // (`\"u`, `\'e`: the mark and the letter; `\c c` and `\v s` need the space or a brace, else `\cite` and `\vec` lose their name)
  out = out.replaceAllMapped(RegExp(r'''\\(?:(["'`^~])\{?\\?([A-Za-z])\}?|([cv])(?: +|\{\\?)([A-Za-z])\}?)'''), (m) {
    final key = m.group(1) != null ? '${m.group(1)}${m.group(2)}' : '${m.group(3)}${m.group(4)}';
    return _accents[key] ?? (m.group(2) ?? m.group(4))!;
  });
  out = out
      .replaceAll(r'\ss', 'ß')
      .replaceAll(r'\&', '&')
      .replaceAll(r'\%', '%')
      .replaceAll(r'\_', '_')
      .replaceAll(r'\#', '#')
      .replaceAll(r'\$', '\$')
      .replaceAll(RegExp(r'\\(?:textit|emph|textbf|textsc|url)\{([^{}]*)\}'), r'$1')
      .replaceAll(RegExp(r'[{}]'), '')
      .replaceAll('--', '–')
      .replaceAll(RegExp(r'\s+'), ' ');
  return out.trim();
}

SourceType _bibType(String type, Map<String, String> f) => switch (type) {
      'article' => SourceType.article,
      'inbook' || 'incollection' => SourceType.chapter,
      'inproceedings' || 'conference' => SourceType.conference,
      'phdthesis' || 'mastersthesis' || 'thesis' => SourceType.thesis,
      'techreport' || 'report' => SourceType.report,
      'online' || 'electronic' || 'www' || 'webpage' => SourceType.webpage,
      'misc' => f.containsKey('url') && !f.containsKey('publisher') ? SourceType.webpage : SourceType.book,
      _ => SourceType.book,
    };

List<Person> _bibPeople(String? text) {
  if (text == null || text.trim().isEmpty) return const [];
  return [
    for (final name in text.split(RegExp(r'\s+and\s+')))
      // a name in double braces, {World Health Organization}, is one organisation
      if (name.trim().startsWith('{') && name.trim().endsWith('}') && !name.contains(','))
        Person.literal(cleanLatex(name))
      else
        Person.parse(cleanLatex(name)),
  ].where((p) => p.family.isNotEmpty).toList();
}

/// BibTeX / BibLaTeX entries. Entries it cannot make sense of are skipped.
List<CitationSource> parseBibtex(String text) {
  final out = <CitationSource>[];
  final strings = <String, String>{};
  var i = 0;
  while (true) {
    final at = text.indexOf('@', i);
    if (at < 0) break;
    final head = RegExp(r'@\s*([A-Za-z]+)\s*([{(])').matchAsPrefix(text, at);
    if (head == null) {
      i = at + 1;
      continue;
    }
    final kind = head.group(1)!.toLowerCase();
    final open = head.group(2)!;
    final bodyStart = head.end;
    // the entry ends at the bracket that matches, braces inside field values nest
    var depth = 1, j = bodyStart;
    var inQuote = false;
    while (j < text.length && depth > 0) {
      final c = text[j];
      if (c == '\\') {
        j += 2;
        continue;
      }
      if (c == '"' && depth == 1) inQuote = !inQuote;
      if (!inQuote) {
        if (c == '{') depth++;
        if (c == '}') depth--;
        if (c == '(' && open == '(') depth++;
        if (c == ')' && open == '(') depth--;
      }
      j++;
    }
    if (j > text.length) j = text.length; // (a file cut off just after a backslash)
    final body = text.substring(bodyStart, depth == 0 ? j - 1 : j);
    i = j;
    if (kind == 'comment' || kind == 'preamble') continue;
    if (kind == 'string') {
      final m = RegExp(r'^\s*([A-Za-z0-9_\-]+)\s*=\s*(.*)$', dotAll: true).firstMatch(body);
      if (m != null) strings[m.group(1)!.toLowerCase()] = _fieldValue(m.group(2)!, strings);
      continue;
    }
    final comma = body.indexOf(',');
    if (comma < 0) continue;
    final key = body.substring(0, comma).trim();
    final fields = _fields(body.substring(comma + 1), strings);
    out.add(_entry(key, kind, fields));
  }
  return out;
}

/// `name = value, name = value`, a value being {braced}, "quoted", a number or the name of a @string, joined by `#`.
Map<String, String> _fields(String body, Map<String, String> strings) {
  final fields = <String, String>{};
  var i = 0;
  while (i < body.length) {
    final m = RegExp(r'\s*,?\s*([A-Za-z0-9_\-:]+)\s*=\s*').matchAsPrefix(body, i);
    if (m == null) {
      i++;
      continue;
    }
    var j = m.end, depth = 0;
    var inQuote = false;
    while (j < body.length) {
      final c = body[j];
      if (c == '\\') {
        j += 2;
        continue;
      }
      if (c == '"' && depth == 0) inQuote = !inQuote;
      if (!inQuote) {
        if (c == '{') depth++;
        if (c == '}') depth--;
        if (c == ',' && depth == 0) break;
      }
      j++;
    }
    fields[m.group(1)!.toLowerCase()] = _fieldValue(body.substring(m.end, j.clamp(m.end, body.length)), strings);
    i = j + 1;
  }
  return fields;
}

String _fieldValue(String raw, Map<String, String> strings) {
  final parts = <String>[];
  var s = raw.trim();
  while (s.isNotEmpty) {
    if (s.startsWith('{')) {
      var depth = 0, k = 0;
      for (; k < s.length; k++) {
        if (s[k] == '{') depth++;
        if (s[k] == '}' && --depth == 0) break;
      }
      parts.add(s.substring(1, k.clamp(1, s.length)));
      s = s.substring((k + 1).clamp(0, s.length));
    } else if (s.startsWith('"')) {
      final end = s.indexOf('"', 1);
      parts.add(s.substring(1, end < 0 ? s.length : end));
      s = end < 0 ? '' : s.substring(end + 1);
    } else {
      final m = RegExp(r'^[^\s#]+').firstMatch(s);
      if (m == null) break;
      final word = m.group(0)!;
      parts.add(strings[word.toLowerCase()] ?? word);
      s = s.substring(word.length);
    }
    s = s.trimLeft();
    if (s.startsWith('#')) s = s.substring(1).trimLeft();
  }
  return parts.join();
}

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

CitationSource _entry(String key, String kind, Map<String, String> f) {
  String field(String name) => cleanLatex(f[name] ?? '');
  String first(List<String> names) => names.map(field).firstWhere((v) => v.isNotEmpty, orElse: () => '');

  int? year, month, day;
  final date = f['date'] ?? '';
  final dm = RegExp(r'^(\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?').firstMatch(date.trim());
  if (dm != null) {
    year = int.parse(dm.group(1)!);
    month = int.tryParse(dm.group(2) ?? '');
    day = int.tryParse(dm.group(3) ?? '');
  } else {
    year = int.tryParse(RegExp(r'\d{4}').firstMatch(f['year'] ?? '')?.group(0) ?? '');
    final mon = (f['month'] ?? '').trim().toLowerCase();
    month = int.tryParse(mon) ?? (mon.length >= 3 ? _months.indexOf(mon.substring(0, 3)) + 1 : null);
    if (month == 0) month = null;
  }

  final type = _bibType(kind, f);
  final container = switch (type) {
    SourceType.article => first(['journal', 'journaltitle']),
    SourceType.chapter || SourceType.conference => first(['booktitle']),
    SourceType.webpage => first(['website', 'organization']),
    _ => '',
  };
  final publisher = first(['publisher', 'school', 'institution', 'organization']);
  var doi = field('doi').replaceFirst(RegExp(r'^https?://(dx\.)?doi\.org/'), '');
  if (doi.isEmpty && field('url').contains('doi.org/')) doi = field('url').replaceFirst(RegExp(r'^https?://(dx\.)?doi\.org/'), '');

  return CitationSource(
    id: key,
    type: type,
    title: field('title') + (field('subtitle').isEmpty ? '' : ': ${field('subtitle')}'),
    authors: _bibPeople(f['author']),
    editors: _bibPeople(f['editor']),
    year: year,
    month: month,
    day: day,
    container: container,
    publisher: type == SourceType.webpage && container == publisher ? '' : publisher,
    place: first(['address', 'location']),
    volume: field('volume'),
    issue: first(['number', 'issue']),
    pages: first(['pages']),
    edition: field('edition'),
    doi: doi,
    url: doi.isNotEmpty && field('url').contains('doi.org/') ? '' : field('url'),
    isbn: field('isbn'),
    accessed: RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(field('urldate')) ? field('urldate') : '',
  );
}

/// RIS, the format of EndNote, Citavi and most library catalogues: `TY  - JOUR` … `ER  -`.
List<CitationSource> parseRis(String text) {
  final out = <CitationSource>[];
  var fields = <String, List<String>>{};
  void finish() {
    if (fields.isEmpty) return;
    String one(List<String> tags) {
      for (final t in tags) {
        final v = fields[t];
        if (v != null && v.isNotEmpty) return v.first.trim();
      }
      return '';
    }

    final type = switch (one(['TY'])) {
      'JOUR' || 'MGZN' || 'NEWS' => SourceType.article,
      'CHAP' => SourceType.chapter,
      'CONF' || 'CPAPER' => SourceType.conference,
      'THES' => SourceType.thesis,
      'RPRT' => SourceType.report,
      'ELEC' || 'WEB' || 'BLOG' => SourceType.webpage,
      _ => SourceType.book,
    };
    // (DA has the whole date where PY has only the year)
    final date = one(['DA', 'PY', 'Y1']);
    final dm = RegExp(r'(\d{4})(?:[/-](\d{1,2}))?(?:[/-](\d{1,2}))?').firstMatch(date);
    final sp = one(['SP']), ep = one(['EP']);
    out.add(CitationSource(
      id: one(['ID']),
      type: type,
      title: one(['TI', 'T1']),
      authors: [for (final a in [...?fields['AU'], ...?fields['A1']]) Person.parse(a)].where((p) => p.family.isNotEmpty).toList(),
      editors: [for (final a in [...?fields['ED'], ...?fields['A2']]) Person.parse(a)].where((p) => p.family.isNotEmpty).toList(),
      year: dm == null ? null : int.parse(dm.group(1)!),
      month: int.tryParse(dm?.group(2) ?? ''),
      day: int.tryParse(dm?.group(3) ?? ''),
      container: one(['JO', 'JF', 'T2', 'BT', 'JA']),
      publisher: one(['PB']),
      place: one(['CY']),
      volume: one(['VL']),
      issue: one(['IS']),
      pages: sp.isEmpty ? '' : (ep.isEmpty ? sp : '$sp–$ep'),
      edition: one(['ET']),
      doi: one(['DO']).replaceFirst(RegExp(r'^https?://(dx\.)?doi\.org/'), ''),
      url: one(['UR']),
      isbn: one(['SN']),
      accessed: _risDay(one(['Y2'])),
    ));
    fields = {};
  }

  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'^([A-Z][A-Z0-9])\s{1,2}-\s?(.*)$').firstMatch(line);
    if (m == null) continue;
    final tag = m.group(1)!;
    if (tag == 'ER') {
      finish();
    } else {
      (fields[tag] ??= []).add(m.group(2)!);
    }
  }
  finish();
  return out;
}

/// 'YYYY-MM-DD' from a RIS date (`2020/03/04/` or `2020-03-04`), empty when it is not a whole day.
String _risDay(String date) {
  final m = RegExp(r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})').firstMatch(date.trim());
  return m == null ? '' : '${m.group(1)}-${m.group(2)!.padLeft(2, '0')}-${m.group(3)!.padLeft(2, '0')}';
}
