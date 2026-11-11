import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;

import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import '../import/goodnotes_import.dart';
import '../import/import_source.dart';
import '../import/importer.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';
import 'note_file_actions.dart' show pickerFilter;

enum _From { obsidianFolder, obsidianZip, notion, goodnotes }

/// "Bring your notes": asks which app they come from, reads them in and tells what was taken and what was not. [onOpenNote] opens
/// the first note that was made when the person asks for it.
Future<void> showImportFromApps(
  BuildContext context, {
  required NoteRepository repository,
  TagRepository? tags,
  required ValueChanged<String> onOpenNote,
}) async {
  final from = await showDialog<_From>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: const Text('Bring your notes from another app'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!kIsWeb)
              _option(context, const ValueKey('import-obsidian-folder'), Icons.folder_open_outlined, 'Obsidian: a vault folder',
                  'Notes, folders, pictures, PDFs and tags are taken; links between notes keep working.', _From.obsidianFolder),
            _option(context, const ValueKey('import-obsidian-zip'), Icons.folder_zip_outlined, 'Obsidian: a vault as a zip',
                'The same, from a zip of the vault folder.', _From.obsidianZip),
            _option(context, const ValueKey('import-notion'), Icons.archive_outlined, 'Notion: an export',
                'In Notion: Settings, Export all workspace content, Markdown & CSV. Pick the zip you get.', _From.notion),
            _option(context, const ValueKey('import-goodnotes'), Icons.picture_as_pdf_outlined, 'GoodNotes: PDFs or a .goodnotes file',
                'In GoodNotes: Share, Export as PDF. Handwriting stays as it looks. A .goodnotes file can only give its PDFs.', _From.goodnotes),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    ),
  );
  if (from == null || !context.mounted) return;
  try {
    final progress = ValueNotifier<(int, int)>((0, 0));
    ImportReport? report;
    Future<void> run(Future<ImportReport> Function() job) async {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PlatformAlertDialog(
          title: const Text('Reading your notes...'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (context, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v.$2 == 0 ? null : v.$1 / v.$2),
              const SizedBox(height: 8),
              Text.verbatim(v.$2 == 0 ? '' : '${v.$1} / ${v.$2}'),
            ]),
          ),
        ),
      );
      try {
        report = await job();
      } finally {
        if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      }
    }

    void onProgress(int done, int total) => progress.value = (done, total);
    switch (from) {
      case _From.obsidianFolder:
        final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Pick the vault folder');
        if (dir == null || !context.mounted) return;
        final source = await sourceFromDirectory(Directory(dir));
        await run(() => importNotes(kind: ImportKind.obsidian, source: source, repository: repository, tags: tags, rootName: source.name, onProgress: onProgress));
      case _From.obsidianZip || _From.notion:
        final picked = await FilePicker.pickFile(
          dialogTitle: from == _From.notion ? 'Pick the Notion export (zip)' : 'Pick the vault (zip)',
          type: pickerFilter(const ['zip']).type,
          allowedExtensions: pickerFilter(const ['zip']).extensions,
        );
        if (picked == null || !context.mounted) return;
        final bytes = await picked.readAsBytes();
        final stem = p.basenameWithoutExtension(picked.name);
        final source = sourceFromZip(bytes, name: stem);
        await run(() => importNotes(
              kind: from == _From.notion ? ImportKind.notion : ImportKind.obsidian,
              source: source,
              repository: repository,
              tags: tags,
              rootName: from == _From.notion ? 'Notion' : source.name,
              onProgress: onProgress,
            ));
      case _From.goodnotes:
        final picked = await FilePicker.pickFiles(
          dialogTitle: 'Pick the PDFs or the .goodnotes files',
          type: pickerFilter(const ['pdf', 'goodnotes']).type,
          allowedExtensions: pickerFilter(const ['pdf', 'goodnotes']).extensions,
        );
        if (picked.isEmpty || !context.mounted) return;
        final pdfs = <({String name, Uint8List bytes})>[];
        final notices = <String>[];
        for (final file in picked) {
          final bytes = await file.readAsBytes();
          if (file.name.toLowerCase().endsWith('.pdf')) {
            pdfs.add((name: file.name, bytes: bytes));
            continue;
          }
          final stem = p.basenameWithoutExtension(file.name);
          final inside = await goodnotesPdfs(bytes, name: stem);
          for (var i = 0; i < inside.length; i++) {
            pdfs.add((name: i == 0 ? '$stem.pdf' : '$stem (${i + 1}).pdf', bytes: inside[i].bytes));
          }
          notices.add(tr('What is written by hand in "{name}" is in a format that cannot be read. Only its PDF pages were taken; to keep the handwriting, export the notebook as a PDF in GoodNotes.', {'name': file.name}));
        }
        await run(() async => (await importPdfs(pdfs: pdfs, repository: repository, onProgress: onProgress))..notices.addAll(notices));
    }
    if (report != null && context.mounted) await _showReport(context, report!, onOpenNote);
  } on FormatException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr(e.message)), duration: const Duration(seconds: 10)));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not read the notes: {error}', {'error': e})), duration: const Duration(seconds: 10)));
    }
  }
}

Widget _option(BuildContext context, Key key, IconData icon, String title, String subtitle, _From value) => ListTile(
      key: key,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => Navigator.pop(context, value),
    );

Future<void> _showReport(BuildContext context, ImportReport r, ValueChanged<String> onOpenNote) async {
  String names(Iterable<String> s) => s.take(60).join('\n') + (s.length > 60 ? '\n...' : '');
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: Text(r.total == 0 ? 'Nothing was taken in' : 'Your notes are here'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r.notes > 0) Text.verbatim(trCount(r.notes, '{n} note', '{n} notes')),
            if (r.pdfs > 0) Text.verbatim(trCount(r.pdfs, '{n} PDF', '{n} PDFs')),
            if (r.tables > 0) Text.verbatim(trCount(r.tables, '{n} table (a database)', '{n} tables (databases)')),
            if (r.pictures > 0) Text.verbatim(trCount(r.pictures, '{n} picture', '{n} pictures')),
            if (r.folders > 0) Text.verbatim(trCount(r.folders, '{n} folder', '{n} folders')),
            if (r.links > 0) Text.verbatim(trCount(r.links, '{n} link between notes kept', '{n} links between notes kept')),
            for (final n in r.notices) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(n)),
            if (r.failed.isNotEmpty) _list(context, 'Could not be read', r.failed, names, const ValueKey('import-failed')),
            if (r.skipped.isNotEmpty) _list(context, 'Left out (not notes or pictures)', r.skipped, names, const ValueKey('import-skipped')),
            if (r.missing.isNotEmpty) _list(context, 'Links to something that was not there (kept as plain text)', r.missing, names, const ValueKey('import-missing')),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
        if (r.firstNoteId != null) FilledButton(key: const ValueKey('import-open'), onPressed: () => Navigator.pop(context, true), child: const Text('Open a note')),
      ],
    ),
  );
  if (open == true && r.firstNoteId != null) onOpenNote(r.firstNoteId!);
}

Widget _list(BuildContext context, String title, Iterable<String> items, String Function(Iterable<String>) names, Key key) => Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: key,
        tilePadding: EdgeInsets.zero,
        title: Text.verbatim('${tr(title)} (${items.length})'),
        children: [Align(alignment: Alignment.centerLeft, child: SelectableText(names(items)))],
      ),
    );
