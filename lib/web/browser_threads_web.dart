import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The threads the runtime of the models can use in this page: half the cores, between 2 and 8, as on the other platforms. A page
/// that is not cross-origin isolated (the server does not send the headers of web/.htaccess) has no shared memory, and the
/// runtime has one thread whatever is asked for. web/index.html decides the same for the runtime itself.
int browserThreads() {
  final isolated = (globalContext['crossOriginIsolated'] as JSBoolean?)?.toDart ?? false;
  if (!isolated) return 1;
  return (web.window.navigator.hardwareConcurrency ~/ 2).clamp(2, 8);
}
