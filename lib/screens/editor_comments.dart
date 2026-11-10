part of 'fixed_page_note_editor.dart';

/// Comments shown as speech bubbles beside the page.
extension _EditorComments on _FixedPageNoteEditorState {
  /// How wide the strip to the right of the pages is for the boxes of comments: 0 when
  /// there are none, or the window is too narrow to leave room (they stay on the page then).
  double get _commentGutterWidth {
    if (_infinite || _commentBoxIds().isEmpty) return 0;
    final room = _contentWidth - (_pagesLeft + _paperWidth * _pageScale) - 16;
    return room >= 150 ? math.min(240.0, room) : 0;
  }

  /// Whether [box] is a comment shown beside the page instead of on it.
  bool _inGutter(TextBoxWidgetModel box) => _commentGutterWidth > 0 && _commentBoxIds().contains(box.id);

  /// [page] with the boxes of its comments beside it, each level with the text it is about.
  Widget _pageWithComments(int index, Widget page) {
    final width = _commentGutterWidth;
    if (width == 0) return page;
    final boxes = [
      for (final b in _textBoxesPerPage[index] ?? const <TextBoxWidgetModel>[])
        if (_inGutter(b)) b,
    ];
    if (boxes.isEmpty) return page;
    final scale = _pageScale;
    final pageRight = _pagesLeft + _paperWidth * scale;
    double wantedTop(TextBoxWidgetModel b) {
      final marks = [for (final h in _highlightsPerPage[index] ?? const <PdfHighlight>[]) if (h.commentBox == b.id) h.rect.top];
      return (marks.isEmpty ? b.position.dy : marks.reduce(math.min)) * scale;
    }

    boxes.sort((a, b) => wantedTop(a).compareTo(wantedTop(b)));
    final cards = <Widget>[];
    var free = 0.0; // where the card above ends: the next one starts below that
    for (final b in boxes) {
      final top = math.max(wantedTop(b), free);
      final painter = TextPainter(
        text: TextSpan(text: b.controller.text.isEmpty ? ' ' : b.controller.text, style: const TextStyle(fontSize: 13, height: 1.35)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - 56);
      final height = painter.height + 22;
      free = top + height + 8;
      cards.add(Positioned(left: pageRight + 4, top: top, width: width - 4, child: _commentCard(b)));
    }
    return Stack(children: [page, ...cards]);
  }

  Widget _commentCard(TextBoxWidgetModel box) {
    return CustomPaint(
      key: ValueKey('comment-card-${box.id}'),
      painter: _SpeechBubble(color: const Color(0xFFFFFAD9), edge: const Color(0xFFF0C419)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 10, 12),
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: TextField(
              key: ValueKey('comment-text-${box.id}'),
              controller: box.controller,
              focusNode: box.focusNode,
              maxLines: null,
              style: const TextStyle(fontSize: 13, height: 1.35, color: Color(0xFF3B3200)),
              cursorColor: const Color(0xFF3B3200),
              decoration: InputDecoration(filled: false, border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero, hintText: tr('Write the comment...'), hintStyle: TextStyle(color: Color(0x803B3200))),
              onChanged: (_) => setState(() {}), // the bubble grows with the text, and the ones below move
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: InkWell(
              key: ValueKey('comment-delete-${box.id}'),
              onTap: () => _deleteComment(box),
              child: const Icon(Icons.close_rounded, size: 14, color: Color(0x803B3200)),
            ),
          ),
        ]),
      ),
    );
  }

  /// Takes a comment away: its box and the marks on the text.
  void _deleteComment(TextBoxWidgetModel box) {
    setState(() {
      for (final list in _highlightsPerPage.values) {
        list.removeWhere((h) => h.commentBox == box.id);
      }
      for (final list in _textBoxesPerPage.values) {
        list.remove(box);
      }
      if (_activeSelectedBox == box) _activeSelectedBox = null;
    });
    _scheduleSave();
  }

  // ---- the assistant for the whole document
}

/// A rounded speech bubble whose curved tail, at the top left, points at the text it is about.
class _SpeechBubble extends CustomPainter {
  final Color color, edge;
  const _SpeechBubble({required this.color, required this.edge});

  @override
  void paint(Canvas canvas, Size size) {
    const tail = 11.0, radius = 14.0;
    final body = RRect.fromLTRBR(tail, 0, size.width, size.height, const Radius.circular(radius));
    final path = Path()
      ..addRRect(body)
      ..moveTo(tail + 1, 8)
      ..quadraticBezierTo(tail - 3, 13, 0, 17)
      ..quadraticBezierTo(tail + 4, 18, tail + 1, 24)
      ..close();
    canvas.drawShadow(path.shift(const Offset(0, 1)), const Color(0xFF6B5A00), 4, true);
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, Color.lerp(color, edge, 0.35)!])
            .createShader(Offset.zero & size),
    );
    canvas.drawPath(path, Paint()..color = edge.withValues(alpha: 0.7)..style = PaintingStyle.stroke..strokeWidth = 0.8);
  }

  @override
  bool shouldRepaint(_SpeechBubble old) => old.color != color || old.edge != edge;
}
