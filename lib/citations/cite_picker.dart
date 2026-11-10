import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import 'citation_library_screen.dart';
import 'citation_service.dart';
import 'citation_document.dart';
import 'citation_style.dart';

/// [value] with [citation] written at the cursor (after the selection when there is one), a space before it when it follows a word.
TextEditingValue withCitation(TextEditingValue value, String citation) {
  final sel = value.selection;
  final at = sel.isValid ? sel.end.clamp(0, value.text.length) : value.text.length;
  final before = at == 0 ? '' : value.text[at - 1];
  final lead = before.isEmpty || RegExp(r'[\s(\[]').hasMatch(before) ? '' : ' ';
  final text = value.text.replaceRange(at, at, '$lead$citation');
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at + lead.length + citation.length));
}

/// [value] with the line `[bibliography]` (the list of the sources the note cites) on lines of its own at the cursor.
TextEditingValue withBibliography(TextEditingValue value) {
  final sel = value.selection;
  final at = sel.isValid ? sel.end.clamp(0, value.text.length) : value.text.length;
  final before = value.text.substring(0, at), after = value.text.substring(at);
  final lead = before.isEmpty || before.endsWith('\n\n') ? '' : (before.endsWith('\n') ? '\n' : '\n\n');
  final tail = after.isEmpty || after.startsWith('\n\n') ? '' : (after.startsWith('\n') ? '\n' : '\n\n');
  final text = '$before$lead[bibliography]$tail$after';
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: before.length + lead.length + '[bibliography]'.length));
}

/// `[@a, p. 42; @b]`: [items] are the keys with the place in each source (null or empty: the source as a whole).
String citationText(List<(String key, String locator)> items) =>
    citationTextOf([for (final (key, locator) in items) CiteRef(key, locator: Locator.parse(locator))]);

/// `[see @a, p. 42, emphasis added; -@b]` for [items].
String citationTextOf(List<CiteRef> items) => '[${items.map((r) => r.write()).join('; ')}]';

/// The citation of [text] that the cursor [at] is in or touches, null if there is none.
CitationMark? citationAround(String text, int at) {
  for (final mark in findCitations(text)) {
    if (at >= mark.start && at <= mark.end) return mark;
  }
  return null;
}

/// [text] with the citation [mark] replaced by [citation], or taken out when [citation] is empty (with the space that led up to it).
TextEditingValue replaceCitation(TextEditingValue value, CitationMark mark, String citation) {
  var start = mark.start;
  if (citation.isEmpty && start > 0 && value.text[start - 1] == ' ') start--;
  final text = value.text.replaceRange(start, mark.end, citation);
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start + citation.length));
}

/// Lets the person choose what to cite from the library (or add a source on the spot), each with the place in it. Returns the text
/// to write, `[@key, p. 42]`, or null when cancelled. With [editing] (what the citation cites now) the sheet changes that citation
/// instead, and offers to take it out: the answer is then empty.
Future<String?> showCitePicker(BuildContext context, CitationService service, {List<CiteRef>? editing}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _CitePicker(service: service, editing: editing),
  );
}

class _Pick {
  final String key;
  final TextEditingController locator;
  final TextEditingController prefix;
  final TextEditingController suffix;
  bool suppressAuthor;

  _Pick(this.key, String locator, {String prefix = '', String suffix = '', this.suppressAuthor = false})
      : locator = TextEditingController(text: locator),
        prefix = TextEditingController(text: prefix),
        suffix = TextEditingController(text: suffix);

  void dispose() {
    locator.dispose();
    prefix.dispose();
    suffix.dispose();
  }

  CiteRef get ref => CiteRef(key, locator: Locator.parse(locator.text), prefix: prefix.text.trim(), suffix: suffix.text.trim(), suppressAuthor: suppressAuthor);
}

class _CitePicker extends StatefulWidget {
  final CitationService service;
  final List<CiteRef>? editing;

  const _CitePicker({required this.service, this.editing});

  @override
  State<_CitePicker> createState() => _CitePickerState();
}

class _CitePickerState extends State<_CitePicker> {
  final _search = TextEditingController();
  late final List<_Pick> _chosen = [
    for (final r in widget.editing ?? const <CiteRef>[]) _Pick(r.key, r.locator?.text() ?? '', prefix: r.prefix, suffix: r.suffix, suppressAuthor: r.suppressAuthor),
  ];

  @override
  void dispose() {
    _search.dispose();
    for (final p in _chosen) {
      p.dispose();
    }
    super.dispose();
  }

  bool _has(String key) => _chosen.any((p) => p.key == key);

  void _toggle(String key, bool on) => setState(() {
        if (on && !_has(key)) _chosen.add(_Pick(key, ''));
        if (!on) {
          for (final p in _chosen.where((p) => p.key == key)) {
            p.dispose();
          }
          _chosen.removeWhere((p) => p.key == key);
        }
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.editing != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.service, _search]),
        builder: (context, _) {
          final q = _search.text.trim().toLowerCase();
          final all = widget.service.sources;
          final shown = [
            for (final s in all)
              if (q.isEmpty || '${s.id} ${s.title} ${s.authors.map((a) => a.family).join(' ')} ${s.year ?? ''}'.toLowerCase().contains(q)) s,
          ];
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(children: [
                  Expanded(child: Text(editing ? 'Change the citation' : 'Cite a source', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
                  AddSourceButton(service: widget.service, onAdded: (s) => _toggle(s.id, true)),
                ]),
              ),
              if (all.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    key: const ValueKey('cite-search'),
                    controller: _search,
                    decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Search by author, title or key'), border: const OutlineInputBorder(), isDense: true),
                  ),
                ),
              Flexible(
                child: all.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(child: Text.verbatim(tr('No sources yet. Add one to cite it.'), style: TextStyle(color: scheme.onSurfaceVariant))),
                      )
                    : ListView(shrinkWrap: true, children: [
                        for (final s in shown)
                          CheckboxListTile.adaptive(
                            key: ValueKey('cite-${s.id}'),
                            dense: true,
                            value: _has(s.id),
                            onChanged: (on) => _toggle(s.id, on == true),
                            title: Text.verbatim(sourceLabel(s)),
                            subtitle: Text.verbatim(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        // a key the library does not have (a source that was deleted): it can be seen and taken out
                        for (final p in _chosen.where((p) => !widget.service.byId.containsKey(p.key)))
                          ListTile(
                            dense: true,
                            leading: Icon(Icons.error_outline, color: scheme.error),
                            title: Text.verbatim('@${p.key}'),
                            subtitle: Text('This source is not in the library.'),
                            trailing: IconButton(tooltip: tr('Remove'), icon: const Icon(Icons.close), onPressed: () => _toggle(p.key, false)),
                          ),
                      ]),
              ),
              if (_chosen.isNotEmpty) ...[
                const Divider(height: 1),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), children: [
                    for (final p in _chosen)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(children: [
                          Row(children: [
                            Expanded(
                              flex: 3,
                              child: Text.verbatim(widget.service.byId[p.key] == null ? '@${p.key}' : sourceLabel(widget.service.byId[p.key]!), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                key: ValueKey('cite-locator-${p.key}'),
                                controller: p.locator,
                                decoration: InputDecoration(labelText: tr('Where in it'), hintText: 'p. 42', border: const OutlineInputBorder(), isDense: true),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          Row(children: [
                            Expanded(
                              child: TextField(
                                key: ValueKey('cite-prefix-${p.key}'),
                                controller: p.prefix,
                                decoration: InputDecoration(labelText: tr('Before'), hintText: tr('see'), border: const OutlineInputBorder(), isDense: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                key: ValueKey('cite-suffix-${p.key}'),
                                controller: p.suffix,
                                decoration: InputDecoration(labelText: tr('After'), hintText: tr('emphasis added'), border: const OutlineInputBorder(), isDense: true),
                              ),
                            ),
                            IconButton(
                              key: ValueKey('cite-no-author-${p.key}'),
                              tooltip: tr('Leave out the author (the text names them)'),
                              isSelected: p.suppressAuthor,
                              icon: const Icon(Icons.person_outline),
                              selectedIcon: const Icon(Icons.person_off),
                              onPressed: () => setState(() => p.suppressAuthor = !p.suppressAuthor),
                            ),
                          ]),
                        ]),
                      ),
                  ]),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  if (editing)
                    TextButton.icon(
                      key: const ValueKey('cite-remove'),
                      onPressed: () => Navigator.pop(context, ''),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Remove the citation'),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('cite-insert'),
                    onPressed: _chosen.isEmpty ? null : () => Navigator.pop(context, citationTextOf([for (final p in _chosen) p.ref])),
                    child: Text(editing ? 'Save' : 'Insert'),
                  ),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}
