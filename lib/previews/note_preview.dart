import '../pdf/open_pdf.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/note_repository.dart';
import '../models/canvas_view.dart';
import '../painters/canvas_painters.dart';
import '../pdf/pdf_page_loader.dart';

/// Small pictures of the first page of the notes, for the cards of the dashboard and the folders. A picture is drawn once
/// (the first page of the PDF, the lines of the page, the writing and text on it) and kept as a file named after the note and
/// the time it was last changed, so a note that changed gets a new one and the old file goes.
class NotePreviews {
  final NoteRepository repository;

  /// Where the pictures are kept (the app's support directory when null).
  final Future<Directory> Function()? directory;

  /// How wide the pictures are, in pixels.
  static const width = 360;

  NotePreviews(this.repository, {this.directory});

  final Map<String, Future<File?>> _asked = {};
  Future<void> _queue = Future.value();

  /// The pictures there are of each note, read from the folder once and kept up to date: looking through the folder for those of
  /// a note after each picture takes as long as there are pictures.
  Future<Map<String, Set<String>>>? _files;

  Future<Map<String, Set<String>>> _filesIn(Directory dir) => _files ??= () async {
        final found = <String, Set<String>>{};
        await for (final f in dir.list()) {
          final name = p.basename(f.path), end = name.lastIndexOf('-');
          if (f is File && end > 0) (found[name.substring(0, end)] ??= {}).add(f.path);
        }
        return found;
      }();

  Future<Directory> _dir() async {
    if (directory != null) return (await directory!()).create(recursive: true);
    final support = (await getApplicationSupportDirectory()).path;
    // The browser kept blank pictures of PDFs (the page was let go of before it was drawn) under the names the right ones get, and
    // a picture is only drawn when there is none: those went to a folder of their own, so they are drawn anew, and the old folder goes.
    if (kIsWeb) {
      final old = Directory(p.join(support, 'previews'));
      if (old.existsSync()) old.delete(recursive: true).catchError((Object _) => old);
    }
    return Directory(p.join(support, kIsWeb ? 'previews-2' : 'previews')).create(recursive: true);
  }

  /// The picture of the first page of note [id] as it was at [changed], or null if there is none to show (a locked note, no page).
  Future<File?> of(String id, DateTime changed, {bool locked = false}) {
    if (locked) return Future.value(null);
    final key = '$id-${changed.millisecondsSinceEpoch}';
    return _asked.putIfAbsent(key, () async {
      final dir = await _dir();
      final file = File(p.join(dir.path, '$key.png'));
      if (await file.exists()) return file;
      // one at a time: a long list must not draw fifty pages at once
      final done = Completer<File?>();
      _queue = _queue.then((_) async {
        try {
          done.complete(await _draw(id, file, dir));
        } catch (e, st) {
          debugPrint('The picture of note $id could not be drawn: $e\n$st');
          done.complete(null);
        }
      });
      return done.future;
    });
  }

  Future<File?> _draw(String id, File file, Directory dir) async {
    if (!await repository.locks.isReadable(id)) return null;
    final note = await repository.loadNote(id);
    if (note == null) return null;

    final recorder = ui.PictureRecorder();
    ui.Image? pdfImage;
    late double aspect;
    final pdfPath = note.pdfPath;
    if (pdfPath != null && await File(pdfPath).exists()) {
      PdfDocument? doc;
      try {
        doc = await openPdfFile(pdfPath);
        if (doc.pages.isNotEmpty) {
          pdfImage = await renderPageImage(doc.pages.first, width);
          aspect = pdfImage.height / pdfImage.width;
        }
      } finally {
        await doc?.dispose();
      }
    }
    // an infinite canvas shows the part that has something on it
    Rect? canvasView;
    if (pdfImage == null) {
      if (pdfPath != null) return null; // a PDF that cannot be read has nothing to show
      if (note.pageFormat.isInfinite) {
        canvasView = canvasWindow(
          canvasContentBounds(
            strokes: note.strokes.values.expand((e) => e),
            boxes: note.textBoxes.values.expand((e) => e),
            images: note.images.values.expand((e) => e),
          ),
          aspect: 0.75,
        );
        aspect = canvasView.height / canvasView.width;
      } else {
        aspect = note.pageFormat.aspect(landscape: note.landscape);
      }
    }
    final height = (width * aspect).round();
    // the pages are laid out as wide as the paper (an A4 sheet 800), a PDF's 800
    final units = canvasView?.width ?? (pdfPath != null ? 800.0 : note.pageFormat.widthUnits(landscape: note.landscape));
    final scale = width / units;
    final canvas = ui.Canvas(recorder);
    final painters = <TextPainter>[];
    canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.white);
    if (pdfImage != null) {
      canvas.drawImageRect(pdfImage, Rect.fromLTWH(0, 0, pdfImage.width.toDouble(), pdfImage.height.toDouble()),
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..filterQuality = FilterQuality.medium);
      // (a first page that was added to the PDF has the paper's lines)
      if (note.nativePages.contains(0)) {
        canvas.save();
        canvas.scale(scale);
        PageBackgroundPainter(note.background,).paint(canvas, Size(units, units * aspect));
        canvas.restore();
      }
    } else {
      canvas.save();
      canvas.scale(scale);
      if (canvasView != null) {
        canvas.translate(-canvasView.left, -canvasView.top);
        CanvasBackgroundPainter(note.background, () => (rect: canvasView!, scale: scale)).paint(canvas, const Size(canvasExtent, canvasExtent));
      } else {
        PageBackgroundPainter(note.background,).paint(canvas, Size(units, units * aspect));
      }
      canvas.restore();
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    canvas.scale(scale);
    if (canvasView != null) canvas.translate(-canvasView.left, -canvasView.top);
    if (note.documentText.trim().isNotEmpty && pdfPath == null) {
      final text = TextPainter(
        text: TextSpan(text: note.documentText, style: const TextStyle(color: Colors.black87, fontSize: 18, height: 1.3)),
        textDirection: TextDirection.ltr,
        maxLines: 40,
      )..layout(maxWidth: units - note.marginLeft - note.marginRight);
      text.paint(canvas, Offset(note.marginLeft, note.marginTop));
      painters.add(text);
    }
    for (final box in note.textBoxes[0] ?? const []) {
      if (!note.layers.byId(box.layer).visible) continue;
      final text = TextPainter(
        text: TextSpan(text: box.controller.text, style: TextStyle(color: Colors.black87, fontSize: box.fontSize)),
        textDirection: TextDirection.ltr,
        maxLines: 30,
      )..layout(maxWidth: box.size.width > 0 ? box.size.width : 260);
      text.paint(canvas, box.position);
      painters.add(text);
    }
    UnifiedInkPainter(strokes: note.strokes[0] ?? const [], layers: note.layers).paint(canvas, canvasView != null ? const Size(canvasExtent, canvasExtent) : Size(units, units * aspect));
    canvas.restore();

    final picture = recorder.endRecording();
    // (what is drawn lives outside the memory of Dart, which does not see it fill up: let go of it now, not at the next collection)
    for (final t in painters) {
      t.dispose();
    }
    final image = await picture.toImage(width, height);
    picture.dispose();
    // (not before: the picture only points at the page, and in the browser a page let go of by now is drawn as nothing)
    pdfImage?.dispose();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    // the pictures of earlier states of this note are not needed any more
    final kept = (await _filesIn(dir))[id] ??= {};
    for (final old in kept) {
      if (old != file.path) File(old).delete().catchError((Object _) => File(old));
    }
    kept
      ..clear()
      ..add(file.path);
    return file;
  }

  /// Removes the pictures of notes that no longer exist.
  Future<void> tidy(Set<String> existing) async {
    final dir = await _dir();
    await for (final f in dir.list()) {
      final name = p.basename(f.path);
      final id = name.contains('-') ? name.substring(0, name.lastIndexOf('-')) : name;
      if (f is File && !existing.contains(id)) f.delete().catchError((Object _) => f);
    }
  }
}

/// The picture of the first page of a note, drawn faintly over what is behind it (the banner of the note).
class NotePreviewImage extends StatelessWidget {
  final NotePreviews? previews;
  final String noteId;
  final DateTime changed;
  final bool locked;
  final double opacity;
  final BorderRadius borderRadius;
  final BoxFit fit;
  final Alignment alignment;

  const NotePreviewImage({
    super.key,
    required this.previews,
    required this.noteId,
    required this.changed,
    this.locked = false,
    this.opacity = 0.8,
    this.borderRadius = BorderRadius.zero,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.topCenter,
  });

  @override
  Widget build(BuildContext context) {
    final service = previews;
    if (service == null || locked) return const SizedBox.shrink();
    return FutureBuilder<File?>(
      future: service.of(noteId, changed, locked: locked),
      builder: (context, snapshot) {
        final file = snapshot.data;
        return AnimatedOpacity(
          duration: MediaQuery.maybeOf(context)?.disableAnimations ?? false ? Duration.zero : const Duration(milliseconds: 250),
          opacity: file == null ? 0 : opacity,
          child: file == null
              ? const SizedBox.expand()
              : ClipRRect(
                  borderRadius: borderRadius,
                  child: ExcludeSemantics(
                    child: Image.file(file, key: ValueKey(file.path), fit: fit, alignment: alignment, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                  ),
                ),
        );
      },
    );
  }
}
