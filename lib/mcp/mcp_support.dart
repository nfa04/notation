import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether this build can offer the notes to an AI agent (see `McpService`): on a computer, where an agent runs beside the app. On a
/// phone the app is stopped as soon as it is not on the screen, and few agents run there. A build for another system leaves the
/// whole of it out: a check like this one, on the system the build is for, is known when the app is compiled.
bool get mcpSupported => !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);
