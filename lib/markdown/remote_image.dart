import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';

/// A picture in a note that lives on a web server. It is not fetched when the note opens: loading it tells whoever runs the server
/// the address of this device and when the note was read (a note that was sent to you can use that to follow you), and it makes this
/// device request an address the note chose, also one inside a private network. The person taps to load it, knowing which server.
class RemoteImage extends StatefulWidget {
  final String url;
  final String label;
  final double? width;
  final BoxFit? fit;
  final double fontSize;
  final Color? color;

  const RemoteImage({super.key, required this.url, this.label = '', this.width, this.fit, this.fontSize = 14, this.color});

  /// The pictures the person chose to load in this run of the app (so scrolling or editing the note does not ask again).
  static final Set<String> _allowed = {};

  /// Whether [url] is a web address a picture can be loaded from.
  static bool isWeb(String url) {
    final u = Uri.tryParse(url);
    return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
  }

  @visibleForTesting
  static void forgetAll() => _allowed.clear();

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final style = TextStyle(fontSize: widget.fontSize * 0.8, color: widget.color?.withValues(alpha: 0.7));
    Widget placeholder(String words) => Container(
          constraints: BoxConstraints(maxWidth: widget.width ?? 320),
          padding: const EdgeInsets.all(8),
          color: widget.color?.withValues(alpha: 0.06),
          child: Text.verbatim(words, style: style),
        );
    if (!RemoteImage.isWeb(url)) return placeholder('🖼 ${widget.label}');
    if (RemoteImage._allowed.contains(url)) {
      return Image.network(url, width: widget.width, fit: widget.fit, errorBuilder: (_, _, _) => placeholder('🖼 ${widget.label.isEmpty ? url : widget.label}'));
    }
    final host = Uri.parse(url).host;
    return InkWell(
      key: const ValueKey('remote-image-load'),
      onTap: () => setState(() => RemoteImage._allowed.add(url)),
      child: placeholder('🖼 ${tr('Tap to load the picture from {host}', {'host': host})}'),
    );
  }
}
