import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/settings_repository.dart';
import 'source.dart';

/// The library of sources and the styles notes and folders are cited in. They are kept as settings (one per source, `cite:<key>`,
/// and one per note or folder that has a style of its own), so that the sync between a person's devices carries them like it carries
/// every other setting, the newer change of each one winning. A source that is deleted stays as an empty value so that the deletion
/// reaches the other devices too.
class CitationRepository {
  static const sourcePrefix = 'cite:';
  static const styleKey = 'citation_style';
  static const noteStylePrefix = 'citation_style_note:';
  static const folderStylePrefix = 'citation_style_folder:';

  final SettingsRepository _settings;

  /// The database the first version kept the library in (a table of its own), read once and emptied; null: none to read.
  final Database? _legacy;

  CitationRepository(this._settings, {Database? legacy}) : _legacy = legacy;

  /// The sources, in the order they were added.
  Future<List<CitationSource>> all() async {
    final rows = await _settings.allWhere((k) => k.startsWith(sourcePrefix));
    final out = <(int, CitationSource)>[];
    for (final e in rows.entries) {
      if (e.value.value.isEmpty) continue; // deleted
      try {
        final j = jsonDecode(e.value.value) as Map<String, dynamic>;
        out.add((j['added'] as int? ?? 0, CitationSource.fromJson(j['source'] as Map<String, dynamic>, id: e.key.substring(sourcePrefix.length))));
      } catch (_) {
        // a value this version cannot read (from a newer one) is left alone
      }
    }
    out.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.id.compareTo(b.$2.id));
    return [for (final (_, s) in out) s];
  }

  Future<void> save(CitationSource s, {int? added}) => _settings.set(
        '$sourcePrefix${s.id}',
        jsonEncode({'added': added ?? DateTime.now().millisecondsSinceEpoch, 'source': s.toJson()}),
      );

  /// Changes the key a source is cited by. The texts that cite the old key are not changed.
  Future<void> rename(String from, CitationSource s, {int? added}) async {
    await delete(from);
    await save(s, added: added);
  }

  Future<void> delete(String id) => _settings.set('$sourcePrefix$id', '');

  /// When the source was added (to keep the order when it is edited).
  Future<int?> addedAt(String id) async {
    final v = await _settings.get('$sourcePrefix$id');
    if (v == null || v.isEmpty) return null;
    try {
      return (jsonDecode(v) as Map<String, dynamic>)['added'] as int?;
    } catch (_) {
      return null;
    }
  }

  // ---- styles

  Future<String?> style() => _settings.get(styleKey);

  Future<void> setStyle(String id) => _settings.set(styleKey, id);

  /// The style ids of the notes (`noteStylePrefix`) or folders (`folderStylePrefix`) that have one, by their id.
  Future<Map<String, String>> stylesOf(String prefix) async {
    final rows = await _settings.allWhere((k) => k.startsWith(prefix));
    return {for (final e in rows.entries) if (e.value.value.isNotEmpty) e.key.substring(prefix.length): e.value.value};
  }

  /// [styleId] null or empty: the note or folder has no style of its own.
  Future<void> setStyleOf(String prefix, String id, String? styleId) => _settings.set('$prefix$id', styleId ?? '');

  // ---- the first version

  /// Moves the sources of the first version's table into the settings, once. Returns how many were taken over.
  Future<int> adoptLegacy() async {
    final db = _legacy;
    if (db == null) return 0;
    final has = await db.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'citation_sources'");
    if (has.isEmpty) return 0;
    var n = 0;
    for (final r in await db.query('citation_sources')) {
      final id = r['id'] as String;
      if (await _settings.get('$sourcePrefix$id') != null) continue;
      await save(CitationSource.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>, id: id), added: r['created_at'] as int);
      n++;
    }
    await db.execute('DROP TABLE citation_sources');
    return n;
  }
}
