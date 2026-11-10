/// A browser that is used for a while only ("Connect temporarily" in the sync settings): what is kept of it, and the warning
/// before the tab is closed.
library;

export 'temporary_session_io.dart' if (dart.library.js_interop) 'temporary_session_web.dart';
