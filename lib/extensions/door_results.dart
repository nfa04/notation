import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import '../import/import_source.dart';
import 'draw_result.dart';
import 'extension_host.dart';
import 'extension_service.dart' show BlockDrawing, ExportedFile, ImportedNote, ImporterResult;

/// What a place gives an extension that can talk to the person: a message, a question, how far a long job is. A place passes the
/// functions that do it (a dialog, a snack bar); without them the calls fail with a sentence, so a script that runs in the
/// background cannot suddenly put a dialog on the screen.
class InteractiveApi extends ExtensionApi {
  final void Function(String text)? onMessage;
  final Future<Object?> Function(String kind, Map<String, Object?> args)? onAsk;
  final void Function(String text, double? fraction)? onProgress;

  InteractiveApi({this.onMessage, this.onAsk, this.onProgress});

  @override
  void message(String text) => onMessage?.call(text);

  @override
  Future<Object?> askPerson(String kind, Map<String, Object?> args) {
    final ask = onAsk;
    if (ask == null) throw ExtensionError('The person cannot be asked here (not while this runs in the background).');
    return ask(kind, args);
  }

  @override
  void showProgress(String text, double? fraction) => onProgress?.call(text, fraction);
}

/// The place an importer runs in: the files the person picked, read when the script asks, and the questions and the progress.
class ImportApi extends InteractiveApi {
  final List<SourceFile> files;
  ImportApi(this.files, {super.onMessage, super.onAsk, super.onProgress});

  @override
  Future<String> readImportFile(int index, {bool binary = false}) async {
    if (index >= files.length) throw ExtensionError('There is no file number $index.');
    final bytes = await files[index].read();
    return binary ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true);
  }
}

const _mostNotes = 20000;
const _largestMarkdown = 2 * 1024 * 1024;
const _mostAttachments = 60;
const _largestImport = 400 * 1024 * 1024;

Uint8List _bytes(Object? b64, String what) {
  if (b64 is! String) throw ExtensionError('$what has to be base64 text.');
  try {
    return base64Decode(b64);
  } catch (_) {
    throw ExtensionError('$what is not valid base64.');
  }
}

DateTime? _date(Object? v, String what) {
  if (v == null) return null;
  final d = v is String ? DateTime.tryParse(v) : (v is num && v.isFinite ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null);
  if (d == null) throw ExtensionError('"$what" has to be a date like 2026-12-24 or 2026-12-24T09:30.');
  return d;
}

/// The notes an importer answered with, checked: `{ notes: [{ path, title, markdown, tags, created, updated, attachments: [{ name,
/// base64 }], pdf: { name, base64 }, sourceId }], notices: [text] }`. Anything that is not right fails with [ExtensionError] and
/// nothing is made.
ImporterResult parseImporterResult(Object? value) {
  if (value is! Map) throw ExtensionError('An importer has to answer with { notes: [...] }.');
  final raw = value['notes'];
  if (raw is! List) throw ExtensionError('"notes" has to be a list.');
  if (raw.length > _mostNotes) throw ExtensionError('Too many notes in one go (at most $_mostNotes).');
  final notes = <ImportedNote>[];
  var total = 0;
  final seen = <String>{};
  for (final n in raw) {
    if (n is! Map) throw ExtensionError('A note has to be an object.');
    final title = n['title'];
    if (title != null && (title is! String || title.length > 200)) throw ExtensionError('"title" has to be text of up to 200 characters.');
    final path = n['path'];
    if (path != null && (path is! String || path.length > 400 || path.split('/').contains('..'))) throw ExtensionError('"path" has to be like Folder/Sub/Name.');
    final markdown = n['markdown'] ?? '';
    if (markdown is! String || markdown.length > _largestMarkdown) throw ExtensionError('"markdown" has to be text of up to 2 MB.');
    if ((title == null || (title as String).trim().isEmpty) && (path == null || (path as String).trim().isEmpty)) throw ExtensionError('A note needs a "title" or a "path".');
    final tags = n['tags'];
    if (tags != null && (tags is! List || tags.length > 50 || tags.any((t) => t is! String || t.isEmpty || t.length > 80))) throw ExtensionError('"tags" has to be a list of up to 50 short texts.');
    final attachments = <String, Uint8List>{};
    final att = n['attachments'];
    if (att != null) {
      if (att is! List || att.length > _mostAttachments) throw ExtensionError('"attachments" has to be a list of up to $_mostAttachments.');
      for (final a in att) {
        if (a is! Map || a['name'] is! String || (a['name'] as String).isEmpty || (a['name'] as String).length > 200) throw ExtensionError('An attachment needs a "name" and "base64".');
        final data = _bytes(a['base64'], 'The "base64" of an attachment');
        total += data.length;
        attachments[a['name'] as String] = data;
      }
    }
    ({String name, Uint8List bytes})? pdf;
    final rawPdf = n['pdf'];
    if (rawPdf != null) {
      if (rawPdf is! Map || rawPdf['name'] is! String) throw ExtensionError('"pdf" needs a "name" and "base64".');
      final data = _bytes(rawPdf['base64'], 'The "base64" of the pdf');
      total += data.length;
      pdf = (name: rawPdf['name'] as String, bytes: data);
    }
    if (total > _largestImport) throw ExtensionError('The import is too big (at most 400 MB).');
    final sourceId = n['sourceId'];
    if (sourceId != null && (sourceId is! String || sourceId.isEmpty || sourceId.length > 200)) throw ExtensionError('"sourceId" has to be text of up to 200 characters.');
    if (sourceId != null && !seen.add(sourceId as String)) throw ExtensionError('Two notes have the sourceId "$sourceId".');
    final p = (path as String?)?.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '') ?? '';
    final name = (title as String?)?.trim().isNotEmpty == true ? title!.trim() : p.substring(p.lastIndexOf('/') + 1);
    notes.add(ImportedNote(
      path: p,
      title: name,
      markdown: markdown,
      tags: [...?(tags as List?)?.cast<String>()],
      created: _date(n['created'], 'created'),
      updated: _date(n['updated'], 'updated'),
      attachments: attachments,
      pdf: pdf,
      sourceId: sourceId as String?,
    ));
  }
  final notices = value['notices'];
  if (notices != null && (notices is! List || notices.any((x) => x is! String))) throw ExtensionError('"notices" has to be a list of texts.');
  return ImporterResult(notes, [for (final x in (notices as List?)?.cast<String>() ?? const <String>[]) x.length > 300 ? '${x.substring(0, 300)}...' : x]);
}

/// What an exporter answered with: `{ name, text }` or `{ name, base64 }`. The name gets the extension of the exporter.
ExportedFile parseExportedFile(Object? value, String extension) {
  if (value is! Map) throw ExtensionError('An exporter has to answer with { name, text }.');
  var name = value['name'];
  if (name is! String || name.trim().isEmpty || name.length > 120) throw ExtensionError('"name" has to be a file name of up to 120 characters.');
  name = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  if (!name.toLowerCase().endsWith('.$extension')) name = '$name.$extension';
  final Uint8List bytes;
  if (value['text'] is String) {
    bytes = Uint8List.fromList(utf8.encode(value['text'] as String));
  } else if (value['base64'] != null) {
    bytes = _bytes(value['base64'], '"base64"');
  } else {
    throw ExtensionError('Say "text" or "base64".');
  }
  if (bytes.length > 50 * 1024 * 1024) throw ExtensionError('The file is too big (at most 50 MB).');
  return ExportedFile(name, bytes);
}

/// What a block answered with: `{ width, height, strokes: [...as a drawing tool's], texts: [{ x, y, text, size, color }] }`.
BlockDrawing parseBlockDrawing(Object? value) {
  if (value is! Map) throw ExtensionError('A block has to answer with { width, height, strokes, texts }.');
  double size(String key) {
    final v = value[key];
    if (v is! num || !v.isFinite || v < 10 || v > 2000) throw ExtensionError('"$key" has to be a number from 10 to 2000.');
    return v.toDouble();
  }

  final w = size('width'), h = size('height');
  // the strokes are checked like a drawing tool's (the same limits)
  parseDrawnStrokes(value['strokes'], color: const Color(0xFF000000), width: 1);
  final strokes = [for (final s in (value['strokes'] as List?) ?? const []) (s as Map).cast<String, Object?>()];
  final raw = value['texts'];
  if (raw != null && (raw is! List || raw.length > 300)) throw ExtensionError('"texts" has to be a list of up to 300 entries.');
  final texts = <Map<String, Object?>>[];
  for (final t in (raw as List?) ?? const []) {
    if (t is! Map || t['text'] is! String || (t['text'] as String).length > 300) throw ExtensionError('A text needs "text" (up to 300 letters), "x" and "y".');
    final x = t['x'], y = t['y'], s = t['size'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite || x.abs() > 100000 || y.abs() > 100000) throw ExtensionError('A text needs a "x" and a "y".');
    if (s != null && (s is! num || !s.isFinite || s < 4 || s > 400)) throw ExtensionError('"size" of a text has to be from 4 to 400.');
    if (t['color'] != null && colorFromHex(t['color']) == null) throw ExtensionError('"color" has to be like #1a2b3c.');
    texts.add({'x': x, 'y': y, 'text': t['text'], 'size': s ?? 14, if (t['color'] != null) 'color': t['color']});
  }
  return BlockDrawing(w, h, strokes, texts);
}
