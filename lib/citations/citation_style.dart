import 'source.dart';

/// Where in a source a citation points: page 42, chapter 2.
class Locator {
  final String label;
  final String value;

  const Locator(this.label, this.value);

  static const _labels = {
    'p': 'page', 'pp': 'page', 'page': 'page', 'pages': 'page', 'S': 'page', 'S.': 'page', 'seite': 'page',
    'ch': 'chapter', 'chap': 'chapter', 'chapter': 'chapter', 'kap': 'chapter',
    'sec': 'section', 'sect': 'section', 'section': 'section', '§': 'section',
    'fig': 'figure', 'figure': 'figure',
    'para': 'paragraph', '¶': 'paragraph', 'paragraph': 'paragraph',
    'vol': 'volume', 'volume': 'volume',
  };

  /// "p. 42", "pp. 3-5", "ch. 2", "42" (a bare number is a page). Null for empty text.
  static Locator? parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'^([A-Za-z§¶]+)\.?\s*(.+)$').firstMatch(t);
    if (m != null) {
      final label = _labels[m.group(1)!] ?? _labels[m.group(1)!.toLowerCase()];
      if (label != null) return Locator(label, _dash(m.group(2)!.trim()));
    }
    return Locator('page', _dash(t));
  }

  /// What follows a key in a citation, `, p. 42, emphasis added`, as the place in the source and what is said about the citation
  /// (its suffix). A place starts with a label (`p.`, `ch.`) or a number; anything else is all suffix: `[@a, passim]`.
  static (Locator?, String) parseWithSuffix(String text) {
    final t = text.trim();
    if (t.isEmpty) return (null, '');
    var label = 'page';
    var rest = t;
    final m = RegExp(r'^([A-Za-z§¶]+)\.?\s*(.+)$').firstMatch(t);
    final named = m == null ? null : (_labels[m.group(1)!] ?? _labels[m.group(1)!.toLowerCase()]);
    if (named != null) {
      label = named;
      rest = m!.group(2)!.trim();
    } else if (!RegExp(r'^(\d|[A-Za-z]\d|[ivxlcdm]+$)').hasMatch(t)) {
      return (null, t);
    }
    final p = RegExp(r'^(\w+(?:\s*[-‐‑–—]+\s*\w+)?(?:\s*,\s*\d\w*(?:\s*[-‐‑–—]+\s*\w+)?)*)(?:\s*,\s*|\s+)(.+)$').firstMatch(rest);
    final value = p == null ? rest : p.group(1)!;
    return (Locator(label, _dash(value.trim())), p?.group(2)!.trim() ?? '');
  }

  bool get isPage => label == 'page';

  /// "42" or "42–45".
  String get shown => value;

  /// The label in front of the value: "p. 42", "pp. 42–45", "ch. 2". Page numbers alone ([bare]) for the styles that omit "p.".
  String text({bool bare = false}) {
    if (isPage && bare) return value;
    final plural = RegExp(r'[–,]').hasMatch(value);
    final word = switch (label) {
      'page' => plural ? 'pp.' : 'p.',
      'chapter' => 'ch.',
      'section' => plural ? 'secs.' : 'sec.',
      'figure' => 'fig.',
      'paragraph' => plural ? 'paras.' : 'para.',
      'volume' => 'vol.',
      _ => label,
    };
    return '$word $value';
  }
}

String _dash(String s) => s.replaceAllMapped(RegExp(r'(\w)\s*[-‐‑–—]+\s*(\w)'), (m) => '${m.group(1)}–${m.group(2)}');

/// One citation of a source with its place in it. A [prefix] ("see") comes before the citation and a [suffix] ("emphasis added")
/// after it; [suppressAuthor] leaves the author out because the text names them already (`Smith [-@smith2020]` → "Smith (2020)").
class Cite {
  final CitationSource source;
  final Locator? locator;
  final String prefix;
  final String suffix;
  final bool suppressAuthor;

  const Cite(this.source, [this.locator, this.prefix = '', this.suffix = '', this.suppressAuthor = false]);

  Cite withoutAuthor() => Cite(source, locator, '', '', true);
}

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _monthShort = ['Jan.', 'Feb.', 'Mar.', 'Apr.', 'May', 'June', 'July', 'Aug.', 'Sept.', 'Oct.', 'Nov.', 'Dec.'];

/// A way of writing citations in the text and the list of sources at the end. Entries are written in the inline Markdown of the
/// app: `*italic*` is a title in italics. Styles are built into the app; each is a small class below.
abstract class CitationStyle {
  const CitationStyle();

  String get id;
  String get name;

  /// Numbered styles cite by the number of the source ([1]), in the order of first use; the others cite by author and year.
  bool get numeric => false;

  /// The citation in the text for [cites] (one bracket of `[@a; @b]`). [numbers] gives a source its number in numbered styles.
  String inText(List<Cite> cites, Map<String, int> numbers);

  /// The entry of the list of sources for [s]; [number] for the numbered styles.
  String entry(CitationSource s, {int? number});

  /// From how many names the text writes "Smith et al.", and whether a list of three names has the comma before "and".
  int get etAlFrom => 3;
  bool get oxford => true;

  /// [core], what the style makes of one citation, with what the writer said before ([Cite.prefix]) and after it ([Cite.suffix]).
  String decorate(Cite c, String core) {
    final head = _join([c.prefix, core]);
    return c.suffix.isEmpty ? head : _join([head, c.suffix], ', ');
  }

  /// A citation that is part of the sentence, `@smith2020 [p. 4]`: "Smith (2020, p. 4)", with the numbers of the numbered styles
  /// after the name: "Smith [1, p. 4]".
  String narrative(Cite c, Map<String, int> numbers) {
    final name = authorsInText(c.source, and: 'and', etAlFrom: etAlFrom, oxford: oxford) ?? shortTitle(c.source.title);
    final rest = inText([c.withoutAuthor()], numbers);
    return rest.replaceAll(RegExp(r'[()\s]'), '').isEmpty ? name : '$name $rest';
  }

  /// The order of the list of sources: by the names of the authors one after the other (a work of one author before a work of the
  /// same author and others), then year, then title. Capitals, accents and a leading "The" do not count. Numbered styles list in
  /// order of first use instead (see [CitationDocument]).
  int compare(CitationSource a, CitationSource b) {
    final ka = _sortKeys(a), kb = _sortKeys(b);
    for (var i = 0; i < ka.length && i < kb.length; i++) {
      final c = ka[i].compareTo(kb[i]);
      if (c != 0) return c;
    }
    if (ka.length != kb.length) return ka.length.compareTo(kb.length);
    final y = (a.year ?? 9999).compareTo(b.year ?? 9999);
    return y != 0 ? y : _titleKey(a.title).compareTo(_titleKey(b.title));
  }

  /// Family name and given names of each author (else editor) in turn; a source without any is sorted by its title.
  static List<String> _sortKeys(CitationSource s) {
    final people = s.authors.isNotEmpty ? s.authors : s.editors;
    if (people.isEmpty) return [_titleKey(s.title)];
    return [for (final p in people) ...[p.literal ? _titleKey(p.family) : fold(p.family), fold(p.given)]];
  }

  static String _titleKey(String t) => fold(plain(t).trim()).replaceFirst(RegExp(r'^(the|a|an|der|die|das|ein|eine|le|la|les|el|il)\s+'), '');

  static final _accents = {
    for (final e in const {'a': 'àáâãäåā', 'c': 'çćč', 'e': 'èéêëēě', 'i': 'ìíîïī', 'n': 'ñń', 'o': 'òóôõöøō', 's': 'śš', 'u': 'ùúûüū', 'y': 'ýÿ', 'z': 'źżž'}.entries)
      for (final ch in e.value.split('')) ch: e.key,
    'ß': 'ss',
    'æ': 'ae',
    'œ': 'oe',
  };

  /// [s] in lower case without accents, to put names in order: "Müller" sorts as "muller".
  static String fold(String s) => s.toLowerCase().split('').map((ch) => _accents[ch] ?? ch).join();

  // ---- helpers the styles share ----

  /// [s] with a full stop at its end unless it ends with one (or ? or !). Empty stays empty.
  static String dot(String s) {
    final t = s.trimRight();
    if (t.isEmpty) return t;
    return RegExp(r'[.?!]["”’]?$').hasMatch(t) ? t : '$t.';
  }

  static String pages(String p) => _dash(p.trim());

  static bool multiPage(String p) => RegExp(r'[–,]').hasMatch(_dash(p));

  static String stripScheme(String url) => url.replaceFirst(RegExp(r'^https?://'), '');

  /// Marks for italics must not appear inside what is italic.
  static String plain(String s) => s.replaceAll('*', '');

  /// 'YYYY-MM-DD' as (year, month, day).
  static (int, int, int)? ymd(String s) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (m == null) return null;
    final month = int.parse(m.group(2)!);
    return month < 1 || month > 12 ? null : (int.parse(m.group(1)!), month, int.parse(m.group(3)!)); // (a month that is none is no date)
  }

  /// The title as a short form for a citation of a source without an author: the first words.
  static String shortTitle(String t) {
    final words = plain(t).split(RegExp(r'\s+'));
    final cut = words.length > 4 ? '${words.take(4).join(' ')}…' : words.join(' ');
    return cut.replaceFirst(RegExp(r'[.,:;]+$'), '');
  }

  /// Family names for the text: "Smith", "Smith and Jones", "Smith et al.". A source without authors is known by its editors,
  /// else by its short title (null here: the style decides how to write it).
  static String? authorsInText(CitationSource s, {required String and, required int etAlFrom, bool oxford = true}) {
    final people = s.authors.isNotEmpty ? s.authors : s.editors;
    if (people.isEmpty) return null;
    if (people.length >= etAlFrom) return '${people.first.family} et al.';
    if (people.length == 1) return people.first.family;
    final names = [for (final p in people) p.family];
    return '${names.sublist(0, names.length - 1).join(', ')}${names.length > 2 && oxford ? ',' : ''} $and ${names.last}';
  }
}

/// All the styles built in, in the order they are listed.
const List<CitationStyle> citationStyles = [ApaStyle(), MlaStyle(), ChicagoStyle(), HarvardStyle(), IeeeStyle(), Iso690Style()];

CitationStyle citationStyleById(String? id) => citationStyles.firstWhere((s) => s.id == id, orElse: () => citationStyles.first);

String _join(Iterable<String> parts, [String sep = ' ']) => parts.where((p) => p.trim().isNotEmpty).join(sep);

String _year(CitationSource s) => '${s.year ?? 'n.d.'}${s.yearSuffix}';

String _it(String s) => s.isEmpty ? '' : '*${CitationStyle.plain(s)}*';

// ---------------------------------------------------------------------------------------------------------------- APA 7

class ApaStyle extends CitationStyle {
  const ApaStyle();

  @override
  String get id => 'apa';
  @override
  String get name => 'APA 7th edition';
  @override
  int get etAlFrom => 3;

  String _people(List<Person> people) {
    final names = [for (final p in people) p.literal || p.given.isEmpty ? p.family : '${p.family}, ${p.initials}'];
    if (names.length == 1) return names.single;
    if (names.length <= 20) return '${names.sublist(0, names.length - 1).join(', ')}, & ${names.last}';
    return '${names.take(19).join(', ')}, . . . ${names.last}';
  }

  String _natural(List<Person> people) {
    final names = [for (final p in people) p.literal || p.given.isEmpty ? p.family : '${p.initials} ${p.family}'];
    return names.length == 1 ? names.single : '${names.sublist(0, names.length - 1).join(', ')} & ${names.last}';
  }

  String _date(CitationSource s) {
    if (s.year == null) return '(n.d.${s.yearSuffix})';
    if (s.type == SourceType.webpage && s.month != null) {
      return '(${s.year}${s.yearSuffix}, ${_monthNames[s.month! - 1]}${s.day == null ? '' : ' ${s.day}'})';
    }
    return '(${s.year}${s.yearSuffix})';
  }

  @override
  String inText(List<Cite> cites, Map<String, int> numbers) {
    final sorted = [...cites]..sort((a, b) => compare(a.source, b.source));
    final parts = [
      for (final c in sorted)
        decorate(
          c,
          _join([
            c.suppressAuthor ? '' : CitationStyle.authorsInText(c.source, and: '&', etAlFrom: etAlFrom, oxford: oxford) ?? '"${CitationStyle.shortTitle(c.source.title)}"',
            _year(c.source),
            c.locator?.text() ?? '',
          ], ', '),
        ),
    ];
    return '(${parts.join('; ')})';
  }

  @override
  String entry(CitationSource s, {int? number}) {
    final authors = s.authors.isNotEmpty ? s.authors : s.editors;
    final who = authors.isEmpty ? '' : '${_people(authors)}${s.authors.isEmpty ? (authors.length > 1 ? ' (Eds.)' : ' (Ed.)') : ''}';
    final lead = authors.isEmpty ? '' : CitationStyle.dot(who);
    final date = CitationStyle.dot(_date(s));
    final link = s.link;
    final title = CitationStyle.plain(s.title);
    final vol = s.volume.isEmpty ? '' : '*${s.volume}*';
    final pages = CitationStyle.pages(s.pages);

    // a source without an author starts with its title, and the date follows
    String assemble(String titlePart, List<String> rest) =>
        authors.isEmpty ? _join([titlePart, date, ...rest]) : _join([lead, date, titlePart, ...rest]);

    switch (s.type) {
      case SourceType.article:
        final inJournal = _join([
          _it(s.container),
          _join(['$vol${s.issue.isEmpty ? '' : '(${s.issue})'}', pages], ', ').replaceFirst(RegExp(r'^,\s*'), ''),
        ], ', ');
        return assemble(CitationStyle.dot(title), [CitationStyle.dot(inJournal), link]);
      case SourceType.chapter:
      case SourceType.conference:
        final eds = s.editors.isEmpty || authors == s.editors ? '' : '${_natural(s.editors)} (${s.editors.length > 1 ? 'Eds.' : 'Ed.'}), ';
        final book = '${_it(s.container)}${pages.isEmpty ? '' : ' (${CitationStyle.multiPage(pages) ? 'pp.' : 'p.'} $pages)'}';
        return assemble(CitationStyle.dot(title), [CitationStyle.dot('In $eds$book'), CitationStyle.dot(s.publisher), link]);
      case SourceType.thesis:
        return assemble('${_it(title)} [${_join(['Thesis', s.publisher], ', ')}].', [link]);
      case SourceType.webpage:
        return assemble(CitationStyle.dot(_it(title)), [CitationStyle.dot(s.container), link]);
      case SourceType.book:
      case SourceType.report:
        final ed = s.edition.isEmpty ? '' : ' (${s.edition} ed.)';
        return assemble(CitationStyle.dot('${_it(title)}$ed'), [CitationStyle.dot(s.publisher), link]);
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------- MLA 9

class MlaStyle extends CitationStyle {
  const MlaStyle();

  @override
  String get id => 'mla';
  @override
  String get name => 'MLA 9th edition';

  String _people(List<Person> people) {
    if (people.length >= 3) return '${people.first.inverted}, et al.';
    if (people.length == 2) return '${people[0].inverted}, and ${people[1].natural}';
    return people.first.inverted;
  }

  String _quoted(String t) => CitationStyle.dot('"${CitationStyle.plain(t)}')
      .replaceFirstMapped(RegExp(r'([.?!])$'), (m) => '${m.group(1)}"')
      .replaceFirstMapped(RegExp(r'^("[^"]*[^.?!"])$'), (m) => '${m.group(1)}."');

  String _date(CitationSource s) =>
      s.year == null ? '' : _join([s.day?.toString() ?? '', s.month == null ? '' : _monthShort[s.month! - 1], '${s.year}']);

  @override
  String inText(List<Cite> cites, Map<String, int> numbers) {
    final parts = [
      for (final c in cites)
        decorate(
          c,
          _join([
            c.suppressAuthor
                ? ''
                : CitationStyle.authorsInText(c.source, and: 'and', etAlFrom: etAlFrom, oxford: oxford) ??
                    (c.source.type == SourceType.book || c.source.container.isEmpty ? CitationStyle.shortTitle(c.source.title) : '"${CitationStyle.shortTitle(c.source.title)}"'),
            c.locator?.text(bare: true) ?? '',
          ]),
        ),
    ];
    return '(${parts.join('; ')})';
  }

  @override
  String entry(CitationSource s, {int? number}) {
    final authors = s.authors.isNotEmpty ? s.authors : s.editors;
    final lead = authors.isEmpty ? '' : CitationStyle.dot('${_people(authors)}${s.authors.isEmpty ? ', editor${authors.length > 1 ? 's' : ''}' : ''}');
    final link = CitationStyle.stripScheme(s.link);
    final pages = CitationStyle.pages(s.pages);
    final pp = pages.isEmpty ? '' : '${CitationStyle.multiPage(pages) ? 'pp.' : 'p.'} $pages';
    final title = CitationStyle.plain(s.title);
    final accessed = CitationStyle.ymd(s.accessed);

    switch (s.type) {
      case SourceType.article:
        final inJournal = _join([
          _it(s.container),
          s.volume.isEmpty ? '' : 'vol. ${s.volume}',
          s.issue.isEmpty ? '' : 'no. ${s.issue}',
          s.year == null ? '' : _date(s),
          pp,
          link,
        ], ', ');
        return _join([lead, _quoted(title), CitationStyle.dot(inJournal)]);
      case SourceType.chapter:
      case SourceType.conference:
        final eds = s.editors.isEmpty || authors == s.editors ? '' : 'edited by ${s.editors.map((p) => p.natural).join(s.editors.length == 2 ? ' and ' : ', ')}';
        final inBook = _join([_it(s.container), eds, s.publisher, s.year?.toString() ?? '', pp, link], ', ');
        return _join([lead, _quoted(title), CitationStyle.dot(inBook)]);
      case SourceType.webpage:
        final site = _join([_it(s.container), s.publisher, _date(s), link], ', ');
        final acc = accessed == null ? '' : 'Accessed ${accessed.$3} ${_monthShort[accessed.$2 - 1]} ${accessed.$1}.';
        return _join([lead, _quoted(title), CitationStyle.dot(site), acc]);
      case SourceType.thesis:
        return _join([lead, CitationStyle.dot(_it(title)), s.year == null ? '' : '${s.year}.', CitationStyle.dot(_join([s.publisher, 'Thesis'], ', '))]);
      case SourceType.book:
      case SourceType.report:
        final pub = _join([s.edition.isEmpty ? '' : '${s.edition} ed.', s.publisher, s.year?.toString() ?? '', link], ', ');
        return _join([lead, CitationStyle.dot(_it(title)), CitationStyle.dot(pub)]);
    }
  }
}

// ----------------------------------------------------------------------------------------------- Chicago (author-date)

class ChicagoStyle extends CitationStyle {
  const ChicagoStyle();

  @override
  String get id => 'chicago';
  @override
  String get name => 'Chicago (author-date)';
  @override
  int get etAlFrom => 4;

  String _people(List<Person> people) {
    final names = [people.first.inverted, for (final p in people.skip(1)) p.natural];
    if (people.length > 10) return '${names.take(7).join(', ')}, et al.';
    if (names.length == 1) return names.single;
    if (names.length == 2) return '${names[0]}, and ${names[1]}';
    return '${names.sublist(0, names.length - 1).join(', ')}, and ${names.last}';
  }

  String _quoted(String t) {
    final p = CitationStyle.plain(t);
    return RegExp(r'[.?!]$').hasMatch(p) ? '"$p"' : '"$p."';
  }

  @override
  String inText(List<Cite> cites, Map<String, int> numbers) {
    final parts = [
      for (final c in cites)
        decorate(
          c,
          _join([
                c.suppressAuthor ? '' : CitationStyle.authorsInText(c.source, and: 'and', etAlFrom: etAlFrom, oxford: oxford) ?? CitationStyle.shortTitle(c.source.title),
                _year(c.source),
              ]) +
              (c.locator == null ? '' : ', ${c.locator!.text(bare: true)}'),
        ),
    ];
    return '(${parts.join('; ')})';
  }

  @override
  String entry(CitationSource s, {int? number}) {
    final authors = s.authors.isNotEmpty ? s.authors : s.editors;
    final lead = authors.isEmpty ? '' : CitationStyle.dot('${_people(authors)}${s.authors.isEmpty ? ', ed${authors.length > 1 ? 's' : ''}.' : ''}');
    final year = CitationStyle.dot(_year(s));
    final link = s.link.isEmpty ? '' : CitationStyle.dot(s.link);
    final pages = CitationStyle.pages(s.pages);
    final title = CitationStyle.plain(s.title);
    final pub = _join([s.place.isEmpty ? '' : '${s.place}:', s.publisher]);

    switch (s.type) {
      case SourceType.article:
        final vol = _join(['${s.volume}${s.issue.isEmpty ? '' : ' (${s.issue})'}', pages], ': ');
        return _join([lead, year, _quoted(title), CitationStyle.dot(_join([_it(s.container), vol])), link]);
      case SourceType.chapter:
      case SourceType.conference:
        final eds = s.editors.isEmpty || authors == s.editors ? '' : ', edited by ${s.editors.map((p) => p.natural).join(s.editors.length == 2 ? ' and ' : ', ')}';
        return _join([lead, year, _quoted(title), CitationStyle.dot('In ${_it(s.container)}$eds${pages.isEmpty ? '' : ', $pages'}'), CitationStyle.dot(pub), link]);
      case SourceType.webpage:
        final date = s.year == null ? '' : CitationStyle.dot(_join([s.month == null ? '' : _monthNames[s.month! - 1], s.day == null ? '' : '${s.day},', '${s.year}']).replaceFirst(RegExp(r',$'), ''));
        return _join([lead, year, _quoted(title), CitationStyle.dot(s.container), date, link]);
      case SourceType.thesis:
        return _join([lead, year, _quoted(title), CitationStyle.dot(_join(['Thesis', s.publisher], ', ')), link]);
      case SourceType.book:
      case SourceType.report:
        final ed = s.edition.isEmpty ? '' : ' ${s.edition} ed.';
        return _join([lead, year, CitationStyle.dot(_it(title)) + ed, CitationStyle.dot(pub), link]);
    }
  }
}

// ----------------------------------------------------------------------------------------------- Harvard (Cite Them Right)

class HarvardStyle extends CitationStyle {
  const HarvardStyle();

  @override
  String get id => 'harvard';
  @override
  String get name => 'Harvard';
  @override
  int get etAlFrom => 4;
  @override
  bool get oxford => false;

  String _people(List<Person> people) {
    final names = [for (final p in people) p.literal || p.given.isEmpty ? p.family : '${p.family}, ${p.initials}'];
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  @override
  String inText(List<Cite> cites, Map<String, int> numbers) {
    final sorted = [...cites]..sort((a, b) => compare(a.source, b.source));
    final parts = [
      for (final c in sorted)
        decorate(
          c,
          _join([
            c.suppressAuthor ? '' : CitationStyle.authorsInText(c.source, and: 'and', etAlFrom: etAlFrom, oxford: oxford) ?? CitationStyle.shortTitle(c.source.title),
            _year(c.source),
            c.locator?.text() ?? '',
          ], ', '),
        ),
    ];
    return '(${parts.join('; ')})';
  }

  @override
  String entry(CitationSource s, {int? number}) {
    final authors = s.authors.isNotEmpty ? s.authors : s.editors;
    final who = authors.isEmpty ? '' : '${_people(authors)}${s.authors.isEmpty ? ' (ed${authors.length > 1 ? 's' : ''}.)' : ''}';
    final lead = _join([who, '(${_year(s)})']);
    final pages = CitationStyle.pages(s.pages);
    final pp = pages.isEmpty ? '' : '${CitationStyle.multiPage(pages) ? 'pp.' : 'p.'} $pages';
    final title = CitationStyle.plain(s.title);
    final pub = _join([s.place.isEmpty ? '' : '${s.place}:', s.publisher]);
    final link = s.doi.isNotEmpty ? 'doi:${s.doi}' : (s.url.isEmpty ? '' : 'Available at: ${s.url}');
    final accessed = CitationStyle.ymd(s.accessed);
    final acc = accessed == null ? '' : '(Accessed: ${accessed.$3} ${_monthNames[accessed.$2 - 1]} ${accessed.$1})';

    switch (s.type) {
      case SourceType.article:
        final vol = '${s.volume}${s.issue.isEmpty ? '' : '(${s.issue})'}';
        return _join([lead, "'${title.replaceFirst(RegExp(r'[.,]$'), '')}',", CitationStyle.dot(_join([_it(s.container), vol, pp], ', ')), CitationStyle.dot(link)]);
      case SourceType.chapter:
      case SourceType.conference:
        final eds = s.editors.isEmpty || authors == s.editors ? '' : '${_people(s.editors)} (ed${s.editors.length > 1 ? 's' : ''}.) ';
        return _join([lead, "'${title.replaceFirst(RegExp(r'[.,]$'), '')}', in $eds${_it(s.container)}.", CitationStyle.dot(_join([pub, pp], ', ')), CitationStyle.dot(link)]);
      case SourceType.webpage:
        return _join([lead, CitationStyle.dot(_it(title)), CitationStyle.dot(s.container), link, acc]);
      case SourceType.thesis:
        return _join([lead, CitationStyle.dot(_it(title)), CitationStyle.dot(_join(['Thesis', s.publisher], '. ')), CitationStyle.dot(link)]);
      case SourceType.book:
      case SourceType.report:
        return _join([lead, CitationStyle.dot(_it(title)), s.edition.isEmpty ? '' : '${s.edition} edn.', CitationStyle.dot(pub), CitationStyle.dot(link)]);
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------- IEEE

class IeeeStyle extends CitationStyle {
  const IeeeStyle();

  @override
  String get id => 'ieee';
  @override
  String get name => 'IEEE';
  @override
  bool get numeric => true;

  String _people(List<Person> people) {
    final names = [for (final p in people) p.literal || p.given.isEmpty ? p.family : '${p.initials} ${p.family}'];
    if (names.length > 6) return '${names.first} et al.';
    if (names.length == 1) return names.single;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    return '${names.sublist(0, names.length - 1).join(', ')}, and ${names.last}';
  }

  /// `[1], [3]`; three or more numbers in a row, with nothing said about them, are one range: `[1]–[3]`. In the order of the numbers.
  @override
  String inText(List<Cite> cites, Map<String, int> numbers) {
    int? nr(Cite c) => numbers[c.source.id];
    bool plain(Cite c) => c.locator == null && c.prefix.isEmpty && c.suffix.isEmpty;
    final sorted = [for (final (i, c) in cites.indexed) (i, c)]..sort((a, b) => (nr(a.$2) ?? 0) != (nr(b.$2) ?? 0) ? (nr(a.$2) ?? 0).compareTo(nr(b.$2) ?? 0) : a.$1.compareTo(b.$1));
    final list = [for (final (_, c) in sorted) c];
    final out = <String>[];
    var i = 0;
    while (i < list.length) {
      var j = i;
      while (j + 1 < list.length && plain(list[j]) && plain(list[j + 1]) && nr(list[j]) != null && nr(list[j + 1]) == nr(list[j])! + 1) {
        j++;
      }
      if (j - i >= 2) {
        out.add('[${nr(list[i])}]–[${nr(list[j])}]');
        i = j + 1;
      } else {
        final c = list[i++];
        out.add('[${decorate(c, '${nr(c) ?? '?'}${c.locator == null ? '' : ', ${c.locator!.text()}'}')}]');
      }
    }
    return out.join(', ');
  }

  @override
  String entry(CitationSource s, {int? number}) {
    final authors = s.authors.isNotEmpty ? s.authors : s.editors;
    final who = authors.isEmpty ? '' : '${_people(authors)}${s.authors.isEmpty ? ', Ed${authors.length > 1 ? 's' : ''}.' : ''}';
    final pages = CitationStyle.pages(s.pages);
    final pp = pages.isEmpty ? '' : '${CitationStyle.multiPage(pages) ? 'pp.' : 'p.'} $pages';
    final title = CitationStyle.plain(s.title);
    final date = s.year == null ? '' : _join([s.month == null ? '' : _monthShort[s.month! - 1], '${s.year}']);
    final doi = s.doi.isEmpty ? '' : 'doi: ${s.doi}';
    final num = number == null ? '' : '[$number] ';
    final quoted = '"${title.replaceFirst(RegExp(r'[.,]$'), '')},"';
    final accessed = CitationStyle.ymd(s.accessed);
    final acc = accessed == null ? '' : '(accessed ${_monthShort[accessed.$2 - 1]} ${accessed.$3}, ${accessed.$1})';
    final pub = _join([s.publisher.isEmpty ? '' : s.place.isEmpty ? s.publisher : '${s.place}: ${s.publisher}']);

    String body;
    switch (s.type) {
      case SourceType.article:
        body = _join([
          who.isEmpty ? '' : '$who,',
          quoted,
          '${_join([_it(s.container), s.volume.isEmpty ? '' : 'vol. ${s.volume}', s.issue.isEmpty ? '' : 'no. ${s.issue}', pp, date, doi], ', ')}.',
        ]);
      case SourceType.chapter:
      case SourceType.conference:
        final eds = s.editors.isEmpty || authors == s.editors ? '' : '${_people(s.editors)}, Ed${s.editors.length > 1 ? 's' : ''}.';
        body = _join([
          who.isEmpty ? '' : '$who,',
          quoted,
          'in ${_join([_it(s.container), eds, pub, s.year?.toString() ?? '', pp, doi], ', ')}.',
        ]);
      case SourceType.webpage:
        body = _join([who.isEmpty ? '' : '$who,', quoted, CitationStyle.dot(s.container), s.url, acc]);
        body = body.endsWith('.') ? body : '$body.';
      case SourceType.thesis:
        body = _join([who.isEmpty ? '' : '$who,', quoted, '${_join(['Thesis', s.publisher, s.place, s.year?.toString() ?? ''], ', ')}.']);
      case SourceType.book:
      case SourceType.report:
        body = _join([
          who.isEmpty ? '' : '$who,',
          '${_join([_it(title), s.edition.isEmpty ? '' : '${s.edition} ed.', pub, s.year?.toString() ?? '', doi], ', ')}.',
        ]);
    }
    return '$num$body';
  }
}

// ------------------------------------------------------------------------------------------------- ISO 690 (author-date)

/// ISO 690, the international standard that DIN 1505 (used at German-speaking universities) follows: family names in capitals,
/// the year after the names, `Available from:` for addresses.
class Iso690Style extends CitationStyle {
  const Iso690Style();

  @override
  String get id => 'iso690';
  @override
  String get name => 'ISO 690 (author-date)';
  @override
  int get etAlFrom => 4;
  @override
  bool get oxford => false;

  String _name(Person p) => p.literal || p.given.isEmpty ? p.family.toUpperCase() : '${p.family.toUpperCase()}, ${p.given}';

  String _people(List<Person> people) {
    final names = [for (final p in people) _name(p)];
    if (names.length > 3) return '${names.first} et al.';
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join('; ')} and ${names.last}';
  }

  @override
  String inText(List<Cite> cites, Map<String, int> numbers) {
    final parts = [
      for (final c in cites)
        decorate(
          c,
          _join([
            c.suppressAuthor ? '' : CitationStyle.authorsInText(c.source, and: 'and', etAlFrom: etAlFrom, oxford: oxford) ?? CitationStyle.shortTitle(c.source.title),
            '${_year(c.source)}${c.locator == null ? '' : ', ${c.locator!.text()}'}',
          ]),
        ),
    ];
    return '(${parts.join('; ')})';
  }

  @override
  String entry(CitationSource s, {int? number}) {
    final authors = s.authors.isNotEmpty ? s.authors : s.editors;
    final who = authors.isEmpty ? '' : '${_people(authors)}${s.authors.isEmpty ? ' (ed${authors.length > 1 ? 's' : ''}.)' : ''}';
    final lead = authors.isEmpty ? '' : '$who, ${_year(s)}.';
    final title = CitationStyle.plain(s.title);
    final pages = CitationStyle.pages(s.pages);
    final pub = _join([s.place.isEmpty ? '' : '${s.place}:', s.publisher]);
    final accessed = CitationStyle.ymd(s.accessed);
    final acc = accessed == null ? '' : '[viewed ${accessed.$3} ${_monthNames[accessed.$2 - 1]} ${accessed.$1}]';
    final link = s.doi.isNotEmpty ? 'DOI ${s.doi}' : (s.url.isEmpty ? '' : 'Available from: ${s.url}');

    String assemble(String titlePart, List<String> rest) =>
        authors.isEmpty ? _join([CitationStyle.dot(titlePart), '${_year(s)}.', ...rest]) : _join([lead, CitationStyle.dot(titlePart), ...rest]);

    switch (s.type) {
      case SourceType.article:
        final vol = '${s.volume}${s.issue.isEmpty ? '' : '(${s.issue})'}';
        return assemble(title, [CitationStyle.dot(_join([_it(s.container), _join([vol, pages], ', ')], '. ')), CitationStyle.dot(link)]);
      case SourceType.chapter:
      case SourceType.conference:
        final eds = s.editors.isEmpty || authors == s.editors ? '' : 'In: ${_people(s.editors)} (ed${s.editors.length > 1 ? 's' : ''}.), ';
        final inBook = eds.isEmpty ? 'In: ${_it(s.container)}' : '$eds${_it(s.container)}';
        return assemble(title, [CitationStyle.dot(_join([inBook, pub, pages.isEmpty ? '' : '${CitationStyle.multiPage(pages) ? 'pp.' : 'p.'} $pages'], ', ')), CitationStyle.dot(link)]);
      case SourceType.webpage:
        return assemble(_it(title), [CitationStyle.dot(s.container), acc, CitationStyle.dot(link)]);
      case SourceType.thesis:
        return assemble(_it(title), [CitationStyle.dot(_join(['Thesis', s.publisher], '. ')), CitationStyle.dot(link)]);
      case SourceType.book:
      case SourceType.report:
        return assemble(_it(title), [s.edition.isEmpty ? '' : '${s.edition} ed.', CitationStyle.dot(pub), CitationStyle.dot(link)]);
    }
  }
}
