import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../models/canvas_models.dart';
import '../models/connector.dart';
import '../models/image_item.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';
import '../models/pdf_models.dart';
import '../models/rich_text.dart';
import '../models/bezier.dart';
import '../models/brush_desc.dart';
import '../models/gradient.dart';
import '../models/stroke_label.dart';
import '../models/layers.dart';
import '../search/search_query.dart' show InkText;
import 'note_data.dart';
import 'note_text_repository.dart' show InkRead;
import 'safe_names.dart';
import 'safe_zip.dart';
import '../l10n/language.dart';

/// The `.uninote` file: one note in one file, to keep, to send, or to open on
/// another device. It is an ordinary ZIP archive, so it can be looked into with
/// any archive tool:
///
///     manifest.json      what the note is (see below)
///     strokes.bin        the pen strokes, packed (see [encodeStrokes])
///     source.pdf         the imported PDF, for a note made from one
///     media/<n>.<ext>    the pictures placed on pages, and the theme image
///     media/audio/<id>.wav   the sounds kept with the note (recordings, the note read aloud)
///     brushes/<id>.strokedesc   the designed brushes its lines are drawn with (JSON, see [BrushDesc.toJson]), so that they look the
///                        same where the brush was never made; <id> is the id of the brush without its `custom:`
///
/// `manifest.json` is JSON with the fields `format` ("uninote"), `version` (1),
/// `generator`, `exportedAt` and `note` (title, times, page setup, the written
/// `document` with its `spans`, the `pdf` it comes from, the `themeImage`), then
/// `textBoxes`, `images` and `highlights` as lists. Positions are in the page space
/// of the editor (800 units wide, origin top left). Colours are ARGB integers.
/// Who made what: a text box, picture or highlight has an `author` (a name), and `strokes`
/// has `authors` (the names) and `by` (stroke id -> number of its name); all are left out
/// where the author is not known.
/// What the AI made of the note (a summary, a presentation, ...) is `ai`, a list of `kind`, `key`, `content`, `sourceHash`, `model`
/// and `createdAt`: it travels with the note so that it need not be made again.
/// What the handwriting reader made of the strokes is `ink`: `texts` (`key`, `page`, `text`, `l`, `t`, `r`, `b`: the text of a block of strokes
/// and where it lies) and `reads` (`key`, `ids`, `text`, `latex`: formulas and conversions of selections). The keys name the strokes as
/// they are, so a device that gets the note does not read it again. It is not part of what makes two note files the same note.
/// `audio` lists the sounds kept with the note: `id`, `kind` ("recording" or "speech"), `title`, `file`, `durationMs` and `createdAt`.
/// A reader must ignore fields it does not know; a change that breaks readers
/// raises `version`.
const noteFileExtension = 'uninote';
const noteFileVersion = 1;

/// Why a file is not a note file this app can open.
class NoteFileException implements Exception {
  final String message;
  const NoteFileException(this.message);

  @override
  String toString() => message;
}

/// A sound kept with a note, as it goes into a note file.
class AudioPart {
  final String id;

  /// 'recording' or 'speech'.
  final String kind;
  final String title;
  final Uint8List bytes;
  final int durationMs;
  final DateTime createdAt;

  const AudioPart({required this.id, required this.kind, required this.title, required this.bytes, required this.durationMs, required this.createdAt});
}

/// What goes into a note file: the note, and the bytes of the files it refers to
/// (read from disk by the caller; null when a file is missing).
class NoteFileParts {
  final NoteData note;
  final DateTime? createdAt, updatedAt;
  final Uint8List? pdf;
  final Uint8List? themeImage;

  /// Picture id -> its bytes.
  final Map<String, Uint8List> images;

  /// Lets the file say which way a picture or the theme image is stored.
  final Map<String, String> imageExtensions;
  final String themeExtension;

  /// The pictures in the written document (`![...](image:<file>)`): where the text says they are -> their bytes.
  final Map<String, Uint8List> documentImages;

  /// What the AI made of the note.
  final List<NoteAiRow> ai;

  /// What the handwriting reader made of the strokes (see [InkReadingParts]).
  final InkReadingParts ink;

  /// The sounds kept with the note.
  final List<AudioPart> audio;

  const NoteFileParts(
    this.note, {
    this.createdAt,
    this.updatedAt,
    this.pdf,
    this.themeImage,
    this.images = const {},
    this.imageExtensions = const {},
    this.themeExtension = 'png',
    this.documentImages = const {},
    this.ai = const [],
    this.ink = InkReadingParts.none,
    this.audio = const [],
  });
}

/// What the handwriting reader made of a note's strokes (the `ink_text` and `ink_reads` tables), so that a device that gets the note does
/// not read it again. Keys name the strokes as they are, so they are the same on every device.
class InkReadingParts {
  final List<InkText> texts;
  final List<InkRead> reads;
  const InkReadingParts({this.texts = const [], this.reads = const []});
  static const none = InkReadingParts();
  bool get isEmpty => texts.isEmpty && reads.isEmpty;
}

/// A note file, read.
class ParsedNoteFile {
  final NoteData note;
  final DateTime? createdAt, updatedAt;
  final Uint8List? pdf;
  final Uint8List? themeImage;
  final String themeExtension;

  /// Picture id -> bytes and file extension.
  final Map<String, ({Uint8List bytes, String extension})> images;

  /// The pictures in the written document: where the text says they are -> their bytes.
  final Map<String, Uint8List> documentImages;

  /// Things the file named that were not in it.
  final List<String> warnings;

  /// What the AI made of the note.
  final List<NoteAiRow> ai;

  /// What the handwriting reader made of the strokes.
  final InkReadingParts ink;

  /// The sounds kept with the note.
  final List<AudioPart> audio;

  /// The designed brushes the file came with (`brushes/*.strokedesc`).
  final List<BrushDesc> brushes;

  ParsedNoteFile(this.note,
      {this.ai = const [],
      this.ink = InkReadingParts.none,
      this.audio = const [],
      this.brushes = const [],
      this.createdAt,
      this.updatedAt,
      this.pdf,
      this.themeImage,
      this.themeExtension = 'png',
      this.images = const {},
      this.documentImages = const {},
      this.warnings = const []});
}

/// The strokes as one binary block: `UNST`, the version (2), the number of strokes (all
/// 32-bit little-endian), then for each stroke its id (one byte of length, then UTF-8), its page,
/// colour (ARGB) and width (float32), then (from version 3) the dash (a byte) and the fill (a byte for whether there is
/// one, and the colour), the number of points and the points as float32 x, y pairs, then (from version 4) a byte for whether
/// there is a pressure for every point, and the pressures as bytes, then (from version 5) the brush (one byte of length, then
/// UTF-8; length 0: the pen), then (from version 6) the layer (the same: length 0 is the base layer).
/// Versions 1 (no ids), 2 (no dash and fill), 3 (no pressure), 4 (no brush) and 5 (no layer) are still read.
Uint8List encodeStrokes(Map<int, List<DrawingStroke>> strokes) {
  final all = [
    for (final e in strokes.entries)
      for (final s in e.value)
        if (s.points.length >= 2) (e.key, s),
  ];
  final ids = [for (final (_, s) in all) utf8.encode(s.id)];
  final brushes = [for (final (_, s) in all) s.brush == penBrushId ? const <int>[] : utf8.encode(s.brush).take(255).toList()];
  final layers = [for (final (_, s) in all) s.layer == baseLayerId ? const <int>[] : utf8.encode(s.layer).take(255).toList()];
  var size = 12;
  for (var i = 0; i < all.length; i++) {
    size += 17 + 6 + 1 + 1 + 1 + ids[i].length + brushes[i].length + layers[i].length + all[i].$2.points.length * 9;
  }
  final data = ByteData(size);
  var at = 0;
  void u32(int v) {
    data.setUint32(at, v, Endian.little);
    at += 4;
  }

  void f32(double v) {
    data.setFloat32(at, v, Endian.little);
    at += 4;
  }

  u32(0x54534E55); // "UNST"
  u32(6);
  u32(all.length);
  for (var i = 0; i < all.length; i++) {
    final (page, s) = all[i];
    data.setUint8(at++, ids[i].length);
    for (final b in ids[i]) {
      data.setUint8(at++, b);
    }
    u32(page);
    u32(s.color.toARGB32());
    f32(s.width);
    data.setUint8(at++, s.dash.index);
    data.setUint8(at++, s.fill == null ? 0 : 1);
    u32(s.fill?.toARGB32() ?? 0);
    u32(s.points.length);
    for (final p in s.points) {
      f32(p.dx);
      f32(p.dy);
    }
    final pr = s.pressures;
    final has = pr != null && pr.length == s.points.length;
    data.setUint8(at++, has ? 1 : 0);
    if (has) {
      for (final b in pr) {
        data.setUint8(at++, b);
      }
    }
    data.setUint8(at++, brushes[i].length);
    for (final b in brushes[i]) {
      data.setUint8(at++, b);
    }
    data.setUint8(at++, layers[i].length);
    for (final b in layers[i]) {
      data.setUint8(at++, b);
    }
  }
  return data.buffer.asUint8List(0, at);
}

Map<int, List<DrawingStroke>> decodeStrokes(Uint8List bytes) {
  if (bytes.length < 12) throw NoteFileException(tr('The strokes of the file are cut off'));
  final data = ByteData.sublistView(bytes);
  var at = 0;
  int u32() {
    if (at + 4 > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
    final v = data.getUint32(at, Endian.little);
    at += 4;
    return v;
  }

  double f32() {
    if (at + 4 > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
    final v = data.getFloat32(at, Endian.little);
    at += 4;
    return v;
  }

  if (u32() != 0x54534E55) throw NoteFileException(tr('The strokes of the file are not in a known form'));
  final version = u32();
  if (version < 1 || version > 6) throw NoteFileException(tr('The strokes are in version {version}, which this app does not know', {'version': version}));
  final count = u32();
  final out = <int, List<DrawingStroke>>{};
  for (var i = 0; i < count; i++) {
    String? id;
    if (version >= 2) {
      if (at >= bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      final n = data.getUint8(at++);
      if (at + n > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      id = utf8.decode(bytes.sublist(at, at + n), allowMalformed: true);
      at += n;
    }
    final page = u32();
    if (page >= maxNotePage) throw NoteFileException(tr('The strokes of the file are not in a known form'));
    final color = Color(u32());
    final width = f32();
    if (!width.isFinite) throw NoteFileException(tr('The strokes of the file are not in a known form'));
    var dash = StrokeDash.solid;
    Color? fill;
    if (version >= 3) {
      if (at + 2 > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      dash = StrokeDash.byIndex(data.getUint8(at++));
      final filled = data.getUint8(at++) == 1;
      final colour = u32();
      if (filled) fill = Color(colour);
    }
    final n = u32();
    if (n > (bytes.length - at) ~/ 8) throw NoteFileException(tr('The strokes of the file are cut off'));
    final points = [for (var k = 0; k < n; k++) Offset(f32(), f32())];
    if (points.any((o) => !o.dx.isFinite || !o.dy.isFinite)) throw NoteFileException(tr('The strokes of the file are not in a known form'));
    List<int>? pressures;
    if (version >= 4) {
      if (at >= bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      if (data.getUint8(at++) == 1) {
        if (at + n > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
        pressures = [for (var k = 0; k < n; k++) data.getUint8(at++)];
      }
    }
    var brush = penBrushId;
    if (version >= 5) {
      if (at >= bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      final len = data.getUint8(at++);
      if (at + len > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      if (len > 0) brush = utf8.decode(bytes.sublist(at, at + len), allowMalformed: true);
      at += len;
    }
    var layer = baseLayerId;
    if (version >= 6) {
      if (at >= bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      final len = data.getUint8(at++);
      if (at + len > bytes.length) throw NoteFileException(tr('The strokes of the file are cut off'));
      if (len > 0) layer = utf8.decode(bytes.sublist(at, at + len), allowMalformed: true);
      at += len;
    }
    out.putIfAbsent(page, () => []).add(DrawingStroke(id: id, color: color, width: width, points: points, dash: dash, fill: fill, pressures: pressures, brush: brush, layer: layer));
  }
  return out;
}

List<Map<String, Object?>> _spansJson(List<TextSpanAttribute> spans) => [
      for (final s in spans) {'s': s.start, 'e': s.end, 't': s.type.name, if (s.value != null) 'v': s.value},
    ];

List<TextSpanAttribute> _spansFrom(Object? json) => [
      for (final m in _listOf(json))
        if (AttributeType.values.where((t) => t.name == m['t']).firstOrNull case final type?)
          if (_int(m['s']) case final start? when start >= 0)
            if (_int(m['e']) case final end? when end >= start) TextSpanAttribute(start: start, end: end, type: type, value: _str(m['v'])),
    ];

// What a note file says is read without trusting its form: a part of the wrong kind is no part, instead of an error.

String? _str(Object? v) => v is String ? v : null;

int? _int(Object? v) => v is num && v.isFinite ? v.toInt() : null;

Map<String, Object?> _mapOf(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

List<Map<String, Object?>> _listOf(Object? v) => [for (final e in v is List ? v : const []) if (e is Map) e.cast<String, Object?>()];

/// The most pages a note file may name. A blank note has as many pages as its last used one, so a page far out would make the editor
/// build them all.
const int maxNotePage = 10000;

int? _page(Object? v) {
  final page = _int(v);
  return page != null && page >= 0 && page < maxNotePage ? page : null;
}

/// The descriptions of the designed brushes that [strokes] are drawn with (the ones this device knows; a line of a brush it does not
/// know is drawn as the pen draws it, and has nothing to take along).
List<BrushDesc> designedBrushesUsedBy(Map<int, List<DrawingStroke>> strokes) {
  final ids = <String>{
    for (final list in strokes.values)
      for (final s in list)
        if (s.brush.startsWith(customBrushPrefix)) s.brush,
  };
  return [for (final id in ids.toList()..sort()) ?CustomBrushes.of(id)];
}

/// The most designed brushes a note file may bring.
const maxBrushesInNoteFile = 200;

/// One file of the archive: its name, its bytes, and whether they are worth compressing.
typedef NoteFileEntry = (String name, Uint8List bytes, bool compress);

/// Packs [entries] as a ZIP archive. This is the slow part of making a note file and
/// only takes plain data, so it can run apart from the screen ([Isolate.run]).
Uint8List zipNoteFile(List<NoteFileEntry> entries) {
  final archive = Archive();
  for (final (name, bytes, compress) in entries) {
    final f = ArchiveFile.bytes(name, bytes);
    if (!compress) f.compression = CompressionType.none; // a PDF or a picture is compressed already
    archive.add(f);
  }
  return ZipEncoder().encodeBytes(archive);
}

/// A big file taken out of a note file (see [splitNoteFile]): its name in the archive, the SHA-256 of its bytes, and the bytes.
typedef NoteBlob = ({String name, String hash, Uint8List bytes});

/// Whether the file [name] of a note file is one of those that are big and do not change when the strokes do: the PDF, the pictures
/// and the sounds.
bool _isNoteAttachment(String name) => name == 'source.pdf' || name.startsWith('media/');

/// Takes the big files (at least [minBlob] bytes: the PDF, pictures and sounds) out of the note file [bytes]: what is left is the note
/// without them ([slim], still a note file, which holds the strokes and the text), and [blobs] are the files. Null when there is no
/// such file. A cloud folder keeps the blobs once, under the name of their hash, and writes only [slim] again when the person draws on
/// a PDF of many megabytes.
({Uint8List slim, List<NoteBlob> blobs})? splitNoteFile(Uint8List bytes, {int minBlob = 64 * 1024}) {
  final x = decodeZipLimited(bytes);
  final kept = <NoteFileEntry>[];
  final blobs = <NoteBlob>[];
  for (final f in x.files) {
    if (!f.isFile) continue;
    final content = f.content;
    if (content.length >= minBlob && _isNoteAttachment(f.name)) {
      blobs.add((name: f.name, hash: sha256.convert(content).toString(), bytes: content));
    } else {
      kept.add((f.name, content, !_isNoteAttachment(f.name)));
    }
  }
  if (blobs.isEmpty) return null;
  return (slim: zipNoteFile(kept), blobs: blobs);
}

/// The note file that [splitNoteFile] took [blobs] (name -> bytes) out of, whole again.
Uint8List joinNoteFile(Uint8List slim, Map<String, Uint8List> blobs) {
  final x = decodeZipLimited(slim);
  final entries = <NoteFileEntry>[];
  for (final f in x.files) {
    if (!f.isFile) continue;
    entries.add((f.name, f.content, !_isNoteAttachment(f.name)));
  }
  for (final e in blobs.entries) {
    entries.add((e.key, e.value, false));
  }
  return zipNoteFile(entries);
}

/// The big files of a note file (see [splitNoteFile]) that are the size [lengths] says (name -> length), by hash: the ones a device
/// that has the note already can take from its own copy instead of fetching them. Null for something that is not a note file.
Map<String, Uint8List> noteAttachmentsByHash(Uint8List bytes, Set<int> lengths) {
  final found = <String, Uint8List>{};
  try {
    for (final f in decodeZipLimited(bytes).files) {
      if (!f.isFile || !_isNoteAttachment(f.name) || !lengths.contains(f.size)) continue;
      final content = f.content;
      found[sha256.convert(content).toString()] = content;
    }
  } catch (_) {
    // not a note file: nothing to take from it
  }
  return found;
}

/// The note file for [parts], as the bytes of the archive.
Uint8List encodeNoteFile(NoteFileParts parts, {DateTime? now}) => zipNoteFile(noteFileEntries(parts, now: now));

/// The files that make up the note file for [parts], the manifest first.
List<NoteFileEntry> noteFileEntries(NoteFileParts parts, {DateTime? now}) {
  final n = parts.note;
  final files = <NoteFileEntry>[];

  void add(String name, Uint8List bytes, {bool compress = true}) => files.add((name, bytes, compress));

  final docImages = <Map<String, Object?>>[];
  for (final e in parts.documentImages.entries) {
    final ext = e.key.contains('.') ? e.key.substring(e.key.lastIndexOf('.') + 1).replaceAll(RegExp(r'[^a-z0-9]'), '') : 'png';
    final file = 'media/document-${docImages.length + 1}.${ext.isEmpty ? 'png' : ext}';
    add(file, e.value, compress: false);
    docImages.add({'target': e.key, 'file': file});
  }
  final images = <Map<String, Object?>>[];
  var mediaCount = 0;
  final named = <String, String>{};
  for (final e in n.images.entries) {
    for (final m in e.value) {
      final bytes = parts.images[m.id];
      String? file;
      if (bytes != null) {
        file = named[m.id] ??= 'media/${++mediaCount}.${parts.imageExtensions[m.id] ?? 'png'}';
        if (!files.any((f) => f.$1 == file)) add(file, bytes, compress: false);
      }
      images.add({
        'id': m.id,
        'page': e.key,
        'x': m.position.dx,
        'y': m.position.dy,
        'w': m.size.width,
        'h': m.size.height,
        'file': file,
        if (m.author != null) 'author': m.author,
        if (m.layer != baseLayerId) 'layer': m.layer,
        if (m.group != noGroup) 'group': m.group,
      });
    }
  }
  String? theme;
  if (parts.themeImage != null) {
    theme = 'media/theme.${parts.themeExtension}';
    add(theme, parts.themeImage!, compress: false);
  }
  final audio = <Map<String, Object?>>[];
  for (final a in parts.audio) {
    final file = 'media/audio/${a.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.wav';
    add(file, a.bytes); // (a mu-law sound is not compressed as much as a picture, a little still)
    audio.add({'id': a.id, 'kind': a.kind, 'title': a.title, 'file': file, 'durationMs': a.durationMs, 'createdAt': a.createdAt.millisecondsSinceEpoch});
  }
  final hasPdf = n.pdfName != null;
  if (hasPdf && parts.pdf != null) add('source.pdf', parts.pdf!, compress: false);

  final strokes = encodeStrokes(n.strokes);
  add('strokes.bin', strokes);
  // who drew what: the names once, and for each stroke the number of its name (strokes.bin has no room for it)
  final strokeNames = <String>[];
  final strokeBy = <String, int>{};
  for (final list in n.strokes.values) {
    for (final s in list) {
      final a = s.author;
      if (a != null && s.points.length >= 2) strokeBy[s.id] = strokeNames.contains(a) ? strokeNames.indexOf(a) : (strokeNames..add(a)).length - 1;
    }
  }

  // the connectors: for each the items its ends are fixed to (strokes.bin has no room for it either)
  final strokeLinks = <String, Object?>{
    for (final list in n.strokes.values)
      for (final s in list)
        if (s.link != null && s.points.length >= 2) s.id: s.link!.toJson(),
  };
  // the groups, and the points and handles of the lines of the pen for curves
  final strokeGroups = <String, Object?>{
    for (final list in n.strokes.values)
      for (final s in list)
        if (s.group != noGroup && s.points.length >= 2) s.id: s.group,
  };
  final strokeCurves = <String, Object?>{
    for (final list in n.strokes.values)
      for (final s in list)
        if (s.curve != null && s.points.length >= 2) s.id: s.curve!.encode(),
  };
  final strokeGradients = <String, Object?>{
    for (final list in n.strokes.values)
      for (final s in list)
        if (s.gradient != null && s.fill != null && s.points.length >= 2) s.id: s.gradient!.encode(),
  };
  final strokeLabels = <String, Object?>{
    for (final list in n.strokes.values)
      for (final s in list)
        if (s.label != null && s.points.length >= 2) s.id: s.label!.encode(),
  };

  final manifest = <String, Object?>{
    'format': 'uninote',
    'version': noteFileVersion,
    'generator': 'Notation',
    'exportedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
    'note': {
      'id': n.id,
      'title': n.title,
      'createdAt': parts.createdAt?.millisecondsSinceEpoch,
      'updatedAt': parts.updatedAt?.millisecondsSinceEpoch,
      'background': n.background.name,
      if (n.layers.toJsonText() != null) 'layers': jsonDecode(n.layers.toJsonText()!),
      'pageFormat': n.pageFormat.name,
      'landscape': n.landscape,
      if (n.nativePages.isNotEmpty) 'nativePages': (n.nativePages.toList()..sort()),
      'marginLeft': n.marginLeft,
      'marginRight': n.marginRight,
      'marginTop': n.marginTop,
      'marginBottom': n.marginBottom,
      'document': {'text': n.documentText, 'spans': _spansJson(n.documentSpans)},
      'pdf': hasPdf
          ? {
              'name': n.pdfName,
              'sha256': n.pdfSha256,
              'pages': n.pdfPageCount,
              'file': parts.pdf != null ? 'source.pdf' : null,
            }
          : null,
      'themeImage': theme,
    },
    'strokes': {
      'file': 'strokes.bin',
      'count': (ByteData.sublistView(strokes).getUint32(8, Endian.little)),
      if (strokeNames.isNotEmpty) 'authors': strokeNames,
      if (strokeBy.isNotEmpty) 'by': strokeBy,
      if (strokeLinks.isNotEmpty) 'links': strokeLinks,
      if (strokeGroups.isNotEmpty) 'groups': strokeGroups,
      if (strokeCurves.isNotEmpty) 'curves': strokeCurves,
      if (strokeGradients.isNotEmpty) 'gradients': strokeGradients,
      if (strokeLabels.isNotEmpty) 'labels': strokeLabels,
    },
    'textBoxes': [
      for (final e in n.textBoxes.entries)
        for (final b in e.value)
          {
            'id': b.id,
            'page': e.key,
            'x': b.position.dx,
            'y': b.position.dy,
            'w': b.size.width,
            'h': b.size.height,
            'fontSize': b.fontSize,
            'text': b.controller.text,
            'spans': _spansJson(b.controller.attributes),
            'style': b.style.isDefault ? null : b.style.toJson(),
            if (b.author != null) 'author': b.author,
            if (b.layer != baseLayerId) 'layer': b.layer,
            if (b.group != noGroup) 'group': b.group,
          },
    ],
    'images': images,
    if (docImages.isNotEmpty) 'documentImages': docImages,
    if (audio.isNotEmpty) 'audio': audio,
    if (parts.ai.isNotEmpty)
      'ai': [
        for (final a in parts.ai)
          {
            'kind': a.kind,
            if (a.key.isNotEmpty) 'key': a.key,
            'content': a.content,
            'sourceHash': a.sourceHash,
            if (a.model.isNotEmpty) 'model': a.model,
            'createdAt': a.createdAt.millisecondsSinceEpoch,
          },
      ],
    if (!parts.ink.isEmpty)
      'ink': {
        'texts': [
          for (final t in parts.ink.texts)
            {'key': t.key, 'page': t.page, 'text': t.text, 'l': t.bounds.left, 't': t.bounds.top, 'r': t.bounds.right, 'b': t.bounds.bottom, if (t.unsure.isNotEmpty) 'u': t.unsure},
        ],
        'reads': [
          for (final r in parts.ink.reads) {'key': r.key, if (r.ids.isNotEmpty) 'ids': r.ids, if (r.text != null) 'text': r.text, if (r.latex != null) 'latex': r.latex},
        ],
      },
    'highlights': [
      for (final e in n.highlights.entries)
        for (final h in e.value)
          {
            'id': h.id,
            'page': e.key,
            'l': h.rect.left,
            't': h.rect.top,
            'r': h.rect.right,
            'b': h.rect.bottom,
            'color': h.color.toARGB32(),
            'commentBox': h.commentBox,
            if (h.author != null) 'author': h.author,
          },
    ],
  };
  // the designed brushes its lines are drawn with go along, so that the lines look the same on a device that never made them
  for (final desc in designedBrushesUsedBy(n.strokes)) {
    add('brushes/${desc.id.substring(customBrushPrefix.length)}.$strokeDescExtension', desc.toBytes());
  }
  // the manifest first, so that it is the first thing a tool shows
  return [
    ('manifest.json', Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(manifest))), true),
    ...files,
  ];
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

/// A digest of what a note file holds, the same for two files that [sameNoteContent] takes for the same; null for anything that is
/// not a note file.
String? noteContentDigest(Uint8List bytes) {
  try {
    final x = decodeZipLimited(bytes);
    final files = {for (final f in x.files) if (f.isFile) f.name: f};
    final out = _DigestSink();
    final sink = sha256.startChunkedConversion(out);
    for (final name in files.keys.toList()..sort()) {
      final f = files[name]!;
      sink.add(utf8.encode('$name\n'));
      if (name == 'manifest.json') {
        final m = (jsonDecode(utf8.decode(f.content)) as Map).cast<String, Object?>()
          ..remove('exportedAt')
          ..remove('ai')
          ..remove('ink');
        final note = (m['note'] as Map?)?.cast<String, Object?>();
        if (note != null) {
          note
            ..remove('createdAt')
            ..remove('updatedAt');
          m['note'] = note;
        }
        sink.add(utf8.encode(jsonEncode(m)));
      } else {
        final c = f.content;
        sink.add(utf8.encode('${c.length}\n'));
        sink.add(c);
      }
    }
    sink.close();
    return out.digest.toString();
  } catch (_) {
    return null;
  }
}

/// Whether two note files hold the same note: the same files, and the same manifest apart from when the file was made, the times
/// of the note, and what the AI made of it (each device may have made its own). False for anything that is not a note file.
bool sameNoteContent(Uint8List a, Uint8List b) {
  try {
    final x = decodeZipLimited(a), y = decodeZipLimited(b);
    final xs = {for (final f in x.files) if (f.isFile) f.name: f}, ys = {for (final f in y.files) if (f.isFile) f.name: f};
    if (xs.length != ys.length || !xs.keys.every(ys.containsKey)) return false;
    String manifest(ArchiveFile f) {
      final m = (jsonDecode(utf8.decode(f.content)) as Map).cast<String, Object?>()
        ..remove('exportedAt')
        ..remove('ai')
          ..remove('ink');
      final note = (m['note'] as Map?)?.cast<String, Object?>();
      if (note != null) {
        note
          ..remove('createdAt')
          ..remove('updatedAt');
        m['note'] = note;
      }
      return jsonEncode(m);
    }

    for (final name in xs.keys) {
      final p = xs[name]!.content, q = ys[name]!.content;
      if (name == 'manifest.json') {
        if (manifest(xs[name]!) != manifest(ys[name]!)) return false;
        continue;
      }
      if (p.length != q.length) return false;
      for (var i = 0; i < p.length; i++) {
        if (p[i] != q[i]) return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Reads a note file. Throws [NoteFileException] for something that is not one, or that is
/// from a newer version of the app. Pieces that are missing from an otherwise good file are
/// left out and named in [ParsedNoteFile.warnings].
ParsedNoteFile decodeNoteFile(Uint8List bytes) => _guarded(() {
      final Archive archive;
      try {
        archive = decodeZipLimited(bytes);
      } on ArchiveTooBigException {
        throw NoteFileException(tr('This note file is too big to open'));
      } catch (_) {
        throw NoteFileException(tr('This is not a note file (it is not a ZIP archive)'));
      }
      return _decodeNoteFile(archive);
    });

/// What [decodeNoteFile] makes of the files [entries] (as [zipNoteFile] takes them), without zipping them and unzipping them
/// again: for files that are apart already, as a version in the history is.
ParsedNoteFile decodeNoteFileEntries(List<NoteFileEntry> entries) => _guarded(() {
      final archive = Archive();
      for (final (name, bytes, _) in entries) {
        archive.add(ArchiveFile.bytes(name, bytes));
      }
      return _decodeNoteFile(archive);
    });

ParsedNoteFile _guarded(ParsedNoteFile Function() decode) {
  try {
    return decode();
  } on NoteFileException {
    rethrow;
  } catch (_) {
    // a file made by hand or damaged in a way nothing below looks for: it is not a note file, however it is wrong
    throw NoteFileException(tr('This note file is damaged and cannot be read'));
  }
}

ParsedNoteFile _decodeNoteFile(Archive archive) {
  if (archive.isEmpty) throw NoteFileException(tr('This is not a note file (it is not a ZIP archive)'));
  final manifestFile = archive.find('manifest.json');
  if (manifestFile == null) throw NoteFileException(tr('This is not a note file (it has no manifest.json)'));
  final Map<String, Object?> m;
  try {
    m = (jsonDecode(utf8.decode(manifestFile.content)) as Map).cast<String, Object?>();
  } catch (_) {
    throw NoteFileException(tr('The manifest of this note file cannot be read'));
  }
  if (m['format'] != 'uninote') throw NoteFileException(tr('This is not a note file (wrong format)'));
  final version = m['version'];
  if (version is! int || version < 1) throw NoteFileException(tr('The version of this note file is not known'));
  if (version > noteFileVersion) {
    throw NoteFileException(tr('This note file is from a newer version of Notation (file version {version}); update the app to open it', {'version': version}));
  }

  final warnings = <String>[];
  final info = _mapOf(m['note']);
  double num_(Object? v, double fallback) => v is num && v.isFinite ? v.toDouble() : fallback;
  DateTime? time(Object? v) {
    if (v is! int) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(v);
    } on ArgumentError {
      return null; // (a time out of the range there is)
    }
  }

  Uint8List? fileBytes(Object? name) => name is String ? archive.find(name)?.content : null;

  /// Reads one piece of the file; one that is not in the form the app writes is left out and named, the rest of the note is kept.
  T? piece<T>(String warning, T Function() read) {
    try {
      return read();
    } catch (_) {
      warnings.add(warning);
      return null;
    }
  }

  final doc = _mapOf(info['document']);
  final pdf = info['pdf'] is Map ? _mapOf(info['pdf']) : null;
  final pdfBytes = pdf == null ? null : fileBytes(pdf['file']);
  if (pdf != null && pdfBytes == null) warnings.add(tr('The PDF "{name}" is not in the file; the note is opened without it', {'name': _str(pdf['name']) ?? ''}));

  final note = NoteData(
    id: _str(info['id']) ?? '',
    title: _str(info['title']) ?? '',
    background: PageBackground.values.where((b) => b.name == info['background']).firstOrNull ?? PageBackground.blank,
    pageFormat: PageFormat.values.where((f) => f.name == info['pageFormat']).firstOrNull ?? PageFormat.a4,
    landscape: info['landscape'] == true,
    layers: info['layers'] is List ? LayerStack.fromJsonText(jsonEncode(info['layers'])) : LayerStack.plain,
    nativePages: {for (final i in (info['nativePages'] is List ? info['nativePages'] as List : const [])) if (i is int && i >= 0) i},
    marginLeft: num_(info['marginLeft'], 56),
    marginRight: num_(info['marginRight'], 56),
    marginTop: num_(info['marginTop'], 56),
    marginBottom: num_(info['marginBottom'], 56),
    documentText: _str(doc['text']) ?? '',
    documentSpans: _spansFrom(doc['spans']),
    pdfName: pdfBytes == null ? null : _str(pdf!['name']),
    pdfSha256: pdfBytes == null ? null : _str(pdf!['sha256']),
    pdfPageCount: pdfBytes == null ? null : _int(pdf!['pages']),
  );

  final strokesInfo = _mapOf(m['strokes']);
  final strokeBytes = fileBytes(strokesInfo['file']);
  if (strokeBytes != null) {
    note.strokes = decodeStrokes(strokeBytes);
    final names = [for (final a in (strokesInfo['authors'] is List ? strokesInfo['authors'] as List : const [])) a?.toString()];
    final links = _mapOf(strokesInfo['links']);
    if (links.isNotEmpty) {
      for (final list in note.strokes.values) {
        for (final s in list) {
          final l = links[s.id];
          if (l != null) s.link = StrokeLink.fromJson(l);
        }
      }
    }
    final groups = _mapOf(strokesInfo['groups']), curves = _mapOf(strokesInfo['curves']), gradients = _mapOf(strokesInfo['gradients']), labels = _mapOf(strokesInfo['labels']);
    if (groups.isNotEmpty || curves.isNotEmpty || gradients.isNotEmpty || labels.isNotEmpty) {
      for (final list in note.strokes.values) {
        for (final s in list) {
          final g = groups[s.id];
          if (g is String) s.group = g;
          final c = curves[s.id];
          if (c is String) s.curve = CurvedPath.decode(c);
          final gd = gradients[s.id];
          if (gd is String) s.gradient = FillGradient.decode(gd);
          final lb = labels[s.id];
          if (lb is String) s.label = StrokeLabel.decode(lb);
        }
      }
    }
    final by = _mapOf(strokesInfo['by']);
    if (by.isNotEmpty) {
      for (final list in note.strokes.values) {
        for (final s in list) {
          final i = by[s.id];
          if (i is num && i.isFinite && i.toInt() >= 0 && i.toInt() < names.length) s.author = names[i.toInt()];
        }
      }
    }
  } else if (num_(strokesInfo['count'], 0) > 0) {
    warnings.add(tr('The pen strokes are not in the file'));
  }

  for (final b in _listOf(m['textBoxes'])) {
    piece(tr('A text box in the file could not be read and was left out'), () {
      final page = _page(b['page']);
      final id = _str(b['id']);
      if (page == null || id == null) throw const FormatException('no place or id');
      final box = TextBoxWidgetModel(
        id: id,
        position: Offset(num_(b['x'], 0), num_(b['y'], 0)),
        size: Size(num_(b['w'], 260), num_(b['h'], 0)),
        initialText: _str(b['text']) ?? '',
        fontSize: num_(b['fontSize'], 16),
        style: TextBoxStyle.fromJson(b['style']),
        author: _str(b['author']),
        layer: _str(b['layer']) ?? baseLayerId,
        group: _str(b['group']) ?? noGroup,
      );
      box.controller.attributes.addAll(_spansFrom(b['spans']));
      note.textBoxes.putIfAbsent(page, () => []).add(box);
    });
  }

  final images = <String, ({Uint8List bytes, String extension})>{};
  for (final i in _listOf(m['images'])) {
    piece(tr('A picture in the file could not be read and was left out'), () {
      final file = _str(i['file']);
      final data = fileBytes(file);
      final id = _str(i['id']);
      final page = _page(i['page']);
      if (id == null || page == null) throw const FormatException('no place or id');
      if (data == null) {
        warnings.add(tr('A picture is not in the file and was left out'));
        return;
      }
      images[id] = (bytes: data, extension: extensionOfEntry(file));
      note.images.putIfAbsent(page, () => []).add(ImageItem(
            id: id,
            path: file!, // the place in the file; the importer puts the picture on disk and changes this
            position: Offset(num_(i['x'], 0), num_(i['y'], 0)),
            size: Size(num_(i['w'], 100), num_(i['h'], 100)),
            author: _str(i['author']),
            layer: _str(i['layer']) ?? baseLayerId,
            group: _str(i['group']) ?? noGroup,
          ));
    });
  }

  for (final h in _listOf(m['highlights'])) {
    piece(tr('A highlight in the file could not be read and was left out'), () {
      final page = _page(h['page']);
      final color = _int(h['color']);
      if (page == null || color == null) throw const FormatException('no place or colour');
      note.highlights.putIfAbsent(page, () => []).add(PdfHighlight(
            id: _str(h['id']),
            rect: Rect.fromLTRB(num_(h['l'], 0), num_(h['t'], 0), num_(h['r'], 0), num_(h['b'], 0)),
            color: Color(color),
            commentBox: _str(h['commentBox']),
            author: _str(h['author']),
          ));
    });
  }

  final ai = [
    for (final a in _listOf(m['ai']))
      if (a['kind'] is String && a['content'] is String)
        NoteAiRow(
          noteId: note.id,
          kind: a['kind'] as String,
          key: _str(a['key']) ?? '',
          content: a['content'] as String,
          sourceHash: _int(a['sourceHash']) ?? 0,
          model: _str(a['model']) ?? '',
          createdAt: time(a['createdAt']) ?? DateTime.now(),
        ),
  ];
  final inkMap = m['ink'] is Map ? (m['ink'] as Map).cast<String, Object?>() : const <String, Object?>{};
  double? opt_(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  final ink = InkReadingParts(
    texts: [
      for (final t in _listOf(inkMap['texts']))
        if (t['key'] is String && t['text'] is String && _int(t['page']) != null && [t['l'], t['t'], t['r'], t['b']].every((v) => opt_(v) != null))
          InkText(key: t['key'] as String, page: _int(t['page'])!, text: t['text'] as String, bounds: Rect.fromLTRB(opt_(t['l'])!, opt_(t['t'])!, opt_(t['r'])!, opt_(t['b'])!), unsure: _str(t['u']) ?? ''),
    ],
    reads: [
      for (final r in _listOf(inkMap['reads']))
        if (r['key'] is String) (key: r['key'] as String, ids: _str(r['ids']) ?? '', text: _str(r['text']), latex: _str(r['latex'])),
    ],
  );
  final audio = <AudioPart>[];
  for (final a in _listOf(m['audio'])) {
    final data = fileBytes(a['file']);
    final id = _str(a['id']);
    if (id == null) continue;
    if (!isSafeId(id)) {
      warnings.add(tr('A sound with an unusable name was left out'));
      continue;
    }
    if (data == null) {
      warnings.add(tr('A sound is not in the file and was left out'));
      continue;
    }
    audio.add(AudioPart(
      id: id,
      kind: _str(a['kind']) ?? 'recording',
      title: _str(a['title']) ?? '',
      bytes: data,
      durationMs: _int(a['durationMs']) ?? 0,
      createdAt: time(a['createdAt']) ?? DateTime.now(),
    ));
  }
  final brushes = <BrushDesc>[];
  for (final f in archive.files) {
    if (!f.isFile || !f.name.startsWith('brushes/') || !f.name.endsWith('.$strokeDescExtension')) continue;
    if (brushes.length >= maxBrushesInNoteFile) {
      warnings.add(tr('The file has more brushes than the app takes; the rest were left out'));
      break;
    }
    try {
      if (f.size > strokeDescMaxBytes) throw const BrushDescException('too big');
      brushes.add(BrushDesc.fromBytes(f.content));
    } on BrushDescException {
      warnings.add(tr('A brush in the file could not be read and was left out'));
    }
  }
  final themeName = _str(info['themeImage']);
  return ParsedNoteFile(
    note,
    ai: ai,
    ink: ink,
    audio: audio,
    brushes: brushes,
    createdAt: time(info['createdAt']),
    updatedAt: time(info['updatedAt']),
    pdf: pdfBytes,
    themeImage: fileBytes(themeName),
    themeExtension: extensionOfEntry(themeName),
    images: images,
    documentImages: {
      for (final i in _listOf(m['documentImages']))
        if ((_str(i['target']), fileBytes(i['file'])) case (final target?, final bytes?)) target: bytes,
    },
    warnings: warnings,
  );
}
