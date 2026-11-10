/// The files of the web (memory, kept in IndexedDB) where there is no disk; nothing elsewhere.
library;

export 'web_files_io.dart' if (dart.library.js_interop) 'web_files_web.dart';
