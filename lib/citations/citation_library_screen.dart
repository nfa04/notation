import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import '../export/file_dialogs.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../l10n/language.dart';
import '../l10n/text.dart';
import 'citation_service.dart';
import 'citation_style.dart';
import 'export.dart';
import 'import.dart';
import 'lookup.dart';
import 'source.dart';
import 'source_editor.dart';
import '../style/platform_dialog.dart';

/// An entry of the list of sources as styled text: what is between `*` marks is in italics.
TextSpan entrySpan(String entry, TextStyle? style) {
  final parts = entry.split('*');
  return TextSpan(style: style, children: [
    for (var i = 0; i < parts.length; i++) TextSpan(text: parts[i], style: i.isOdd ? const TextStyle(fontStyle: FontStyle.italic) : null),
  ]);
}

/// "Smith & Jones (2020)" — a short name for a source in a list.
String sourceLabel(CitationSource s) {
  final names = s.authors.isNotEmpty ? s.authors : s.editors;
  final who = names.isEmpty ? '' : names.length > 2 ? '${names.first.family} et al.' : names.map((p) => p.family).join(' & ');
  return who.isEmpty ? '${s.title}${s.year == null ? '' : ' (${s.year})'}' : '$who (${s.year ?? 'n.d.'})';
}

void _say(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text.verbatim(message)));

/// Asks for a DOI or ISBN, finds the work and opens the form filled in. Returns the source saved, or null.
Future<CitationSource?> addSourceFromLookup(BuildContext context, CitationService service, {CitationLookup? lookup}) async {
  final controller = TextEditingController();
  final query = await showDialog<String>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: const Text('Find by DOI or ISBN'),
      content: TextField(
        key: const ValueKey('lookup-query'),
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: '10.1000/xyz123  /  978-3-16-148410-0', border: const OutlineInputBorder(), isDense: true, labelText: tr('DOI or ISBN')),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Find')),
      ],
    ),
  );
  controller.dispose();
  if (query == null || query.trim().isEmpty || !context.mounted) return null;
  CitationSource? found;
  try {
    found = await (lookup ?? CitationLookup()).find(query);
  } catch (_) {
    if (context.mounted) _say(context, tr('Could not reach the service. Check the connection, or enter the source by hand.'));
    return null;
  }
  if (!context.mounted) return null;
  if (found == null) {
    _say(context, tr('Nothing found for "{query}".', {'query': query.trim()}));
    return null;
  }
  return addSourceByHand(context, service, initial: found);
}

/// The form for a new source; saved into the library when confirmed. A source that is in the library already is not added a second
/// time unless the person says so: the one that is there is returned then.
Future<CitationSource?> addSourceByHand(BuildContext context, CitationService service, {CitationSource? initial}) async {
  final made = await showSourceEditor(context, service, initial: initial);
  if (made == null) return null;
  final twin = service.duplicateOf(made);
  if (twin == null || !context.mounted) return service.add(made);
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: const Text('Already in the library'),
      content: Text.verbatim(tr('This looks like a source you have: {name} [@{key}].', {'name': sourceLabel(twin), 'key': twin.id})),
      actions: [
        TextButton(key: const ValueKey('duplicate-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(key: const ValueKey('duplicate-add'), onPressed: () => Navigator.pop(context, 'add'), child: const Text('Add it anyway')),
        FilledButton(key: const ValueKey('duplicate-use'), onPressed: () => Navigator.pop(context, 'use'), child: const Text('Use the one there')),
      ],
    ),
  );
  return switch (choice) {
    'use' => twin,
    'add' => service.add(made),
    _ => null,
  };
}

/// Writes the library in [format] to a file the person chooses.
Future<void> exportSourcesFile(BuildContext context, CitationService service, ExportFormat format) async {
  if (service.sources.isEmpty) return _say(context, tr('No sources yet.'));
  final bytes = utf8.encode(format.write(service.sources));
  final savePath = await saveWithDialog(
    dialogTitle: tr('Export the sources'),
    fileName: 'sources.${format.extension}',
    extension: format.extension,
    bytes: Uint8List.fromList(bytes),
  );
  if (savePath == null) return;
  if (context.mounted) _say(context, tr('Successfully exported to {path}', {'path': savePath}));
}

/// Puts the library in [format] on the clipboard, to paste into a reference manager or a LaTeX project.
Future<void> copySources(BuildContext context, CitationService service, ExportFormat format) async {
  if (service.sources.isEmpty) return _say(context, tr('No sources yet.'));
  await Clipboard.setData(ClipboardData(text: format.write(service.sources)));
  if (context.mounted) _say(context, tr('Copied {format}.', {'format': format.label}));
}

/// Imports a `.bib`, `.ris` or CSL `.json` file chosen by the person into the library.
Future<void> importSourcesFile(BuildContext context, CitationService service) async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['bib', 'bibtex', 'ris', 'json', 'txt']);
  if (file == null) return;
  try {
    final bytes = await file.readAsBytes();
    final sources = importReferences(utf8.decode(bytes, allowMalformed: true));
    final added = await service.addAll(sources);
    if (context.mounted) {
      _say(context, sources.isEmpty
          ? tr('No sources found in this file.')
          : trCount(added, 'Added 1 source.', 'Added {n} sources.') + (added < sources.length ? ' ${tr('{n} were in the library already.', {'n': sources.length - added})}' : ''));
    }
  } catch (_) {
    if (context.mounted) _say(context, tr('This file could not be read as BibTeX, RIS or CSL-JSON.'));
  }
}

/// The menu that adds a source: by hand, from a DOI or ISBN, or from a file.
class AddSourceButton extends StatelessWidget {
  final CitationService service;
  final ValueChanged<CitationSource>? onAdded;

  const AddSourceButton({super.key, required this.service, this.onAdded});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      key: const ValueKey('add-source'),
      tooltip: tr('Add a source'),
      onSelected: (v) async {
        CitationSource? added;
        if (v == 0) {
          added = await addSourceFromLookup(context, service);
        } else if (v == 1) {
          added = await addSourceByHand(context, service);
        } else {
          await importSourcesFile(context, service);
        }
        if (added != null) onAdded?.call(added);
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 0, child: ListTile(leading: const Icon(Icons.travel_explore), title: const Text('From a DOI or ISBN'), dense: true, contentPadding: EdgeInsets.zero)),
        PopupMenuItem(value: 1, child: ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Enter by hand'), dense: true, contentPadding: EdgeInsets.zero)),
        PopupMenuItem(value: 2, child: ListTile(leading: const Icon(Icons.upload_file_outlined), title: const Text('Import a file (BibTeX, RIS, CSL-JSON)'), dense: true, contentPadding: EdgeInsets.zero)),
      ],
      child: IgnorePointer(
        child: FilledButton.icon(onPressed: () {}, icon: const Icon(Icons.add, size: 18), label: const Text('Add a source')),
      ),
    );
  }
}

/// The style the sources are cited in.
class CitationStylePicker extends StatelessWidget {
  final CitationService service;

  const CitationStylePicker({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const ValueKey('citation-style'),
      initialValue: service.style.id,
      decoration: InputDecoration(labelText: tr('Citation style'), border: const OutlineInputBorder(), isDense: true),
      items: [for (final s in citationStyles) DropdownMenuItem(value: s.id, child: Text.verbatim(s.name))],
      onChanged: (id) => service.setStyle(citationStyleById(id)),
    );
  }
}

/// All the sources, with the style they are cited in, and where each is cited.
class CitationLibraryScreen extends StatefulWidget {
  final CitationService service;

  const CitationLibraryScreen({super.key, required this.service});

  @override
  State<CitationLibraryScreen> createState() => _CitationLibraryScreenState();
}

class _CitationLibraryScreenState extends State<CitationLibraryScreen> {
  /// The notes that cite each key; null while it is being read, or when the library cannot say.
  Map<String, List<NoteRef>>? _usage;
  bool _uncitedOnly = false;
  bool _gone = false;

  CitationService get service => widget.service;

  @override
  void initState() {
    super.initState();
    _readUsage();
    service.addListener(_readUsage);
  }

  @override
  void dispose() {
    _gone = true;
    service.removeListener(_readUsage);
    super.dispose();
  }

  Future<void> _readUsage() async {
    if (!service.knowsUsage) return;
    Map<String, List<NoteRef>> usage;
    try {
      usage = await service.usage();
    } catch (_) {
      return; // (the library is still there without it)
    }
    if (!_gone) setState(() => _usage = usage);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final style = service.style;
        final usage = _usage;
        final sources = [
          for (final s in [...service.sources]..sort(style.compare))
            if (!_uncitedOnly || usage == null || !(usage[s.id]?.isNotEmpty ?? false)) s,
        ];
        // keys that notes cite and the library does not have
        final unknown = usage == null ? const <String>[] : ([for (final k in usage.keys) if (!service.has(k)) k]..sort());
        return Scaffold(
          appBar: AppBar(
            title: const Text('Sources', style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              PopupMenuButton<(bool, ExportFormat)>(
                key: const ValueKey('export-sources'),
                tooltip: tr('Export the sources'),
                icon: const Icon(Icons.ios_share),
                onSelected: (v) => v.$1 ? copySources(context, service, v.$2) : exportSourcesFile(context, service, v.$2),
                itemBuilder: (_) => [
                  for (final f in ExportFormat.values) PopupMenuItem(value: (false, f), child: Text.verbatim(tr('Save as {format}...', {'format': f.label}))),
                  const PopupMenuDivider(),
                  PopupMenuItem(value: (true, ExportFormat.bibtex), child: Text.verbatim(tr('Copy as {format}', {'format': ExportFormat.bibtex.label}))),
                ],
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text.verbatim(
                  tr('Quote a source in any written document or text box with its key, like [@key] or [@key, p. 42]. What it reads as, and the list of sources under a document, follow the style chosen here.'),
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
                const SizedBox(height: 14),
                CitationStylePicker(service: service),
                const SizedBox(height: 14),
                Row(children: [
                  AddSourceButton(service: service),
                  const SizedBox(width: 12),
                  if (usage != null)
                    FilterChip(
                      key: const ValueKey('uncited-only'),
                      label: const Text('Not cited yet'),
                      selected: _uncitedOnly,
                      onSelected: (on) => setState(() => _uncitedOnly = on),
                    ),
                ]),
                const SizedBox(height: 14),
                if (unknown.isNotEmpty) ...[
                  Card(
                    key: const ValueKey('unknown-keys'),
                    color: scheme.errorContainer,
                    margin: const EdgeInsets.only(bottom: 14),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text.verbatim(tr('Cited in notes, but not in the library'), style: TextStyle(fontWeight: FontWeight.bold, color: scheme.onErrorContainer)),
                        const SizedBox(height: 6),
                        for (final k in unknown)
                          ListTile(
                            key: ValueKey('unknown-$k'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text.verbatim('[@$k]', style: TextStyle(fontFamily: 'monospace', color: scheme.onErrorContainer)),
                            subtitle: Text.verbatim(_noteTitles(usage![k]!), style: TextStyle(color: scheme.onErrorContainer)),
                            trailing: TextButton(
                              onPressed: () => addSourceByHand(context, service, initial: CitationSource(id: k, title: '')),
                              child: const Text('Add'),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ],
                if (sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text.verbatim(tr(_uncitedOnly ? 'Every source is cited in a note.' : 'No sources yet.'), style: TextStyle(color: scheme.onSurfaceVariant))),
                  ),
                for (final s in sources) _SourceTile(service: service, source: s, citedIn: usage == null ? null : (usage[s.id] ?? const [])),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// "Lecture 1, Essay and 2 more": the titles of [notes], the first few.
String _noteTitles(List<NoteRef> notes) {
  final names = [for (final n in notes) n.title.trim().isEmpty ? tr('Untitled') : n.title.trim()];
  if (names.length <= 3) return names.join(', ');
  return '${names.take(3).join(', ')} ${trCount(names.length - 3, 'and 1 more', 'and {n} more')}';
}

class _SourceTile extends StatelessWidget {
  final CitationService service;
  final CitationSource source;

  /// The notes that cite the source; null: not known.
  final List<NoteRef>? citedIn;

  const _SourceTile({required this.service, required this.source, this.citedIn});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = service.style.entry(source, number: service.style.numeric ? service.sources.indexWhere((o) => o.id == source.id) + 1 : null);
    final cited = citedIn;
    return Card(
      key: ValueKey('source-${source.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text.rich(entrySpan(entry, Theme.of(context).textTheme.bodyMedium)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.verbatim('[@${source.id}]', style: TextStyle(fontFamily: 'monospace', color: scheme.primary, fontSize: 12)),
            if (cited != null)
              Text.verbatim(
                cited.isEmpty ? tr('Not cited in any note') : '${trCount(cited.length, 'Cited in 1 note', 'Cited in {n} notes')}: ${_noteTitles(cited)}',
                key: ValueKey('cited-in-${source.id}'),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
          ]),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'copy':
                await Clipboard.setData(ClipboardData(text: '[@${source.id}]'));
                if (context.mounted) _say(context, tr('Copied [@{key}].', {'key': source.id}));
              case 'edit':
                final made = await showSourceEditor(context, service, source: source);
                if (made != null) await service.update(source.id, made);
              case 'delete':
                final sure = await showDialog<bool>(
                  context: context,
                  builder: (context) => PlatformAlertDialog(
                    title: const Text('Delete this source?'),
                    content: Text.verbatim(
                      cited == null || cited.isEmpty
                          ? tr('Notes that cite [@{key}] keep the citation but it can no longer be read.', {'key': source.id})
                          : '${tr('Notes that cite [@{key}] keep the citation but it can no longer be read.', {'key': source.id})}\n\n${trCount(cited.length, 'It is cited in 1 note', 'It is cited in {n} notes')}: ${_noteTitles(cited)}',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                    ],
                  ),
                );
                if (sure == true) await service.remove(source.id);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'copy', child: Text('Copy the citation')),
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}

/// The card in the settings: the style, how many sources there are, a way into the library.
class CitationSettings extends StatelessWidget {
  final CitationService service;

  const CitationSettings({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Citations', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          'The papers and books you quote, kept once for all your notes. Write [@key] in a text to cite one; the citation and the list of sources follow the style chosen here.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 12),
        CitationStylePicker(service: service),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('open-library'),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CitationLibraryScreen(service: service))),
          icon: const Icon(Icons.format_quote, size: 18),
          label: Text.verbatim(trCount(service.sources.length, 'Open the library (1 source)', 'Open the library ({n} sources)')),
        ),
      ]),
    );
  }
}
