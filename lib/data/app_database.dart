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
}
