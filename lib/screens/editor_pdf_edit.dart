part of 'fixed_page_note_editor.dart';

/// A pan that starts after a few pixels, ahead of the scrolling of the pages (which starts at more): dragging a picture or a
/// handle must not scroll the page instead.
class _EarlyPanRecognizer extends PanGestureRecognizer {
  _EarlyPanRecognizer({super.debugOwner});

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) => globalDistanceMoved.abs() > 4;
}

/// Drag (and double tap) on [child] that takes precedence over scrolling.
class _PdfEditGesture extends StatelessWidget {
  final VoidCallback? onDoubleTap;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final GestureDragCancelCallback? onPanCancel;
  final Widget child;

  const _PdfEditGesture({this.onDoubleTap, this.onPanStart, this.onPanUpdate, this.onPanEnd, this.onPanCancel, required this.child});

  @override
  Widget build(BuildContext context) => RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          _EarlyPanRecognizer: GestureRecognizerFactoryWithHandlers<_EarlyPanRecognizer>(
            _EarlyPanRecognizer.new,
            (r) => r
              ..onStart = onPanStart
              ..onUpdate = onPanUpdate
              ..onEnd = onPanEnd
              ..onCancel = onPanCancel,
          ),
          if (onDoubleTap != null)
            DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              DoubleTapGestureRecognizer.new,
              (r) => r.onDoubleTap = onDoubleTap,
            ),
        },
        child: child,
      );
}

/// Draws the outlines of what can be edited on a PDF page, and the one picked.
class _PdfEditPainter extends CustomPainter {
  final List<PdfEditObject> objects;
  final PdfEditObject? selected;
  final double scale;
  final Color color;
  const _PdfEditPainter(this.objects, this.selected, this.scale, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final text = Paint()
      ..color = color.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final image = Paint()
      ..color = Colors.orange.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final o in objects) {
      if (o.kind == PdfObjectKind.text) {
        canvas.drawRect(_scaled(o.rect), text);
      } else if (o.kind == PdfObjectKind.image) {
        canvas.drawRect(_scaled(o.rect), image);
      }
    }
  }

  Rect _scaled(Rect r) => Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);

  @override
  bool shouldRepaint(_PdfEditPainter old) => old.objects != objects || old.selected != selected || old.scale != scale || old.color != color;
}

/// Editing the PDF itself in document mode: its text, pictures and shapes, not an overlay.
extension _PdfEdit on _FixedPageNoteEditorState {
  bool get _pdfEditable => !_isBlank && pdfContentEditingSupported;

  /// Opens the PDF for editing (once; it stays open while the mode is on).
  Future<void> _openPdfEditor() async {
    final path = _pdfFilePath;
    if (path == null || _pdfEditor != null || _pdfEditOpening) return;
    _pdfEditOpening = true;
    try {
      final bytes = await File(path).readAsBytes();
      final editor = await PdfContentEditor.open(bytes, fallbackFonts: await loadStandInFonts());
      if (!mounted || _pdfFilePath != path || _mode != CanvasInteractionMode.document) {
        unawaited(editor.close());
        return;
      }
      setState(() => _pdfEditor = editor);
    } catch (e) {
      if (mounted) {
        setState(() => _mode = CanvasInteractionMode.selectText);
        _pdfEditMessage(e);
      }
    } finally {
      _pdfEditOpening = false;
    }
  }

  void _closePdfEditor() {
    final editor = _pdfEditor;
    if (editor != null) unawaited(editor.close().catchError((Object _) {}));
    _pdfEditor = null;
    _pdfEditObjects.clear();
    _pdfEditLoading.clear();
    _pdfEditSelected = null;
    _endPdfInlineEdit(apply: false);
  }

  /// Leaves document mode: a line still being typed is put in the PDF first, and the editor is closed once that is done.
  void _leavePdfEdit() {
    _endPdfInlineEdit(apply: true);
    final work = _pdfEditWork;
    if (work == null) {
      _closePdfEditor();
      return;
    }
    work.whenComplete(() {
      if (mounted && _mode != CanvasInteractionMode.document) _closePdfEditor();
    });
  }

  void _pdfEditMessage(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('{error}', {'error': error}))));
  }

  /// Starts afresh for another PDF: nothing to take back, nothing open.
  void _resetPdfEdit() {
    _closePdfEditor();
    _discardEditedPdfs(keep: null);
    _discardShapedPdfs(keep: null);
  }

  /// Deletes the earlier states of the PDF that edits left (all but [keep]).
  void _discardEditedPdfs({required String? keep}) {
    for (final (path, _) in _pdfEditUndo) {
      if (path != keep) File(path).delete().catchError((Object _) => File(path));
    }
    _pdfEditUndo.clear();
  }

  /// What is on [page] to edit; read in the background the first time (the page shows it when it is there).
  List<PdfEditObject> _editObjectsOf(int page) {
    final editor = _pdfEditor;
    final known = _pdfEditObjects[page];
    if (known != null || editor == null) return known ?? const [];
    if (_pdfEditLoading.add(page)) {
      editor.objects(page).then((objects) {
        if (mounted && identical(editor, _pdfEditor)) setState(() => _pdfEditObjects[page] = objects);
      }).catchError((Object e) {
        debugPrint('reading the objects of page $page failed: $e');
        if (mounted && identical(editor, _pdfEditor)) setState(() => _pdfEditObjects[page] = const []);
      }).whenComplete(() => _pdfEditLoading.remove(page));
    }
    return const [];
  }

  /// Makes an edit with [edit] on the open PDF, writes the result as the note's PDF and shows it.
  Future<void> _applyPdfEdit(int page, Future<void> Function(PdfContentEditor editor) edit, {bool keepSelected = true}) async {
    final was = _pdfEditSelected?.$1 == page ? _pdfEditSelected!.$2 : null;
    final editor = _pdfEditor;
    final oldPath = _pdfFilePath;
    if (editor == null || oldPath == null || _pdfEditBusy) return;
    setState(() => _pdfEditBusy = true);
    final work = Completer<void>();
    _pdfEditWork = work.future;
    try {
      await edit(editor);
      final bytes = await editor.save();
      final objects = await editor.objects(page);
      final path = p.join(p.dirname(oldPath), '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}.pdf');
      await File(path).writeAsBytes(bytes);
      final sha = await sha256Of(bytes); // (not on this isolate when it is big: every edit saves the whole PDF)
      final PdfDocument doc;
      try {
        doc = await openPdfFile(path);
      } catch (_) {
        File(path).delete().catchError((Object _) => File(path));
        rethrow;
      }
      // the new picture of the page is made and decoded before it replaces the old one, which stays until then
      await _dpiSetting.catchError((Object _) => _dpi);
      final fresh = await loadPdfPicture(doc.pages[page], _pictureWidthOf(page), priority: PdfPageRenderPriority.high);
      if (!mounted) {
        fresh.release();
        doc.dispose();
        return;
      }
      _pdfEditUndo.add((oldPath, _pdfSha256));
      if (_pdfEditUndo.length > 20) {
        final (dropped, _) = _pdfEditUndo.removeAt(0);
        File(dropped).delete().catchError((Object _) => File(dropped));
      }
      _pdfEditObjects[page] = objects;
      // the picked object stays picked: the one of the same kind now nearest to where it was
      PdfEditObject? still;
      if (keepSelected && was != null) {
        for (final o in objects) {
          if (o.kind != was.kind) continue;
          if (still == null || (o.rect.center - was.rect.center).distance < (still.rect.center - was.rect.center).distance) still = o;
        }
      }
      _pdfEditSelected = still == null ? null : (page, still);
      _showPdf(path, sha, doc, page: page, data: fresh);
      _scheduleSave();
    } catch (e) {
      // what was half done is dropped: the PDF is read again from the file
      _closePdfEditor();
      _pdfEditMessage(e);
      unawaited(_openPdfEditor());
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
      work.complete();
      if (identical(_pdfEditWork, work.future)) _pdfEditWork = null;
    }
  }

  /// Shows [doc] (the file at [path]) as the note's PDF; the annotations stay as they are.
  ///
  /// With [page] and its new [data] only that page changed: the others keep what was made of them, and the old picture of
  /// [page] stays on screen until [data] replaces it.
  void _showPdf(String path, String sha, PdfDocument doc, {int? page, PdfPageData? data}) {
    final previous = _pdfDocument;
    final stale = <ui.Image>[];
    if (page != null && data != null) {
      _pageFutures[page] = SynchronousFuture(data);
      _setPageRead(page, data);
      _forgetWords(page); // (its text may have changed: it is read again)
      _jobs.dropWhere((j) => j.page == page && j.kind != PageJobKind.words);
      _hiResPending.remove(page);
      final sharp = _hiRes.remove(page);
      if (sharp != null) stale.add(sharp.image);
    } else {
      _forgetPages();
      stale.addAll(_hiRes.values.map((patch) => patch.image));
      _hiRes.clear();
      _hiResPending.clear();
    }
    _pdfPageTexts = null;
    setState(() {
      _pdfFilePath = path;
      _pdfSha256 = sha;
      _pdfDocument = doc;
      _totalPages = doc.pages.length;
      _applyPageSizes(doc);
    });
    // (not while the old picture may still be drawn this frame)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in stale) {
        image.dispose();
      }
    });
    previous?.dispose();
  }

  Future<void> _undoPdfEdit() async {
    if (_pdfEditUndo.isEmpty || _pdfEditBusy) return;
    final (path, sha) = _pdfEditUndo.last;
    final undone = _pdfFilePath;
    try {
      final doc = await openPdfFile(path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _pdfEditUndo.removeLast();
      _closePdfEditor();
      _showPdf(path, sha ?? '', doc);
      if (undone != null) File(undone).delete().catchError((Object _) => File(undone));
      _scheduleSave();
      unawaited(_openPdfEditor());
    } catch (e) {
      _pdfEditMessage(e);
    }
  }

  /// How to set text like the PDF does, as near as can be: a stand-in font of the same kind, weight and slant, as big as makes it
  /// take the room of the old text.
  Future<({String family, double factor, TextStyle style})> _pdfTextFit(int page, PdfEditObject line) async {
    try {
      final fit = fitStandIn(line, await _pdfEditor!.fontInfo(page, line));
      return line.color == null ? fit : (family: fit.family, factor: fit.factor, style: fit.style.copyWith(color: Color(line.color!)));
    } catch (e) {
      debugPrint('reading the font of the line failed: $e');
      return (family: 'sans', factor: 1.0, style: const TextStyle(color: Colors.black));
    }
  }

  /// Starts editing [line] right where it is on the page.
  Future<void> _editPdfText(int page, PdfEditObject line) async {
    _endPdfInlineEdit(apply: true);
    final fit = await _pdfTextFit(page, line);
    if (!mounted || _pdfEditor == null) return;
    _pdfInlineFit = fit;
    final controller = TextEditingController(text: line.text);
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    final focus = FocusNode();
    focus.addListener(() {
      if (!focus.hasFocus) _endPdfInlineEdit(apply: true);
    });
    setState(() => _pdfInline = (page, line, controller, focus));
    WidgetsBinding.instance.addPostFrameCallback((_) => focus.requestFocus());
  }

  /// Ends the edit in place: the typed text goes into the PDF when [apply] is set and it differs.
  void _endPdfInlineEdit({required bool apply}) {
    final inline = _pdfInline;
    if (inline == null) return;
    _pdfInline = null;
    final (page, line, controller, focus) = inline;
    final text = controller.text.replaceAll('\n', ' ');
    if (mounted) setState(() {});
    // (the field is still on screen for this frame)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
      focus.dispose();
    });
    final fit = _pdfInlineFit;
    if (apply && text.trim() != line.text) {
      unawaited(_applyPdfEdit(page, (e) => e.setText(page, line, text, family: fit?.family == 'system' ? null : fit?.family, sizeFactor: fit?.factor ?? 1)));
    }
  }

  /// The text field over [line] while it is edited: set like the text, on its line, on white where the old text was.
  Widget _pdfInlineField(PdfEditObject line, double scale, double pageWidth, TextEditingController controller, FocusNode focus, Color color) {
    final left = line.rect.left * scale;
    final fit = _pdfInlineFit;
    final size = (line.fontSize ?? 12) * scale * (fit?.factor ?? 1);
    // (the field's own theme adds letter spacing: not wanted, the text is to take the room the PDF's does)
    final style = (fit?.style ?? const TextStyle(color: Colors.black)).copyWith(fontSize: size, height: 1.0, letterSpacing: 0, wordSpacing: 0, decoration: TextDecoration.none);
    // the field's text goes on the line the old text was on
    final painter = TextPainter(text: TextSpan(text: 'Hg', style: style), textDirection: TextDirection.ltr)..layout();
    final above = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final top = (line.baseline != null ? line.baseline! * scale : line.rect.bottom * scale - size * 0.2) - above;
    painter.dispose();
    return Positioned(
      left: left,
      top: top,
      width: math.min(math.max(line.rect.width * scale + 24, 80.0), pageWidth - left),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _endPdfInlineEdit(apply: false)},
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: color.withValues(alpha: 0.6), width: 1)),
          child: TextField(
            controller: controller,
            focusNode: focus,
            style: style,
            cursorColor: color,
            decoration: const InputDecoration(isDense: true, filled: false, border: InputBorder.none, contentPadding: EdgeInsets.zero),
            maxLines: 1,
            onSubmitted: (_) => _endPdfInlineEdit(apply: true),
          ),
        ),
      ),
    );
  }

  /// The object under [at] (points of the page): text before pictures before shapes; a shape that fills the page is background.
  PdfEditObject? _editObjectAt(int page, Offset at, Size pageSize) {
    PdfEditObject? best;
    var bestRank = 9;
    var bestArea = double.infinity;
    for (final o in _editObjectsOf(page)) {
      if (!o.rect.inflate(2).contains(at)) continue;
      final area = o.rect.width * o.rect.height;
      if (o.kind == PdfObjectKind.path && area > pageSize.width * pageSize.height * 0.5) continue;
      final rank = switch (o.kind) { PdfObjectKind.text => 0, PdfObjectKind.image => 1, _ => 2 };
      if (rank < bestRank || rank == bestRank && area < bestArea) {
        best = o;
        bestRank = rank;
        bestArea = area;
      }
    }
    return best;
  }

  /// A PDF page in document mode: the page as it is, with what is on it ready to be picked and changed.
  Widget _pdfEditPage(int index) {
    return FutureBuilder<PdfPageData>(
      future: _getOrLoadPage(index),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox(width: _paperWidth, height: _heightOf(index), child: _PageSpinner(label: tr('Loading Page {n}...', {'n': index + 1})));
        }
        final data = snapshot.data!;
        final scale = _paperWidth / data.pageWidth;
        final objects = _editObjectsOf(index);
        final selected = _pdfEditSelected?.$1 == index ? _pdfEditSelected!.$2 : null;
        final color = Theme.of(context).colorScheme.primary;
        return Stack(children: [
          IgnorePointer(child: _buildPageTile(index, data)),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) {
                final hit = _editObjectAt(index, d.localPosition / scale, Size(data.pageWidth, data.pageHeight));
                _pdfEditBox.value = null; // (a drag that never ended must not leave its outline behind)
                _pdfResizeStart = null;
                setState(() => _pdfEditSelected = hit == null ? null : (index, hit));
              },
              child: CustomPaint(painter: _PdfEditPainter(objects, selected, scale, color)),
            ),
          ),
          if (selected != null && _pdfInline?.$1 != index) Positioned.fill(child: _pdfEditSelection(index, selected, scale, color, _paperWidth)),
          if (_pdfInline != null && _pdfInline!.$1 == index)
            Positioned.fill(child: Stack(children: [_pdfInlineField(_pdfInline!.$2, scale, _paperWidth, _pdfInline!.$3, _pdfInline!.$4, color)])),
          if (_pdfEditor == null)
            const Positioned(top: 8, right: 8, child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2))),
        ]);
      },
    );
  }

  /// Puts the colour from the wheel among the user's own colours (the ones the pens offer), without changing the pen.
  Future<void> _pdfPickOtherColor(Color current, void Function(Color) pick) async {
    final picked = await pickColorOnWheel(context, current);
    if (picked == null || !mounted) return;
    setState(() {
      _customColors.removeWhere((c) => c.toARGB32() == picked.toARGB32());
      _customColors.add(picked);
      if (_customColors.length > _maxCustomColors) _customColors.removeAt(0);
    });
    unawaited(widget.repository.settings.setPenColors(_customColors));
    pick(picked);
  }

  Future<PdfFontInfo> _pdfFontInfoOf(int page, PdfEditObject line) {
    if (!identical(_pdfEditInfoFor, line)) {
      _pdfEditInfoFor = line;
      _pdfEditInfo = _pdfEditor!.fontInfo(page, line);
    }
    return _pdfEditInfo!;
  }

  /// A handle on a corner or edge of the picked object. [fx] and [fy] say where: -1 left/top, 0 middle, 1 right/bottom.
  /// Dragging a corner keeps the proportions; an edge stretches one way (not for text, which only scales).
  Widget _pdfResizeHandle(int page, PdfEditObject object, Rect rect, double scale, Color color, int fx, int fy) {
    final corner = fx != 0 && fy != 0;
    final centre = Offset(rect.left + rect.width * (fx + 1) / 2, rect.top + rect.height * (fy + 1) / 2);
    Rect resized() {
      final r = _pdfResizeStart ?? rect;
      final moved = _pdfResizeMoved;
      // the corner or edge being dragged, and the opposite one that stays where it is
      final anchor = Offset(r.left + r.width * (1 - fx) / 2, r.top + r.height * (1 - fy) / 2);
      final to = Offset(r.left + r.width * (fx + 1) / 2, r.top + r.height * (fy + 1) / 2) + moved;
      var w = fx == 0 ? r.width : (to.dx - anchor.dx).abs() * (fx > 0 ? (to.dx >= anchor.dx ? 1 : 0) : (to.dx <= anchor.dx ? 1 : 0));
      var h = fy == 0 ? r.height : (to.dy - anchor.dy).abs() * (fy > 0 ? (to.dy >= anchor.dy ? 1 : 0) : (to.dy <= anchor.dy ? 1 : 0));
      if (corner) {
        // (as much bigger as the drag asks for, taken from both directions)
        final f = math.max(8 / math.min(r.width, r.height), (w / r.width + h / r.height) / 2);
        w = r.width * f;
        h = r.height * f;
      } else {
        w = math.max(w, 8);
        h = math.max(h, 8);
      }
      final left = fx == 1 || fx == 0 ? r.left : r.right - w;
      final top = fy == 1 || fy == 0 ? r.top : r.bottom - h;
      return Rect.fromLTWH(left, top, w, h);
    }

    return Positioned(
      key: ValueKey('pdf-handle-$fx-$fy'),
      left: centre.dx - 16,
      top: centre.dy - 16,
      width: 32,
      height: 32,
      child: _PdfEditGesture(
        onPanStart: (_) {
          _pdfResizeStart = rect;
          _pdfResizeMoved = Offset.zero;
        },
        onPanUpdate: (d) {
          _pdfResizeMoved += d.delta;
          _pdfEditBox.value = resized();
        },
        onPanEnd: (_) {
          final to = resized();
          _pdfEditBox.value = null;
          _pdfResizeStart = null;
          _applyPdfEdit(page, (e) => e.resizeObject(page, object, Rect.fromLTRB(to.left / scale, to.top / scale, to.right / scale, to.bottom / scale)));
        },
        onPanCancel: () {
          _pdfEditBox.value = null;
          _pdfResizeStart = null;
        },
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: Colors.white, shape: corner ? BoxShape.circle : BoxShape.rectangle, border: Border.all(color: color, width: 2)),
          ),
        ),
      ),
    );
  }

  /// The handle above a picked picture or shape: dragged round its middle to turn it (a little help to land on 15 degree steps).
  Widget _pdfTurnHandle(int page, PdfEditObject object, Rect box, Color color) {
    final centre = box.center;
    // (on the side the bar is not: the bar is above unless the top is too near the edge of the page)
    final below = box.top > 52;
    final grip = Offset(centre.dx, below ? box.bottom + 26 : box.top - 26);
    double angle() {
      final at = Offset(grip.dx - 16, grip.dy - 16) + _pdfTurnMoved - centre; // (_pdfTurnMoved: where the pointer is in the handle)
      var deg = math.atan2(at.dx, -at.dy) * 180 / math.pi - (below ? 180 : 0);
      if (deg <= -180) deg += 360;
      final near = (deg / 15).roundToDouble() * 15;
      if ((deg - near).abs() < 4) deg = near;
      return deg;
    }

    return Positioned(
      key: const ValueKey('pdf-turn-handle'),
      left: grip.dx - 16,
      top: grip.dy - 16,
      width: 32,
      height: 32,
      child: _PdfEditGesture(
        onPanStart: (d) {
          _pdfTurnMoved = d.localPosition;
          _pdfEditTurn.value = 0;
        },
        onPanUpdate: (d) {
          _pdfTurnMoved = d.localPosition;
          _pdfEditTurn.value = angle();
        },
        onPanEnd: (_) {
          final deg = _pdfEditTurn.value ?? 0;
          _pdfEditTurn.value = null;
          if (deg.abs() >= 0.5) _applyPdfEdit(page, (e) => e.rotateObject(page, object, deg));
        },
        onPanCancel: () => _pdfEditTurn.value = null,
        child: Center(
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
            child: Icon(Icons.rotate_right, size: 14, color: color),
          ),
        ),
      ),
    );
  }

  Widget _pdfFormatButton(IconData icon, String tooltip, bool on, VoidCallback? onTap, Color color) => IconButton(
        tooltip: tooltip,
        isSelected: on,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(backgroundColor: on ? color.withValues(alpha: 0.18) : null),
        icon: Icon(icon, size: 18),
        onPressed: onTap,
      );

  /// The bar above the picked object: for text what it says, colour, style and size; for all of it, delete.
  Widget _pdfEditBar(int page, PdfEditObject object, double scale, Color color) {
    final isText = object.kind == PdfObjectKind.text;
    final size = object.fontSize ?? 12;
    void format({int? color, bool? bold, bool? italic, bool? underline, bool? strike}) =>
        _applyPdfEdit(page, (e) => e.formatText(page, object, color: color, bold: bold, italic: italic, underline: underline, strikethrough: strike));
    void resizeText(double to) {
      if (to < 4 || to > 400) return;
      final f = to / size;
      final r = object.rect;
      _applyPdfEdit(page, (e) => e.resizeObject(page, object, Rect.fromLTWH(r.left, r.top, r.width * f, r.height * f)));
    }

    final current = Color(object.color ?? 0xFF000000);
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (isText) ...[
            IconButton(
              tooltip: tr('Edit text'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _editPdfText(page, object),
            ),
            PopupMenuButton<Object>(
              tooltip: tr('Text colour'),
              position: PopupMenuPosition.under,
              onSelected: (picked) {
                if (picked is Color) {
                  format(color: picked.toARGB32());
                } else {
                  _pdfPickOtherColor(current, (c) => format(color: c.toARGB32()));
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem<Object>(
                  enabled: false,
                  child: SizedBox(
                    width: 250,
                    // the colours every other colour choice of the app offers, and the user's own
                    child: ColorSwatches(
                      selected: current,
                      onPick: (c) => Navigator.pop(context, c),
                      extra: _customColors,
                      onMore: () => Navigator.pop(context, 'other'),
                      keyPrefix: 'pdf-text',
                    ),
                  ),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(color: current, shape: BoxShape.circle, border: Border.all(color: Colors.black38)),
                ),
              ),
            ),
            FutureBuilder<PdfFontInfo>(
              future: _pdfFontInfoOf(page, object),
              builder: (context, snapshot) {
                final info = snapshot.data;
                return Row(mainAxisSize: MainAxisSize.min, children: [
                  _pdfFormatButton(Icons.format_bold, tr('Bold'), info?.bold ?? false, info == null ? null : () => format(bold: !info.bold), color),
                  _pdfFormatButton(Icons.format_italic, tr('Italic'), info?.italic ?? false, info == null ? null : () => format(italic: !info.italic), color),
                ]);
              },
            ),
            _pdfFormatButton(Icons.format_underlined, tr('Underline'), object.underlined, () => format(underline: !object.underlined), color),
            _pdfFormatButton(Icons.format_strikethrough, tr('Strikethrough'), object.struckThrough, () => format(strike: !object.struckThrough), color),
            IconButton(
              tooltip: tr('Smaller'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 18),
              onPressed: () => resizeText(size.roundToDouble() - (size == size.roundToDouble() ? 1 : 0)),
            ),
            Text.verbatim(size.round().toString(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            IconButton(
              tooltip: tr('Bigger'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => resizeText(size.roundToDouble() + 1),
            ),
          ],
          if (!isText)
            IconButton(
              tooltip: tr('Rotate'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 18),
              onPressed: () => _applyPdfEdit(page, (e) => e.rotateObject(page, object, 90)),
            ),
          IconButton(
            tooltip: tr('Delete'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => _applyPdfEdit(page, (e) => e.removeObject(page, object), keepSelected: false),
          ),
        ]),
      ),
    );
  }

  /// The picked object: dragged to move it, handles to resize it, the bar with what can be done to it above.
  Widget _pdfEditSelection(int page, PdfEditObject object, double scale, Color color, double pageWidth) {
    final rest = Rect.fromLTRB(object.rect.left * scale, object.rect.top * scale, object.rect.right * scale, object.rect.bottom * scale);
    final isText = object.kind == PdfObjectKind.text;
    return ListenableBuilder(
      listenable: Listenable.merge([_pdfEditBox, _pdfEditTurn]),
      builder: (context, _) {
        final live = _pdfEditBox.value;
        final turn = _pdfEditTurn.value;
        final box = live ?? rest;
        return Stack(children: [
          Positioned.fromRect(
            rect: box.inflate(2),
            child: _PdfEditGesture(
              onDoubleTap: isText ? () => _editPdfText(page, object) : null,
              onPanStart: (_) => _pdfEditBox.value = rest,
              onPanUpdate: (d) => _pdfEditBox.value = (_pdfEditBox.value ?? rest).shift(d.delta),
              onPanEnd: (_) {
                final to = _pdfEditBox.value ?? rest;
                _pdfEditBox.value = null;
                final by = (to.topLeft - rest.topLeft) / scale;
                if (by.distance > 1) _applyPdfEdit(page, (e) => e.moveObject(page, object, by));
              },
              onPanCancel: () => _pdfEditBox.value = null,
              child: Transform.rotate(
                angle: (turn ?? 0) * math.pi / 180,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: color, width: 1.5),
                    color: color.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
          ),
          // (kept while dragging: a handle taken away mid-drag never gets to say the drag is over)
          if (turn == null)
            for (final (fx, fy) in [(-1, -1), (1, -1), (-1, 1), (1, 1), if (!isText) ...[(0, -1), (0, 1), (-1, 0), (1, 0)]])
              _pdfResizeHandle(page, object, box, scale, color, fx, fy),
          if (!isText && live == null) _pdfTurnHandle(page, object, box, color),
          if (live == null && turn == null)
            Positioned(
              left: 0,
              right: 0,
              top: box.top > 52 ? box.top - 46 : box.bottom + 10,
              child: Align(
                // (about over the object, and always inside the page)
                alignment: Alignment((box.center.dx / pageWidth * 2 - 1).clamp(-1.0, 1.0), 0),
                child: ConstrainedBox(constraints: BoxConstraints(maxWidth: pageWidth - 8), child: _pdfEditBar(page, object, scale, color)),
              ),
            ),
        ]);
      },
    );
  }
}
