part of 'fixed_page_note_editor.dart';

/// The pages of the note as SVG (see `svg_export.dart`): the lines stay shapes, the layers are named groups, for a vector program to
/// open. A written document, the text boxes and a PDF page under the lines are pictures in the file.
extension _EditorSvgExport on _FixedPageNoteEditorState {
  /// Asks which pages (and whether the paper is left out), then makes the files and saves them.
  Future<void> _exportSvg() async {
    final pages = _picturePages;
    final shown = pages.contains(_visiblePage().$1) ? _visiblePage().$1 : pages.first;
    var all = false, seeThrough = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => PlatformAlertDialog(
          title: Text(tr('Export as SVG')),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Drawings stay shapes you can edit in a vector program; layers become named groups. Text boxes and pictures are pictures in the file.')),
              if (pages.length > 1)
                SwitchListTile(key: const ValueKey('export-svg-all'), contentPadding: EdgeInsets.zero, title: Text(tr('All pages (a ZIP of files)')), value: all, onChanged: (v) => setLocal(() => all = v)),
              SwitchListTile(key: const ValueKey('export-svg-clear'), contentPadding: EdgeInsets.zero, title: Text(tr('Leave the paper out (see-through)')), value: seeThrough, onChanged: (v) => setLocal(() => seeThrough = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            TextButton(key: const ValueKey('export-svg-go'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Export'))),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    await _exportSvgPages(all ? pages : [shown], seeThrough: seeThrough);
  }

  Future<void> _exportSvgPages(List<int> pages, {required bool seeThrough}) async {
    if (pages.isEmpty) return;
    try {
      _setLoadingPdf(true);
      await Future<void>.delayed(Duration.zero);
      final made = <Uint8List>[];
      for (final page in pages) {
        if (!mounted) return;
        made.add(Uint8List.fromList(utf8.encode(await _svgPage(page, seeThrough: seeThrough))));
      }
      if (mounted) _setLoadingPdf(false);
      final name = fileNameOf(_titleController.text);
      if (made.length == 1) {
        await _saveExportedFile(made.first, pages.first == 0 && _picturePages.length == 1 ? '$name.svg' : '$name - ${pages.first + 1}.svg', 'svg');
        return;
      }
      final digits = '${pages.last + 1}'.length;
      final archive = Archive();
      for (var k = 0; k < made.length; k++) {
        archive.add(ArchiveFile.bytes('$name-${'${pages[k] + 1}'.padLeft(digits, '0')}.svg', made[k]));
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

  Future<Uint8List> _pngOf(ui.Image image) async => (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

  /// Page [i] as the text of an SVG file.
  Future<String> _svgPage(int i, {required bool seeThrough}) async {
    final window = _infinite ? _canvasPicture() : null;
    final size = window?.size ?? Size(_paperWidth, _heightOf(i));
    final view = window ?? Offset.zero & size;
    final sensitivity = widget.stylus?.effectiveSensitivity ?? 0.6;
    final defs = SvgDefs();
    final behind = <String>[];
    final parts = <int, SvgLayerParts>{};
    SvgLayerParts partsOf(String layer) => parts.putIfAbsent(_layers.indexOf(layer), SvgLayerParts.new);

    // a picture of a line that cannot be written as shapes (a brush that blurs, text along a line)
    Future<String?> raster(DrawingStroke s) async {
      final box = _boundsOfPoints(s.points).inflate(s.width * 2 + 24);
      final scale = math.min(2.0, 4096 / math.max(box.width, box.height));
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..scale(scale)
        ..translate(-box.left, -box.top);
      paintStrokes(canvas, [s], sensitivity);
      final image = await recorder.endRecording().toImage(math.max(1, (box.width * scale).ceil()), math.max(1, (box.height * scale).ceil()));
      try {
        return svgImage(await _pngOf(image), 'image/png', box);
      } finally {
        image.dispose();
      }
    }

    // under the layers: the paper, the page of a PDF, the written document, the highlights
    if (!seeThrough) behind.add('<rect id="paper" x="${view.left}" y="${view.top}" width="${view.width}" height="${view.height}" fill="#ffffff"/>');
    if (!_isBlank && _pdfDocument != null && i < _pdfDocument!.pages.length) {
      final page = await renderPageImage(_pdfDocument!.pages[i], (size.width * 2).round());
      try {
        behind.add(svgImage(await _pngOf(page), 'image/png', view));
      } finally {
        page.dispose();
      }
    }
    if (!seeThrough && _background != PageBackground.blank && window == null && (_isBlank || _nativePages.contains(i))) behind.add(svgPaper(_background, size));

    final boxes = [
      for (final b in _textBoxesPerPage[i] ?? const <TextBoxWidgetModel>[])
        if (b.controller.text.trim().isNotEmpty && _layers.byId(b.layer).visible && !_inGutter(b)) b,
    ];
    final document = _isDocumentPage(i);
    if (!mounted) throw StateError('the note was closed');
    final taken = await pictureWidgets(
      context,
      [
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
      ],
      pixelRatio: 2,
    );
    try {
      if (document && taken.first != null) behind.add(svgImage(await _pngOf(taken.first!.image), 'image/png', Offset(_marginLeft, _marginTop) & taken.first!.size));
      for (var k = 0; k < boxes.length; k++) {
        final shot = taken[k + (document ? 1 : 0)];
        if (shot != null) partsOf(boxes[k].layer).boxes.add(svgImage(await _pngOf(shot.image), 'image/png', boxes[k].position & shot.size));
      }
    } finally {
      for (final s in taken) {
        s?.dispose();
      }
    }
    for (final h in _highlightsPerPage[i] ?? const <PdfHighlight>[]) {
      behind.add('<rect x="${h.rect.left}" y="${h.rect.top}" width="${h.rect.width}" height="${h.rect.height}" fill="${svgColor(h.color)}"${h.color.a >= 1 ? '' : ' fill-opacity="${h.color.a.toStringAsFixed(3)}"'} style="mix-blend-mode:multiply"/>');
    }

    for (final m in _imagesPerPage[i] ?? const <ImageItem>[]) {
      if (!_layers.byId(m.layer).visible) continue;
      final file = File(m.path);
      if (!await file.exists()) continue;
      final ext = m.path.toLowerCase().split('.').last;
      final mime = switch (ext) { 'jpg' || 'jpeg' => 'image/jpeg', 'gif' => 'image/gif', 'webp' => 'image/webp', 'bmp' => 'image/bmp', _ => 'image/png' };
      partsOf(m.layer).pictures.add(svgImage(await file.readAsBytes(), mime, m.position & m.size));
    }
    for (final s in _strokesPerPage[i] ?? const <DrawingStroke>[]) {
      if (s.points.length < 2 || !_layers.byId(s.layer).visible) continue;
      final svg = await svgStroke(s, sensitivity: sensitivity, defs: defs, raster: raster);
      if (svg.isNotEmpty) partsOf(s.layer).ink.add(svg);
    }
    return svgDocument(view: view, layers: _layers, parts: parts, defs: defs, behind: behind, title: _titleController.text);
  }
}
