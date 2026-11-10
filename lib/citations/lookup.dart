import 'dart:convert';

import 'package:dio/dio.dart';

import 'source.dart';

/// Finds the details of a work from its DOI (Crossref) or ISBN (Open Library), so that a source does not have to be typed in.
/// Neither needs an account. [get] fetches a web address as text, and is replaced in tests.
class CitationLookup {
  final Future<String> Function(String url) _get;

  CitationLookup({Future<String> Function(String url)? get}) : _get = get ?? _dioGet;

  static Future<String> _dioGet(String url) async {
    final r = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.plain,
      headers: {'User-Agent': 'Notation (citation lookup)'},
    )).get<String>(url);
    return r.data ?? '';
  }

  static final _doi = RegExp(r'10\.\d{4,9}/[^\s"<>]+');

  /// The DOI in [text] (a bare DOI, `doi:10…` or a doi.org address), without a trailing full stop; null if there is none.
  static String? doiIn(String text) => _doi.firstMatch(text)?.group(0)?.replaceFirst(RegExp(r'[.,;)]+$'), '');

  /// The ISBN in [text] without dashes; null if [text] is not one (the check digit is checked).
  static String? isbnIn(String text) {
    final digits = text.replaceAll(RegExp(r'[\s\-]|^ISBN(-1[03])?:?', caseSensitive: false), '').toUpperCase();
    if (RegExp(r'^\d{13}$').hasMatch(digits)) {
      var sum = 0;
      for (var i = 0; i < 13; i++) {
        sum += int.parse(digits[i]) * (i.isEven ? 1 : 3);
      }
      return sum % 10 == 0 ? digits : null;
    }
    if (RegExp(r'^\d{9}[\dX]$').hasMatch(digits)) {
      var sum = 0;
      for (var i = 0; i < 10; i++) {
        sum += (digits[i] == 'X' ? 10 : int.parse(digits[i])) * (10 - i);
      }
      return sum % 11 == 0 ? digits : null;
    }
    return null;
  }

  /// The source [query] names (a DOI or an ISBN), or null when it names neither or nothing is found. Throws when the
  /// service cannot be reached.
  Future<CitationSource?> find(String query) async {
    final doi = doiIn(query);
    if (doi != null) return fromDoi(doi);
    final isbn = isbnIn(query.trim());
    if (isbn != null) return fromIsbn(isbn);
    return null;
  }

  Future<CitationSource?> fromDoi(String doi) async {
    final String body;
    try {
      body = await _get('https://api.crossref.org/works/${Uri.encodeComponent(doi).replaceAll('%2F', '/')}');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
    final message = (jsonDecode(body) as Map<String, dynamic>)['message'];
    return message is Map<String, dynamic> ? crossrefToSource(message) : null;
  }

  Future<CitationSource?> fromIsbn(String isbn) async {
    final body = await _get('https://openlibrary.org/api/books?bibkeys=ISBN:$isbn&format=data&jscmd=data');
    final data = jsonDecode(body) as Map<String, dynamic>;
    final book = data['ISBN:$isbn'];
    return book is Map<String, dynamic> ? openLibraryToSource(book, isbn) : null;
  }
}

/// What Crossref returns for a work, as a source (the key is left empty for the library to make).
CitationSource crossrefToSource(Map<String, dynamic> m) {
  final type = switch (m['type']) {
    'journal-article' => 'article-journal',
    'book-chapter' || 'reference-entry' => 'chapter',
    'proceedings-article' => 'paper-conference',
    'dissertation' => 'thesis',
    'report' || 'report-component' => 'report',
    'posted-content' => 'webpage',
    _ => 'book',
  };
  List<Map<String, dynamic>> people(Object? list) => [
        for (final p in (list as List?) ?? const [])
          if (p is Map<String, dynamic>) p['name'] is String && p['family'] == null ? {'literal': p['name']} : p,
      ];
  final issued = m['issued'] ?? m['published'] ?? m['published-print'] ?? m['published-online'];
  return CitationSource.fromJson({
    ...m,
    'id': '',
    'type': type,
    'author': people(m['author']),
    'editor': people(m['editor']),
    'issued': issued,
    // the title of a book chapter's book is the container; a journal's is too
    'container-title': m['container-title'],
  });
}

/// What Open Library returns for an ISBN, as a book.
CitationSource openLibraryToSource(Map<String, dynamic> m, String isbn) {
  String first(String key) {
    final list = m[key];
    return list is List && list.isNotEmpty && list.first is Map ? '${(list.first as Map)['name'] ?? ''}' : '';
  }

  final title = '${m['title'] ?? ''}${m['subtitle'] == null ? '' : ': ${m['subtitle']}'}';
  return CitationSource(
    id: '',
    type: SourceType.book,
    title: title,
    authors: [for (final a in (m['authors'] as List?) ?? const []) if (a is Map) Person.parse('${a['name']}')],
    year: int.tryParse(RegExp(r'\d{4}').firstMatch('${m['publish_date'] ?? ''}')?.group(0) ?? ''),
    publisher: first('publishers'),
    place: first('publish_places'),
    isbn: isbn,
  );
}
