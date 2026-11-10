import 'dart:io' show Platform;
import '../l10n/language.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Where a looked-up word is searched.
enum LookupSource {
  web('Web'),
  wikipedia('Wikipedia'),
  translate('Translate'),
  synonyms('Synonyms');

  final String label;
  const LookupSource(this.label);

  Uri urlFor(String term, {String language = 'en'}) {
    final q = Uri.encodeQueryComponent(term);
    return switch (this) {
      LookupSource.translate => Uri.parse('https://translate.google.com/?sl=auto&tl=$language&text=$q&op=translate'),
      LookupSource.web => Uri.parse('https://duckduckgo.com/?q=$q'),
      LookupSource.wikipedia => Uri.parse('https://en.wikipedia.org/w/index.php?search=$q'),
      // a thesaurus in the language of the app (German has its own, open one)
      LookupSource.synonyms => AppLanguage.instance.code == 'de'
          ? Uri.parse('https://www.openthesaurus.de/synonyme/${Uri.encodeComponent(term.trim())}')
          : Uri.parse('https://www.thesaurus.com/browse/${Uri.encodeComponent(term.trim().toLowerCase())}'),
    };
  }
}

/// Languages offered as the target of a translation: code -> name.
const translateLanguages = {
  'en': 'English',
  'de': 'Deutsch',
  'fr': 'Français',
  'es': 'Español',
  'it': 'Italiano',
  'pt': 'Português',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'ru': 'Русский',
  'tr': 'Türkçe',
  'ar': 'العربية',
  'zh-CN': '中文',
  'ja': '日本語',
  'ko': '한국어',
};

/// Text worth translating: a word up to a few paragraphs, but not a formula.
bool isTranslatable(String? text) {
  final t = text?.trim();
  return t != null &&
      t.length <= 500 &&
      RegExp(r'\p{L}{2}', unicode: true).hasMatch(t) &&
      !t.contains(RegExp(r'[=^\\$]'));
}

final _word = r"\p{L}[\p{L}'’\-]*";
final _lookupTerm = RegExp('^$_word(\\s+$_word)?\$', unicode: true);
final _plainWords = RegExp("^$_word(\\s+$_word)*\$", unicode: true);

/// One or two words (no digits or symbols): something worth looking up.
bool isLookupTerm(String? text) {
  final t = text?.trim();
  return t != null && t.length <= 60 && _lookupTerm.hasMatch(t);
}

/// Only words, at least two letters each: prose, not a formula.
bool isPlainWords(String? text) {
  final t = text?.trim();
  return t != null && _plainWords.hasMatch(t) && t.split(RegExp(r'\s+')).every((w) => w.length >= 2);
}

/// Whether pages can be shown inside the app on this platform; elsewhere they
/// open in the browser.
bool get webViewSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

Future<void> openInBrowser(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

typedef WebPageBuilder = Widget Function(Uri url);

/// The page the web view has reached (after links were followed) and its title.
typedef PageReport = void Function(Uri url, String? title);

/// The text that links [url] in a note: Markdown, which the note's text shows as a link.
String markdownLink(Uri url, String? title) {
  final name = (title ?? '').replaceAll(RegExp(r'[\[\]\s]+'), ' ').trim();
  final address = url.toString().replaceAll(' ', '%20').replaceAll(')', '%29').replaceAll('(', '%28');
  return '[${name.isEmpty ? url.host : name}]($address)';
}

class _WebPage extends StatefulWidget {
  final Uri url;
  final PageReport? onPage;

  /// Told what is selected on the page (empty when nothing is).
  final ValueChanged<String>? onSelection;
  const _WebPage({super.key, required this.url, this.onPage, this.onSelection});

  @override
  State<_WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<_WebPage> {
  int _progress = 0;
  bool _loading = true;

  /// Tells the app what is selected on the page, whenever the selection changes.
  static const _watchSelection = '''
    (function () {
      if (window.__uniSelection) return;
      window.__uniSelection = true;
      document.addEventListener('selectionchange', function () {
        UniSelection.postMessage(String(window.getSelection()).slice(0, 8000));
      });
    })();
  ''';

  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel('UniSelection', onMessageReceived: (m) => widget.onSelection?.call(m.message))
    ..setNavigationDelegate(NavigationDelegate(
      onPageStarted: (_) {
        widget.onSelection?.call('');
        _set(() => _loading = true);
      },
      onProgress: (p) => _set(() => _progress = p),
      onPageFinished: (url) async {
        _set(() => _loading = false);
        if (widget.onSelection != null) {
          try {
            await _controller.runJavaScript(_watchSelection);
          } catch (_) {} // a page that does not let scripts run
        }
        final reached = Uri.tryParse(url);
        if (reached == null || widget.onPage == null) return;
        String? title;
        try {
          title = await _controller.getTitle();
        } catch (_) {}
        widget.onPage!(reached, title);
      },
      onWebResourceError: (_) => _set(() => _loading = false),
    ))
    ..loadRequest(widget.url);

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: WebViewWidget(controller: _controller)),
      // a bar that fills as the page arrives; indeterminate until the first progress
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: AnimatedOpacity(
          opacity: _loading ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 250),
          child: LinearProgressIndicator(
            key: const ValueKey('lookup-loading'),
            minHeight: 3,
            value: _progress > 0 && _progress < 100 ? _progress / 100 : null,
          ),
        ),
      ),
      if (_loading && _progress < 15)
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: Theme.of(context,).colorScheme.surface.withValues(alpha: 0.7),
              child: const Center(child: CircularProgressIndicator.adaptive(),),
            ),
          ),
        ),
    ]);
  }
}

/// A web page about [term] beside (or over) the note: search results or the
/// Wikipedia article, switchable.
class LookupPanel extends StatefulWidget {
  final String term;
  final LookupSource source;

  /// A page to show as it is (a link from the note), instead of a search for [term]:
  /// the choice of source is then hidden.
  final Uri? address;
  final VoidCallback onClose;
  final WebPageBuilder? page;

  /// Puts a link to the page on the note (the page now shown, and its title).
  /// The button is only there when this is given.
  final void Function(Uri url, String? title)? onLinkPage;

  /// Puts text selected on the page into a text box on the note. The button
  /// for it shows while something is selected.
  final ValueChanged<String>? onAddText;

  /// What is selected on the page; the panel keeps its own unless given one
  /// (the tests stand in for the web view with it).
  final ValueNotifier<String>? selection;

  /// The language translations go to, and what to do when the user changes it.
  final String language;
  final ValueChanged<String>? onLanguage;

  const LookupPanel({
    super.key,
    required this.term,
    required this.source,
    this.address,
    required this.onClose,
    this.page,
    this.onLinkPage,
    this.onAddText,
    this.selection,
    this.language = 'en',
    this.onLanguage,
  });

  @override
  State<LookupPanel> createState() => _LookupPanelState();
}

class _LookupPanelState extends State<LookupPanel> {
  late LookupSource _source = widget.source;
  late String _language = widget.language;

  late final ValueNotifier<String> _selected = widget.selection ?? ValueNotifier('');

  /// Whether the text goes into the note with a link to where it came from.
  bool _withSource = true;

  @override
  void dispose() {
    if (widget.selection == null) _selected.dispose();
    super.dispose();
  }

  // where the page has got to by following links; reset when another page is asked for
  Uri? _reached;
  String? _reachedTitle;
  Uri? _asked;

  @override
  void didUpdateWidget(LookupPanel old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source || old.term != widget.term) _source = widget.source;
    if (old.address != widget.address) _asked = null;
  }

  void _report(Uri url, String? title) {
    _reached = url;
    _reachedTitle = title;
  }

  Widget _page(Uri url) {
    if (_asked != url) {
      _asked = url;
      _reached = null;
      _reachedTitle = null;
    }
    return _WebPage(key: ValueKey(url), url: url, onPage: _report, onSelection: widget.onAddText == null ? null : (t) => _selected.value = t.trim());
  }

  void _addSelection(Uri asked) {
    final text = _selected.value.trim();
    if (text.isEmpty) return;
    final url = _reached ?? asked;
    final title = _reached == null ? widget.term : _reachedTitle;
    widget.onAddText!(_withSource ? '$text\n\n${markdownLink(url, title)}' : text);
  }

  /// The strip under the page: what is selected there, and the button that takes it.
  Widget _selectionBar(BuildContext context, Uri asked) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String>(
      valueListenable: _selected,
      builder: (context, text, _) {
        if (text.isEmpty) return const SizedBox.shrink();
        return Material(
          key: const ValueKey('lookup-selection'),
          color: scheme.secondaryContainer,
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text.verbatim(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSecondaryContainer)),
                  InkWell(
                    key: const ValueKey('lookup-with-source'),
                    onTap: () => setState(() => _withSource = !_withSource),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_withSource ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: scheme.onSecondaryContainer),
                      const SizedBox(width: 4),
                      Text('with a link to the page', style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('lookup-add-text'),
                onPressed: () => _addSelection(asked),
                icon: const Icon(Icons.note_add_outlined, size: 18),
                label: const Text('Add to the note'),
              ),
            ]),
          ),
        );
      },
    );
  }

  void _link(Uri asked) {
    final url = _reached ?? asked;
    final title = _reached == null ? (widget.address != null ? widget.term : '${widget.term} (${tr(_source.label)})') : _reachedTitle;
    widget.onLinkPage!(url, title);
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.address ?? _source.urlFor(widget.term, language: _language);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(children: [
            Expanded(
              child: Text.verbatim(widget.term, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
            ),
            if (widget.onLinkPage != null)
              IconButton(
                key: const ValueKey('lookup-link'),
                tooltip: tr('Link this page on the note'),
                icon: const Icon(Icons.add_link, size: 20),
                onPressed: () => _link(url),
              ),
            IconButton(
              tooltip: tr('Open in the browser'),
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => openInBrowser(url),
            ),
            IconButton(
              key: const ValueKey('lookup-close'),
              tooltip: tr('Close'),
              icon: const Icon(Icons.close, size: 20),
              onPressed: widget.onClose,
            ),
          ]),
        ),
        if (widget.address == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            key: const ValueKey('lookup-source'),
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final s in LookupSource.values)
                ChoiceChip(
                  label: Text(s.label),
                  visualDensity: VisualDensity.compact,
                  selected: _source == s,
                  onSelected: (_) => setState(() => _source = s),
                ),
              if (_source == LookupSource.translate)
                DropdownButton<String>(
                  key: const ValueKey('lookup-language'),
                  value: _language,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final e in translateLanguages.entries) DropdownMenuItem(value: e.key, child: Text.verbatim(tr('to {language}', {'language': e.value}))),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _language = v);
                    widget.onLanguage?.call(v);
                  },
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: (widget.page ?? _page)(url)),
        if (widget.onAddText != null) _selectionBar(context, url),
      ]),
    );
  }
}
