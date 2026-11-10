/// How many threads a model may use in a browser (and nothing to say elsewhere).
library;

export 'browser_threads_io.dart' if (dart.library.js_interop) 'browser_threads_web.dart';
