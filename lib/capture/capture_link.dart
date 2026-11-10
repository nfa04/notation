import 'package:path/path.dart' as p;
/// What a `notation://` link asks to be saved. Anyone can make such a link (a web page can send the browser to one), so the app
/// never saves from one without asking.
sealed class CaptureLink {
  const CaptureLink();
}

/// Text (or a shared file) to make a note of: `notation://capture?text=...&title=...` or `...?file=<path>`. With nothing in it,
/// it is a request for a note to write something in.
class QuickCaptureLink extends CaptureLink {
  final String text;
  final String? title;

  /// A file another app shared with this one (Android copies it to the cache folder first).
  final String? file;

  const QuickCaptureLink({this.text = '', this.title, this.file});
}

/// A page of the web to keep: `notation://clip?u=<address>&t=<title>&x=<selected text>`, as the bookmarklet makes it.
class ClipLink extends CaptureLink {
  final Uri url;
  final String? title;
  final String selection;

  const ClipLink(this.url, {this.title, this.selection = ''});
}

/// The longest text taken from a link.
const maxCaptureText = 200000;

/// What [uri] asks for, or null when it is not a capture link (or an unusable one).
CaptureLink? parseCaptureLink(Uri uri) {
  if (uri.scheme != 'notation') return null;
  final q = uri.queryParameters;
  String? clean(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
  switch (uri.host) {
    case 'capture':
      final text = q['text'] ?? '';
      return QuickCaptureLink(
        text: text.length > maxCaptureText ? text.substring(0, maxCaptureText) : text,
        title: clean(q['title']),
        file: clean(q['file']),
      );
    case 'clip':
      final url = Uri.tryParse(q['u'] ?? '');
      if (url == null || !(url.scheme == 'http' || url.scheme == 'https') || url.host.isEmpty) return null;
      final x = q['x'] ?? '';
      return ClipLink(url, title: clean(q['t']), selection: x.length > maxCaptureText ? x.substring(0, maxCaptureText) : x);
    default:
      return null;
  }
}

/// Whether a capture link may name the file [path]: only on a phone, and only inside the cache folder [cache], where the share of
/// Android puts what it hands over. On a computer the temporary folder is shared with every other program and user, so no link
/// there can name a file.
bool captureFileAllowed(String path, String cache, {required bool mobile}) => mobile && p.isAbsolute(path) && p.isWithin(cache, path);
