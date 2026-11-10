import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// The database factories of the web, best first: SQLite compiled to WebAssembly (`sqlite3.wasm`), run in a shared worker
/// (`sqflite_sw.js`), in a plain web worker, or in the page itself. Browsers differ in which of the first two they allow
/// (a private window, a phone, a page that is not served from a secure address), and the last one needs the least.
List<DatabaseFactory> makeDatabaseFactories() =>
    [databaseFactoryFfiWeb, databaseFactoryFfiWebBasicWebWorker, databaseFactoryFfiWebNoWebWorker];
