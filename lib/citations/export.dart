import 'dart:convert';

import 'source.dart';

/// The formats a library can be written in, to be read by another reference manager (or by [importReferences] again).
enum ExportFormat {
  bibtex('BibTeX', 'bib', 'application/x-bibtex'),
  ris('RIS', 'ris', 'application/x-research-info-systems'),
  cslJson('CSL-JSON', 'json', 'application/json');

  final String label;
  final String extension;
  final String mime;
  const ExportFormat(this.label, this.extension, this.mime);

  String write(Iterable<CitationSource> sources) => switch (this) {
        bibtex => exportBibtex(sources),
        ris => exportRis(sources),
        cslJson => exportCslJson(sources),
      };
}

/// CSL-JSON, the array Zotero and Mendeley read.
String exportCslJson(Iterable<CitationSource> sources) => '${const JsonEncoder.withIndent('  ').convert([for (final s in sources) s.toJson()])}\n';

// ---------------------------------------------------------------------------------------------------------------- BibTeX

const _bibMonths = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// Text for a BibTeX field: the characters LaTeX takes for commands are escaped, braces (which could unbalance the entry) dropped.
String _bibText(String s) => s
    .replaceAll(RegExp(r'[{}]'), '')
    .replaceAllMapped(RegExp(r'[&%$#_]'), (m) => '\\${m.group(0)}')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Pages as BibTeX writes a range: `12--34`.
String _bibPages(String pages) => pages.replaceAll(RegExp(r'\s*[–—]\s*'), '--');

/// "Smith, John"; a name that is one whole (an organisation, or a family name with spaces and no given name) in braces.
String _bibPeople(List<Person> people) => people
    .map((p) => p.literal || (p.given.isEmpty && p.family.contains(' '))
        ? '{${_bibText(p.family)}}'
        : p.given.isEmpty
            ? _bibText(p.family)
            : '${_bibText(p.family)}, ${_bibText(p.given)}')
    .join(' and ');

/// A key BibTeX accepts: no spaces, commas, braces or quotes.
String _bibKey(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_:.\-/]'), '_');

/// BibTeX / BibLaTeX, one entry for each source. The day of a date is not kept (BibTeX has no field for it); the other formats keep it.
String exportBibtex(Iterable<CitationSource> sources) {
  final out = StringBuffer();
  for (final s in sources) {
    final type = switch (s.type) {
      SourceType.article => 'article',
      SourceType.chapter => 'incollection',
      SourceType.conference => 'inproceedings',
      SourceType.thesis => 'phdthesis',
      SourceType.report => 'techreport',
      SourceType.webpage => 'online',
      SourceType.book => 'book',
    };
    final container = switch (s.type) {
      SourceType.article => 'journal',
      SourceType.chapter || SourceType.conference => 'booktitle',
      SourceType.webpage => 'website',
      _ => null,
    };
    final publisher = switch (s.type) {
      SourceType.thesis => 'school',
      SourceType.report => 'institution',
      _ => 'publisher',
    };
    final fields = <(String, String)>[
      if (s.authors.isNotEmpty) ('author', '{${_bibPeople(s.authors)}}'),
      if (s.editors.isNotEmpty) ('editor', '{${_bibPeople(s.editors)}}'),
      ('title', '{${_bibText(s.title)}}'),
      if (container != null && s.container.isNotEmpty) (container, '{${_bibText(s.container)}}'),
      if (s.publisher.isNotEmpty) (publisher, '{${_bibText(s.publisher)}}'),
      if (s.place.isNotEmpty) ('address', '{${_bibText(s.place)}}'),
      if (s.year != null) ('year', '{${s.year}}'),
      if (s.month != null) ('month', _bibMonths[s.month! - 1]),
      if (s.volume.isNotEmpty) ('volume', '{${_bibText(s.volume)}}'),
      if (s.issue.isNotEmpty) ('number', '{${_bibText(s.issue)}}'),
      if (s.pages.isNotEmpty) ('pages', '{${_bibText(_bibPages(s.pages))}}'),
      if (s.edition.isNotEmpty) ('edition', '{${_bibText(s.edition)}}'),
      if (s.doi.isNotEmpty) ('doi', '{${s.doi.replaceAll(RegExp(r'[{}]'), '')}}'),
      if (s.url.isNotEmpty) ('url', '{${s.url.replaceAll(RegExp(r'[{}]'), '')}}'),
      if (s.isbn.isNotEmpty) ('isbn', '{${_bibText(s.isbn)}}'),
      if (s.accessed.isNotEmpty) ('urldate', '{${s.accessed}}'),
    ];
    out.writeln('@$type{${_bibKey(s.id)},');
    for (final (i, (name, value)) in fields.indexed) {
      out.writeln('  $name = $value${i == fields.length - 1 ? '' : ','}');
    }
    out.writeln('}\n');
  }
  return out.toString();
}

// -------------------------------------------------------------------------------------------------------------------- RIS

/// RIS, the format of EndNote and Citavi. A person without a given name is written `Family,` (the way EndNote writes an organisation).
String exportRis(Iterable<CitationSource> sources) {
  final out = StringBuffer();
  void line(String tag, String value) {
    if (value.trim().isNotEmpty) out.writeln('$tag  - ${value.replaceAll(RegExp(r'\s+'), ' ').trim()}');
  }

  String person(Person p) => p.literal || p.given.isEmpty ? '${p.family},' : '${p.family}, ${p.given}';

  for (final s in sources) {
    final (type, containerTag) = switch (s.type) {
      SourceType.article => ('JOUR', 'JO'),
      SourceType.chapter => ('CHAP', 'T2'),
      SourceType.conference => ('CONF', 'T2'),
      SourceType.thesis => ('THES', ''),
      SourceType.report => ('RPRT', ''),
      SourceType.webpage => ('ELEC', 'T2'),
      SourceType.book => ('BOOK', ''),
    };
    line('TY', type);
    line('ID', s.id);
    line('TI', s.title);
    for (final a in s.authors) {
      line('AU', person(a));
    }
    for (final e in s.editors) {
      line('ED', person(e));
    }
    if (s.year != null) {
      line('PY', '${s.year}');
      if (s.month != null) {
        line('DA', '${s.year}/${'${s.month}'.padLeft(2, '0')}/${s.day == null ? '' : '${s.day}'.padLeft(2, '0')}');
      }
    }
    if (containerTag.isNotEmpty) line(containerTag, s.container);
    line('PB', s.publisher);
    line('CY', s.place);
    line('VL', s.volume);
    line('IS', s.issue);
    // "12–34" is a start and an end page; anything else ("e1234") is one value
    final range = RegExp(r'^(\S+?)\s*[–—-]+\s*(\S+)$').firstMatch(s.pages.trim());
    if (range != null) {
      line('SP', range.group(1)!);
      line('EP', range.group(2)!);
    } else {
      line('SP', s.pages);
    }
    line('ET', s.edition);
    line('DO', s.doi);
    line('UR', s.url);
    line('SN', s.isbn);
    line('Y2', s.accessed.replaceAll('-', '/'));
    out.writeln('ER  - \n');
  }
  return out.toString();
}
