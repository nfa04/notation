part of 'fixed_page_note_editor.dart';

/// The page as an OpenRaster file (see `ora_export.dart`): every layer of the note a layer of the file, with its name, opacity,
/// visibility and blend mode, the groups as groups, and the paper (with the page of a PDF and the highlights) as the layer at the
/// bottom; for Krita, GIMP and other programs that paint on layers. The size is chosen as for pictures.
extension _EditorOraExport on _FixedPageNoteEditorState {
  Future<void> _exportOra() async {
    final pages = _picturePages;
    final shown = pages.contains(_visiblePage().$1) ? _visiblePage().$1 : pages.first;
    final choice = await showImageExportDialog(context, pageSize: _pictureSize(shown), pages: pages.length);
    if (choice == null || !mounted) return;
    await _exportOraPages(choice.preset, choice.allPages ? pages : [shown], seeThrough: choice.seeThrough);
  }

  Future<void> _exportOraPages(ImagePreset preset, List<int> pages, {required bool seeThrough}) async {
    if (pages.isEmpty) return;
    try {
      _setLoadingPdf(true);
      await Future<void>.delayed(Duration.zero);
      final made = <Uint8List>[];
      for (final page in pages) {
        if (!mounted) return;
        made.add(await _oraPage(page, preset, seeThrough: seeThrough));
      }
      if (mounted) _setLoadingPdf(false);
      final name = fileNameOf(_titleController.text);
      if (made.length == 1) {
        await _saveExportedFile(made.first, pages.first == 0 && _picturePages.length == 1 ? '$name.ora' : '$name - ${pages.first + 1}.ora', 'ora');
        return;
      }
      final digits = '${pages.last + 1}'.length;
      final archive = Archive();
      for (var k = 0; k < made.length; k++) {
        archive.add(ArchiveFile.bytes('$name-${'${pages[k] + 1}'.padLeft(digits, '0')}.ora', made[k])..compression = CompressionType.none);
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

  /// Page [i] as the bytes of an .ora file.
  Future<Uint8List> _oraPage(int i, ImagePreset preset, {required bool seeThrough}) async {
    final plan = planImage(preset, _pictureSize(i));
    final merged = await _picturePage(i, preset, seeThrough: seeThrough);
    final files = <String, Uint8List>{};
    final names = <String, String>{};
    // (a layer with nothing on it is a one-pixel picture, not a page-sized empty one)
    final blank = await _blankPng();
    for (final l in _layers.layers) {
      if (l.isGroup) continue;
      final has = (_strokesPerPage[i] ?? const <DrawingStroke>[]).any((s) => s.layer == l.id && s.points.length >= 2) ||
          (_imagesPerPage[i] ?? const <ImageItem>[]).any((m) => m.layer == l.id) ||
          (_textBoxesPerPage[i] ?? const <TextBoxWidgetModel>[]).any((b) => b.layer == l.id && b.controller.text.trim().isNotEmpty);
      final file = 'data/layer${names.length + 1}.png';
      names[l.id] = file;
      files[file] = has ? await _picturePage(i, preset, seeThrough: true, only: l.id) : blank;
    }
    const paperFile = 'data/paper.png';
    files[paperFile] = await _picturePage(i, preset, seeThrough: seeThrough, only: _paperLayer);
    final xml = oraStackXml(width: plan.width, height: plan.height, layers: _layers, srcOf: (l) => names[l.id]!, paper: paperFile);
    return oraArchive(stackXml: xml, layerPngs: files, merged: merged, thumbnail: await _thumbnailOf(merged));
  }

  Future<Uint8List> _blankPng() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    try {
      return await _pngOf(image);
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  /// A picture of at most 256 pixels across the long side, from [png].
  Future<Uint8List> _thumbnailOf(Uint8List png) async {
    final probe = await ui.instantiateImageCodec(png);
    final first = (await probe.getNextFrame()).image;
    final wide = first.width >= first.height;
    first.dispose();
    probe.dispose();
    final codec = await ui.instantiateImageCodec(png, targetWidth: wide ? 256 : null, targetHeight: wide ? null : 256);
    final frame = (await codec.getNextFrame()).image;
    codec.dispose();
    try {
      return await _pngOf(frame);
    } finally {
      frame.dispose();
    }
  }
}
