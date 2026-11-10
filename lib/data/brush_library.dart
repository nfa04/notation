import 'dart:convert';

import '../models/brush_desc.dart';
import 'settings_repository.dart';

/// A designed brush as the library keeps it.
typedef LibraryBrush = ({BrushDesc desc, bool listed});

/// The brushes a person designed or took from notes and files, kept as settings (one setting for each, `brush:<id>`, so that
/// they travel between a person's devices like the other settings and two devices that each made one keep both).
///
/// A brush is *listed* when it is in the brush menu. Every brush ever kept stays here, listed or not, because lines in notes
/// are drawn with it: taking one out of the menu must not change how a note looks. Brushes that arrive with a note (see
/// [adopt]) are not listed until the person keeps them.
class BrushLibrary {
  final SettingsRepository _settings;

  const BrushLibrary(this._settings);

  static const keyPrefix = 'brush:';

  /// The most brushes taken from files and notes: a note cannot fill the library.
  static const maxBrushes = CustomBrushes.maxLearned;

  /// Reads the library, makes its brushes be the designed brushes there are (see [CustomBrushes.sync]) and returns them.
  Future<List<LibraryBrush>> load() async {
    final all = await _settings.allWhere((k) => k.startsWith(keyPrefix));
    final out = <LibraryBrush>[];
    final seen = <String>{};
    for (final e in all.entries) {
      try {
        final json = jsonDecode(e.value.value);
        if (json is Map && json['removed'] == true) continue;
        final desc = BrushDesc.fromJson(json);
        if (!seen.add(desc.id)) continue;
        out.add((desc: desc, listed: json is Map ? json['listed'] != false : true));
      } on FormatException {
        // (a setting that is not a brush: left alone)
      } on BrushDescException {
        // (a brush from a newer version of the app, or damaged: left alone, not shown, not deleted)
      }
    }
    out.sort((a, b) => a.desc.name.toLowerCase().compareTo(b.desc.name.toLowerCase()));
    CustomBrushes.sync(out);
    return out;
  }

  Future<void> _write(BrushDesc desc, bool listed) =>
      _settings.set('$keyPrefix${desc.id}', jsonEncode({...desc.toJson(), 'listed': listed}));

  /// Keeps [desc] (a new one, or the same design under another name) and makes it available. Returns its id.
  Future<String> save(BrushDesc desc, {bool listed = true}) async {
    await _write(desc, listed);
    await load();
    return desc.id;
  }

  /// Puts the brush [id] in the brush menu, or takes it out; it stays in the library either way.
  Future<void> setListed(String id, bool listed) async {
    final desc = CustomBrushes.of(id);
    if (desc == null) return;
    await _write(desc, listed);
    await load();
  }

  /// Whether the brush with [key] is in the library (a deleted one is not: see [delete]).
  Future<bool> _kept(String key) async {
    final text = await _settings.get(key);
    if (text == null) return false;
    try {
      final json = jsonDecode(text);
      return !(json is Map && json['removed'] == true);
    } on FormatException {
      return true;
    }
  }

  /// Takes the brush [id] out of the library for good, out of the menu too. Lines in notes that are drawn with it are drawn with the
  /// pen from now on, until a note file or a live session brings the brush again (see [adopt], [keep]).
  ///
  /// What is left is a mark that the brush was deleted, not a missing setting: a missing one would be given back by the next device
  /// that the settings are synced with (see `syncedSetting`).
  Future<void> delete(String id) async {
    await _settings.set('$keyPrefix$id', jsonEncode({'removed': true}));
    await load();
  }

  /// Keeps one brush that came with a line in a live session, if it is not kept already (a brush the person keeps in the menu is
  /// never taken out of it by this), and makes the library the brushes there are.
  Future<void> keep(BrushDesc desc) async {
    final key = '$keyPrefix${desc.id}';
    if (!await _kept(key)) await _write(desc, false);
    await load();
  }

  /// Takes in the brushes that came with a note or a file: the ones this device does not have yet are kept, not in the brush menu
  /// (the person chooses which to keep). Returns how many were new.
  Future<int> adopt(Iterable<BrushDesc> descs) async {
    // (read first: a brush that is kept already must not be written again as one that is not in the menu)
    final known = {for (final b in await load()) b.desc.id};
    var added = 0;
    for (final d in descs) {
      if (known.length >= maxBrushes) break;
      if (!known.add(d.id)) continue;
      await _write(d, false);
      added++;
    }
    if (added > 0) await load();
    return added;
  }
}
