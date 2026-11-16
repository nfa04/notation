import 'dart:io' show File, FileSystemException;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_factory_io.dart' if (dart.library.js_interop) 'database_factory_web.dart';
import 'database_schema.dart';

/// Opens (and creates / migrates) the notes database.
class AppDatabase {
  /// Call once before [open] on desktop; no-op elsewhere is fine to keep.
  static void initFfi() {
    databaseFactory = makeDatabaseFactories().first;
  }

  /// [path] defaults to `notes.db` in the app's data directory; pass
  /// [inMemoryDatabasePath] in tests.
  static Future<Database> open({String? path}) async {
    // (the web has no data directory: the database is named, and the browser keeps it)
    final dbPath = path ?? (kIsWeb ? 'notes.db' : p.join((await getApplicationSupportDirectory()).path, 'notes.db'));
    final options = OpenDatabaseOptions(
        version: schemaVersion,
        // cascades and SET NULL only work with this on, and it is per connection
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // a write-ahead log makes a small change cost one append instead of several syncs of the
          // whole file; NORMAL still survives a crash of the app (only a power cut can lose the last
          // commit). They are asked as queries: some platforms refuse these as statements.
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.rawQuery('PRAGMA synchronous = NORMAL');
        },
        onCreate: (db, _) async {
          for (final sql in createStatements) {
            await db.execute(sql);
          }
        },
        // a newer build made this database: its tables are not what this build knows, and writing this build's number into it (which
        // sqflite does when nothing is said) would make the newer build run its upgrades a second time when it opens it again
        onDowngrade: (db, from, to) async => throw StateError(
            'The notes were last opened by a newer version of the app (database version $from, this version knows $to). Install that version again.'),
        onUpgrade: (db, from, to) async {
          for (var v = from; v < to; v++) {
            for (final sql in migrations[v] ?? const <String>[]) {
              try {
                await db.execute(sql);
              } on DatabaseException catch (e) {
                // a column added by an earlier step of the same upgrade (or by a build that did not number it right) is there already
                if (!e.toString().contains('duplicate column name')) rethrow;
              }
            }
          }
        },
      );
    if (!kIsWeb && path != inMemoryDatabasePath) await backUpBeforeUpgrade(dbPath);
    // (on the web the first way of running SQLite may be refused by the browser: the next is tried, and what failed is logged)
    Object? failure;
    for (final factory in makeDatabaseFactories()) {
      try {
        final db = await factory.openDatabase(dbPath, options: options);
        databaseFactory = factory;
        return db;
      } catch (e) {
        debugPrint('The database could not be opened that way: $e');
        failure ??= e;
      }
    }
    throw failure!;
  }

  /// The version of the schema a database file says it has (its `user_version`, read from the header without opening it), or null if
  /// there is no such file or it is not a database.
  static Future<int?> fileVersion(String path) async {
    try {
      final f = await File(path).open();
      try {
        final header = await f.read(100);
        if (header.length < 100 || String.fromCharCodes(header.sublist(0, 15)) != 'SQLite format 3') return null;
        return ByteData.sublistView(header).getUint32(60); // (big-endian, as SQLite writes it)
      } finally {
        await f.close();
      }
    } on FileSystemException {
      return null;
    }
  }

  /// Before an upgrade of the schema, the database (and its write-ahead log, which may hold the last commits) is copied beside it as
  /// `<name>.before-upgrade`: an upgrade that goes wrong half way, or a build with a broken step, leaves a copy to go back to. One copy
  /// is kept, the one from before the last upgrade. Nothing is copied when the database is new or up to date.
  static Future<void> backUpBeforeUpgrade(String path) async {
    final version = await fileVersion(path);
    if (version == null || version == 0 || version >= schemaVersion) return;
    final copy = '$path.before-upgrade';
    try {
      await File(path).copy(copy);
      final wal = File('$path-wal');
      if (await wal.exists()) {
        await wal.copy('$copy-wal');
      } else {
        await File('$copy-wal').delete().catchError((Object _) => File('$copy-wal'));
      }
      debugPrint('The database (version $version) was copied to $copy before its upgrade to version $schemaVersion');
    } on FileSystemException catch (e) {
      // (no room for the copy: the upgrade goes ahead, as it did before there were copies)
      debugPrint('The database could not be copied before its upgrade: $e');
    }
  }
}
