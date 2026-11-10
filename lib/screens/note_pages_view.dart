part of 'history_panel.dart';

/// The pages of a note read from a file (a version), as they look in the editor but without anything to touch,
/// with the changes of [diff] marked on them. [newer]: the note shown is the newer side of the comparison (things
/// that were removed are shown as outlines of where they were); else the older side (things that were added since
/// are outlines).
class NotePagesView extends StatefulWidget {
  final ParsedNoteFile file;
  final VersionDiff? diff;
  final bool newer;

  /// Colour what each person added in their own colour.
  final bool byAuthor;

  /// Colour each thing by the version it is from.
  final NoteBlame? blame;

  const NotePagesView({super.key, required this.file, this.diff, this.newer = false, this.byAuthor = false, this.blame});

  @override
  State<NotePagesView> createState() => _NotePagesViewState();
}

class _NotePagesViewState extends State<NotePagesView> {
  PdfDocument? _pdf;
  final Map<int, ui.Image> _rendered = {};
  final Map<int, Future<ui.Image?>> _rendering = {};
  late final RichInlineTextController _document = RichInlineTextController()
    ..text = widget.file.note.documentText
    ..attributes.addAll(widget.file.note.documentSpans);

  @override
  void initState() {
    super.initState();
    final bytes = widget.file.pdf;
    if (bytes != null) {
      PdfDocument.openData(bytes).then((doc) {
        if (mounted) {
          setState(() => _pdf = doc);
        } else {
          doc.dispose();
        }
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    for (final i in _rendered.values) {
      i.dispose();
    }
    _pdf?.dispose();
    _document.dispose();
    super.dispose();
  }

  NoteData get _note => widget.file.note;

  /// The width of a page in the page space: that of the paper, and 800 for the pages of a PDF.
  double get _pageWidth => _isPdf ? _pdfPageWidth : _note.pageFormat.widthUnits(landscape: _note.landscape);

  late final List<String> _authorNames = [for (final p in NoteAuthors.of(widget.file.note).people) p.name];

  /// The text boxes, pictures and highlights of page [index] with their authors, to frame in their colours.
  List<({Rect rect, Color color})> _framesOn(int index) {
    Color colorOf(ElementKind kind, String id, String? author) {
      final blame = widget.blame;
      if (blame == null) return NoteAuthors.colorOf(author, _authorNames);
      return _VersionViewState.blameColor(blame.origin['${kind.name}:$id'] ?? blame.versions.length, blame.versions.length);
    }

    return [
      for (final b in _note.textBoxes[index] ?? const <TextBoxWidgetModel>[])
        (rect: b.position & Size(b.size.width, b.size.height < 40 ? 40 : b.size.height), color: colorOf(ElementKind.box, b.id, b.author)),
      for (final m in _note.images[index] ?? const <ImageItem>[]) (rect: m.position & m.size, color: colorOf(ElementKind.image, m.id, m.author)),
      for (final h in _note.highlights[index] ?? const <PdfHighlight>[]) (rect: h.rect, color: colorOf(ElementKind.mark, h.id, h.author)),
    ];
  }
  bool get _isPdf => widget.file.pdf != null;
  bool get _hasDocument => !_isPdf && _note.documentText.trim().isNotEmpty;

  int get _pageCount {
    if (_isPdf) return _pdf?.pages.length ?? _note.pdfPageCount ?? 1;
    var last = 0;
    for (final m in [_note.strokes, _note.textBoxes, _note.images, _note.highlights]) {
      for (final page in m.keys) {
        if ((m[page] as List).isNotEmpty && page > last) last = page;
      }
    }
    for (final e in widget.diff?.elements ?? const <ElementChange>[]) {
      if (e.page > last) last = e.page;
    }
    return last + 1;
  }

  double _heightOf(int index) {
    final pdf = _pdf;
    if (pdf != null && index < pdf.pages.length) {
      final page = pdf.pages[index];
      return _pdfPageWidth * page.height / page.width;
    }
    return _pageWidth * _note.pageFormat.aspect(landscape: _note.landscape);
  }

  Future<ui.Image?> _render(int index) => _rendering[index] ??= () async {
        final pdf = _pdf;
        if (pdf == null || index >= pdf.pages.length) return null;
        final image = await renderPageImage(pdf.pages[index], 1200);
        if (!mounted) {
          image.dispose();
          return null;
        }
        _rendered[index] = image;
        return image;
      }();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        itemCount: _pageCount,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: FittedBox(fit: BoxFit.fitWidth, child: _page(i)),
            ),
          ),
        ),
      ),
    );
  }

  /// An infinite canvas: not a page but the part of the surface that has something on it, as big as it is.
  bool get _infinite => !_isPdf && _note.pageFormat.isInfinite;

  late final Rect _canvasView = canvasWindow(canvasContentBounds(
    strokes: _note.strokes.values.expand((e) => e),
    boxes: _note.textBoxes.values.expand((e) => e),
    images: _note.images.values.expand((e) => e),
  ));

  Widget _canvasPage(int index) {
    final view = _canvasView;
    return Container(
      key: ValueKey('preview-page-$index'),
      width: view.width,
      height: view.height,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 3))]),
      child: ClipRect(
        child: Stack(children: [
          Positioned(
            left: -view.left,
            top: -view.top,
            width: canvasExtent,
            height: canvasExtent,
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: CanvasBackgroundPainter(_note.background, () => (rect: view, scale: 1.0)))),
              Positioned.fill(child: _content(index)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _page(int index) {
    if (_infinite) return _canvasPage(index);
    final h = _heightOf(index);
    final content = _content(index);
    if (index == 0 && _hasDocument) {
      // the written document: the page grows with it
      return Stack(key: ValueKey('preview-page-$index'), children: [
        DocumentSheet(
          controller: _document,
          editing: false,
          width: _pageWidth,
          minHeight: h,
          background: _note.background,
          marginLeft: _note.marginLeft,
          marginRight: _note.marginRight,
          marginTop: _note.marginTop,
          marginBottom: _note.marginBottom,
        ),
        Positioned.fill(child: content),
      ]);
    }
    return Container(
      key: ValueKey('preview-page-$index'),
      width: _pageWidth,
      height: h,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 3))]),
      child: ClipRect(
        child: Stack(children: [
          // (a page added to a PDF shows the paper, not the file)
          if (_isPdf && !_note.nativePages.contains(index))
            Positioned.fill(
              child: FutureBuilder<ui.Image?>(
                future: _pdf == null ? null : _render(index),
                builder: (context, snap) => snap.data == null ? const SizedBox.shrink() : RawImage(image: snap.data, fit: BoxFit.fill),
              ),
            )
          else
            Positioned.fill(child: CustomPaint(painter: PageBackgroundPainter(_note.background))),
          Positioned.fill(child: content),
        ]),
      ),
    );
  }

  /// What is on page [index]. With a comparison, what did not change is faded, drawings that changed are drawn in
  /// colour (as they were, and as they are), and the other things that changed are framed.
  Widget _content(int index) {
    final diff = widget.diff;
    final changes = diff?.onPage(index) ?? const <ElementChange>[];
    final changed = {for (final c in changes) '${c.kind.name}:${c.id}'};
    Widget faded(String key, Widget child) => diff == null || changed.contains(key) ? child : Opacity(opacity: 0.35, child: child);
    final strokes = _note.strokes[index] ?? const <DrawingStroke>[];
    return IgnorePointer(
      child: Stack(clipBehavior: Clip.hardEdge, children: [
        for (final m in _note.images[index] ?? const [])
          if (_note.layers.byId(m.layer).visible)
          if (widget.file.images[m.id] case final picture?)
            Positioned(
              left: m.position.dx,
              top: m.position.dy,
              width: m.size.width,
              height: m.size.height,
              child: faded('image:${m.id}', Image.memory(picture.bytes, fit: BoxFit.fill, errorBuilder: (_, _, _) => const SizedBox.shrink())),
            ),
        Positioned.fill(child: CustomPaint(painter: HighlightsPainter(highlights: _note.highlights[index] ?? const []))),
        Positioned.fill(
          child: CustomPaint(
            key: widget.blame != null
                ? ValueKey('blame-ink-$index')
                : widget.byAuthor
                    ? ValueKey('author-ink-$index')
                    : (diff == null ? null : ValueKey('diff-ink-$index')),
            painter: widget.blame != null
                ? _ColouredInkPainter(strokes, (s) => _VersionViewState.blameColor(widget.blame!.origin['stroke:${s.id}'] ?? widget.blame!.versions.length, widget.blame!.versions.length))
                : widget.byAuthor
                ? _ColouredInkPainter(strokes, (s) => NoteAuthors.colorOf(s.author, _authorNames))
                : diff == null
                    ? UnifiedInkPainter(strokes: strokes, layers: _note.layers)
                    : _DiffInkPainter(strokes, [for (final c in changes) if (c.kind == ElementKind.stroke) c]),
          ),
        ),
        for (final box in _note.textBoxes[index] ?? const <TextBoxWidgetModel>[])
          if (_note.layers.byId(box.layer).visible)
          Positioned(
            left: box.position.dx,
            top: box.position.dy,
            child: faded(
              'box:${box.id}',
              Container(
                width: box.size.width,
                constraints: BoxConstraints(minHeight: box.size.height),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: box.style.fill,
                  borderRadius: BorderRadius.circular(box.style.radius),
                  border: box.style.borderWidth > 0 ? Border.all(color: box.style.borderColor, width: box.style.borderWidth) : null,
                ),
                child: MarkdownView(controller: box.controller, fontSize: box.fontSize, textColor: box.style.textColor),
              ),
            ),
          ),
        if (widget.byAuthor || widget.blame != null)
          Positioned.fill(child: CustomPaint(key: ValueKey('${widget.blame != null ? 'blame' : 'author'}-marks-$index'), painter: _ColouredFramesPainter(_framesOn(index)))),
        if (changes.any((c) => c.kind != ElementKind.stroke))
          Positioned.fill(
            child: CustomPaint(
              key: ValueKey('diff-marks-$index'),
              painter: _ChangesPainter([for (final c in changes) if (c.kind != ElementKind.stroke) c], shownIsNewer: widget.newer),
            ),
          ),
      ]),
    );
  }
}

/// The drawings of a page, each in a colour of its own ([colorOf]: of who drew it, or of the version it is from).
class _ColouredInkPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final Color Function(DrawingStroke stroke) colorOf;

  _ColouredInkPainter(this.strokes, this.colorOf);

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.points.length < 2) continue;
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (var i = 1; i < s.points.length; i++) {
        path.lineTo(s.points[i].dx, s.points[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colorOf(s)
          ..strokeWidth = s.width < 2 ? 2 : s.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ColouredInkPainter old) => true;
}

/// A frame in its own colour round each text box, picture and highlight.
class _ColouredFramesPainter extends CustomPainter {
  final List<({Rect rect, Color color})> frames;

  _ColouredFramesPainter(this.frames);

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in frames) {
      final rect = RRect.fromRectAndRadius(f.rect.inflate(3), const Radius.circular(4));
      canvas.drawRRect(rect, Paint()..color = f.color.withValues(alpha: 0.12));
      canvas.drawRRect(
        rect,
        Paint()
          ..color = f.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ColouredFramesPainter old) => true;
}

/// The drawings of a page with a comparison: those that did not change faded, the ones that were added green, removed
/// red, and a changed one both ways: red as it was, green as it is.
class _DiffInkPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final List<ElementChange> changes;

  _DiffInkPainter(this.strokes, this.changes);

  static const added = Color(0xFF2E9E44), removed = Color(0xFFE53935);

  @override
  void paint(Canvas canvas, Size size) {
    final involved = {for (final c in changes) c.id};
    for (final s in strokes) {
      if (!involved.contains(s.id)) _draw(canvas, s, s.color.withValues(alpha: 0.25));
    }
    for (final c in changes) {
      final older = c.older is DrawingStroke ? c.older as DrawingStroke : null;
      final newer = c.newer is DrawingStroke ? c.newer as DrawingStroke : null;
      switch (c.change) {
        case ChangeKind.added:
          if (newer != null) _draw(canvas, newer, added, glow: true);
        case ChangeKind.removed:
          if (older != null) _draw(canvas, older, removed, glow: true);
        case ChangeKind.changed:
          if (older != null) _draw(canvas, older, removed.withValues(alpha: 0.7), glow: true);
          if (newer != null) _draw(canvas, newer, added, glow: true);
      }
    }
  }

  static void _draw(Canvas canvas, DrawingStroke s, Color color, {bool glow = false}) {
    if (s.points.length < 2) return;
    final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
    for (var i = 1; i < s.points.length; i++) {
      path.lineTo(s.points[i].dx, s.points[i].dy);
    }
    Paint paint(Color c, double width) => Paint()
      ..color = c
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    // a soft band under it, so that a thin line in a changed colour is easy to see
    if (glow) canvas.drawPath(path, paint(color.withValues(alpha: 0.18), s.width + 10));
    canvas.drawPath(path, paint(color, s.width < 2 ? 2 : s.width));
  }

  @override
  bool shouldRepaint(covariant _DiffInkPainter old) => old.strokes != strokes || old.changes != changes;
}

/// Marks changes on a page: added green, removed red, changed orange. What is not on the page shown (removed, when the
/// newer side is shown; added, when the older side is) is drawn as a dashed outline of where it is.
class _ChangesPainter extends CustomPainter {
  final List<ElementChange> changes;
  final bool shownIsNewer;

  _ChangesPainter(this.changes, {required this.shownIsNewer});

  @override
  void paint(Canvas canvas, Size size) {
    for (final c in changes) {
      final color = switch (c.change) {
        ChangeKind.added => Colors.green,
        ChangeKind.removed => Colors.red,
        ChangeKind.changed => Colors.orange,
      };
      final absent = shownIsNewer ? c.change == ChangeKind.removed : c.change == ChangeKind.added;
      final rect = RRect.fromRectAndRadius(c.rect.inflate(4), const Radius.circular(4));
      if (!absent) canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: 0.15));
      final outline = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      if (absent) {
        _dashed(canvas, rect, outline);
      } else {
        canvas.drawRRect(rect, outline);
      }
    }
  }

  static void _dashed(Canvas canvas, RRect rect, Paint paint) {
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 12) {
        canvas.drawPath(metric.extractPath(d, d + 7), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChangesPainter old) => old.changes != changes || old.shownIsNewer != shownIsNewer;
}
