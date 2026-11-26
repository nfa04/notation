import 'dart:io';
import 'dart:typed_data';

import '../data/note_repository.dart';
import '../data/pdf_note.dart';
import '../data/tag_repository.dart';
import '../extensions/extension_service.dart' show ImportedNote;
import '../markdown/document_images.dart';
import 'importer.dart' show ImportReport;

final _wiki = RegExp(r'(?<!!)\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]');
final _picture = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _sourceLink = RegExp(r'\[([^\]]*)\]\(source:([^)\s]+)\)');

/// Makes the notes an importer extension answered with, the way the built-in importers make theirs: folders from the paths, links
/// between the notes (`[[Title]]`, `[[Title|text]]` and `[text](source:<sourceId>)` become links to the new notes; one that points
/// at nothing in the import stays as plain text and is counted in the report), pictures kept, tags set.
///
/// A note with a `sourceId` that was imported before ([known]: source id to note id) is updated in place instead of made again;
/// [onMapped] says which note each source id became, for the next run. A note's `created` and `updated` dates are kept when the importer gives them.
Future<ImportReport> importExtensionNotes({
  required List<ImportedNote> notes,
  required NoteRepository repository,
  TagRepository? tags,
  String? rootName,
  String? parentFolderId,
  Map<String, String> known = const {},
  void Function(String sourceId, String noteId)? onMapped,
  void Function(int done, int total)? onProgress,
  Directory? pdfDirectory,
  List<String> notices = const [],
}) async {
  final report = ImportReport()..notices.addAll(notices);
  final existing = {for (final n in await repository.listNotes()) n.id};
  final ids = <ImportedNote, String>{};
  final byTitle = <String, String>{};
  final bySource = <String, String>{};
  for (final n in notes) {
    final old = n.sourceId == null ? null : known[n.sourceId];
    final id = old != null && existing.contains(old) ? old : NoteRepository.newId();
    ids[n] = id;
    byTitle.putIfAbsent(n.title.toLowerCase(), () => id);
    if (n.sourceId != null) bySource[n.sourceId!] = id;
  }

  final folders = <String, String>{};
  String? rootId;
  Future<String?> root() async {
    if (rootName == null || rootName.trim().isEmpty) return parentFolderId;
    if (rootId == null) {
      report.folders++;
      rootId = await repository.createFolder(rootName.trim(), parentId: parentFolderId);
      report.rootFolderId = rootId;
    }
    return rootId;
  }

  Future<String?> folderFor(String path) async {
    var parent = await root();
    if (!path.contains('/')) return parent;
    final parts = path.substring(0, path.lastIndexOf('/')).split('/').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i < parts.length; i++) {
      final key = parts.sublist(0, i + 1).join('/');
      if (!folders.containsKey(key)) {
        report.folders++;
        folders[key] = await repository.createFolder(parts[i], parentId: parent);
      }
      parent = folders[key];
    }
    return parent;
  }

  var done = 0;
  for (final n in notes) {
    final id = ids[n]!;
    try {
      final folder = await folderFor(n.path);
      if (n.pdf != null) {
        final temp = await Directory.systemTemp.createTemp('notation_import');
        try {
          final file = File('${temp.path}/${n.pdf!.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
          await file.writeAsBytes(n.pdf!.bytes);
          final pdfId = await createNoteFromPdf(repository, file.path, folderId: folder, directory: pdfDirectory);
          if (n.sourceId != null) onMapped?.call(n.sourceId!, pdfId);
          bySource[n.sourceId ?? ''] = pdfId;
          report.pdfs++;
          report.firstNoteId ??= pdfId;
        } finally {
          await temp.delete(recursive: true).catchError((Object _) => temp);
        }
        continue;
      }
      var text = n.markdown.replaceAll('\r\n', '\n');
      text = text.replaceAllMapped(_wiki, (m) {
        final target = byTitle[m.group(1)!.trim().toLowerCase()];
        final label = (m.group(2) ?? m.group(1)!).trim();
        if (target == null) {
          report.missing.add(m.group(1)!.trim());
          return label;
        }
        report.links++;
        return '[$label](note:$target)';
      });
      text = text.replaceAllMapped(_sourceLink, (m) {
        final target = bySource[m.group(2)!];
        if (target == null) {
          report.missing.add(m.group(2)!);
          return m.group(1)!;
        }
        report.links++;
        return '[${m.group(1)}](note:$target)';
      });
      final kept = <String, String?>{};
      final out = StringBuffer();
      var at = 0;
      for (final m in _picture.allMatches(text)) {
        out.write(text.substring(at, m.start));
        at = m.end;
        final name = Uri.decodeFull(m.group(2)!);
        final bytes = n.attachments[name] ?? n.attachments[name.substring(name.lastIndexOf('/') + 1)];
        if (bytes == null) {
          out.write(m.group(0));
          continue;
        }
        if (!kept.containsKey(name)) {
          try {
            final picture = await DocumentImages.forKeeping(Uint8List.fromList(bytes));
            kept[name] = await DocumentImages.keep(id, picture.bytes, picture.ext);
            report.pictures++;
          } catch (_) {
            kept[name] = null;
            report.skipped.add(name);
          }
        }
        out.write(kept[name] == null ? m.group(1)! : '![${m.group(1)}](${kept[name]})');
      }
      out.write(text.substring(at));
      if (existing.contains(id)) {
        final note = await repository.loadNote(id);
        if (note != null) {
          note.title = n.title;
          note.documentText = out.toString();
          await repository.saveNote(note);
        }
      } else {
        await repository.createNote(title: n.title, folderId: folder, id: id);
        final note = (await repository.loadNote(id))!;
        note.documentText = out.toString();
        await repository.saveNote(note);
      }
      if (n.created != null || n.updated != null) {
        // the dates the other app had (they are set after the save, which dated the note by now)
        final was = await repository.noteTimes(id);
        final created = n.created ?? (was != null && existing.contains(id) ? was.created : n.updated!);
        final edited = n.updated ?? n.created!;
        await repository.setTimes(id, created: created.isAfter(edited) ? edited : created, edited: edited);
      }
      if (tags != null && n.tags.isNotEmpty) await tags.setTags(id, n.tags);
      if (n.sourceId != null) onMapped?.call(n.sourceId!, id);
      report.notes++;
      report.firstNoteId ??= id;
    } catch (e) {
      report.failed.add('${n.path.isEmpty ? n.title : n.path}: $e');
    } finally {
      onProgress?.call(++done, notes.length);
    }
    if (done % 20 == 0) await Future<void>.delayed(Duration.zero);
  }
  return report;
}
