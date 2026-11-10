import 'package:flutter/foundation.dart' show kIsWeb;

/// The `User-Agent` the app names itself with towards the servers it talks to (a Nextcloud lists an app password under it).
///
/// Left out in the browser: a page is not supposed to set it, Firefox sends it anyway and names it in the CORS preflight
/// (`Access-Control-Request-Headers: user-agent`), and a server that does not list it there refuses the whole request. In a browser the
/// server sees the browser's own.
Map<String, String> get userAgentHeader => kIsWeb ? const {} : const {'User-Agent': 'Notation'};
