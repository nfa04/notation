import 'dart:async';
import 'dart:io';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web/web.dart' as web;

import 'package:file/memory.dart';
import 'package:file/file.dart' as f;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The files of the web. A browser has no file system the app can open files in, so the rest of the app, which reads and
/// writes `dart:io` files, gets a file system that lives in memory. What is kept under /support (the PDFs and pictures of the
/// notes) is copied into the browser's IndexedDB ([keepWebFiles]) and put back when the page is opened again.
final MemoryFileSystem _fs = MemoryFileSystem();

void installWebFiles() {
  _fs.directory('/support').createSync(recursive: true);
  _fs.directory('/tmp').createSync(recursive: true);
  IOOverrides.global = _WebOverrides();
  PathProviderPlatform.instance = _WebPaths();
}

base class _WebOverrides extends IOOverrides {
  @override
  Directory createDirectory(String path) => _fs.directory(path);

  @override
  File createFile(String path) => _fs.file(path);

  @override
  Link createLink(String path) => _fs.link(path);

  @override
  Directory getCurrentDirectory() => _fs.directory('/');

  @override
  Directory getSystemTempDirectory() => _fs.directory('/tmp');

  @override
  Future<FileStat> stat(String path) => _fs.stat(path);

  @override
  FileStat statSync(String path) => _fs.statSync(path);

  @override
  Future<bool> fseIdentical(String a, String b) => _fs.identical(a, b);

  @override
  bool fseIdenticalSync(String a, String b) => _fs.identicalSync(a, b);

  @override
  bool fsWatchIsSupported() => false;
}

class _WebPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => '/support';

  @override
  Future<String?> getApplicationDocumentsPath() async => '/support';

  @override
  Future<String?> getTemporaryPath() async => '/tmp';

  @override
  Future<String?> getLibraryPath() async => '/support';
}


/// Puts back the files kept under /support and keeps every change to them in the browser from then on.
///
/// They are kept in an IndexedDB store of their own, one entry per file, and not in the database: the browser's SQLite holds its
/// whole database in memory, so a PDF there would be in memory twice. [db] is only read once, for files an earlier version kept
/// in it. The browser is also asked to keep the site's storage for good (otherwise it may clear it when the disk is full).
///
/// The weights of a model (hundreds of MB) are not read at the start: such a file is there but empty ([_lazy]) until
/// [ensureWebFile] reads it, which is done right before the model is opened.
Future<void> keepWebFiles(Database db) async {
  unawaited(_askToPersist());
  final store = _store = await _FileStore.open();
  for (final path in await store.keys()) {
    final file = _fs.file(path);
    file.parent.createSync(recursive: true);
    if (_isWeights(path)) {
      file.writeAsBytesSync(const []);
      _lazy.add(path);
    } else {
      file.writeAsBytesSync(await store.get(path) ?? Uint8List(0));
    }
    _known[path] = _signature(file);
  }
  // what an earlier version kept in the database moves to the store
  try {
    for (final row in await db.query('web_files')) {
      final path = row['path']! as String;
      final bytes = row['data']! as Uint8List;
      if (!_known.containsKey(path)) {
        await store.put(path, bytes);
        final file = _fs.file(path);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        _known[path] = _signature(file);
      }
    }
    await db.execute('DROP TABLE web_files');
  } catch (_) {
    // (no such table: nothing to move)
  }

  var busy = false;
  Future<void> save() async {
    if (busy) return;
    busy = true;
    try {
      final now = <String, int>{};
      for (final e in _fs.directory('/support').listSync(recursive: true)) {
        if (e is f.File) now[e.path] = _signature(e);
      }
      for (final e in now.entries) {
        if (_known[e.key] == e.value) continue;
        _lazy.remove(e.key); // (written anew: what is in the store is the old one)
        await store.put(e.key, _fs.file(e.key).readAsBytesSync());
        _known[e.key] = e.value;
      }
      for (final gone in _known.keys.where((k) => !now.containsKey(k)).toList()) {
        await store.delete(gone);
        _known.remove(gone);
        _lazy.remove(gone);
      }
    } catch (e) {
      debugPrint('The files could not be kept in the browser: $e'); // (the next turn tries again)
    } finally {
      busy = false;
    }
  }

  Timer.periodic(const Duration(seconds: 2), (_) => save());
  // a page that is hidden may be closed without another word: what changed is kept now
  web.document.addEventListener(
      'visibilitychange',
      (web.Event _) {
        if (web.document.visibilityState == 'hidden') unawaited(save());
      }.toJS);
}

_FileStore? _store;

/// What each kept file was like when it was last put in the store (size and time), to see what changed.
final Map<String, int> _known = {};

/// Files that are in the store but were left empty here until they are needed.
final Set<String> _lazy = {};

/// The big files of models: read when the model is opened, not at the start.
bool _isWeights(String path) =>
    path.startsWith('/support/models/') && RegExp(r'\.(onnx|onnx_data(_\d+)?|ort|bin)$').hasMatch(path);

/// Makes sure the file at [path] has its content (see [keepWebFiles]).
Future<void> ensureWebFile(String path) async {
  if (!_lazy.contains(path)) return;
  final bytes = await _store?.get(path);
  if (bytes == null) return;
  final file = _fs.file(path)..writeAsBytesSync(bytes);
  _known[path] = _signature(file);
  _lazy.remove(path);
}

/// The content of the file at [path] for the runtime of a model. A file that is only in the store is read from there and not put
/// in the memory file system first (a copy less, of hundreds of MB).
Future<Uint8List> webFileBytes(String path) async {
  if (_lazy.contains(path)) {
    final bytes = await _store?.get(path);
    if (bytes != null) return bytes;
  }
  return _fs.file(path).readAsBytes();
}

/// Lets go of the content of the file at [path] again, which stays in the store (a model that was opened has its own copy).
Future<void> releaseWebFile(String path) async {
  if (!_isWeights(path) || !_known.containsKey(path) || _lazy.contains(path)) return;
  final file = _fs.file(path);
  if (_signature(file) != _known[path]) return; // (changed and not kept yet: it stays)
  file.writeAsBytesSync(const []);
  _known[path] = _signature(file);
  _lazy.add(path);
}

Future<void> _askToPersist() async {
  try {
    final storage = web.window.navigator.storage;
    if (!(await storage.persisted().toDart).toDart) await storage.persist().toDart;
  } catch (_) {
    // (an older browser: it keeps what it keeps)
  }
}

int _signature(f.File file) => Object.hash(file.lengthSync(), file.lastModifiedSync().microsecondsSinceEpoch);

/// One IndexedDB object store, path -> bytes.
class _FileStore {
  static const _name = 'notation-files', _store = 'files';
  final web.IDBDatabase _db;
  _FileStore._(this._db);

  static Future<_FileStore> open() async {
    final request = web.window.indexedDB.open(_name, 1);
    request.onupgradeneeded = (web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
    }.toJS;
    return _FileStore._(await _done(request) as web.IDBDatabase);
  }

  web.IDBObjectStore _objects(String mode) => _db.transaction(_store.toJS, mode).objectStore(_store);

  /// A file bigger than [_chunk] is kept in pieces (under keys `path\u0000n`) with a marker string under `path` itself, written
  /// last: one huge value is refused by some browsers, and a view of a typed array would be cloned with its whole buffer.
  static const _chunk = 32 * 1024 * 1024;

  Future<List<String>> keys() async => [
        for (final k in (await _done(_objects('readonly').getAllKeys()) as JSArray<JSAny?>).toDart)
          if (!(k as JSString).toDart.contains('\u0000')) k.toDart
      ];

  Future<Uint8List?> get(String path) async {
    final v = await _done(_objects('readonly').get(path.toJS));
    if (v == null) return null;
    if (v.isA<JSString>()) {
      final fields = (v as JSString).toDart.split(':'); // chunks:<pieces>[:<bytes>]
      final n = int.parse(fields[1]);
      final total = fields.length > 2 ? int.parse(fields[2]) : null;
      final whole = total == null ? null : Uint8List(total);
      final parts = <Uint8List>[];
      var at = 0;
      for (var i = 0; i < n; i++) {
        final part = (await _done(_objects('readonly').get('$path\u0000$i'.toJS)) as JSUint8Array?)?.toDart;
        if (part == null) return null; // (kept only in part: as if it was not there)
        if (whole != null) {
          whole.setRange(at, at + part.length, part); // (one piece at a time: the whole is there once)
          at += part.length;
        } else {
          parts.add(part);
        }
      }
      if (whole != null) return whole;
      final joined = BytesBuilder(copy: false);
      parts.forEach(joined.add);
      return joined.takeBytes();
    }
    return (v as JSUint8Array).toDart;
  }

  Future<void> put(String path, Uint8List bytes) async {
    await delete(path);
    if (bytes.length <= _chunk) {
      await _done(_objects('readwrite').put(bytes.toJS, path.toJS));
      return;
    }
    var n = 0;
    for (var at = 0; at < bytes.length; at += _chunk, n++) {
      final piece = Uint8List.fromList(Uint8List.sublistView(bytes, at, at + _chunk > bytes.length ? bytes.length : at + _chunk));
      await _done(_objects('readwrite').put(piece.toJS, '$path\u0000$n'.toJS));
    }
    await _done(_objects('readwrite').put('chunks:$n:${bytes.length}'.toJS, path.toJS));
  }

  Future<void> delete(String path) async {
    await _done(_objects('readwrite').delete(path.toJS));
    await _done(_objects('readwrite').delete(web.IDBKeyRange.bound('$path\u0000'.toJS, '$path\u0001'.toJS)));
  }
}

/// What [request] gives, when it is done.
Future<JSAny?> _done(web.IDBRequest request) {
  final c = Completer<JSAny?>();
  request.onsuccess = (web.Event _) {
    c.complete(request.result);
  }.toJS;
  request.onerror = (web.Event _) {
    if (!c.isCompleted) c.completeError(StateError('IndexedDB: ${request.error?.message}'));
  }.toJS;
  return c.future;
}
