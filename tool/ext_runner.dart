import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:notes/extensions/door_results.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/import/import_source.dart';

/// Runs the cases in `<folder>/tests.json` against the extension in `<folder>` (its manifest and script, with every permission it asks
/// for given) and says what did not come out as written. A case:
///
/// ```json
/// { "name": "counts words", "kind": "tool", "id": "count",
///   "context": { "text": "a b c" },                      // what the handler is called with (tool, action, command...)
///   "note": { "id": "n1", "title": "T", "text": "..." }, // the open note, for note.get
///   "settings": { "mode": "fast" }, "files": { "dir/a.json": "text" or { "base64": "..." } },   // for importers
///   "fetches": { "https://api.example.com/x": { "status": 200, "body": "..." } },
///   "notes": [{ "id": "n2", "title": "Daily 2026-01-02" }],  // the other notes, for notes.search
///   "answers": { "confirm": true },                      // what the person says to ui.confirm / choose / form
///   "expect": { "value": <subset>, "error": "part of the message", "calls": ["insert:..."] } }
/// ```
///
/// `value` is compared as a subset (an object may have more keys than written; an array has to have the same length). An importer's
/// answer is checked like the app checks it, and `value` is compared with the notes it makes (attachments as their sizes). `calls` is
/// the list of the changes the script asked for, as `insert:text`, `replace:text`, `title:text`, `create:title`, `task:title`, `tag:id:tags`, `message:text`.
/// Returns the problems; empty when everything held.
Future<List<String>> runExtensionCases(Directory folder) async {
  final problems = <String>[];
  final manifestFile = File('${folder.path}/manifest.json');
  if (!manifestFile.existsSync()) return ['${folder.path}: no manifest.json'];
  final ExtensionManifest manifest;
  try {
    manifest = ExtensionManifest.fromJson(jsonDecode(manifestFile.readAsStringSync()));
  } on ManifestException catch (e) {
    return ['manifest: ${e.message}'];
  }
  var script = File('${folder.path}/${manifest.main}').readAsStringSync();
  script = [for (final m in manifest.modules) File('${folder.path}/$m').readAsStringSync(), script].join('\n;\n');
  final testsFile = File('${folder.path}/tests.json');
  if (!testsFile.existsSync()) return ['${manifest.id}: no tests.json'];
  final cases = (jsonDecode(testsFile.readAsStringSync()) as Map)['cases'] as List;
  for (final raw in cases.cast<Map>()) {
    final name = '${manifest.id}: ${raw['name'] ?? raw['id']}';
    try {
      final failure = await _runCase(manifest, script, raw.cast<String, Object?>());
      if (failure != null) problems.add('$name: $failure');
    } catch (e, s) {
      problems.add('$name: threw $e\n$s');
    }
  }
  return problems;
}

class _Api extends ExtensionApi {
  final calls = <String>[];
  final Map<String, Object?> note0;
  final List<SourceFile> files;
  final Map<String, Object?> answers;
  final List<Map<String, Object?>> notes;
  _Api(this.note0, this.files, this.answers, this.notes);

  @override
  Future<List<Map<String, Object?>>> searchNotes(String query, {int limit = 10}) async =>
      [for (final n in notes) if ('${n['title']}'.toLowerCase().contains(query.toLowerCase())) {'id': n['id'], 'title': n['title'], 'snippet': ''}];
  @override
  Future<void> tagNote(String id, List<String> tags) async => calls.add('tag:$id:${tags.join(',')}');

  @override
  Future<Map<String, Object?>> note() async => note0.isEmpty ? throw ExtensionError('There is no note here.') : note0;
  @override
  Future<void> insertText(String text) async => calls.add('insert:$text');
  @override
  Future<void> replaceSelection(String text) async => calls.add('replace:$text');
  @override
  Future<void> setTitle(String title) async => calls.add('title:$title');
  @override
  Future<String> createNote(String title, String text, {String? folder}) async {
    calls.add('create:$title');
    return 'new-${calls.length}';
  }

  @override
  Future<void> addTask(String title, {String? due}) async => calls.add('task:$title');
  @override
  void message(String text) => calls.add('message:$text');
  @override
  Future<Object?> askPerson(String kind, Map<String, Object?> args) async => answers[kind];
  @override
  Future<String> readImportFile(int index, {bool binary = false}) async {
    final bytes = await files[index].read();
    return binary ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true);
  }
}

class _Secrets extends ExtensionSecrets {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String? value) async => value == null ? map.remove(key) : map[key] = value;
}

class _Store extends ExtensionStorage {
  Map<String, Object?> data = {};
  @override
  Future<Map<String, Object?>> read() async => data;
  @override
  Future<void> write(Map<String, Object?> values) async => data = values;
}

Future<String?> _runCase(ExtensionManifest manifest, String script, Map<String, Object?> c) async {
  final kind = c['kind'] as String;
  final id = c['id'] as String;
  final files = <SourceFile>[
    for (final e in ((c['files'] as Map?) ?? const {}).entries)
      () {
        final v = e.value;
        final bytes = Uint8List.fromList(v is Map ? base64Decode(v['base64'] as String) : utf8.encode('$v'));
        return SourceFile('${e.key}', bytes.length, () async => bytes);
      }(),
  ];
  final api = _Api(
    ((c['note'] as Map?) ?? const {}).cast<String, Object?>(),
    files,
    ((c['answers'] as Map?) ?? const {}).cast<String, Object?>(),
    [for (final n in (c['notes'] as List?) ?? const []) (n as Map).cast<String, Object?>()],
  );
  final fetches = ((c['fetches'] as Map?) ?? const {}).cast<String, Object?>();
  final runtime = ExtensionRuntime(
    manifest: manifest,
    script: script,
    granted: manifest.permissions,
    api: api,
    storage: _Store(),
    secrets: _Secrets()..map.addAll({for (final e in ((c['secrets'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'}),
    settings: ((c['settings'] as Map?) ?? const {}).cast<String, Object?>(),
    heavy: kind == 'importer',
    fetch: (url, {method = 'GET', headers = const {}, body}) async {
      final hit = fetches[url.toString()] as Map?;
      if (hit == null) throw ExtensionError('No answer is written for ${url.toString()} in "fetches".');
      return {'status': hit['status'] ?? 200, 'headers': hit['headers'] ?? {}, 'body': hit['body'] ?? ''};
    },
    fetchBytes: (url, {method = 'GET', headers = const {}, body, limit = 0}) async {
      final hit = fetches[url.toString()] as Map?;
      if (hit == null) throw ExtensionError('No answer is written for ${url.toString()} in "fetches".');
      return {'status': hit['status'] ?? 200, 'headers': hit['headers'] ?? {}, 'body': hit['base64'] ?? ''};
    },
    limit: const Duration(seconds: 20),
  );
  final context = <String, Object?>{
    ...((c['context'] as Map?) ?? const {}).cast<String, Object?>(),
    if (kind == 'importer') 'files': [for (final f in files) {'path': f.path, 'name': f.name, 'size': f.size}],
  };
  final run = await runtime.run(kind, id, context);
  final expect = ((c['expect'] as Map?) ?? const {}).cast<String, Object?>();
  if (expect['error'] != null) {
    if (run.error == null) return 'expected the error "${expect['error']}" but it worked';
    return run.error!.contains('${expect['error']}') ? null : 'expected the error "${expect['error']}", got "${run.error}"';
  }
  if (run.error != null) return 'failed: ${run.error}';
  Object? value = run.value;
  if (kind == 'importer') {
    final result = parseImporterResult(value);
    value = {
      'notes': [
        for (final n in result.notes)
          {
            'path': n.path,
            'title': n.title,
            'markdown': n.markdown,
            'tags': n.tags,
            'sourceId': n.sourceId,
            'attachments': {for (final a in n.attachments.entries) a.key: a.value.length},
            if (n.pdf != null) 'pdf': {'name': n.pdf!.name, 'size': n.pdf!.bytes.length},
          },
      ],
      'notices': result.notices,
    };
  } else if (kind == 'exporter') {
    final file = parseExportedFile(value, manifest.exporters.firstWhere((e) => e.id == id).extension);
    value = {'name': file.name, 'text': utf8.decode(file.bytes, allowMalformed: true)};
  } else if (kind == 'block') {
    parseBlockDrawing(value);
  }
  if (expect.containsKey('value')) {
    final why = _subset(expect['value'], value, 'value');
    if (why != null) return why;
  }
  if (expect['calls'] != null) {
    final want = (expect['calls'] as List).cast<String>();
    if (api.calls.join('\n') != want.join('\n')) return 'calls were ${api.calls}, expected $want';
  }
  return null;
}

String? _subset(Object? want, Object? got, String where) {
  if (want is Map) {
    if (got is! Map) return '$where: expected an object, got ${jsonEncode(got)}';
    for (final e in want.entries) {
      final why = _subset(e.value, got['${e.key}'], '$where.${e.key}');
      if (why != null) return why;
    }
    return null;
  }
  if (want is List) {
    if (got is! List || got.length != want.length) return '$where: expected a list of ${want.length}, got ${got is List ? 'a list of ${got.length}' : jsonEncode(got)}';
    for (var i = 0; i < want.length; i++) {
      final why = _subset(want[i], got[i], '$where[$i]');
      if (why != null) return why;
    }
    return null;
  }
  if (want is String && want.startsWith('~')) {
    return got is String && got.contains(want.substring(1)) ? null : '$where: expected text containing "${want.substring(1)}", got ${jsonEncode(got)}';
  }
  return jsonEncode(want) == jsonEncode(got) ? null : '$where: expected ${jsonEncode(want)}, got ${jsonEncode(got)}';
}
