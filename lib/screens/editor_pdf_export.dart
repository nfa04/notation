part of 'fixed_page_note_editor.dart';

/// A colour for the PDF; [opacity] replaces the colour's own alpha when given.
pw.PdfColor _pdfColor(Color c, [double? opacity]) => pw.PdfColor(c.r, c.g, c.b, opacity ?? c.a);

/// The least height of a text box in the PDF: the height it has in the editor
/// when that is known, else what it was pulled to (0: as tall as its text).
double exportBoxHeight(double pulledTo, double? shown) => math.max(pulledTo, shown ?? 0);

extension _PdfExport on _FixedPageNoteEditorState {
  /// Builds the annotation page for [i], or null if it has none and no
  /// [background] (page image for the rasterised export) was given.
  Future<pw_widgets.Page?> _buildOverlayPage(int i,
      {Uint8List? background, bool blank = false, bool skipEmpty = false, bool commentsAsAnnotations = false}) async {
    var highlights = _highlightsPerPage[i] ?? [];
    // (what is on a hidden layer is left out)
    var boxes = (_textBoxesPerPage[i] ?? [])
        .where((b) => b.controller.text.trim().isNotEmpty && _layers.byId(b.layer).visible)
        .toList();
    if (commentsAsAnnotations) {
      // comments go into the PDF as comments (see _pdfComments): not drawn as well
      final ids = _commentBoxIds();
      highlights = highlights.where((h) => h.commentBox == null || !ids.contains(h.commentBox)).toList();
      boxes = boxes.where((b) => !ids.contains(b.id)).toList();
    }
    // (the lines of the shown layers, in the order of the layers, with a see-through layer's opacity in their colour)
    final strokes = _layers.forExport((_strokesPerPage[i] ?? []).where((st) => st.points.length >= 2));
    final sensitivity =
        widget.stylus?.effectiveSensitivity ??
        0.6; // (as the pages on the screen have it)
    final shownStroke = {
      for (final st in _strokesPerPage[i] ?? const <DrawingStroke>[]) st.id: st,
    };
    final pictures = <(ImageItem, Uint8List)>[];
    for (final m in _imagesPerPage[i] ?? const <ImageItem>[]) {
      if (!_layers.byId(m.layer).visible) continue;
      final file = File(m.path);
      if (await file.exists()) pictures.add((m, await file.readAsBytes()));
    }
    if (blank && skipEmpty && !_isDocumentPage(i) && highlights.isEmpty && boxes.isEmpty && strokes.isEmpty &&
        pictures.isEmpty) {
      return null;
    }
    // (a page added to the PDF has the paper's lines drawn on it, over the empty page of the file)
    final paper = blank || _nativePages.contains(i);
    if (!blank && background == null && highlights.isEmpty && boxes.isEmpty && strokes.isEmpty &&
        pictures.isEmpty && !(paper && _background != PageBackground.blank)) {
      return null;
    }
    final documentPage = blank && _isDocumentPage(i);
    // Helvetica is not Flutter's font: leave room in case the text runs longer
    final pageHeight = documentPage && _heightOf(i) > basePageHeight
        ? _heightOf(i) * 1.12
        : _heightOf(i);
    if (!mounted) return null;
    // formulas are drawn as pictures first (the PDF cannot typeset LaTeX)
    final docMath = documentPage
        ? await renderMathImages(context, mathIn([_documentController.text]), fontSize: DocumentSheet.fontSize)
        : MathImages.empty;
    if (!mounted) return null;
    final boxMath = <TextBoxWidgetModel, MathImages>{
      for (final box in boxes)
        box: await renderMathImages(context, mathIn([box.controller.text]), fontSize: box.fontSize, color: box.style.textColor),
    };
    // what the handwriting says, as text under it that a PDF viewer can select (not what is on a hidden layer)
    final inkLines = await _inkText?.pageLines(i, (_strokesPerPage[i] ?? const <DrawingStroke>[]).where((st) => _layers.byId(st.layer).visible)) ?? const <InkTextLine>[];
    // (pictures, lines and boxes lie over each other by their layers: see PageStacking)
    final stacking = PageStacking(
      _layers,
      pictures: {for (final p in pictures) _layers.indexOf(p.$1.layer)},
      ink: {for (final st in strokes) _layers.indexOf(st.layer)},
      boxes: {for (final b in boxes) _layers.indexOf(b.layer)},
    );
    final usualPictures = [for (final p in pictures) if (stacking.isUsualFor(StackKind.picture, _layers.indexOf(p.$1.layer))) p];
    final usualStrokes = [for (final st in strokes) if (stacking.isUsualFor(StackKind.ink, _layers.indexOf(st.layer))) st];
    final usualBoxes = [for (final b in boxes) if (stacking.isUsualFor(StackKind.box, _layers.indexOf(b.layer))) b];
    List<pw_widgets.Widget> picturesOf(Iterable<(ImageItem, Uint8List)> list) => [
      for (final (m, bytes) in list)
          pw_widgets.Positioned(
            left: m.position.dx,
            top: m.position.dy,
            child: pw_widgets.Opacity(
              opacity: _layers.byId(m.layer).opacity,
              child: pw_widgets.Image(pw_widgets.MemoryImage(bytes), width: m.size.width, height: m.size.height, fit: pw_widgets.BoxFit.fill),
            ),
          ),
    ];
    pw_widgets.Widget strokesOf(List<DrawingStroke> list) => pw_widgets.Positioned(
            left: 0,
            top: 0,
            child: pw_widgets.Builder(builder: (pw_widgets.Context context) {
              final document = context.document; // (a gradient is an object of the document)
              final labelFonts = PdfLabelFonts(document); // (so is a font)
              return pw_widgets.CustomPaint(
              size: pw.PdfPoint(_paperWidth, pageHeight),
              painter: (pw.PdfGraphics canvas, pw.PdfPoint size) {
                for (final st in list) {
                // a line of a brush (the roller, a brush of an extension): the pieces of its shape (made from the line as it is in
                // the note, which knows its shape already: a see-through layer's line is a copy, with the same points)
                  final shape = st.brush == penBrushId ? null : brushShape(shownStroke[st.id] ??st);
                  if (shape != null) {
                  drawBrushOnPdf(canvas, size.y, st, shape);
                  drawLabelOnPdf (canvas, size.y, st, labelFonts);
                  continue;
                }
                // a line of the pen, thicker where it pressed harder, as on the screen
                if(drawsWithPressure(st, sensitivity)) {
                  drawPressureLineOnPdf ( canvas, size.y, st,
                    pressureHalfWidths(st, sensitivity));
                    drawLabelOnPdf(canvas, size.y, st, labelFonts);
                    continue;
                  }
                  void trace() {
                    // PDF y axis points up, canvas y axis points down
                    canvas.moveTo(st.points.first.dx, size.y - st.points.first.dy);
                    for (final pt in st.points.skip(1)) {
                      canvas.lineTo(pt.dx, size.y - pt.dy);
                    }
                  }

                  final fill = st.fill;
                  if (fill != null && st.isClosed) {
                    final gradient = st.gradient;
                    if (gradient != null) {
                      // the inside is the clip, and the gradient is laid over all of it (the PDF has no alpha in a colour: the
                      // two colours share the mean of their opacities)
                      final bounds = Path()..addPolygon(st.points, true);
                      final box = bounds.getBounds();
                      final centre = box.center;
                      final colours = [pw.PdfColor(fill.r, fill.g, fill.b), pw.PdfColor(gradient.end.r, gradient.end.g, gradient.end.b)];
                      pw.PdfPoint at(Offset o) => pw.PdfPoint(o.dx, size.y - o.dy);
                      final (from, to) = gradient.line(box);
                      final shading = gradient.radial
                          ? pw.PdfShading(document,
                              shadingType: pw.PdfShadingType.radial,
                              function: pw.PdfBaseFunction.colorsAndStops(document, colours),
                              start: at(centre),
                              end: at(centre),
                              radius0: 0,
                              radius1: math.max(1.0, math.sqrt(box.width * box.width + box.height * box.height) / 2),
                              extendStart: true,
                              extendEnd: true)
                          : pw.PdfShading(document,
                              shadingType: pw.PdfShadingType.axial,
                              function: pw.PdfBaseFunction.colorsAndStops(document, colours),
                              start: at(from),
                              end: at(to),
                              extendStart: true,
                              extendEnd: true);
                      canvas
                        ..saveContext()
                        ..setGraphicState(pw.PdfGraphicState(opacity: (fill.a + gradient.end.a) / 2));
                      trace();
                      canvas
                        ..clipPath()
                        ..applyShader(shading)
                        ..restoreContext();
                    } else {
                      canvas
                        ..saveContext()
                        ..setGraphicState(pw.PdfGraphicState(opacity: fill.a))
                        ..setFillColor(pw.PdfColor(fill.r, fill.g, fill.b));
                      trace();
                      canvas
                        ..fillPath()
                        ..restoreContext();
                    }
                  }
                  canvas
                    ..saveContext()
                    ..setGraphicState(pw.PdfGraphicState(
                        strokeOpacity: st.color.a, opacity: st.color.a))
                    ..setStrokeColor(pw.PdfColor(st.color.r, st.color.g, st.color.b))
                    ..setLineWidth(st.width)
                    ..setLineCap(pw.PdfLineCap.round)
                    ..setLineJoin(pw.PdfLineJoin.round);
                  if (st.dash == StrokeDash.dashed) {
                    canvas.setLineDashPattern([math.max(8.0, st.width * 3.5), math.max(6.0, st.width * 2.5)]);
                  } else if (st.dash == StrokeDash.dotted) {
                    canvas.setLineDashPattern([0.1, math.max(5.0, st.width * 2.2)]);
                  }
                  trace();
                  canvas
                    ..strokePath()
                    ..restoreContext();
                  drawLabelOnPdf(canvas, size.y, st, labelFonts);
                }
              },
            );
            }),
          );
    List<pw_widgets.Widget> boxesOf(Iterable<TextBoxWidgetModel> list) => [
        ...list.map((box) => pw_widgets.Positioned(
              left: box.position.dx,
              top: box.position.dy,
              child: pw_widgets.Opacity(
                opacity: _layers.byId(box.layer).opacity,
                child: pw_widgets.Container(
                width: box.size.width,
                // as tall as the box is in the editor (what it was pulled to, or its text),
                // and taller only if the text needs it
                constraints: pw_widgets.BoxConstraints(minHeight: exportBoxHeight(box.size.height, _shownHeight(box))),
                padding: const pw_widgets.EdgeInsets.all(8),
                decoration: pw_widgets.BoxDecoration(
                  color: box.style.opacity <= 0 ? null : _pdfColor(box.style.background, box.style.opacity),
                  border: box.style.borderWidth <= 0
                      ? null
                      : pw_widgets.Border.all(color: _pdfColor(box.style.borderColor), width: box.style.borderWidth),
                  borderRadius: pw_widgets.BorderRadius.circular(box.style.radius),
                ),
                child: markdownToPdf(box.controller, box.fontSize,
                    math: boxMath[box]!, color: _pdfColor(box.style.textColor), citations: _citationsFor(box.controller.text)),
              ),
              ),
            )),
    ];
    return pw_widgets.Page(
      pageFormat: pw.PdfPageFormat(_paperWidth, pageHeight),
      margin: pw_widgets.EdgeInsets.zero,
      build: (_) => pw_widgets.Stack(children: [
        if (blank)
          pw_widgets.Positioned(
            left: 0,
            top: 0,
            child: pw_widgets.Container(
                width: _paperWidth,
                height: pageHeight,
                color: pw.PdfColors.white),
          ),
        if (paper && _background != PageBackground.blank)
          pw_widgets.Positioned(
            left: 0,
            top: 0,
            child: pw_widgets.CustomPaint(
              size: pw.PdfPoint(_paperWidth, pageHeight),
              painter: (pw.PdfGraphics canvas, pw.PdfPoint size) {
                canvas
                  ..setStrokeColor(pw.PdfColor.fromInt(paperInk(_background).toARGB32()))
                  ..setLineWidth(1);
                for (final (from, to) in paperLines(_background, Size(size.x, size.y))) {
                  // PDF y axis points up, canvas y axis points down
                  canvas
                    ..moveTo(from.dx, size.y - from.dy)
                    ..lineTo(to.dx, size.y - to.dy)
                    ..strokePath();
                }
                final dots = paperDots(_background, Size(size.x, size.y));
                if (dots.isNotEmpty) {
                  canvas.setFillColor(pw.PdfColor.fromInt(paperDotColor.toARGB32()));
                  for (final d in dots) {
                    canvas
                      ..drawEllipse(d.dx, size.y - d.dy, 1.2, 1.2)
                      ..fillPath();
                  }
                }
              },
            ),
          ),
        if (documentPage)
          pw_widgets.Positioned(
            left: _marginLeft,
            top: _marginTop,
            child: pw_widgets.SizedBox(
              width: _paperWidth -
                  _marginLeft - _marginRight,
              child: markdownToPdf(_documentController, DocumentSheet.fontSize,
                  math: docMath, citations: _citationsFor(_documentController.text), bibliography: true),
            ),
          ),
        if (background != null)
          pw_widgets.Positioned(
            left: 0,
            top: 0,
            child: pw_widgets.Image(pw_widgets.MemoryImage(background),
                width: _paperWidth, height: pageHeight, fit: pw_widgets.BoxFit.fill),
          ),
        ...picturesOf(usualPictures),
        if (highlights.isNotEmpty)
          pw_widgets.Positioned(
            left: 0,
            top: 0,
            child: pw_widgets.CustomPaint(
              size: pw.PdfPoint(_paperWidth, pageHeight),
              painter: (pw.PdfGraphics canvas, pw.PdfPoint size) {
                for (final h in highlights) {
                  // PDF colours carry no alpha: use opacity + multiply so the
                  // text under the highlight stays visible
                  canvas
                    ..saveContext()
                    ..setGraphicState(pw.PdfGraphicState(
                        opacity: h.color.a, blendMode: pw.PdfBlendMode.multiply))
                    ..setFillColor(pw.PdfColor(h.color.r, h.color.g, h.color.b))
                    ..drawRect(h.rect.left, size.y - h.rect.bottom, h.rect.width, h.rect.height)
                    ..fillPath()
                    ..restoreContext();
                }
              },
            ),
          ),
        if (usualStrokes.isNotEmpty) strokesOf(usualStrokes),
        ...boxesOf(usualBoxes),
        if (inkLines.isNotEmpty)
          pw_widgets.Positioned(
            left: 0,
            top: 0,
            child: pw_widgets.Builder(builder: (pw_widgets.Context context) {
              final font = pw.PdfFont.helvetica(context.document);
              return pw_widgets.CustomPaint(
                size: pw.PdfPoint(_paperWidth, pageHeight),
                painter: (pw.PdfGraphics canvas, pw.PdfPoint size) => drawInkText(canvas, size.y, inkLines, font),
              );
            }),
          ),
        // (the parts that lie over those by their layers)
        for (final part in stacking.above) ...switch (part.kind) {
          StackKind.picture => picturesOf([for (final p in pictures) if (_layers.indexOf(p.$1.layer) == part.layer) p]),
          StackKind.ink => [strokesOf([for (final st in strokes) if (_layers.indexOf(st.layer) == part.layer) st])],
          StackKind.box => boxesOf([for (final b in boxes) if (_layers.indexOf(b.layer) == part.layer) b]),
        },
      ]),
    );
  }

  /// The text boxes that hold a comment some highlights belong to.
  Set<String> _commentBoxIds() {
    final marked = {
      for (final list in _highlightsPerPage.values)
        for (final h in list)
          if (h.commentBox != null) h.commentBox!,
    };
    return {
      for (final list in _textBoxesPerPage.values)
        for (final b in list)
          if (marked.contains(b.id)) b.id,
    };
  }

  /// The comments of the note as comments of the PDF: each box of "Comment: ..." with
  /// the text it is about marked, so that any PDF viewer lists them and shows the note.
  Future<List<PdfComment>> _pdfComments() async {
    final boxes = {
      for (final list in _textBoxesPerPage.values)
        for (final b in list) b.id: b,
    };
    final comments = <PdfComment>[];
    for (final entry in _highlightsPerPage.entries) {
      final byBox = <String, List<PdfHighlight>>{};
      for (final h in entry.value) {
        if (h.commentBox != null && boxes.containsKey(h.commentBox)) {
          byBox.putIfAbsent(h.commentBox!, () => []).add(h);
        }
      }
      if (byBox.isEmpty) continue;
      // the page's size in points: what the marks (in page units) are scaled to
      final scale = _pdfDocument!.pages[entry.key].width / _paperWidth; // (the size of every page is known when the PDF opens)
      byBox.forEach((id, marks) {
        // "Comment: what was said": the label is not part of the comment
        final said = boxes[id]!.controller.text.trim().replaceFirst(RegExp(r'^Comment:\s*', caseSensitive: false), '').trim();
        final color = marks.first.color;
        comments.add(PdfComment(
          page: entry.key,
          rects: [for (final m in marks) [m.rect.left * scale, m.rect.top * scale, m.rect.right * scale, m.rect.bottom * scale]],
          color: [color.r, color.g, color.b],
          opacity: color.a,
          contents: said,
        ));
      });
    }
    return comments;
  }

  /// What the handwriting says, to be put under it in the PDF about to be made; null: nothing is (the person switched it off).
  Future<PdfInkText?> _newInkText() async {
    if (await widget.repository.settings.get(pdfInkTextSetting) == '0') return null;
    // what was read for the search, and what the open note has read ahead
    final known = {for (final t in await widget.repository.text.inkTexts(widget.noteId)) t.key: t.text};
    for (final r in _reader.prefetcher?.readings() ?? const <({InkCluster block, String? text, String? latex})>[]) {
      final text = r.text;
      if (text != null) known[r.block.key] = text;
    }
    final reader = widget.handwriting;
    final canRead = reader != null && _inSettings(Feature.handwriting) && reader.status == HandwritingStatus.installed;
    return PdfInkText(known: known, read: canRead ? reader.recognize : null);
  }

  Future<void> _saveExportedPdf(Uint8List bytes) async {
    final unread = _inkText?.unread ?? 0;
    _inkText = null;
    // an automation names the file itself: no dialog, no message
    final target = _exportTo;
    if (target != null) {
      await File(target).writeAsBytes(bytes);
      return;
    }
    final savePath = await saveWithDialog(
      dialogTitle: 'Export PDF',
      fileName: _isBlank
          ? '${_titleController.text.trim().isEmpty ? 'Note' : _titleController.text.trim()}.pdf'
          : 'Annotated_$_importedPdfName',
      extension: 'pdf',
      bytes: bytes,
    );
    if (savePath == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text.verbatim(tr('Successfully exported to {path}', {'path': savePath}))));
      if (unread > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text.verbatim(trCount(unread, '1 block of handwriting could not be read in time: it cannot be selected in the PDF',
                '{n} blocks of handwriting could not be read in time: they cannot be selected in the PDF'))));
      }
    }
  }

  /// Fallback for PDFs [mergeOverlay] cannot handle (encrypted, damaged): every
  /// page is rendered to an image and the annotations are drawn on top.
  Future<void> _exportPdfRasterized({String? reason}) async {
    if (_pdfFilePath == null) return;
    try {
      _setLoadingPdf(true);
      _inkText = await _newInkText();
      final doc = pw_widgets.Document();
      // the page images the editor shows are the backgrounds
      for (var i = 0; i < _totalPages; i++) {
        final page = await _buildOverlayPage(i, background: await _pagePng(i));
        if (page != null) doc.addPage(page);
      }
      final bytes = await doc.save();
      if (mounted) _setLoadingPdf(false);
      await _saveExportedPdf(bytes);
    } catch (e) {
      _exportError = '$e';
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text.verbatim(tr('Error exporting PDF: {error}', {'error': '${reason != null ? '($reason) ' : ''}$e'}))));
      }
    }
  }

  /// No PDF imported: every notebook page becomes a white page.
  Future<void> _exportBlank() async {
    try {
      _setLoadingPdf(true);
      await Future<void>.delayed(Duration.zero); // let the spinner paint
      _inkText = await _newInkText();
      final doc = pw_widgets.Document();
      // the trailing empty page is only there for the editor: skip empty pages
      var added = 0;
      for (var i = 0; i < _pageCount; i++) {
        final page = await _buildOverlayPage(i, blank: true, skipEmpty: true);
        if (page == null) continue;
        doc.addPage(page);
        added++;
      }
      if (added == 0) doc.addPage((await _buildOverlayPage(0, blank: true))!);
      final bytes = await doc.save();
      if (mounted) _setLoadingPdf(false);
      await _saveExportedPdf(bytes);
    } catch (e) {
      _exportError = '$e';
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text.verbatim(tr('Error exporting PDF: {error}', {'error': e}))));
      }
    }
  }

  Future<void> _exportPdf() async {
    if (_infinite) {
      // (the pages of a PDF are a fixed size; a canvas has none to cut it into)
      _exportError = tr('A note that is an infinite canvas cannot be exported as a PDF');
      if (_exportTo == null) ScaffoldMessenger.maybeOf(context,)?.showSnackBar(SnackBar(content: Text.verbatim(_exportError!)));
      return;
    }
    if (_isBlank) return _exportBlank();
    try {
      _setLoadingPdf(true);
      await Future<void>.delayed(Duration.zero); // let the spinner paint
      _inkText = await _newInkText();

      // 1. overlay: one page per page that has annotations
      final overlay = pw_widgets.Document();
      final targets = <int>[];
      for (var i = 0; i < _totalPages; i++) {
        final page = await _buildOverlayPage(i, commentsAsAnnotations: true);
        if (page == null) continue;
        targets.add(i);
        overlay.addPage(page);
      }
      final comments = await _pdfComments();

      // 2. merge onto the original
      final original = Uint8List.fromList(await File(_pdfFilePath!).readAsBytes());
      final Uint8List bytes = targets.isEmpty && comments.isEmpty
          ? original
          : mergeOverlay(original, targets.isEmpty ? null : await overlay.save(), targetPages: targets, comments: comments);

      if (mounted) _setLoadingPdf(false);

      // 3. save
      await _saveExportedPdf(bytes);
    } on UnsupportedPdfException catch (e) {
      // encrypted / damaged: use your old rasterising export instead
      if (mounted) _setLoadingPdf(false);
      await _exportPdfRasterized(reason: e.message);
    } catch (e) {
      _exportError = '$e';
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text.verbatim(tr('Error exporting PDF: {error}', {'error': e}))));
      }
    }
  }
}
