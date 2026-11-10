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

  const InstalledExtension(this.manifest, this.script, {this.enabled = false, this.granted = const {}});

  String get id => manifest.id;

  InstalledExtension copyWith({bool? enabled, Set<ExtensionPermission>? granted}) =>
      InstalledExtension(manifest, script, enabled: enabled ?? this.enabled, granted: granted ?? this.granted);
}

/// An extension as it comes (a zip, or text), checked but not installed: what the person is shown before they say yes.
class ExtensionPackage {
  final ExtensionManifest manifest;
  final String manifestText, script;
  const ExtensionPackage(this.manifest, this.manifestText, this.script);
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
    this.addTask,
    this.bus,
  })  : _directory = directory ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'extensions'))),
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
          final script = await File(p.join(dir.path, manifest.main)).readAsString();
          final s = state[manifest.id];
          final granted = <ExtensionPermission>{
            if (s is Map && s['granted'] is List)
              for (final g in s['granted'] as List) ...[?ExtensionPermission.byId('$g')].where(manifest.permissions.contains),
          };
          _installed[manifest.id] = InstalledExtension(manifest, script, enabled: s is Map && s['enabled'] == true, granted: granted);
        } catch (e) {
          debugPrint('[extensions] ${dir.path} is not an extension: $e');
        }
      }
    }
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
    return installSource(package.manifestText, package.script);
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
    return inspectSource(manifestText, utf8.decode(scriptFile.content as List<int>, allowMalformed: true));
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
  ExtensionPackage inspectSource(String manifestText, String script) {
    final manifest = _parse(manifestText);
    if (script.trim().isEmpty) throw ManifestException('The script is empty.');
    if (script.length > 256 * 1024) throw ManifestException('The script is too big (at most 256 KB).');
    return ExtensionPackage(manifest, manifestText, script);
  }

  /// Installs an extension from its manifest and its script as text.
  Future<InstalledExtension> installSource(String manifestText, String script) async {
    final manifest = inspectSource(manifestText, script).manifest;
    final dir = Directory(p.join((await _directory()).path, manifest.id));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'manifest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    await File(p.join(dir.path, manifest.main)).writeAsString(script);
    final before = _installed[manifest.id];
    final installed = InstalledExtension(
      manifest,
      script,
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

  Future<ExtensionRun> _run(InstalledExtension e, String kind, String id, Map<String, Object?> context, ExtensionApi api) => _one(() {
        final live = _installed[e.id] ?? e;
        // whoever asks, an extension that is off does not run (the permissions are read now too, so a taken-back one counts at once)
        if (!live.enabled) return Future.value(const ExtensionRun(error: 'This extension is switched off.'));
        return ExtensionRuntime(
          manifest: live.manifest,
          script: live.script,
          granted: live.granted,
          api: api,
          storage: _storageOf(live.id),
          fetch: _fetch,
          emit: (name, data) => _emit(live, context, name, data),
          engineFactory: _engine,
        ).run(kind, id, context);
      });

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
  Future<String> runAction(InstalledExtension e, ExtensionActionDef action, {required Map<String, Object?> event, required ExtensionApi api}) async {
    if (!canRun) return 'Extensions cannot run on this device.';
    final r = await _run(e, 'action', action.id, event, api);
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
    final response = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 10))).request<List<int>>(
      url.toString(),
      data: body,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.bytes,
        followRedirects: false,
        validateStatus: (_) => true,
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        maxRedirects: 0,
      ),
    );
    final bytes = response.data ?? const <int>[];
    if (bytes.length > 1024 * 1024) throw ExtensionError('The answer is too big.');
    return {
      'status': response.statusCode,
      'headers': {for (final e in response.headers.map.entries) e.key: e.value.join(', ')},
      'body': utf8.decode(bytes, allowMalformed: true),
    };
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
