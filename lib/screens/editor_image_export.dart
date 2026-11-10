part of 'fixed_page_note_editor.dart';

/// The pages of the note as pictures (PNG) in a size to choose: for the web, a screen, print, or a post, a slide or a story. A page is
/// drawn the way the editor shows it, but out of sight: the paper and its lines (or the page of the PDF), the written document, the
/// pictures, highlights, lines and text boxes (formulas included) in the order of the layers; hidden layers are left out.
/// The name that stands for the paper (with the page of a PDF, the written document and the highlights) among the layers of an export.
const _paperLayer = '\u0000paper';

extension _EditorImageExport on _FixedPageNoteEditorState {
  /// The pages there are to export: the blank notebook without the empty page it always shows after the last used one.
  List<int> get _picturePages => _infinite ? const [0] : [for (var i = 0; i < (_isBlank ? math.max(1, _lastUsedBlankPage + 1) : _totalPages); i++) i];

  /// The part of the surface of a canvas that has something on it, which is its one page.
  Rect _canvasPicture() => canvasWindow(canvasContentBounds(
        strokes: _strokesPerPage[0] ?? const [],
        boxes: _textBoxesPerPage[0] ?? const [],
        images: _imagesPerPage[0] ?? const [],
      ));

  /// The size of page [i] in the units of the page space.
  Size _pictureSize(int i) => _infinite ? _canvasPicture().size : Size(_paperWidth, _heightOf(i));

  /// Asks for a size, then makes the pictures and saves them.
  Future<void> _exportImages() async {
    final pages = _picturePages;
    final shown = pages.contains(_visiblePage().$1) ? _visiblePage().$1 : pages.first;
    final choice = await showImageExportDialog(context, pageSize: _pictureSize(shown), pages: pages.length);
    if (choice == null || !mounted) return;
    await _exportPictures(choice.preset, choice.allPages ? pages : [shown], seeThrough: choice.seeThrough);
  }

  /// Makes a picture of each of [pages] and saves them: the one picture, or a ZIP of them.
  Future<void> _exportPictures(ImagePreset preset, List<int> pages, {required bool seeThrough}) async {
    if (pages.isEmpty) return;
    try {
      _setLoadingPdf(true);
      await Future<void>.delayed(Duration.zero); // let the spinner paint
      final made = <Uint8List>[];
      for (final page in pages) {
        if (!mounted) return;
        made.add(await _picturePage(page, preset, seeThrough: seeThrough));
      }
      if (mounted) _setLoadingPdf(false);
      final name = fileNameOf(_titleController.text);
      if (made.length == 1) {
        await _saveExportedFile(made.first, pages.first == 0 && _picturePages.length == 1 ? '$name.png' : '$name - ${pages.first + 1}.png', 'png');
        return;
      }
      final digits = '${pages.last + 1}'.length;
      final archive = Archive();
      for (var k = 0; k < made.length; k++) {
        final f = ArchiveFile.bytes('$name-${'${pages[k] + 1}'.padLeft(digits, '0')}.png', made[k]);
        f.compression = CompressionType.none; // (a PNG is compressed already)
        archive.add(f);
      }
      await _saveExportedFile(Uint8List.fromList(ZipEncoder().encodeBytes(archive)), '$name.zip', 'zip');
    } catch (e) {
      _exportError = '$e';
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Error exporting pictures: {error}', {'error': e}))));
      }
    }
  }

  Future<void> _saveExportedFile(Uint8List bytes, String fileName, String extension) async {
    // an automation (or a test) names the file itself: no dialog, no message
    final target = _exportTo;
    if (target != null) {
      await File(target).writeAsBytes(bytes);
      return;
    }
    final savePath = await saveWithDialog(dialogTitle: tr('Export as pictures'), fileName: fileName, extension: extension, bytes: bytes);
    if (savePath == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Successfully exported to {path}', {'path': savePath}))));
    }
  }

  /// A PNG of page [i] in the size of [preset].
  ///
  /// With [only] the picture is of one layer of the note alone, see-through (for the layers of an OpenRaster file): its lines, pictures
  /// and text boxes at full opacity, or with [_paperLayer] the paper, the PDF page, the written document and the highlights.
  Future<Uint8List> _picturePage(int i, ImagePreset preset, {required bool seeThrough, String? only}) async {
    final onPaper = only == _paperLayer, onLayer = only != null && !onPaper;
    final window = _infinite ? _canvasPicture() : null;
    final size = window?.size ?? Size(_paperWidth, _heightOf(i));
    final plan = planImage(preset, size);

    final boxes = [
      for (final b in _textBoxesPerPage[i] ?? const <TextBoxWidgetModel>[])
        if (b.controller.text.trim().isNotEmpty && (onLayer ? b.layer == only : (!onPaper && _layers.byId(b.layer).visible)) && !_inGutter(b)) b,
    ];
    final strokes = [for (final s in _strokesPerPage[i] ?? const <DrawingStroke>[]) if (s.points.length >= 2 && !onPaper && (!onLayer || s.layer == only)) s];
    final highlights = onLayer ? const <PdfHighlight>[] : (_highlightsPerPage[i] ?? const <PdfHighlight>[]);
    final stacking = _stackingOf(i);
    final document = _isDocumentPage(i) && !onLayer;

    final pictures = <(ImageItem, ui.Image)>[];
    ui.Image? paperPage;
    final shots = <WidgetPicture>[];
    try {
      for (final m in _imagesPerPage[i] ?? const <ImageItem>[]) {
        if (onPaper || (onLayer ? m.layer != only : !_layers.byId(m.layer).visible)) continue;
        final file = File(m.path);
        if (!await file.exists()) continue;
        try {
          final codec = await ui.instantiateImageCodec(await file.readAsBytes());
          final frame = await codec.getNextFrame();
          codec.dispose();
          pictures.add((m, frame.image));
        } catch (e) {
          debugPrint('a picture could not be read for the export: $e');
        }
      }
      // the page of the PDF, as sharp as the picture is
      if (!onLayer && !_isBlank && _pdfDocument != null && i < _pdfDocument!.pages.length) {
        paperPage = await renderPageImage(_pdfDocument!.pages[i], plan.page.width.round());
      }
      if (!mounted) throw StateError('the note was closed');
      // the written document and the text boxes: drawn the way the editor draws them (formulas, lists, code), as pictures
      final widgets = <Widget>[
        if (document)
          SizedBox(
            width: _paperWidth - _marginLeft - _marginRight,
            child: LiveMarkdownView(controller: _documentController, fontSize: DocumentSheet.fontSize),
          ),
        for (final box in boxes)
          Container(
            width: box.size.width,
            constraints: BoxConstraints(minHeight: exportBoxHeight(box.size.height, _shownHeight(box))),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: box.style.fill,
              borderRadius: BorderRadius.circular(box.style.radius),
              border: box.style.borderWidth > 0 ? Border.all(color: box.style.borderColor, width: box.style.borderWidth) : null,
            ),
            child: MarkdownView(controller: box.controller, fontSize: box.fontSize, textColor: box.style.textColor),
          ),
      ];
      final taken = await pictureWidgets(context, widgets, pixelRatio: plan.scale);
      shots.addAll(taken.whereType<WidgetPicture>());
      final documentShot = document ? taken.first : null;
      final boxShots = <TextBoxWidgetModel, WidgetPicture>{
        for (var k = 0; k < boxes.length; k++)
          if (taken[k + (document ? 1 : 0)] != null) boxes[k]: taken[k + (document ? 1 : 0)]!,
      };

      final sensitivity = widget.stylus?.effectiveSensitivity ?? 0.6;
      void drawShot(Canvas canvas, WidgetPicture shot, Offset at, double opacity) => canvas.drawImageRect(
            shot.image,
            Rect.fromLTWH(0, 0, shot.image.width.toDouble(), shot.image.height.toDouble()),
            at & shot.size,
            Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
          );
      void drawPictures(Canvas canvas, Iterable<(ImageItem, ui.Image)> list) {
        for (final (m, image) in list) {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
            m.position & m.size,
            Paint()
              ..color = Color.fromRGBO(255, 255, 255, onLayer ? 1 : _layers.byId(m.layer).opacity)
              ..filterQuality = FilterQuality.medium,
          );
        }
      }

      void drawBoxes(Canvas canvas, Iterable<TextBoxWidgetModel> list) {
        for (final box in list) {
          final shot = boxShots[box];
          if (shot != null) drawShot(canvas, shot, box.position, onLayer ? 1 : _layers.byId(box.layer).opacity);
        }
      }

      return await drawImage(plan, (canvas) {
        final bounds = window ?? Offset.zero & size;
        if (window != null) canvas.translate(-window.left, -window.top);
        canvas.clipRect(bounds);
        if (onLayer) {
          drawPictures(canvas, pictures);
          paintStrokes(canvas, strokes, sensitivity);
          drawBoxes(canvas, boxes);
          return;
        }
        if (!seeThrough) canvas.drawRect(bounds, Paint()..color = Colors.white);
        if (paperPage != null) {
          canvas.drawImageRect(paperPage, Rect.fromLTWH(0, 0, paperPage.width.toDouble(), paperPage.height.toDouble()), bounds, Paint()..filterQuality = FilterQuality.medium);
        }
        // (the paper's lines: on a blank page, a page added to a PDF, and the canvas)
        if (!seeThrough && _background != PageBackground.blank && (_isBlank || _nativePages.contains(i) || _infinite)) {
          if (window != null) {
            CanvasBackgroundPainter(_background, () => (rect: window, scale: plan.scale)).paint(canvas, const Size(canvasExtent, canvasExtent));
          } else {
            PageBackgroundPainter(_background).paint(canvas, size);
          }
        }
        if (documentShot != null) drawShot(canvas, documentShot, Offset(_marginLeft, _marginTop), 1);
        drawPictures(canvas, [for (final p in pictures) if (_imageUsual(stacking, p.$1)) p]);
        for (final h in highlights) {
          canvas.drawRect(h.rect, Paint()
            ..color = h.color
            ..blendMode = BlendMode.multiply);
        }
        if (onPaper) return;
        paintLayered(canvas, strokes, sensitivity, _layers, only: _usualInk(stacking));
        drawBoxes(canvas, [for (final b in boxes) if (_boxUsual(stacking, b)) b]);
        // (the parts that lie over those by their layers)
        for (final part in stacking?.above ?? const <StackPart>[]) {
          switch (part.kind) {
            case StackKind.picture:
              drawPictures(canvas, [for (final p in pictures) if (_layers.indexOf(p.$1.layer) == part.layer) p]);
            case StackKind.ink:
              paintLayered(canvas, strokes, sensitivity, _layers, only: {part.layer});
            case StackKind.box:
              drawBoxes(canvas, [for (final b in boxes) if (_layers.indexOf(b.layer) == part.layer) b]);
          }
        }
      }, around: seeThrough || onLayer ? null : Colors.white);
    } finally {
      for (final p in pictures) {
        p.$2.dispose();
      }
      paperPage?.dispose();
      for (final s in shots) {
        s.dispose();
      }
    }
  }
}
