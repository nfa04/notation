import 'dart:convert';

import '../data/settings_repository.dart';
import 'search_filter.dart';
import 'search_query.dart';

/// A search kept under a name: what to find and where to look.
class SavedSearch {
  final String name;
  final SearchQuery query;
  final SearchFilter filter;
  const SavedSearch(this.name, this.query, this.filter);

  Map<String, Object?> toJson() => {'name': name, 'query': query.toJson(), 'filter': filter.toJson()};

  static SavedSearch? fromJson(Object? j) {
    if (j is! Map || j['name'] is! String || j['query'] is! Map) return null;
    return SavedSearch(
      j['name'] as String,
      SearchQuery.fromJson((j['query'] as Map).cast<Object?, Object?>()),
      j['filter'] is Map ? SearchFilter.fromJson((j['filter'] as Map).cast<Object?, Object?>()) : SearchFilter(),
    );
  }
}

/// What the search page remembers between visits: searches the person saved, and the last words they looked for.
/// Kept on this device only (folder ids would mean nothing on another).
class SearchMemory {
  static const savedKey = 'saved_searches';
  static const recentKey = 'recent_searches';
  static const maxRecent = 8;

  final SettingsRepository _settings;
  SearchMemory(this._settings);

  Future<List<Object?>> _list(String key) async {
    final raw = await _settings.get(key);
    if (raw == null) return const [];
    try {
      final j = jsonDecode(raw);
      return j is List ? j : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<List<SavedSearch>> saved() async => [
        for (final j in await _list(savedKey)) ?SavedSearch.fromJson(j),
      ];

  /// Keeps [search]; one with the same name (ignoring case) is replaced, in its place.
  Future<void> save(SavedSearch search) async {
    final all = await saved();
    final at = all.indexWhere((s) => s.name.toLowerCase() == search.name.toLowerCase());
    at < 0 ? all.add(search) : all[at] = search;
    await _settings.set(savedKey, jsonEncode([for (final s in all) s.toJson()]));
  }

  Future<void> forget(String name) async {
    final all = [
      for (final s in await saved())
        if (s.name != name) s,
    ];
    await _settings.set(savedKey, jsonEncode([for (final s in all) s.toJson()]));
  }

  /// The last searches, newest first.
  Future<List<SavedSearch>> recent() async => [
        for (final j in await _list(recentKey)) ?SavedSearch.fromJson(j),
      ];

  /// Remembers that [query] (with [filter]) was looked for; the same search moves to the front. Empty and broken queries are not kept.
  Future<void> remember(SearchQuery query, SearchFilter filter) async {
    if (query.text.trim().isEmpty || query.problem != null) return;
    final key = jsonEncode([query.toJson(), filter.toJson()]);
    final all = [
      SavedSearch(query.text, query, filter),
      for (final s in await recent())
        if (jsonEncode([s.query.toJson(), s.filter.toJson()]) != key) s,
    ];
    await _settings.set(recentKey, jsonEncode([for (final s in all.take(maxRecent)) s.toJson()]));
  }

  Future<void> clearRecent() => _settings.remove(recentKey);
}
