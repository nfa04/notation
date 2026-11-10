/// A person named in a source: [family] always, [given] when known. A [literal] name (an organisation, "World Health Organization")
/// is written as it is and never split into parts.
class Person {
  final String family;
  final String given;
  final bool literal;

  const Person(this.family, [this.given = '']) : literal = false;
  const Person.literal(String name)
      : family = name,
        given = '',
        literal = true;

  /// "John Albert" → "J. A.", "Jean-Paul" → "J.-P."
  String get initials {
    if (given.trim().isEmpty) return '';
    return given
        .trim()
        .split(RegExp(r'\s+'))
        .map((part) => part.split('-').where((p) => p.isNotEmpty).map((p) => '${p[0].toUpperCase()}.').join('-'))
        .where((part) => part.isNotEmpty)
        .join(' ');
  }

  /// "Smith, John"
  String get inverted => given.isEmpty || literal ? family : '$family, $given';

  /// "John Smith"
  String get natural => given.isEmpty || literal ? family : '$given $family';

  Map<String, dynamic> toJson() => literal ? {'literal': family} : {'family': family, if (given.isNotEmpty) 'given': given};

  factory Person.fromJson(Map<String, dynamic> j) {
    if (j['literal'] is String) return Person.literal(j['literal'] as String);
    String text(Object? v) => v == null ? '' : '$v'.trim();
    return Person(text(j['family']), text(j['given']));
  }

  /// "Smith, John", "John Smith" or "Smith J" (a name as BibTeX and a person typing write it).
  factory Person.parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return const Person('');
    final comma = t.indexOf(',');
    if (comma >= 0) return Person(t.substring(0, comma).trim(), t.substring(comma + 1).trim());
    final words = t.split(RegExp(r'\s+'));
    if (words.length == 1) return Person(words.single);
    // a lower-case particle starts the family name: "Ludwig van Beethoven"
    var split = words.length - 1;
    while (split > 1 && words[split - 1] == words[split - 1].toLowerCase() && RegExp(r'^[a-z]').hasMatch(words[split - 1])) {
      split--;
    }
    return Person(words.sublist(split).join(' '), words.sublist(0, split).join(' '));
  }

  @override
  bool operator ==(Object other) => other is Person && other.family == family && other.given == given && other.literal == literal;

  @override
  int get hashCode => Object.hash(family, given, literal);
}

/// What kind of work a source is. The names are those of CSL (Citation Style Language), the format Zotero and Mendeley export.
enum SourceType {
  book('book', 'Book'),
  chapter('chapter', 'Book chapter'),
  article('article-journal', 'Journal article'),
  conference('paper-conference', 'Conference paper'),
  thesis('thesis', 'Thesis'),
  report('report', 'Report'),
  webpage('webpage', 'Web page');

  final String csl;
  final String title;
  const SourceType(this.csl, this.title);

  static SourceType fromCsl(String? csl) => switch (csl) {
        'book' => book,
        'chapter' => chapter,
        'article-journal' || 'article' || 'article-magazine' || 'article-newspaper' => article,
        'paper-conference' => conference,
        'thesis' => thesis,
        'report' => report,
        'webpage' || 'post-weblog' || 'post' => webpage,
        _ => book,
      };
}

/// One thing that can be cited, held the way CSL-JSON does (so the library can be exchanged with other reference managers).
/// [id] is the key the text cites it by: `[@smith2020]`.
class CitationSource {
  final String id;
  final SourceType type;
  final String title;
  final List<Person> authors;

  /// The editors of the book a chapter is in (or of the book itself).
  final List<Person> editors;

  /// Year, month (1-12) and day of publication; null when not known.
  final int? year;
  final int? month;
  final int? day;

  /// The journal, the book a chapter is in, the conference or the web site.
  final String container;
  final String publisher;
  final String place;
  final String volume;
  final String issue;

  /// "12-34" or "e1234".
  final String pages;
  final String edition;
  final String doi;
  final String url;
  final String isbn;

  /// 'YYYY-MM-DD' of the day a web page was read; empty when not known.
  final String accessed;

  /// "a", "b"… when one text cites several works of the same authors and year (Smith 2020a, Smith 2020b). Worked out for a text
  /// (see `CitationDocument`), never stored.
  final String yearSuffix;

  /// A month that is not 1 to 12 and a day that is not 1 to 31 (`2020/00/00` in a RIS file, `month = {13}`) are not known: the styles
  /// and the exports look the month up by its number.
  const CitationSource({
    required this.id,
    this.type = SourceType.book,
    required this.title,
    this.authors = const [],
    this.editors = const [],
    this.year,
    int? month,
    int? day,
    this.container = '',
    this.publisher = '',
    this.place = '',
    this.volume = '',
    this.issue = '',
    this.pages = '',
    this.edition = '',
    this.doi = '',
    this.url = '',
    this.isbn = '',
    this.accessed = '',
    this.yearSuffix = '',
  })  : month = month != null && month >= 1 && month <= 12 ? month : null,
        day = month != null && month >= 1 && month <= 12 && day != null && day >= 1 && day <= 31 ? day : null; // (a day with no month is none)

  CitationSource copyWith({
    String? id,
    SourceType? type,
    String? title,
    List<Person>? authors,
    List<Person>? editors,
    int? year,
    bool clearYear = false,
    int? month,
    int? day,
    String? container,
    String? publisher,
    String? place,
    String? volume,
    String? issue,
    String? pages,
    String? edition,
    String? doi,
    String? url,
    String? isbn,
    String? accessed,
    String? yearSuffix,
  }) =>
      CitationSource(
        id: id ?? this.id,
        type: type ?? this.type,
        title: title ?? this.title,
        authors: authors ?? this.authors,
        editors: editors ?? this.editors,
        year: clearYear ? null : (year ?? this.year),
        month: clearYear ? null : (month ?? this.month),
        day: clearYear ? null : (day ?? this.day),
        container: container ?? this.container,
        publisher: publisher ?? this.publisher,
        place: place ?? this.place,
        volume: volume ?? this.volume,
        issue: issue ?? this.issue,
        pages: pages ?? this.pages,
        edition: edition ?? this.edition,
        doi: doi ?? this.doi,
        url: url ?? this.url,
        isbn: isbn ?? this.isbn,
        accessed: accessed ?? this.accessed,
        yearSuffix: yearSuffix ?? this.yearSuffix,
      );

  /// The address of the work: its DOI as a link when it has one, else its URL, else empty.
  String get link => doi.isNotEmpty ? 'https://doi.org/$doi' : url;

  /// CSL-JSON, one item of the array Zotero exports.
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.csl,
        'title': title,
        if (authors.isNotEmpty) 'author': [for (final a in authors) a.toJson()],
        if (editors.isNotEmpty) 'editor': [for (final a in editors) a.toJson()],
        if (year != null)
          'issued': {
            'date-parts': [
              [year, ?month, if (month != null) ?day],
            ],
          },
        if (container.isNotEmpty) 'container-title': container,
        if (publisher.isNotEmpty) 'publisher': publisher,
        if (place.isNotEmpty) 'publisher-place': place,
        if (volume.isNotEmpty) 'volume': volume,
        if (issue.isNotEmpty) 'issue': issue,
        if (pages.isNotEmpty) 'page': pages,
        if (edition.isNotEmpty) 'edition': edition,
        if (doi.isNotEmpty) 'DOI': doi,
        if (url.isNotEmpty) 'URL': url,
        if (isbn.isNotEmpty) 'ISBN': isbn,
        if (accessed.isNotEmpty)
          'accessed': RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(accessed)
              ? {
                  'date-parts': [
                    [for (final p in accessed.split('-')) int.parse(p)],
                  ],
                }
              : {'raw': accessed},
      };

  /// A CSL-JSON item. Values CSL allows to be numbers, lists or nested dates are read leniently; what is missing is empty.
  factory CitationSource.fromJson(Map<String, dynamic> j, {String? id}) {
    String text(String key) {
      final v = j[key];
      if (v is List) return v.isEmpty ? '' : '${v.first}'.trim();
      return v == null ? '' : '$v'.trim();
    }

    // (one name instead of a list of them is read as the one)
    List<Person> people(String key) => [
          for (final p in switch (j[key]) { final List l => l, null => const [], final other => [other] })
            if (p is Map<String, dynamic>) Person.fromJson(p) else if (p is Map) Person.fromJson(p.cast<String, dynamic>()) else Person.parse('$p'),
        ].where((p) => p.family.isNotEmpty).toList();

    int? year, month, day;
    final issued = j['issued'];
    if (issued is Map) {
      final parts = issued['date-parts'];
      if (parts is List && parts.isNotEmpty && parts.first is List) {
        final p = (parts.first as List).map((e) => int.tryParse('$e')).toList();
        year = p.isNotEmpty ? p[0] : null;
        month = p.length > 1 ? p[1] : null;
        day = p.length > 2 ? p[2] : null;
      } else if (issued['raw'] != null || issued['literal'] != null) {
        year = int.tryParse(RegExp(r'\d{4}').firstMatch('${issued['raw'] ?? issued['literal']}')?.group(0) ?? '');
      }
    }
    var accessed = '';
    final acc = j['accessed'];
    if (acc is Map) {
      final parts = acc['date-parts'];
      if (parts is List && parts.isNotEmpty && parts.first is List && (parts.first as List).length == 3) {
        final p = (parts.first as List).map((e) => '$e'.padLeft(2, '0')).toList();
        accessed = '${p[0].padLeft(4, '0')}-${p[1]}-${p[2]}';
      } else if (acc['raw'] != null) {
        accessed = '${acc['raw']}';
      }
    }
    return CitationSource(
      id: id ?? text('id'),
      type: SourceType.fromCsl(text('type')),
      title: text('title'),
      authors: people('author'),
      editors: people('editor'),
      year: year,
      month: month,
      day: day,
      container: text('container-title'),
      publisher: text('publisher'),
      place: text('publisher-place'),
      volume: text('volume'),
      issue: text('issue'),
      pages: text('page'),
      edition: text('edition'),
      doi: text('DOI'),
      url: text('URL'),
      isbn: text('ISBN'),
      accessed: accessed,
    );
  }

  /// A key for a source that has none: the family name of the first author and the year (`smith2020`), else from the title.
  static String makeKey(CitationSource s, Set<String> taken) {
    final base = (s.authors.isNotEmpty ? s.authors.first.family : s.title.split(RegExp(r'\s+')).first)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    var key = '${base.isEmpty ? 'source' : base}${s.year ?? ''}';
    var n = 0;
    while (taken.contains(key)) {
      key = '${base.isEmpty ? 'source' : base}${s.year ?? ''}${String.fromCharCode(97 + n % 26)}${n >= 26 ? n ~/ 26 : ''}';
      n++;
    }
    return key;
  }
}
