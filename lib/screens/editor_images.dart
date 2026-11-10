part of 'fixed_page_note_editor.dart';

/// The theme image of the note and pictures placed on pages.
extension _EditorImages on _FixedPageNoteEditorState {
  Future<void> _pickThemeImage() async {
    try {
      final picked = await pickedPath(await FilePicker.pickFile(type: FileType.image));
      if (picked == null) return;
      final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'note_images'),
      );
      await dir.create(recursive: true);
      // a new name each time, so that the image widget does not show a cached old one
      final copy = p.join(
        dir.path,
        '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}${p.extension(picked)}',
      );
      await File(picked).copy(copy);
      await widget.repository.setNoteThemeImage(widget.noteId, copy);
      _deleteImageFile(_themeImage);
      if (mounted) setState(() => _themeImage = copy);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text.verbatim(tr('Could not set the theme image: {error}', {'error': e}))),
        );
      }
    }
  }

  Future<void> _removeThemeImage() async {
    await widget.repository.setNoteThemeImage(widget.noteId, null);
    _deleteImageFile(_themeImage);
    if (mounted) setState(() => _themeImage = null);
  }

  /// The banner above the first page; it scrolls away with the pages.
  Widget _buildBanner() {
    return SizedBox(
      height: _bannerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(_bannerImage!),
            key: ValueKey(_bannerImage!),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: Row(
              children: [
                IconButton.filledTonal(
                  tooltip: tr('Change theme image'),
                  icon: const Icon(Icons.image_outlined, size: 18),
                  onPressed: _pickThemeImage,
                ),
                // the folder's banner is not the note's to remove
                if (_themeImage != null) ...[
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: tr('Remove theme image'),
                    icon: const Icon(Icons.hide_image_outlined, size: 18),
                    onPressed: _removeThemeImage,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _deleteImageFile(String? path) {
    if (path == null) return;
    File(
      path,
    ).delete().catchError((Object _) => File(path)); // already gone is fine
  }

  /// Stores [bytes] (PNG, JPEG or anything Flutter can decode) in the app's
  /// storage and puts it on the page on screen.
  Future<ImageItem?> _placeImage(Uint8List bytes, {bool isPng = true, bool isJpeg = false, bool keepMode = false, double maxWidth = 400}) async {
      final decoded = await decodeImageFromList(bytes);
      if (!isPng && !isJpeg) {
        final png = await decoded.toByteData(format: ui.ImageByteFormat.png);
        bytes = png!.buffer.asUint8List();
      }
      final ext = isJpeg ? 'jpg' : 'png';
      final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'images'),
      );
      await dir.create(recursive: true);
      final id = NoteRepository.newId();
      final copy = p.join(dir.path, '${widget.noteId}-$id.$ext');
      await File(copy).writeAsBytes(bytes);

      // at most 400 wide (and not taller than most of a page), same proportions
      var w = math.min(maxWidth, decoded.width.toDouble());
      var h = w * decoded.height / decoded.width;
      final (page, scrolled) = _visiblePage();
      final maxH = (_infinite ? _viewportH / _pageScale : _heightOf(page)) * 0.8;
      if (h > maxH) {
        w = w * maxH / h;
        h = maxH;
      }
      decoded.dispose();
      if (!mounted) return null;
      final item = ImageItem(
        id: id,
        path: copy,
        position: Offset(
          _infinite ? _visibleLeft + 40 : (_paperWidth - w) / 2,
          math.min(scrolled + 40, math.max(0.0, _heightOf(page) - h)),
        ),
        size: Size(w, h),
        author: Authorship.current,
        layer: _placeLayer,
      );
      setState(() {
        _imagesPerPage.putIfAbsent(page, () => []).add(item);
        // a picture is selected to be moved, in the mode that does that; a plot to draw into
        // stays where the pen is, and can be moved later
        if (!keepMode) {
          _selectedImage = item;
          if (_mode == CanvasInteractionMode.draw || _mode == CanvasInteractionMode.document) {
            _mode = CanvasInteractionMode.selectText;
          }
        }
      });
      return item;
  }

  /// Asks for a picture and places it on the page on screen.
  Future<void> _addImage() async {
    if (!_drawingLayer.editable) {
      _layerBlocked();
      return;
    }
    try {
      final picked = await FilePicker.pickFile(type: FileType.image);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();

      // the PDF export embeds PNG and JPEG: turn anything else into a PNG
      final isPng = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
      final isJpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
      await _placeImage(bytes, isPng: isPng, isJpeg: isJpeg);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text.verbatim(tr('Could not add the picture: {error}', {'error': e}))),
        );
      }
    }
  }

  /// Finds the colours that stand out in the picture and offers them for the pen: the one that is tapped is the colour to draw with,
  /// and all that were taken join the colours of the drawing bar.
  Future<void> _paletteFrom(ImageItem item) async {
    try {
      final bytes = await File(item.path).readAsBytes();
      final found = await compute(dominantColoursOf, bytes);
      if (!mounted) return;
      final colours = [for (final (r, g, b) in found) Color.fromARGB(255, r, g, b)];
      final chosen = await showDialog<List<Color>>(context: context, builder: (_) => PaletteDialog(colours: colours));
      if (chosen == null || chosen.isEmpty || !mounted) return;
      await _keepColours(chosen);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not read the picture: {error}', {'error': e}))));
      }
    }
  }

  /// Puts [colours] among the person's own colours (the first one is drawn with from now on), the oldest making room.
  Future<void> _keepColours(List<Color> colours) async {
    if (colours.isEmpty) return;
    setState(() {
      for (final c in colours) {
        _customColors.removeWhere((x) => x.toARGB32() == c.toARGB32());
        _customColors.add(c);
      }
      while (_customColors.length > _maxCustomColors) {
        _customColors.removeAt(0);
      }
      _selectedPenColor = colours.first;
    });
    await widget.repository.settings.setPenColors(_customColors);
  }

  /// Asks for several pictures and lays them out as a mood board over the page on screen: rows of the same height, each filling the
  /// width, one next to the other. (They are pictures like any other afterwards, to move, resize and style one by one.)
  Future<void> _addCollage() async {
    if (!_drawingLayer.editable) {
      _layerBlocked();
      return;
    }
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty) return;
      final items = <ImageItem>[];
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final isPng = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
        final isJpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
        final item = await _placeImage(bytes, isPng: isPng, isJpeg: isJpeg, keepMode: true);
        if (item != null) items.add(item);
      }
      if (items.isEmpty || !mounted) return;
      final (page, scrolled) = _visiblePage();
      const margin = 24.0;
      final width = _paperWidth - 2 * margin;
      var rects = collageRects([for (final m in items) m.size.width / m.size.height], width: width);
      // (not taller than the page: then everything is made smaller, and it stays in the middle)
      final height = rects.last.bottom;
      final room = math.max(200.0, _heightOf(page) - 2 * margin);
      final scale = height > room ? room / height : 1.0;
      final top = math.min(math.max(margin, scrolled + margin), math.max(margin, _heightOf(page) - height * scale - margin));
      final left = margin + width * (1 - scale) / 2;
      setState(() {
        for (var i = 0; i < items.length; i++) {
          final r = rects[i];
          items[i].position = Offset(left + r.left * scale, top + r.top * scale);
          items[i].size = Size(r.width * scale, r.height * scale);
        }
        _selectedImage = null;
      });
      _scheduleSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text.verbatim(tr('Could not add the pictures: {error}', {'error': e}))),
        );
      }
    }
  }

  /// [controls]: the layer above the page that moves and resizes the picture
  /// (it has no picture of its own); else the picture below the page's ink.
  Widget _imageWidget(int pageIndex, ImageItem item, {bool controls = false}) {
    final layer = _layers.byId(item.layer);
    if (!layer.visible) return const SizedBox.shrink(); // (a hidden layer shows nothing)
    if (controls && layer.locked) return const SizedBox.shrink(); // (a locked layer's pictures are only to be seen: nothing to take hold of)
    return ImageItemWidget(
        opacity: layer.opacity,
        key: ValueKey('image-${controls ? 'ctl' : 'pic'}-${item.id}'),
        item: item,
        interactive: controls,
        showPicture: !controls,
        selected: identical(_selectedImage, item),
        onSelect: () => setState(() => _selectedImage = item),
        onTap: () => setState(() {
          if (_addingToSelection) {
            _toggleInSelection(pageIndex, image: item); // Shift: with the others, or out of them
          } else {
            _selectedImage = item;
          }
        }),
        onMoveStart: (global) {
          // a picture in a group is pulled with the rest of the group
          if (!_groupImages.contains(item) && !_selectGroupOf(image: item)) return _startDrag(item, item.position, global);
          setState(() {});
          _startStrokeDrag(global);
        },
        onResize: (d) => setState(() {
          final w = math.max(ImageItemWidget.minWidth, item.size.width + d.dx);
          item.size = Size(w, w / item.aspect);
        }),
        onDuplicate: () => _duplicateImage(pageIndex, item),
        onEdit: _on(Feature.pictureEdit) ? () => _editImage(pageIndex, item) : null,
        onReference: _on(Feature.layers) ? () => _useAsReference(item) : null,
        onPalette: _on(Feature.pictureEdit) ? () => _paletteFrom(item) : null,
        onDelete: () => _deleteImage(item),
        onChangeEnd: _scheduleSave,
      );
  }

  /// Takes the picture off the note.
  void _deleteImage(ImageItem item) {
    setState(() {
      for (final images in _imagesPerPage.values) {
        images.remove(item);
      }
      if (identical(_selectedImage, item)) _selectedImage = null;
    });
    _scheduleSave();
  }

  // ---- persistence ---------------------------------------------------------

  /// Lets go of the picture being edited in the panel beside the note, with [answer] (null: nothing was done).
  void _endPictureEdit(PictureEditResult? answer) {
    final editing = _pictureEditing;
    if (editing == null) return;
    _pictureEditing = null;
    if (!editing.done.isCompleted) editing.done.complete(answer);
  }

  Widget _pictureEditPanel() => PictureEditDialog(
        key: const ValueKey('picture-edit-panel'),
        source: _pictureEditing!.bytes,
        subject: widget.subject,
        onDone: (answer) => setState(() => _endPictureEdit(answer)),
      );

  /// Opens the picture in the editing panel and, if something was done, puts the result in its place: a new picture (a file of its
  /// own, with a new id, so that other devices get it) where the old one was, as one step that can be taken back.
  Future<void> _editImage(int pageIndex, ImageItem item) async {
    try {
      final bytes = await File(item.path).readAsBytes();
      if (!mounted) return;
      final PictureEditResult? answer;
      if (_roomForSidePanel) {
        // beside the note: the page stays in view and can be scrolled while the picture is edited
        _endPictureEdit(null);
        final done = Completer<PictureEditResult?>();
        _closeFindForPanel();
        setState(() {
          _closeSidePanels();
          _pictureEditing = (bytes: bytes, done: done);
        });
        answer = await done.future;
        if (!mounted) return;
      } else {
        answer = await showDialog<PictureEditResult>(context: context, builder: (_) => PictureEditDialog(source: bytes, subject: widget.subject));
      }
      if (answer == null || answer.edit.isNone || !mounted) return;
      final edit = answer.edit;
      final lower = item.path.toLowerCase();
      final jpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
      final out = await compute(editPictureBytes, (bytes, edit, jpeg, pictureEditLongestSide, answer.subject));
      if (out == null) throw tr('The picture cannot be opened.');
      final isJpeg = out.bytes.length > 2 && out.bytes[0] == 0xFF && out.bytes[1] == 0xD8;
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'images'));
      await dir.create(recursive: true);
      final id = NoteRepository.newId();
      final path = p.join(dir.path, '${widget.noteId}-$id.${isJpeg ? 'jpg' : 'png'}');
      await File(path).writeAsBytes(out.bytes);
      if (!mounted) return;
      final list = _imagesPerPage[pageIndex];
      final index = list?.indexOf(item) ?? -1;
      if (list == null || index < 0) return; // (it was deleted in the meantime)

      // the part of the page it fills: what is cut off is cut off the page too, and a turn swaps the two sides
      final turned = edit.turns.isOdd;
      final width = (turned ? item.size.height : item.size.width) * (1 - edit.cropLeft - edit.cropRight);
      final replacement = ImageItem(id: id, path: path, position: item.position, size: Size(width, width * out.height / out.width), author: item.author, layer: item.layer);
      setState(() {
        list[index] = replacement;
        _selectedImage = replacement;
      });
      _undoStack.push(UndoStep(
        () {
          final at = _imagesPerPage[pageIndex]?.indexOf(replacement) ?? -1;
          if (at >= 0) _imagesPerPage[pageIndex]![at] = item;
          if (identical(_selectedImage, replacement)) _selectedImage = item;
        },
        () {
          final at = _imagesPerPage[pageIndex]?.indexOf(item) ?? -1;
          if (at >= 0) _imagesPerPage[pageIndex]![at] = replacement;
          if (identical(_selectedImage, item)) _selectedImage = replacement;
        },
      ));
      _scheduleSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not edit the picture: {error}', {'error': e}))));
      }
    }
  }
}
