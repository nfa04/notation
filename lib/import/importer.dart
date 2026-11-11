import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../data/note_repository.dart';
import '../data/pdf_note.dart';
import '../data/tag_repository.dart';
import '../markdown/document_images.dart';
import 'import_source.dart';
import 'markdown_convert.dart';
import 'notion_import.dart';
import 'obsidian_import.dart';
import 'path_index.dart';

enum ImportKind { obsidian, notion }

/// What an import did, for the person to read.
class ImportReport {
  int notes = 0, pdfs = 0, folders = 0, pictures = 0, tables = 0, links = 0;

  /// Files that were not taken (sound, video, Office files, canvases...), by name.
  final skipped = <String>{};

  /// What notes pointed at and the import did not contain, by name.
  final missing = <String>{};

  /// Pages and files that could not be read, with the reason.
  final failed = <String>[];

  /// Things to tell the person that are no failure (what cannot be read from a format, say).
  final notices = <String>[];

  /// The first note that was made, to open.
  String? firstNoteId;

  /// The folder everything went into, when the import made one.
  String? rootFolderId;

  int get total => notes + pdfs + tables;
}

class _Page {
  final SourceFile file;
  final String kind; // md, csv
  String title;
  String text = '';
  late final String id;
  bool unreadable = false;
  _Page(this.file, this.kind, this.title);
}

/// Reads an Obsidian vault or a Notion export ([source]) into notes: every Markdown page becomes a written document with its links
/// to other pages turned into links to the new notes, its pictures kept, its tags set; every PDF becomes a PDF note; folders stay
/// folders (in a folder named [rootName] when given, inside [parentFolderId]). A Notion database (CSV) becomes a table.
Future<ImportReport> importNotes({
  required ImportKind kind,
  required ImportSource source,
  required NoteRepository repository,
  TagRepository? tags,
  String? rootName,
  String? parentFolderId,
  void Function(int done, int total)? onProgress,

  /// Where the PDFs are kept (the app's folder for PDFs by default).
  Directory? pdfDirectory,
}) async {
  final report = ImportReport();
  final notion = kind == ImportKind.notion;
  final files = source.files;
  final paths = {for (final f in files) f.path};
  final directories = <String>{
    for (final f in files)
      for (var i = f.path.indexOf('/'); i >= 0; i = f.path.indexOf('/', i + 1)) f.path.substring(0, i),
  };

  // --- which file is what
  final pages = <_Page>[];
  final pdfs = <SourceFile>[];
  final pictureFiles = <String, SourceFile>{};
  final filesIndex = PathIndex<String>();
  for (final f in files) {
    final ext = f.ext;
    if (ext == 'md' || ext == 'markdown') {
      pages.add(_Page(f, 'md', notion ? notionName(f.name) : f.name.substring(0, f.name.length - ext.length - 1)));
    } else if (notion && ext == 'csv') {
      final stem = f.path.substring(0, f.path.length - 4);
      if (stem.endsWith('_all') && paths.contains('${stem.substring(0, stem.length - 4)}.csv')) continue; // the same table again
      pages.add(_Page(f, 'csv', notionName(f.name)));
    } else if (ext == 'pdf') {
      pdfs.add(f);
    } else {
      filesIndex.add(f.path, f.path);
      if (pictureExtensions.contains(ext)) {
        pictureFiles[f.path] = f;
      } else {
        report.skipped.add(f.name);
      }
    }
  }
  final total = pages.length + pdfs.length;
  var done = 0;
  void step() => onProgress?.call(++done, total);

  // --- folders
  final folderIds = <String, String>{};
  String? rootId;
  Future<String?> root() async {
    if (rootName == null || rootName.trim().isEmpty) return parentFolderId;
    if (rootId == null) {
      rootId = await _newFolder(repository, report, rootName.trim(), parentFolderId);
      report.rootFolderId = rootId;
    }
    return rootId;
  }

  Future<String?> folderFor(List<({String key, String name})> chain) async {
    var parent = await root();
    for (final level in chain) {
      parent = folderIds[level.key] ??= await _newFolder(repository, report, level.name, parent);
    }
    return parent;
  }

  List<({String key, String name})> chainOf(String path, {bool own = false}) {
    final segs = path.contains('/') ? path.substring(0, path.lastIndexOf('/')).split('/') : <String>[];
    return [
      for (var i = 0; i < segs.length; i++) (key: segs.sublist(0, i + 1).join('/'), name: notion ? notionName(segs[i]) : segs[i]),
      if (own) (key: path.substring(0, path.lastIndexOf('.')).replaceFirst(RegExp(r'_all$'), ''), name: notionName(path.substring(path.lastIndexOf('/') + 1))),
    ];
  }

  /// A page that has a folder of the same name (its sub-pages, the rows of its table) lies in that folder.
  List<({String key, String name})> chainOfPage(SourceFile f) {
    final stem = f.path.substring(0, f.path.lastIndexOf('.')).replaceFirst(RegExp(r'_all$'), '');
    return chainOf(f.path, own: notion && directories.contains(stem));
  }

  // --- the PDFs first: their notes get their ids from the repository and links need them
  final pageIndex = PathIndex<PageRef>();
  final tempDir = pdfs.isEmpty ? null : await Directory.systemTemp.createTemp('notation_import');
  try {
    for (final f in pdfs) {
      try {
        final bytes = await f.read();
        final name = p.basename(f.name).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final temp = File(p.join(tempDir!.path, '${pdfs.indexOf(f)}', name));
        await temp.parent.create(recursive: true);
        await temp.writeAsBytes(bytes);
        final folder = await folderFor(chainOfPage(f));
        final id = await createNoteFromPdf(repository, temp.path, folderId: folder, directory: pdfDirectory);
        await temp.delete();
        pageIndex.add(f.path, PageRef(id, p.basenameWithoutExtension(f.name)));
        report.pdfs++;
        report.firstNoteId ??= id;
      } catch (e) {
        report.failed.add('${f.path}: $e');
      }
      step();
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    if (tempDir != null) await tempDir.delete(recursive: true).catchError((Object _) => tempDir);
  }

  // --- the pages: read them, give them ids, so every link can find its page
  for (final page in pages) {
    try {
      page.text = utf8.decode(await page.file.read(), allowMalformed: true);
    } catch (e) {
      report.failed.add('${page.file.path}: $e');
      page.unreadable = true;
    }
    page.id = NoteRepository.newId();
    if (notion && page.kind == 'md') {
      final h1 = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(page.text.trimLeft().startsWith('#') ? page.text.trimLeft() : '');
      final heading = h1?.group(1)?.trim();
      if (heading != null && heading.isNotEmpty) page.title = heading;
    }
    if (page.title.isEmpty) page.title = 'Untitled';
    pageIndex.add(page.file.path, PageRef(page.id, page.title));
  }
  final byFolder = <String, Map<String, PageRef>>{};
  for (final page in pages) {
    if (page.kind != 'md') continue;
    (byFolder[page.file.directory] ??= {})[page.title.toLowerCase()] = PageRef(page.id, page.title);
  }

  // --- convert and write
  final pictureList = <String>[];
  final keptPictures = <String, String?>{};
  for (final page in pages) {
    if (page.unreadable) {
      step();
      continue;
    }
    try {
      final env = ConvertEnv(pages: pageIndex, files: filesIndex, from: page.file.path, pictures: pictureList);
      final String text;
      var pageTags = <String>{};
      if (page.kind == 'csv') {
        final stem = page.file.path.substring(0, page.file.path.length - 4).replaceFirst(RegExp(r'_all$'), '');
        text = notionTable(page.text, title: page.title, rows: byFolder[stem] ?? const {});
        report.tables++;
      } else if (notion) {
        final dir = page.file.directory;
        final row = dir.isNotEmpty && (paths.contains('$dir.csv') || paths.contains('${dir}_all.csv'));
        text = convertNotionPage(page.text, env, title: page.title, databaseRow: row).text;
        report.notes++;
      } else {
        final converted = convertObsidianPage(page.text, env, title: page.title);
        text = converted.text;
        pageTags = converted.tags;
        report.notes++;
      }
      report.links += env.links;
      report.missing.addAll(env.missing);
      report.skipped.addAll(env.skippedFiles);
      final withPictures = await _keepPictures(text, page.id, pictureList, pictureFiles, keptPictures, report);
      final folder = await folderFor(chainOfPage(page.file));
      await repository.createNote(title: page.title, folderId: folder, id: page.id);
      final note = (await repository.loadNote(page.id))!;
      note.documentText = withPictures;
      await repository.saveNote(note);
      if (tags != null && pageTags.isNotEmpty) await tags.setTags(page.id, pageTags);
      report.firstNoteId ??= page.id;
    } catch (e) {
      report.failed.add('${page.file.path}: $e');
    }
    step();
    await Future<void>.delayed(Duration.zero);
  }
  return report;
}

Future<String> _newFolder(NoteRepository repository, ImportReport report, String name, String? parent) async {
  report.folders++;
  return repository.createFolder(name.isEmpty ? 'Untitled' : name, parentId: parent);
}

/// [text] with every picture mark replaced by the target of the kept picture (a picture that cannot be read is replaced by its
/// description).
Future<String> _keepPictures(
  String text,
  String noteId,
  List<String> pictureList,
  Map<String, SourceFile> pictureFiles,
  Map<String, String?> kept,
  ImportReport report,
) async {
  final pattern = RegExp(r'!\[([^\]]*)\]\(' + pictureMarkPattern.pattern + r'\)');
  final matches = pattern.allMatches(text).toList();
  if (matches.isEmpty) return text;
  final out = StringBuffer();
  var at = 0;
  for (final m in matches) {
    out.write(text.substring(at, m.start));
    at = m.end;
    final path = pictureList[int.parse(m.group(2)!)];
    final key = '$noteId|$path';
    if (!kept.containsKey(key)) {
      try {
        final bytes = await pictureFiles[path]!.read();
        final picture = await DocumentImages.forKeeping(Uint8List.fromList(bytes));
        kept[key] = await DocumentImages.keep(noteId, picture.bytes, picture.ext);
        report.pictures++;
      } catch (_) {
        kept[key] = null;
        report.skipped.add(path.substring(path.lastIndexOf('/') + 1));
      }
    }
    final target = kept[key];
    out.write(target == null ? m.group(1)! : '![${m.group(1)}]($target)');
  }
  out.write(text.substring(at));
  return out.toString();
}

/// Makes a PDF note of each of [pdfs] (a name with its bytes). The PDFs of a GoodNotes notebook come through here: its handwriting
/// is in a format that is not read, so a notice says so.
Future<ImportReport> importPdfs({
  required List<({String name, Uint8List bytes})> pdfs,
  required NoteRepository repository,
  String? folderId,
  Directory? pdfDirectory,
  void Function(int done, int total)? onProgress,
}) async {
  final report = ImportReport();
  final temp = await Directory.systemTemp.createTemp('notation_import');
  try {
    for (var i = 0; i < pdfs.length; i++) {
      final pdf = pdfs[i];
      try {
        final name = p.basename(pdf.name).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final file = File(p.join(temp.path, '$i', name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(pdf.bytes);
        final id = await createNoteFromPdf(repository, file.path, folderId: folderId, directory: pdfDirectory);
        report.pdfs++;
        report.firstNoteId ??= id;
      } catch (e) {
        report.failed.add('${pdf.name}: $e');
      }
      onProgress?.call(i + 1, pdfs.length);
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    await temp.delete(recursive: true).catchError((Object _) => temp);
  }
  return report;
}
