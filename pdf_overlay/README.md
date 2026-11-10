# pdf_overlay

Put a vector overlay (highlights, shapes, text boxes) on top of an existing PDF
**without rewriting it**. Pure Dart: no native code, no external binaries, works
on every Flutter platform including web. The only dependency is `archive` (MIT)
for inflating cross-reference/object streams.

```dart
final merged = mergeOverlay(originalBytes, overlayBytes);
// overlay page k -> original page k

final merged = mergeOverlay(originalBytes, overlayBytes, targetPages: [0, 4, 7]);
// overlay page 0 -> original page 0, overlay page 1 -> page 4, overlay page 2 -> page 7
```

The overlay is an ordinary PDF. Make it with the [`pdf`](https://pub.dev/packages/pdf)
package, drawing in the coordinate space the viewer shows (top-left origin,
after rotation/crop). It is scaled to fit if its page size differs from the
displayed page size, as long as the aspect ratio matches.

## What it does

The output is the original file **byte for byte**, followed by an incremental
update. For each target page, the overlay page becomes a Form XObject that the
page itself draws: the page's `/Contents` gets a small stream before and one
after the original content streams, and the form is added to its resources:

* the original page content is never touched: text stays selectable, vectors stay
  vectors, nothing is re-encoded, the file grows only by the overlay's size
* no UI freeze: there is no image work, just parsing the cross-reference data
  and appending bytes
* the overlay is page content, not an annotation, so every viewer draws it,
  including those that skip annotations (Android's built-in renderer, PDFium
  without annotation rendering); it prints and cannot be dragged around

Handled: classic xref tables, xref streams, hybrid files, `/Prev` chains,
object streams (page dictionaries inside them are fine), linearized files,
page trees of any depth, inherited `/MediaBox` `/CropBox` `/Rotate`, `/Annots`
as direct or indirect array (left as they are), Flate + PNG predictors.

**Refused with `UnsupportedPdfException`** (nothing is written; fall back to
another export): encrypted PDFs, damaged or unreadable cross-reference data,
data before the `%PDF-` header, non-Flate filters on xref/object streams.

## Comments

`mergeOverlay(original, overlay, comments: [PdfComment(...)])` also adds real PDF
comments: a Highlight annotation over the marked rectangles (given as points of
the page as displayed, from its top left; rotation, crop boxes and offsets are
handled) with the note as its `/Contents` and a pop-up, so any viewer lists them
and shows the note. `overlay` may be null when there is only comments to add.

## Limitations to know about

* The overlay is drawn by the page, so it cannot be told apart from the page's
  own content, and annotation tools do not list it. (Earlier versions used a
  Stamp annotation, which viewers that do not render annotations left out.)
* Overlay text is as good as the fonts the overlay PDF embeds (the `pdf`
  package's default Helvetica has no Unicode; embed a TTF for `€`, accents, CJK).
* Signed PDFs stay valid for the signed revision, but viewers will report them
  as modified after signing.
* Not yet tested against: hybrid-reference files and a large real-world corpus.
  Run it over your own PDFs before shipping (see below).

## Testing

```bash
pip install reportlab pikepdf pillow          # fixture generation + verification only
sudo apt install qpdf poppler-utils           # verification only, not needed at runtime

python3 tool/make_fixtures.py                 # (already checked in) regenerate test/fixtures
dart pub get
dart test                                     # merges every fixture into build/test_out/
python3 tool/verify.py                        # independent checks on those outputs
```

`tool/verify.py` does not use any code from this package. For each fixture it
checks: the original is an exact byte prefix of the output; `qpdf --check` is
clean; page count and annotations are right; page text is still extractable;
and a poppler render shows the overlay in the right place (red top-left, green
bottom-right, translucent yellow in the centre) for all four rotations, with
CropBox and offset MediaBox.

The Python design validation that preceded this port passed all 9 fixtures
(classic, xref stream + object streams, inherited rotate, nested tree,
indirect/direct `/Annots`, `/Prev` chain, rotations, linearized, plus refusal of
encrypted and corrupt files).

## Using it in the Flutter app

Replace the rasterising `_exportPdf` with this. Pages without annotations are
left out of the overlay completely.

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw_widgets;
import 'package:pdf_overlay/pdf_overlay.dart';

Future<void> _exportPdf() async {
  if (_pdfFilePath == null) return;
  try {
    setState(() => _isLoadingPdf = true);
    await Future<void>.delayed(Duration.zero); // let the spinner paint

    // 1. overlay: one page per page that has annotations
    final overlay = pw_widgets.Document();
    final targets = <int>[];
    for (var i = 0; i < _totalPages; i++) {
      final highlights = _highlightsPerPage[i] ?? [];
      final boxes = (_textBoxesPerPage[i] ?? [])
          .where((b) => b.controller.text.trim().isNotEmpty)
          .toList();
      if (highlights.isEmpty && boxes.isEmpty) continue;
      targets.add(i);

      overlay.addPage(pw_widgets.Page(
        pageFormat: pw.PdfPageFormat(basePageWidth, basePageHeight),
        margin: pw_widgets.EdgeInsets.zero,
        build: (_) => pw_widgets.Stack(children: [
          ...highlights.map((h) => pw_widgets.Positioned(
                left: h.rect.left,
                top: h.rect.top,
                child: pw_widgets.Container(
                  width: h.rect.width,
                  height: h.rect.height,
                  color: pw.PdfColor(h.color.r, h.color.g, h.color.b, h.color.a),
                ),
              )),
          ...boxes.map((box) => pw_widgets.Positioned(
                left: box.position.dx,
                top: box.position.dy,
                child: pw_widgets.Container(
                  width: box.size.width,
                  height: box.size.height,
                  padding: const pw_widgets.EdgeInsets.all(8),
                  decoration: pw_widgets.BoxDecoration(
                    color: const pw.PdfColor(1, 1, 1, 0.95),
                    border: pw_widgets.Border.all(
                        color: const pw.PdfColor(0.7, 0.7, 0.7), width: 1),
                    borderRadius: pw_widgets.BorderRadius.circular(8),
                  ),
                  child: pw_widgets.Text(box.controller.text,
                      style: pw_widgets.TextStyle(fontSize: box.fontSize)),
                ),
              )),
        ]),
      ));
    }

    // 2. merge onto the original
    final original = Uint8List.fromList(await File(_pdfFilePath!).readAsBytes());
    final Uint8List bytes = targets.isEmpty
        ? original
        : mergeOverlay(original, await overlay.save(), targetPages: targets);

    if (mounted) setState(() => _isLoadingPdf = false);

    // 3. save
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export PDF',
      fileName: 'Annotated_$_importedPdfName',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      bytes: bytes, // mobile/web write it themselves
    );
    if (savePath == null) return;
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      await File(savePath.toLowerCase().endsWith('.pdf') ? savePath : '$savePath.pdf')
          .writeAsBytes(bytes);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully exported to $savePath')));
    }
  } on UnsupportedPdfException catch (e) {
    // encrypted / damaged: use your old rasterising export instead
    if (mounted) setState(() => _isLoadingPdf = false);
    await _exportPdfRasterized(reason: e.message);
  } catch (e) {
    if (mounted) {
      setState(() => _isLoadingPdf = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error exporting PDF: $e')));
    }
  }
}
```

`color.r/.g/.b/.a` are the non-deprecated Flutter accessors (already 0 to 1). On
older Flutter use `color.red / 255` etc. and `color.opacity`.

Keep your previous implementation, renamed `_exportPdfRasterized`, as the
fallback.
