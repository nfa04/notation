import 'dart:async';
import 'dart:convert';
import '../llm/download.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../llm/model_files.dart';
import 'hunspell.dart';
import 'spell_checker.dart';

/// A language the app can check the spelling of: the Hunspell dictionary of the LibreOffice project, downloaded on request
/// (it is not part of the app: the dictionaries have licences of their own).
class DictionaryLanguage {
  final String id, name, folder, file;
  final int megabytes;

  /// The language as the word frequency lists name it (`pt_br`, `de`).
  String get frequencyCode => const {'pt_BR': 'pt_br'}[id] ?? id.split('_').first;

  /// What is known of the licence, or null where the README of the dictionary has to be read.
  final String? licence;

  const DictionaryLanguage(this.id, this.name, this.folder, this.file, this.megabytes, [this.licence]);

  static const _repo = 'https://raw.githubusercontent.com/LibreOffice/dictionaries/master';
  static const _page = 'https://github.com/LibreOffice/dictionaries/tree/master';

  String get affUrl => '$_repo/$folder/$file.aff';
  String get dicUrl => '$_repo/$folder/$file.dic';

  /// The 50,000 most common words of the language, which suggestions are ranked by (FrequencyWords by Hermit Dave, from
  /// film and television subtitles; the lists are licensed CC BY-SA 4.0). Optional: without it suggestions are ranked by the
  /// edit alone.
  String get frequencyUrl => 'https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/$frequencyCode/${frequencyCode}_50k.txt';

  /// Where the licence and the README of the dictionary are.
  String get pageUrl => '$_page/$folder';

  static const all = [
    DictionaryLanguage('en_US', 'English (US)', 'en', 'en_US', 1, 'BSD-style (SCOWL)'),
    DictionaryLanguage('en_GB', 'English (UK)', 'en', 'en_GB', 2, 'LGPL'),
    DictionaryLanguage('de_DE', 'Deutsch', 'de', 'de_DE_frami', 5, 'GPL v2 or v3'),
    DictionaryLanguage('fr_FR', 'Français', 'fr_FR/dictionaries', 'fr', 2, 'MPL 2.0'),
    DictionaryLanguage('es_ES', 'Español', 'es', 'es_ES', 1, 'GPL v3, LGPL or MPL'),
    DictionaryLanguage('it_IT', 'Italiano', 'it_IT', 'it_IT', 2, 'GPL v3'),
    DictionaryLanguage('nl_NL', 'Nederlands', 'nl_NL', 'nl_NL', 3),
    DictionaryLanguage('pt_PT', 'Português (Portugal)', 'pt_PT', 'pt_PT', 2, 'GPL, LGPL or MPL'),
    DictionaryLanguage('pt_BR', 'Português (Brasil)', 'pt_BR', 'pt_BR', 6),
    DictionaryLanguage('pl_PL', 'Polski', 'pl_PL', 'pl_PL', 6, 'GPL, LGPL, MPL, Apache 2.0 or CC BY-SA'),
    DictionaryLanguage('ru_RU', 'Русский', 'ru_RU', 'ru_RU', 4),
  ];
}

/// The files of one dictionary: downloaded on request, read into memory when it is in use.
class DictionaryPack extends ModelFilesService {
  final DictionaryLanguage language;
  HunspellDictionary? dictionary;
  Future<bool>? _opening;
  final Future<void> Function(String url, String path, void Function(double) progress) _fetch;

  DictionaryPack(
    this.language, {
    Future<Directory> Function()? directory,
    super.download,
  })  : _fetch = download ?? _viaDio,
        super(
          files: {
            '${language.file}.aff': (url: language.affUrl, megabytes: 1),
            '${language.file}.dic': (url: language.dicUrl, megabytes: language.megabytes),
          },
          folderName: 'dictionaries/${language.id}',
          modelDirectory: directory,
        );

  static Future<void> _viaDio(String url, String path, void Function(double) progress) => downloadToFile(url, path, progress);

  /// Reads the dictionary into memory if it is on disk. Returns whether it is there afterwards.
  Future<bool> open() async {
    if (dictionary != null) return true;
    if (!installed) return false;
    return _opening ??= _read().whenComplete(() {
      _opening = null;
      notifyListeners();
    });
  }

  Future<bool> _read() async {
    try {
      final aff = await (await file('${language.file}.aff')).readAsBytes();
      final dic = await (await file('${language.file}.dic')).readAsBytes();
      final d = await HunspellDictionary.parse(aff, dic, breathe: () => Future<void>.delayed(Duration.zero));
      final freq = await file('frequency.txt');
      if (await freq.exists()) {
        d.useFrequencies(_words(await freq.readAsString()));
      } else {
        _getFrequencies(); // (for a dictionary that was downloaded before the lists were: in the background)
      }
      dictionary = d;
      return true;
    } catch (e) {
      error = '$e';
      return false;
    }
  }

  static Iterable<String> _words(String text) sync* {
    for (final line in text.split('\n')) {
      final i = line.indexOf(' ');
      final w = (i < 0 ? line : line.substring(0, i)).trim();
      if (w.isNotEmpty) yield w;
    }
  }

  bool _fetching = false;

  /// Downloads the list of common words, if it is not there, and ranks suggestions with it from then on. A failure is no
  /// harm: the dictionary works without.
  Future<void> _getFrequencies() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final target = await file('frequency.txt');
      if (!await target.exists()) {
        await (await directory()).create(recursive: true);
        final partial = '${target.path}.part';
        await _fetch(language.frequencyUrl, partial, (_) {});
        await File(partial).rename(target.path);
      }
      dictionary?.useFrequencies(_words(await target.readAsString()));
    } catch (e) {
      debugPrint('[spell] no word frequencies for ${language.id}: $e');
    } finally {
      _fetching = false;
    }
  }

  @override
  Future<void> install() async {
    await super.install();
    if (installed) await _getFrequencies();
  }

  @override
  Future<void> unload() async {
    dictionary = null;
  }
}

/// Which languages are checked, the words the person added, and the checker that uses both. Kept in the settings.
class SpellService extends ChangeNotifier {
  static const enabledKey = 'spell_languages';
  static const personalKey = 'spell_personal';
  static const showCheckedKey = 'spell_show_checked';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final List<DictionaryPack> packs;
  final SpellChecker checker = SpellChecker();
  Set<String> _enabled = {};

  SpellService(
    this._read,
    this._write, {
    List<DictionaryLanguage> languages = DictionaryLanguage.all,
    Future<Directory> Function(DictionaryLanguage)? directory,
    Future<void> Function(String, String, void Function(double))? download,
  }) : packs = [
          for (final l in languages) DictionaryPack(l, directory: directory == null ? null : () => directory(l), download: download),
        ] {
    for (final pack in packs) {
      pack.addListener(() => _packChanged(pack));
    }
  }

  bool _showChecked = false;

  /// Whether the handwritten words that are spelled right are marked too (and can be tapped), to see that they were read as writing.
  bool get showChecked => _showChecked;

  Future<void> setShowChecked(bool on) async {
    _showChecked = on;
    await _write(showCheckedKey, on ? '1' : '0');
    notifyListeners();
  }

  /// The languages that are on.
  Set<String> get enabled => Set.unmodifiable(_enabled);

  bool isOn(DictionaryLanguage l) => _enabled.contains(l.id);

  /// Whether there is anything being checked.
  bool get active => checker.active;

  DictionaryPack packOf(String id) => packs.firstWhere((p) => p.language.id == id);

  Future<void> load() async {
    for (final pack in packs) {
      await pack.load();
    }
    final text = await _read(enabledKey);
    if (text != null) {
      try {
        _enabled = {for (final id in jsonDecode(text) as List) id as String};
      } catch (_) {
        _enabled = {};
      }
    }
    _showChecked = await _read(showCheckedKey) == '1';
    final words = await _read(personalKey);
    if (words != null) {
      try {
        checker.personal = {for (final w in jsonDecode(words) as List) w as String};
      } catch (_) {}
    }
    await _refresh();
    // a language that is on but whose files are not here (its download failed, or the settings came from another device or an
    // earlier folder of the app) is fetched again: "on" checks, it does not quietly do nothing. It is read in once it is there
    // (see _packChanged); without a connection it stays as it is until the next start.
    for (final pack in packs) {
      if (_enabled.contains(pack.language.id) && !pack.installed) unawaited(pack.install());
    }
  }

  void _packChanged(DictionaryPack pack) {
    // downloaded: use it at once, so that what the person turned on works
    if (pack.installed && pack.error == null && _enabled.contains(pack.language.id) && pack.dictionary == null) {
      _refresh();
    } else {
      notifyListeners();
    }
  }

  Future<void> _queue = Future.value();

  /// Brings the checker up to date with the languages that are on (one at a time).
  Future<void> _refresh() => _queue = _queue.then((_) => _update()).catchError((Object _) {});

  Future<void> _update() async {
    final ready = <HunspellDictionary>[];
    for (final pack in packs) {
      if (!_enabled.contains(pack.language.id)) {
        await pack.unload();
        continue;
      }
      if (await pack.open()) ready.add(pack.dictionary!);
    }
    checker.dictionaries = ready;
    notifyListeners();
  }

  /// Turns [language] on or off. A language that is not on the device yet is downloaded first.
  Future<void> setOn(DictionaryLanguage language, bool on) async {
    on ? _enabled.add(language.id) : _enabled.remove(language.id);
    await _write(enabledKey, jsonEncode(_enabled.toList()..sort()));
    final pack = packOf(language.id);
    if (on && !pack.installed) {
      notifyListeners();
      await pack.install(); // (it is read in when it is there: see _packChanged)
      if (pack.installed) await _refresh();
    } else {
      await _refresh();
    }
  }

  /// Deletes the files of [language].
  Future<void> delete(DictionaryLanguage language) async {
    _enabled.remove(language.id);
    await _write(enabledKey, jsonEncode(_enabled.toList()..sort()));
    await packOf(language.id).remove();
    await _refresh();
  }

  // ---- the person's own words ----

  Future<void> addWord(String word) async {
    final w = word.trim();
    if (w.isEmpty) return;
    checker.personal = {...checker.personal, w};
    await _write(personalKey, jsonEncode(checker.personal.toList()..sort()));
    notifyListeners();
  }

  Future<void> removeWord(String word) async {
    checker.personal = checker.personal.where((w) => w != word).toSet();
    await _write(personalKey, jsonEncode(checker.personal.toList()..sort()));
    notifyListeners();
  }

  /// Set aside until the app is closed.
  void ignore(String word) {
    checker.ignore(word);
    notifyListeners();
  }
}
