import '../transcript/script_result.dart';
import '../transcript/transcript.dart';
import '../transcript/transcript_source.dart';
import 'dart:typed_data' show BytesBuilder;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import '../data/safe_zip.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../events/event_bus.dart';
import '../util/public_host.dart';
import '../models/brush.dart';
import 'draw_result.dart';
import '../models/canvas_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../import/import_source.dart';
import 'door_results.dart';
import 'extension_doors.dart';
import 'extension_host.dart';
import 'extension_manifest.dart';
import 'script_engine.dart';

/// An extension that is on the device: what it says it is, its script, and what the person decided about it.
class InstalledExtension {
  final ExtensionManifest manifest;
  final String script;
  final bool enabled;

  /// The permissions the person gave it (a subset of what it asks for).
  final Set<ExtensionPermission> granted;

  /// The other files of the package (templates, assets), by their path in it: text only, for what the manifest names.
  final Map<String, String> files;

  const InstalledExtension(this.manifest, this.script, {this.enabled = false, this.granted = const {}, this.files = const {}});

  String get id => manifest.id;

  InstalledExtension copyWith({bool? enabled, Set<ExtensionPermission>? granted}) =>
      InstalledExtension(manifest, script, enabled: enabled ?? this.enabled, granted: granted ?? this.granted, files: files);
}

/// An extension as it comes (a zip, or text), checked but not installed: what the person is shown before they say yes.
class ExtensionPackage {
  final ExtensionManifest manifest;
  final String manifestText, script;

  /// The other text files the package brings (modules are already in [script]; these are templates and the like).
  final Map<String, String> files;
  const ExtensionPackage(this.manifest, this.manifestText, this.script, [this.files = const {}]);
}

/// A note an importer made, as it answers: the app writes it the way the built-in importers write theirs.
class ImportedNote {
  /// Where it lies in the import, `Folder/Sub/Title` (the folders are made; the last part is the title when [title] is empty).
  final String path;
  final String title, markdown;
  final List<String> tags;
  final DateTime? created, updated;

  /// Pictures and files the Markdown points at by name (`![](name.png)`), as bytes.
  final Map<String, Uint8List> attachments;

  /// A PDF to make a PDF note of, with its bytes.
  final ({String name, Uint8List bytes})? pdf;

  /// A stable id of the note in its source: running the importer again updates the note it made before.
  final String? sourceId;
  const ImportedNote({
    required this.path,
    required this.title,
    required this.markdown,
    this.tags = const [],
    this.created,
    this.updated,
    this.attachments = const {},
    this.pdf,
    this.sourceId,
  });
}

/// What an importer answered: the notes and what to tell the person.
class ImporterResult {
  final List<ImportedNote> notes;
  final List<String> notices;
  const ImporterResult(this.notes, this.notices);
}

/// What an exporter made: a file's name and its content.
class ExportedFile {
  final String name;
  final Uint8List bytes;
  const ExportedFile(this.name, this.bytes);
}

/// What a block of an extension draws: the lines and the texts, in a box of [width] by [height].
class BlockDrawing {
  final double width, height;
  final List<Map<String, Object?>> strokes, texts;
  const BlockDrawing(this.width, this.height, this.strokes, this.texts);
}

/// The key store of the extensions: one entry per extension and key, in the device's secure storage.
class _SecureSecrets extends ExtensionSecrets {
  final String extensionId;
  _SecureSecrets(this.extensionId);
  static const _store = FlutterSecureStorage();
  String _key(String key) => 'extension/$extensionId/$key';

  @override
  Future<String?> get(String key) async {
    try {
      return await _store.read(key: _key(key));
    } catch (_) {
      throw ExtensionError('Secrets cannot be kept on this device.');
    }
  }

  @override
  Future<void> set(String key, String? value) async {
    try {
      if (value == null) {
        await _store.delete(key: _key(key));
      } else {
        await _store.write(key: _key(key), value: value);
      }
    } catch (_) {
      throw ExtensionError('Secrets cannot be kept on this device.');
    }
  }
}

/// What came of running a tool: text to put in place of the selection, text to put in the note, a message, or a reason it did not work.
class ToolOutcome {
  final String? replace, insert, message, error;
  const ToolOutcome({this.replace, this.insert, this.message, this.error});
  bool get ok => error == null;
}

/// What came of running a drawing tool: the lines to draw (the author is not set), a message, or a reason it did not work.
class DrawOutcome {
  final List<DrawingStroke> strokes;
  final String? message, error;
  const DrawOutcome({this.strokes = const [], this.message, this.error});
  bool get ok => error == null;
}

class _MessageApi extends ExtensionApi {
  final void Function(String)? onMessage;
  _MessageApi(this.onMessage);
  @override
  void message(String text) => onMessage?.call(text);
}

/// The extensions of the app: installing them from a file or from text, switching them on and off, what each is allowed to do,
/// and running their tools and actions (one at a time) with the limits of [ExtensionRuntime].
///
/// An extension is a folder `extensions/<id>/` in the app's own storage with `manifest.json`, the script and `storage.json`;
/// what the person decided (on or off, the permissions given) is in the settings. A new one is off until it is switched on, and
/// has no permission until it is given: what a new version asks for beyond the old one has to be given again.
class ExtensionService extends ChangeNotifier {
  static const stateKey = 'extensions_state';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<Directory> Function() _directory;
  final EngineFactory? _engine;
  final ExtensionFetch _fetch;
  final ExtensionFetchBytes _fetchBytes;

  /// Makes the secret store of an extension (the device's secure storage unless a test brings its own).
  final ExtensionSecrets Function(String extensionId) _secrets;

  /// Adds a task to the calendar (for the permission `tasks.add`); null: not here.
  final Future<void> Function(String title, DateTime? due)? addTask;

  /// Where the events of the extensions are announced (for the permission `events.emit`); null: not here.
  final EventBus? bus;

  ExtensionService(
    this._read,
    this._write, {
    Future<Directory> Function()? directory,
    EngineFactory? engine,
    ExtensionFetch? fetch,
    ExtensionFetchBytes? fetchBytes,
    ExtensionSecrets Function(String extensionId)? secrets,
    this.addTask,
    this.bus,
  })  : _fetchBytes = fetchBytes ?? _defaultFetchBytes,
        _secrets = secrets ?? _SecureSecrets.new,
        _directory = directory ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'extensions'))),
        _engine = engine,
        _fetch = fetch ?? _defaultFetch;

  final Map<String, InstalledExtension> _installed = {};

  /// The extensions, by name.
  List<InstalledExtension> get installed => _installed.values.toList()..sort((a, b) => a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));

  InstalledExtension? byId(String id) => _installed[id];

  /// Whether scripts can be run here at all (the engine's native library is there). Never in a browser: there the engine is the
  /// browser's own JavaScript, which shares the page's access to the notes and the profile secret, so the sandbox the permissions
  /// rely on does not exist.
  bool get canRun => _engine != null || (!kIsWeb && QuickJsEngine.available);

  final _announced = <String>{};

  /// Makes the events of the extensions that are on, and may announce them, known to the bus; lets go of the others.
  void _syncEvents() {
    final b = bus;
    if (b == null) return;
    final now = <String, EventType>{
      for (final e in _installed.values)
        if (e.enabled && e.granted.contains(ExtensionPermission.eventsEmit))
          for (final ev in e.manifest.events) 'ext:${e.id}/${ev.id}': EventType('ext:${e.id}/${ev.id}', '${e.manifest.name}: ${ev.title}'),
    };
    for (final id in _announced.difference(now.keys.toSet())) {
      b.unregister(id);
    }
    for (final t in now.values) {
      b.register(t);
    }
    _announced
      ..clear()
      ..addAll(now.keys);
  }

  /// Makes the brushes of the extensions that are on the brushes there are; lets go of the others. (A brush needs no permission:
  /// it is numbers, not code.)
  void _syncBrushes() => Brushes.sync('ext:', [
        for (final e in _installed.values)
          if (e.enabled)
            for (final b in e.manifest.brushes) ParamBrush(b.brushId(e.id), b.title, b.params),
      ]);

  @override
  void notifyListeners() {
    _syncEvents();
    _syncBrushes();
    super.notifyListeners();
  }

  /// When each extension announced its events lately, to keep one that goes wrong from flooding the automations.
  final _emitted = <String, List<DateTime>>{};
  static const _emitsPerMinute = 20;

  void _emit(InstalledExtension e, Map<String, Object?> context, String name, Map<String, Object?> data) {
    final b = bus;
    if (b == null) throw ExtensionError('Events cannot be announced here.');
    final id = 'ext:${e.id}/$name';
    if (b.type(id) == null) throw ExtensionError('The event "$name" is not on.');
    // reacting to its own event by announcing it again would never end
    if (context['event'] == id) throw ExtensionError('An extension cannot announce the event it is reacting to.');
    final now = DateTime.now();
    final recent = (_emitted[e.id] ??= [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (recent.length >= _emitsPerMinute) throw ExtensionError('Too many events (at most $_emitsPerMinute a minute).');
    recent.add(now);
    // not awaited: whoever reacts may want to run this very extension, which is busy until this run is over
    unawaited(b.emit(AppEvent(id, data: data)));
  }

  Future<void> load() async {
    _installed.clear();
    Map<String, Object?> state = {};
    try {
      state = (jsonDecode(await _read(stateKey) ?? '{}') as Map).cast<String, Object?>();
    } catch (_) {}
    final root = await _directory();
    if (await root.exists()) {
      for (final dir in await root.list().toList()) {
        if (dir is! Directory) continue;
        try {
          final manifest = ExtensionManifest.fromJson(jsonDecode(await File(p.join(dir.path, 'manifest.json')).readAsString()));
          if (manifest.id != p.basename(dir.path)) continue;
          final main = await File(p.join(dir.path, manifest.main)).readAsString();
          final files = <String, String>{};
          final filesDir = Directory(p.join(dir.path, 'files'));
          if (await filesDir.exists()) {
            for (final f in await filesDir.list(recursive: true).toList()) {
              if (f is! File || files.length >= _maxPackageFiles) continue;
              final rel = p.relative(f.path, from: filesDir.path).replaceAll('\\', '/');
              if (await f.length() <= _maxPackageFile) files[rel] = await f.readAsString();
            }
          }
          final script = combineScripts(manifest, main, files);
          final s = state[manifest.id];
          final granted = <ExtensionPermission>{
            if (s is Map && s['granted'] is List)
              for (final g in s['granted'] as List) ...[?ExtensionPermission.byId('$g')].where(manifest.permissions.contains),
          };
          _installed[manifest.id] = InstalledExtension(manifest, script, enabled: s is Map && s['enabled'] == true, granted: granted, files: files);
        } catch (e) {
          debugPrint('[extensions] ${dir.path} is not an extension: $e');
        }
      }
    }
    try {
      final dev = jsonDecode(await _read(devKey) ?? '{}') as Map;
      for (final e in dev.entries) {
        if (_installed.containsKey('${e.key}') && !kIsWeb) {
          _devFolders['${e.key}'] = '${e.value}';
          _watchDev('${e.key}');
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveState() => _write(
        stateKey,
        jsonEncode({
          for (final e in _installed.values) e.id: {'enabled': e.enabled, 'granted': [for (final g in e.granted) g.id]},
        }),
      );

  // ---- installing ----

  /// Installs the extension in [zip] (`manifest.json` and the script, at the top or in one folder). Says what is wrong with it, or
  /// returns the extension that was installed (an older version of it is replaced; what the person decided stays, as far as the
  /// new version still asks for it).
  Future<InstalledExtension> installZip(List<int> zip) async {
    final package = inspectZip(zip);
    return installSource(package.manifestText, package.script, files: package.files);
  }

  /// Reads and checks [zip] like [installZip] does, and installs nothing.
  ExtensionPackage inspectZip(List<int> zip) {
    final Archive archive;
    try {
      archive = decodeZipLimited(zip, maxEntries: 100000, maxEntryBytes: 1 << 20, maxTotalBytes: 8 << 20);
    } on ArchiveTooBigException {
      throw ManifestException('The zip is too big for an extension.');
    } catch (_) {
      throw ManifestException('That is not a zip file.');
    }
    if (archive.files.isEmpty) throw ManifestException('That is not a zip file.');
    if (archive.files.length > 200) throw ManifestException('The zip has too many files.');
    ArchiveFile? find(String name) => archive.files.where((f) => f.isFile && (f.name == name || f.name.endsWith('/$name')) && f.name.split('/').length <= 2).firstOrNull;
    final manifestFile = find('manifest.json');
    if (manifestFile == null) throw ManifestException('The zip has no manifest.json.');
    final manifestText = utf8.decode(manifestFile.content as List<int>, allowMalformed: true);
    final manifest = _parse(manifestText);
    final scriptFile = find(manifest.main);
    if (scriptFile == null) throw ManifestException('The zip has no ${manifest.main}.');
    // the package's other files: the folder the manifest lies in is the root
    final slash = manifestFile.name.lastIndexOf('/');
    final root = slash < 0 ? '' : manifestFile.name.substring(0, slash + 1);
    final files = <String, String>{};
    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith(root)) continue;
      final rel = f.name.substring(root.length);
      if (rel == 'manifest.json' || rel == manifest.main || rel.contains('..')) continue;
      final wanted = manifest.modules.contains(rel) || manifest.templates.any((t) => t.file == rel);
      if (!wanted) continue;
      if (f.size > _maxPackageFile) throw ManifestException('"$rel" is too big for an extension (at most 200 KB).');
      files[rel] = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    for (final m in manifest.modules) {
      if (!files.containsKey(m)) throw ManifestException('The zip has no $m (named in "modules").');
    }
    for (final t in manifest.templates) {
      if (!files.containsKey(t.file)) throw ManifestException('The zip has no ${t.file} (the file of the template "${t.id}").');
    }
    if (files.length > _maxPackageFiles) throw ManifestException('The package has too many files.');
    return inspectSource(manifestText, utf8.decode(scriptFile.content as List<int>, allowMalformed: true), files: files);
  }

  ExtensionManifest _parse(String manifestText) {
    final Object? json;
    try {
      json = jsonDecode(manifestText);
    } catch (_) {
      throw ManifestException('The manifest is not valid JSON.');
    }
    return ExtensionManifest.fromJson(json);
  }

  /// Checks a manifest and a script as text like [installSource] does, and installs nothing.
  ExtensionPackage inspectSource(String manifestText, String script, {Map<String, String> files = const {}}) {
    final manifest = _parse(manifestText);
    if (script.trim().isEmpty) throw ManifestException('The script is empty.');
    if (combineScripts(manifest, script, files).length > 256 * 1024) throw ManifestException('The script is too big (at most 256 KB, the modules included).');
    return ExtensionPackage(manifest, manifestText, script, files);
  }

  static const _maxPackageFiles = 40;
  static const _maxPackageFile = 200 * 1024;

  /// The script that runs: the modules of the manifest in order, then the main script.
  static String combineScripts(ExtensionManifest manifest, String main, Map<String, String> files) =>
      [for (final m in manifest.modules) files[m] ?? '', main].join('\n;\n');

  /// Installs an extension from its manifest and its script as text.
  Future<InstalledExtension> installSource(String manifestText, String script, {Map<String, String> files = const {}}) async {
    final manifest = inspectSource(manifestText, script, files: files).manifest;
    final dir = Directory(p.join((await _directory()).path, manifest.id));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'manifest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    await File(p.join(dir.path, manifest.main)).writeAsString(script);
    final filesDir = Directory(p.join(dir.path, 'files'));
    if (await filesDir.exists()) await filesDir.delete(recursive: true);
    for (final f in files.entries) {
      final target = File(p.join(filesDir.path, f.key));
      await target.parent.create(recursive: true);
      await target.writeAsString(f.value);
    }
    final before = _installed[manifest.id];
    final installed = InstalledExtension(
      manifest,
      combineScripts(manifest, script, files),
      files: files,
      enabled: before?.enabled ?? false,
      granted: {if (before != null) ...before.granted.where(manifest.permissions.contains)},
    );
    _installed[manifest.id] = installed;
    await _saveState();
    notifyListeners();
    return installed;
  }

  Future<void> remove(String id) async {
    if (_installed.remove(id) == null) return;
    final dir = Directory(p.join((await _directory()).path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
    await _saveState();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool on) async {
    final e = _installed[id];
    if (e == null) return;
    _installed[id] = e.copyWith(enabled: on);
    await _saveState();
    notifyListeners();
  }

  Future<void> setGranted(String id, ExtensionPermission permission, bool on) async {
    final e = _installed[id];
    if (e == null || !e.manifest.permissions.contains(permission)) return;
    _installed[id] = e.copyWith(granted: {...e.granted.where((g) => g != permission), if (on) permission});
    await _saveState();
    notifyListeners();
  }

  // ---- what they add ----

  /// The tools of the extensions that are on.
  List<({InstalledExtension extension, ExtensionTool tool})> get tools => [
        for (final e in installed)
          if (e.enabled)
            for (final t in e.manifest.tools) (extension: e, tool: t),
      ];

  /// The drawing tools of the extensions that are on and may draw.
  List<({InstalledExtension extension, ExtensionDrawTool tool})> get drawTools => [
        for (final e in installed)
          if (e.enabled && e.granted.contains(ExtensionPermission.draw))
            for (final t in e.manifest.drawTools) (extension: e, tool: t),
      ];

  /// The transcript sources of the extensions that are on.
  List<({InstalledExtension extension, ExtensionTranscriptSource source})> get transcriptSources => [
        for (final e in installed)
          if (e.enabled)
            for (final t in e.manifest.transcriptSources) (extension: e, source: t),
      ];

  /// The same as what "New note from a transcript" shows: each source with the function that fetches.
  List<TranscriptSource> get transcriptChoices => [
        for (final t in transcriptSources)
          TranscriptSource(
            id: 'ext:${t.extension.id}/${t.source.id}',
            title: t.source.title,
            hint: t.source.hint,
            fetch: (input) => runTranscriptSource(t.extension, t.source, input),
          ),
      ];

  /// The importers of the extensions that are on and may import.
  List<({InstalledExtension extension, ExtensionImporter importer})> get importers => [
        for (final e in installed)
          if (e.enabled && e.granted.contains(ExtensionPermission.notesImport))
            for (final i in e.manifest.importers) (extension: e, importer: i),
      ];

  /// The exporters of the extensions that are on and may read the note.
  List<({InstalledExtension extension, ExtensionExporter exporter})> get exporters => [
        for (final e in installed)
          if (e.enabled && e.granted.contains(ExtensionPermission.noteRead))
            for (final x in e.manifest.exporters) (extension: e, exporter: x),
      ];

  /// The commands of the extensions that are on, for [place] (all when null).
  List<({InstalledExtension extension, ExtensionCommand command})> commands([CommandPlace? place]) => [
        for (final e in installed)
          if (e.enabled)
            for (final c in e.manifest.commands)
              if (place == null || c.where.contains(place)) (extension: e, command: c),
      ];

  /// The code block languages the extensions that are on draw.
  Map<String, ({InstalledExtension extension, ExtensionBlock block})> get blocks => {
        for (final e in installed)
          if (e.enabled)
            for (final b in e.manifest.blocks) b.language: (extension: e, block: b),
      };

  /// The tools for the assistant that extensions bring (only from extensions that are on).
  List<({InstalledExtension extension, ExtensionAgentTool tool})> get agentTools => [
        for (final e in installed)
          if (e.enabled)
            for (final t in e.manifest.agentTools) (extension: e, tool: t),
      ];

  /// The capture handlers of the extensions that are on that want pages of [host].
  List<({InstalledExtension extension, ExtensionCapture handler})> captureFor(String host) => [
        for (final e in installed)
          if (e.enabled)
            for (final c in e.manifest.capture)
              if (c.matches(host)) (extension: e, handler: c),
      ];

  /// The templates the extensions that are on bring: the title, and the Markdown text of the template.
  List<({InstalledExtension extension, ExtensionTemplate template, String text})> get templates => [
        for (final e in installed)
          if (e.enabled)
            for (final t in e.manifest.templates)
              if (e.files[t.file] != null) (extension: e, template: t, text: e.files[t.file]!),
      ];

  /// The extensions that react to the automation event [event] by themselves.
  List<({InstalledExtension extension, ExtensionActionDef action})> reactingTo(String event) => [
        for (final e in installed)
          if (e.enabled && e.manifest.on.containsKey(event))
            for (final a in e.manifest.actions)
              if (a.id == e.manifest.on[event]) (extension: e, action: a),
      ];

  final _reactions = <String, List<DateTime>>{};

  /// Whether extension [id] may run for another event now: a script that makes notes in answer to the creation of notes would never
  /// stop, so each extension may react at most 30 times a minute.
  bool allowReaction(String id) {
    final now = DateTime.now();
    final recent = (_reactions[id] ??= [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (recent.length >= 30) return false;
    recent.add(now);
    return true;
  }

  /// A plain setting kept by the app for the extensions (the address of the gallery, say); null when it was not set.
  Future<String?> settingValue(String key) async {
    final v = await _read(key);
    return v == null || v.trim().isEmpty ? null : v.trim();
  }

  // ---- what an importer made before ----

  String _mapKey(String id, String importer) => 'extension_import_map/$id/$importer';

  /// The notes an importer made on earlier runs: the `sourceId` of each, and the id of the note it became.
  Future<Map<String, String>> importMapOf(String id, String importer) async {
    try {
      return {for (final e in (jsonDecode(await _read(_mapKey(id, importer)) ?? '{}') as Map).entries) '${e.key}': '${e.value}'};
    } catch (_) {
      return {};
    }
  }

  Future<void> saveImportMap(String id, String importer, Map<String, String> map) => _write(_mapKey(id, importer), jsonEncode(map));

  // ---- settings and secrets ----

  static const settingsKey = 'extensions_settings';

  Future<Map<String, Map<String, Object?>>> _allSettings() async {
    try {
      final raw = jsonDecode(await _read(settingsKey) ?? '{}') as Map;
      return {for (final e in raw.entries) '${e.key}': (e.value as Map).cast<String, Object?>()};
    } catch (_) {
      return {};
    }
  }

  /// What the settings of extension [id] are now: the person's values over the defaults (a secret is never in it).
  Future<Map<String, Object?>> settingsOf(String id) async {
    final e = _installed[id];
    if (e == null) return {};
    final mine = (await _allSettings())[id] ?? const {};
    return {
      for (final f in e.manifest.settings)
        if (f.type != FieldType.secret) f.id: mine.containsKey(f.id) ? mine[f.id] : f.initial,
    };
  }

  /// Sets the setting [field] of extension [id] ([value] null: back to the default). A secret goes to the device's secure storage.
  Future<void> setSetting(String id, String field, Object? value) async {
    final e = _installed[id];
    final def = e?.manifest.settings.where((f) => f.id == field).firstOrNull;
    if (e == null || def == null) return;
    if (def.type == FieldType.secret) {
      await _secrets(id).set(field, value is String && value.isNotEmpty ? value : null);
      notifyListeners();
      return;
    }
    final all = await _allSettings();
    final mine = all[id] ??= {};
    if (value == null) {
      mine.remove(field);
    } else {
      mine[field] = value;
    }
    await _write(settingsKey, jsonEncode(all));
    notifyListeners();
  }

  /// Whether the secret setting [field] of extension [id] has a value (the value itself is never given back).
  Future<bool> hasSecret(String id, String field) async {
    try {
      return (await _secrets(id).get(field)) != null;
    } catch (_) {
      return false;
    }
  }

  /// The brushes of the extensions that are on, by the id they have in the notes.
  List<({InstalledExtension extension, ExtensionBrushDef brush})> get brushes => [
        for (final e in installed)
          if (e.enabled)
            for (final b in e.manifest.brushes) (extension: e, brush: b),
      ];

  /// The actions of the extensions that are on.
  List<({InstalledExtension extension, ExtensionActionDef action})> get actions => [
        for (final e in installed)
          if (e.enabled)
            for (final a in e.manifest.actions) (extension: e, action: a),
      ];

  /// Whether [script] is JavaScript the engine reads (nothing of it is run beyond what it does on loading: it only registers its
  /// tools and actions). Null when it is; else why not. Also null when no engine is here, which cannot tell.
  String? checkScript(String script) {
    if (!canRun) return null;
    final engine = (_engine ?? QuickJsEngine.make)(onConsole: (_) {});
    try {
      engine.register('__host', (args) async => '{"error":"not here"}');
      engine.eval(extensionPrelude, filename: 'notation');
      engine.eval(script, filename: 'main.js');
      return null;
    } catch (e) {
      return '$e'.replaceFirst(RegExp(r'^\w*Exception: '), '');
    } finally {
      engine.dispose();
    }
  }

  // ---- running ----

  Future<void> _queue = Future.value();

  Future<T> _one<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await job());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  _Storage _storageOf(String id) => _Storage(() async => File(p.join((await _directory()).path, id, 'storage.json')));

  Future<ExtensionRun> _run(InstalledExtension e, String kind, String id, Map<String, Object?> context, ExtensionApi api, {bool heavy = false}) => _one(() async {
        final live = _installed[e.id] ?? e;
        // whoever asks, an extension that is off does not run (the permissions are read now too, so a taken-back one counts at once)
        if (!live.enabled) return const ExtensionRun(error: 'This extension is switched off.');
        return ExtensionRuntime(
          manifest: live.manifest,
          script: live.script,
          granted: live.granted,
          api: api,
          storage: _storageOf(live.id),
          fetch: _fetch,
          fetchBytes: _fetchBytes,
          settings: await settingsOf(live.id),
          secrets: _secrets(live.id),
          heavy: heavy,
          emit: (name, data) => _emit(live, context, name, data),
          engineFactory: _engine,
        ).run(kind, id, context).then((run) {
          _noteConsole(live.id, kind, id, run);
          return run;
        });
      });

  // ---- the console of each extension (for the one who writes it) ----

  final _console = <String, List<String>>{};

  void _noteConsole(String extension, String kind, String id, ExtensionRun run) {
    final lines = _console[extension] ??= [];
    String stamp() {
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    }

    for (final l in run.log) {
      lines.add('${stamp()} $kind:$id  $l');
    }
    if (run.error != null) lines.add('${stamp()} $kind:$id  error: ${run.error}');
    if (lines.length > 200) lines.removeRange(0, lines.length - 200);
    if (run.log.isNotEmpty || run.error != null) notifyListeners();
  }

  /// What the scripts of extension [id] wrote with `console.log` lately, and the errors of their runs (the last 200 lines).
  List<String> consoleOf(String id) => List.unmodifiable(_console[id] ?? const []);

  void clearConsole(String id) {
    _console.remove(id);
    notifyListeners();
  }

  // ---- developing from a folder ----

  static const devKey = 'extensions_dev';
  final _devFolders = <String, String>{};
  final _devWatch = <String, StreamSubscription<FileSystemEvent>>{};
  final _devStatus = <String, String>{};
  final _devTimers = <String, Timer>{};

  /// The folders extensions are developed from (extension id to path), and how the last load of each went.
  Map<String, String> get devFolders => Map.unmodifiable(_devFolders);
  String? devStatusOf(String id) => _devStatus[id];

  /// Reads the extension in [folder] (manifest.json, its script, the modules and the templates it names) the way a zip would be read.
  Future<ExtensionPackage> readFolder(Directory folder) async {
    final manifestFile = File(p.join(folder.path, 'manifest.json'));
    if (!await manifestFile.exists()) throw ManifestException('The folder has no manifest.json.');
    final manifestText = await manifestFile.readAsString();
    final manifest = _parse(manifestText);
    final main = File(p.join(folder.path, manifest.main));
    if (!await main.exists()) throw ManifestException('The folder has no ${manifest.main}.');
    final files = <String, String>{};
    for (final name in [...manifest.modules, for (final t in manifest.templates) t.file]) {
      final f = File(p.join(folder.path, name));
      if (!await f.exists()) throw ManifestException('The folder has no $name.');
      if (await f.length() > _maxPackageFile) throw ManifestException('"$name" is too big for an extension (at most 200 KB).');
      files[name] = await f.readAsString();
    }
    return inspectSource(manifestText, await main.readAsString(), files: files);
  }

  /// Installs the extension in [folder] and keeps it up to date: whenever a file there changes it is read and installed again (what
  /// the person decided about it - on or off, the permissions - stays). Desktop only; a mistake in the files is shown as its status and
  /// the version that works stays.
  Future<InstalledExtension> linkFolder(Directory folder) async {
    final package = await readFolder(folder);
    final installed = await installSource(package.manifestText, package.script, files: package.files);
    _devFolders[installed.id] = folder.path;
    _devStatus[installed.id] = 'Loaded';
    await _write(devKey, jsonEncode(_devFolders));
    _watchDev(installed.id);
    notifyListeners();
    return installed;
  }

  Future<void> unlinkFolder(String id) async {
    _devFolders.remove(id);
    _devStatus.remove(id);
    await _devWatch.remove(id)?.cancel();
    _devTimers.remove(id)?.cancel();
    await _write(devKey, jsonEncode(_devFolders));
    notifyListeners();
  }

  void _watchDev(String id) {
    final path = _devFolders[id];
    if (path == null || kIsWeb) return;
    _devWatch.remove(id)?.cancel();
    try {
      _devWatch[id] = Directory(path).watch(recursive: true).listen((_) {
        _devTimers[id]?.cancel();
        _devTimers[id] = Timer(const Duration(milliseconds: 400), () => _reloadDev(id));
      });
    } catch (e) {
      _devStatus[id] = 'Cannot watch the folder: $e';
    }
  }

  Future<void> _reloadDev(String id) async {
    final path = _devFolders[id];
    if (path == null) return;
    try {
      final package = await readFolder(Directory(path));
      if (package.manifest.id != id) throw ManifestException('The id changed to "${package.manifest.id}": unlink the folder and load it again.');
      await installSource(package.manifestText, package.script, files: package.files);
      final t = DateTime.now();
      _devStatus[id] = 'Loaded again at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    } catch (e) {
      _devStatus[id] = '$e';
    }
    notifyListeners();
  }

  /// Ends the watching of the folders (the app is closing, or a test is over).
  Future<void> stopWatching() async {
    for (final w in _devWatch.values) {
      await w.cancel();
    }
    for (final t in _devTimers.values) {
      t.cancel();
    }
    _devWatch.clear();
    _devTimers.clear();
  }

  /// Runs [tool] on [text] (what is selected). A string that comes back replaces the text; an object may have `replace`, `insert`
  /// and `message`.
  Future<ToolOutcome> runTool(InstalledExtension e, ExtensionTool tool, {required String text, required ExtensionApi api}) async {
    if (!canRun) return const ToolOutcome(error: 'Extensions cannot run on this device.');
    final r = await _run(e, 'tool', tool.id, {'text': text}, api);
    if (!r.ok) return ToolOutcome(error: r.error);
    final v = r.value;
    if (v is String) return ToolOutcome(replace: v);
    if (v is Map) {
      String? field(String k) => v[k] is String ? v[k] as String : null;
      return ToolOutcome(replace: field('replace'), insert: field('insert'), message: field('message'));
    }
    return const ToolOutcome();
  }

  /// Gives [input] (an address the person typed) to the transcript [source]; what comes back is the transcript (see
  /// [transcriptFromScript]). Throws a [TranscriptSourceError] with a sentence for the person when it cannot be had.
  Future<Transcript> runTranscriptSource(InstalledExtension e, ExtensionTranscriptSource source, String input) async {
    if (!canRun) throw const TranscriptSourceError('Extensions cannot run on this device.');
    final r = await _run(e, 'transcript', source.id, {'input': input}, _MessageApi(null));
    if (!r.ok) throw TranscriptSourceError('${r.error}');
    return transcriptFromScript(r.value, input: input);
  }

  /// Runs [importer] on the files in [source] (none for an account) and checks what it answers. The importer may ask the person
  /// and show progress through [api]. It gets more time and memory than a tool (five minutes, 128 MB).
  Future<ImporterResult> runImporter(InstalledExtension e, ExtensionImporter importer, {ImportSource? source, InteractiveApi? api}) async {
    if (!canRun) throw ExtensionError('Extensions cannot run on this device.');
    final files = source?.files ?? const <SourceFile>[];
    final place = ImportApi(files, onMessage: api?.onMessage, onAsk: api?.onAsk, onProgress: api?.onProgress);
    final context = {
      'files': [for (final f in files) {'path': f.path, 'name': f.name, 'size': f.size}],
      'name': source?.name ?? '',
    };
    final r = await _run(e, 'importer', importer.id, context, place, heavy: true);
    if (!r.ok) throw ExtensionError('${r.error}');
    return parseImporterResult(r.value);
  }

  /// Runs [exporter] on a note ([note]: `id`, `title`, `markdown`, `tags`) and checks the file it answers with.
  Future<ExportedFile> runExporter(InstalledExtension e, ExtensionExporter exporter, Map<String, Object?> note, {InteractiveApi? api}) async {
    if (!canRun) throw ExtensionError('Extensions cannot run on this device.');
    final r = await _run(e, 'exporter', exporter.id, {'note': note}, api ?? InteractiveApi());
    if (!r.ok) throw ExtensionError('${r.error}');
    return parseExportedFile(r.value, exporter.extension);
  }

  /// Runs the [command] of an extension; [context] says where (the open note, the selection). What comes back is shown as the message.
  Future<String> runCommand(InstalledExtension e, ExtensionCommand command, {required ExtensionApi api, Map<String, Object?> context = const {}}) async {
    if (!canRun) return 'Extensions cannot run on this device.';
    final r = await _run(e, 'command', command.id, context, api);
    if (!r.ok) return 'Failed: ${r.error}';
    final v = r.value;
    if (v is String && v.isNotEmpty) return v.length > 300 ? '${v.substring(0, 300)}...' : v;
    if (v is Map && v['message'] is String) return v['message'] as String;
    return 'Done';
  }

  final _blockCache = <String, BlockDrawing>{};

  /// What the extension that draws [language] makes of the block [text]; kept by the text, so a block is drawn again only when it
  /// changed. Throws an [ExtensionError] with the reason when it cannot.
  Future<BlockDrawing> drawBlock(String language, String text, {double width = 600}) async {
    final found = blocks[language] ?? (throw ExtensionError('No extension draws "$language".'));
    // (a width in steps of 100: dragging a window edge does not run the script at every pixel)
    width = (width / 100).ceil().clamp(1, 20) * 100.0;
    final key = '${found.extension.id}@${found.extension.manifest.version}|$language|${width.round()}|$text';
    final kept = _blockCache[key];
    if (kept != null) return kept;
    if (!canRun) throw ExtensionError('Extensions cannot run on this device.');
    final r = await _run(found.extension, 'block', found.block.id, {'text': text, 'language': language, 'width': width}, InteractiveApi());
    if (!r.ok) throw ExtensionError('${r.error}');
    final drawing = parseBlockDrawing(r.value);
    if (_blockCache.length >= 200) _blockCache.remove(_blockCache.keys.first);
    return _blockCache[key] = drawing;
  }

  /// Calls the agent tool [tool] with [args]; the text it answers is what the assistant is told.
  Future<String> runAgentTool(InstalledExtension e, ExtensionAgentTool tool, Map<String, Object?> args, ExtensionApi api) async {
    if (!canRun) throw ExtensionError('Extensions cannot run on this device.');
    final r = await _run(e, 'agenttool', tool.id, {'args': args}, api);
    if (!r.ok) throw ExtensionError('${r.error}');
    final v = r.value;
    final text = v is String ? v : (v == null ? 'Done' : jsonEncode(v));
    return text.length > 6000 ? '${text.substring(0, 6000)}...' : text;
  }

  /// Runs the capture [handler] for a page that was kept (`url`, `site`, `title`, `text`); it may add to the note through [api].
  Future<String> runCapture(InstalledExtension e, ExtensionCapture handler, Map<String, Object?> page, ExtensionApi api) async {
    if (!canRun) return 'Extensions cannot run on this device.';
    final r = await _run(e, 'capture', handler.id, page, api);
    if (!r.ok) return 'Failed: ${r.error}';
    final v = r.value;
    return v is String && v.isNotEmpty ? v : 'Done';
  }

  /// Hands the drag of the pen [gesture] to the drawing [tool]; what comes back is the lines to draw in its place (see
  /// [parseDrawnStrokes]). [onMessage] shows what the script says with `notation.ui.message`.
  Future<DrawOutcome> runDrawTool(InstalledExtension e, ExtensionDrawTool tool, DrawGesture gesture, {void Function(String)? onMessage}) async {
    if (!canRun) return const DrawOutcome(error: 'Extensions cannot run on this device.');
    final live = _installed[e.id] ?? e;
    if (!live.granted.contains(ExtensionPermission.draw)) return const DrawOutcome(error: 'The permission "draw.add" was not given to this extension.');
    final r = await _run(e, 'drawtool', tool.id, gesture.toJson(), _MessageApi(onMessage));
    if (!r.ok) return DrawOutcome(error: r.error);
    try {
      final v = r.value;
      return DrawOutcome(
        strokes: parseDrawnStrokes(v, color: gesture.color, width: gesture.width),
        message: v is Map && v['message'] is String ? v['message'] as String : null,
      );
    } on ExtensionError catch (err) {
      return DrawOutcome(error: err.message);
    }
  }

  /// Runs [action] for an automation: [event] says what happened (`event`, `note`: title and id). What it returns (text) is the
  /// result shown for the automation.
  Future<String> runAction(InstalledExtension e, ExtensionActionDef action, {required Map<String, Object?> event, required ExtensionApi api, Map<String, Object?> params = const {}}) async {
    if (!canRun) return 'Extensions cannot run on this device.';
    final r = await _run(e, 'action', action.id, {...event, if (action.fields.isNotEmpty || params.isNotEmpty) 'params': params}, api);
    if (!r.ok) return 'Failed: ${r.error}';
    final v = r.value;
    if (v is String && v.isNotEmpty) return v.length > 300 ? '${v.substring(0, 300)}...' : v;
    if (v is Map && v['message'] is String) return v['message'] as String;
    return 'Done';
  }

  /// A request for an extension: https only, no redirects (they could lead to a website that was not allowed), a limit on time and size.
  static Future<Map<String, Object?>> _defaultFetch(Uri url, {String method = 'GET', Map<String, String> headers = const {}, String? body}) async {
    try {
      await checkPublicHost(url);
    } on StateError catch (e) {
      throw ExtensionError(e.message);
    }
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
    try {
    final response = await dio.request<ResponseBody>(
      url.toString(),
      data: body,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: false,
        validateStatus: (_) => true,
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        maxRedirects: 0,
      ),
    );
    // (read as it arrives and given up on at the limit: a big answer is never held whole)
    final collected = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      collected.add(chunk);
      if (collected.length > 1024 * 1024) throw ExtensionError('The answer is too big.');
    }
    final bytes = collected.takeBytes();
    return {
      'status': response.statusCode,
      'headers': {for (final e in response.headers.map.entries) e.key: e.value.join(', ')},
      'body': utf8.decode(bytes, allowMalformed: true),
    };
    } finally {
      dio.close(force: true);
    }
  }
}

/// A request whose answer is read as bytes (up to [limit]) and given as base64: https only, no redirects, a public host.
Future<Map<String, Object?>> _defaultFetchBytes(Uri url, {String method = 'GET', Map<String, String> headers = const {}, String? body, int limit = 4 * 1024 * 1024}) async {
  try {
    await checkPublicHost(url);
  } on StateError catch (e) {
    throw ExtensionError(e.message);
  }
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  try {
    final response = await dio.request<ResponseBody>(
      url.toString(),
      data: body,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: false,
        validateStatus: (_) => true,
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        maxRedirects: 0,
      ),
    );
    final collected = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      collected.add(chunk);
      if (collected.length > limit) throw ExtensionError('The answer is too big (at most ${limit ~/ (1024 * 1024)} MB).');
    }
    return {
      'status': response.statusCode,
      'headers': {for (final e in response.headers.map.entries) e.key: e.value.join(', ')},
      'body': base64Encode(collected.takeBytes()),
    };
  } finally {
    dio.close(force: true);
  }
}

/// `storage.json` of an extension.
class _Storage extends ExtensionStorage {
  final Future<File> Function() _file;
  _Storage(this._file);

  @override
  Future<Map<String, Object?>> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> write(Map<String, Object?> values) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(values));
  }
}
