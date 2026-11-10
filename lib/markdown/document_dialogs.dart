import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../models/rich_text.dart';
import 'markdown_parser.dart';
import '../style/platform_dialog.dart';

/// The special characters offered, by group.
const symbolGroups = <String, String>{
  'Punctuation': '–—…•·§¶†‡«»‹›„“”‚‘’¡¿',
  'Signs': '©®™°±×÷≠≈≤≥∞√∑∏∫∂∆∇∈∉∩∪⊂⊃∧∨¬∀∃∅‰′″',
  'Currency': '€£¥¢₹₽₩₺₿¤',
  'Arrows': '←→↑↓↔↕⇐⇒⇑⇓⇔↺↻',
  'Greek': 'αβγδεζηθικλμνξοπρστυφχψωΓΔΘΛΞΠΣΦΨΩ',
  'Shapes': '✓✗★☆♥♦♣♠●○■□▲△◆◇☐☑☒',
  'Letters': 'äöüßÄÖÜàáâãåæçèéêëìíîïñòóôõøœùúûýÿ',
  'Fractions': '½⅓⅔¼¾⅛⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉',
};

/// Asks for a special character; the one tapped (null: none).
Future<String?> showSymbolPicker(BuildContext context) => showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Insert a special character'),
        content: SizedBox(
          width: 420,
          height: 380,
          child: ListView(children: [
            for (final g in symbolGroups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(g.key, style: Theme.of(context).textTheme.labelLarge),
              ),
              Wrap(children: [
                for (final c in g.value.runes.map(String.fromCharCode))
                  InkWell(
                    key: ValueKey('symbol-$c'),
                    onTap: () => Navigator.pop(context, c),
                    child: SizedBox(width: 38, height: 38, child: Center(child: Text.verbatim(c, style: const TextStyle(fontSize: 20)))),
                  ),
              ]),
            ],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
      ),
    );

/// Asks what the top and the bottom of the pages say; the two texts (null: cancelled).
Future<(String, String)?> showHeaderFooterDialog(BuildContext context, {String header = '', String footer = ''}) {
  final h = TextEditingController(text: header);
  final f = TextEditingController(text: footer);
  return showDialog<(String, String)>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: const Text('Header and footer'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(key: const ValueKey('doc-header-field'), controller: h, decoration: InputDecoration(labelText: tr('At the top of every page'))),
          const SizedBox(height: 12),
          TextField(key: const ValueKey('doc-footer-field'), controller: f, decoration: InputDecoration(labelText: tr('At the bottom of every page'))),
          const SizedBox(height: 12),
          Text('{page} is the number of the page, {pages} how many there are, {title} the title of the note, {date} today.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            ActionChip(
              key: const ValueKey('doc-footer-numbers'),
              label: const Text('Page numbers at the bottom'),
              onPressed: () => f.text = tr('Page {page} of {pages}'),
            ),
          ]),
          const SizedBox(height: 4),
          Text('They show on the pages of the exported PDF and Word file.', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('doc-header-footer-ok'), onPressed: () => Navigator.pop(context, (h.text, f.text)), child: const Text('OK')),
      ],
    ),
  ).whenComplete(() {
    h.dispose();
    f.dispose();
  });
}

/// Asks what a comment says ([initial]: what it says now, for one being changed). The text (empty: take the comment away; null:
/// cancelled).
Future<String?> showCommentDialog(BuildContext context, {String initial = ''}) {
  final said = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: Text(initial.isEmpty ? 'Add a comment' : 'Comment'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const ValueKey('comment-field'),
          controller: said,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(hintText: tr('What do you want to say about this?')),
        ),
      ),
      actions: [
        if (initial.isNotEmpty)
          TextButton(key: const ValueKey('comment-delete'), onPressed: () => Navigator.pop(context, ''), child: const Text('Delete')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('comment-ok'),
          onPressed: () => Navigator.pop(context, said.text.trim().isEmpty ? null : said.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(said.dispose);
}

/// Looks for a whole document: its named styles set together.
const documentThemes = <(String, Map<String, NamedStyle>)>[
  ('Plain', {}),
  ('Classic', {
    'body': NamedStyle(font: 'Serif'),
    'h1': NamedStyle(font: 'Serif', size: 22),
    'h2': NamedStyle(font: 'Serif', size: 17),
    'h3': NamedStyle(font: 'Serif', size: 14),
  }),
  ('Modern', {
    'h1': NamedStyle(size: 24, color: 0xFF1565C0),
    'h2': NamedStyle(size: 18, color: 0xFF1565C0),
    'h3': NamedStyle(size: 14, color: 0xFF424242),
  }),
  ('Report', {
    'body': NamedStyle(font: 'Serif', size: 11),
    'h1': NamedStyle(size: 20, color: 0xFF2E7D32),
    'h2': NamedStyle(size: 15, color: 0xFF2E7D32),
    'h3': NamedStyle(size: 12, color: 0xFF424242),
  }),
  ('Typewriter', {
    'body': NamedStyle(font: 'Mono', size: 11),
    'h1': NamedStyle(font: 'Mono', size: 16),
    'h2': NamedStyle(font: 'Mono', size: 13),
  }),
];

/// What the named styles are for, in the order they are shown.
const styleNames = [('body', 'Normal text'), ('h1', 'Heading 1'), ('h2', 'Heading 2'), ('h3', 'Heading 3'), ('h4', 'Heading 4'), ('h5', 'Heading 5'), ('h6', 'Heading 6')];

/// Asks how the kinds of paragraph of the document look (its named styles); the new ones (null: cancelled).
Future<Map<String, NamedStyle>?> showStylesDialog(BuildContext context, Map<String, NamedStyle> now) =>
    showDialog<Map<String, NamedStyle>>(context: context, builder: (_) => _StylesDialog(now));

class _StylesDialog extends StatefulWidget {
  final Map<String, NamedStyle> now;
  const _StylesDialog(this.now);

  @override
  State<_StylesDialog> createState() => _StylesDialogState();
}

class _StylesDialogState extends State<_StylesDialog> {
  late final Map<String, NamedStyle> _styles = Map.of(widget.now);

  static const _sizes = [8.0, 9.0, 10.0, 11.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0, 28.0, 32.0, 36.0];
  static const _colors = [0xFF000000, 0xFF424242, 0xFF1565C0, 0xFF2E7D32, 0xFFC62828, 0xFF6A1B9A, 0xFFE65100];

  void _set(String key, NamedStyle s) => setState(() => _styles[key] = s);

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Styles of this document'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Every paragraph of a kind takes its look; what is picked for single words stays.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              // themes: the looks set together
              Wrap(spacing: 8, children: [
                for (final (name, theme) in documentThemes)
                  ActionChip(
                    key: ValueKey('style-theme-$name'),
                    label: Text(name),
                    onPressed: () => setState(() => _styles
                      ..clear()
                      ..addAll(theme)),
                  ),
              ]),
              const SizedBox(height: 8),
              for (final (key, label) in styleNames)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(
                      width: 110,
                      child: Text(label,
                          style: TextStyle(
                            fontWeight: key == 'body' ? null : FontWeight.bold,
                            fontFamily: documentFonts[_styles[key]?.font],
                            color: _styles[key]?.color == null ? null : Color(_styles[key]!.color!),
                          )),
                    ),
                    Expanded(
                      child: DropdownButton<String>(
                        key: ValueKey('style-font-$key'),
                        isExpanded: true,
                        value: _styles[key]?.font ?? '',
                        items: [
                          DropdownMenuItem(value: '', child: Text('Default')),
                          for (final f in {...documentFonts.keys, if (_styles[key]?.font != null) _styles[key]!.font!})
                            DropdownMenuItem(value: f, child: Text.verbatim(f, style: TextStyle(fontFamily: documentFonts[f]))),
                        ],
                        onChanged: (f) {
                          final s = _styles[key] ?? const NamedStyle();
                          _set(key, NamedStyle(font: f == null || f.isEmpty ? null : f, size: s.size, color: s.color));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: DropdownButton<double>(
                        key: ValueKey('style-size-$key'),
                        isExpanded: true,
                        value: _styles[key]?.size ?? 0,
                        items: [
                          DropdownMenuItem(value: 0, child: Text('Default')),
                          // (a theme or a setting line written by hand can name a size of its own)
                          for (final s in {..._sizes, if (_styles[key]?.size != null) _styles[key]!.size!}.toList()..sort())
                            DropdownMenuItem(value: s, child: Text.verbatim('${s == s.roundToDouble() ? s.toInt() : s} pt')),
                        ],
                        onChanged: (v) {
                          final s = _styles[key] ?? const NamedStyle();
                          _set(key, NamedStyle(font: s.font, size: v == null || v == 0 ? null : v, color: s.color));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<int>(
                      key: ValueKey('style-color-$key'),
                      tooltip: tr('Text colour'),
                      icon: Icon(Icons.format_color_text, color: _styles[key]?.color == null ? null : Color(_styles[key]!.color!)),
                      onSelected: (c) {
                        final s = _styles[key] ?? const NamedStyle();
                        _set(key, NamedStyle(font: s.font, size: s.size, color: c == 0 ? null : c));
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 0, child: Text('Automatic')),
                        for (final c in _colors)
                          PopupMenuItem(value: c, child: Container(width: 60, height: 16, color: Color(c))),
                      ],
                    ),
                  ]),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => setState(_styles.clear), child: const Text('Reset all')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('styles-ok'), onPressed: () => Navigator.pop(context, _styles), child: const Text('OK')),
        ],
      );
}
