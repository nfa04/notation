import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The database factories of this platform: SQLite through dart:ffi.
List<DatabaseFactory> makeDatabaseFactories() {
  sqfliteFfiInit();
  return [databaseFactoryFfi];
}
