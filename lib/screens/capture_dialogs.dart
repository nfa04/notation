import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../capture/capture_link.dart';
import '../capture/capture_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// A note to write something in right away. It is kept in the Inbox. The answer is what was made, null when cancelled.
Future<Captured?> showQuickNote(BuildContext context, CaptureService capture) => showDialog<Captured>(
      context: context,
      builder: (context) => _CaptureDialog(capture: capture, title: tr('Quick note'), link: const QuickCaptureLink()),
    );

/// Asks for the address of a web page and keeps its article as a note; the dialog also tells how to do it from a browser.
Future<Captured?> showClipPage(BuildContext context, CaptureService capture) => showDialog<Captured>(
      context: context,
      builder: (context) => _ClipPageDialog(capture: capture),
    );

/// Asks whether to keep what a link or another app handed over (see [parseCaptureLink]). The person can change the title and, for
/// text, the text itself, first.
Future<Captured?> showCaptureLink(BuildContext context, CaptureService capture, CaptureLink link) => showDialog<Captured>(
      context: context,
      builder: (context) => _CaptureDialog(capture: capture, title: link is ClipLink ? tr('Keep this page?') : tr('Keep this in the Inbox?'), link: link),
    );

class _CaptureDialog extends StatefulWidget {
  final CaptureService capture;
  final String title;
  final CaptureLink link;

  const _CaptureDialog({required this.capture, required this.title, required this.link});

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  late final TextEditingController _name;
  late final TextEditingController _text;
  bool _busy = false;
  String? _problem;

  CaptureLink get _link => widget.link;

  @override
  void initState() {
    super.initState();
    final l = _link;
    _name = TextEditingController(text: switch (l) { QuickCaptureLink() => l.title ?? '', ClipLink() => l.title ?? '' });
    _text = TextEditingController(text: switch (l) { QuickCaptureLink() => l.text, ClipLink() => l.selection });
  }

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final l = _link;
      final name = _name.text.trim();
      final Captured result = switch (l) {
        QuickCaptureLink(file: final f?) => await widget.capture.sharedFile(f),
        QuickCaptureLink() => await widget.capture.sharedText(_text.text, subject: name.isEmpty ? null : name),
        ClipLink() when _text.text.trim().isNotEmpty => await widget.capture.clipSelection(url: l.url, title: name.isEmpty ? null : name, text: _text.text),
        ClipLink() => await widget.capture.clipPage(l.url, fallbackTitle: name.isEmpty ? null : name),
      };
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = _link;
    final file = l is QuickCaptureLink ? l.file : null;
    return PlatformAlertDialog(
      title: Text.verbatim(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (l is ClipLink) Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(l.url.toString(), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))),
            if (file != null)
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.attach_file), title: Text.verbatim(p.basename(file)))
            else ...[
              TextField(key: const ValueKey('capture-title'), controller: _name, decoration: InputDecoration(labelText: tr('Title (optional)'))),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('capture-text'),
                controller: _text,
                autofocus: l is QuickCaptureLink,
                minLines: 4,
                maxLines: 10,
                decoration: InputDecoration(
                  labelText: l is ClipLink ? tr('Selected text (leave empty to keep the whole article)') : tr('Text'),
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('capture-problem'), style: TextStyle(color: scheme.error))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('capture-save'),
          onPressed: _busy ? null : _save,
          child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2)) : const Text('Save to Inbox'),
        ),
      ],
    );
  }
}

class _ClipPageDialog extends StatefulWidget {
  final CaptureService capture;

  const _ClipPageDialog({required this.capture});

  @override
  State<_ClipPageDialog> createState() => _ClipPageDialogState();
}

class _ClipPageDialogState extends State<_ClipPageDialog> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    var text = _url.text.trim();
    if (text.isNotEmpty && !text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      setState(() => _problem = tr('That is not a web address.'));
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final result = await widget.capture.clipPage(uri);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('Keep a web page'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              key: const ValueKey('clip-url'),
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: tr('Web address'), hintText: 'https://'),
              onSubmitted: (_) => _busy ? null : _save(),
            ),
            if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('clip-problem'), style: TextStyle(color: scheme.error))),
            const SizedBox(height: 16),
            Text('The article of the page is kept as a note in the Inbox, without menus and ads.', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('From your browser'),
              children: [
                Text('Make a bookmark in your browser and give it this as its address. Pressing it on a page sends the page, and the text you selected, here.', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                  child: SelectableText(webClipperBookmarklet, key: const ValueKey('clip-bookmarklet'), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('clip-copy'),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                    onPressed: () => Clipboard.setData(const ClipboardData(text: webClipperBookmarklet)),
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('clip-save'),
          onPressed: _busy ? null : _save,
          child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2)) : const Text('Keep'),
        ),
      ],
    );
  }
}

/// Says that something was kept, with a button to open it.
void announceCaptured(BuildContext context, Captured result, VoidCallback open) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text.verbatim(tr('Kept in the Inbox: {title}', {'title': result.title})),
      action: SnackBarAction(label: tr('Open'), onPressed: open),
    ));
}
