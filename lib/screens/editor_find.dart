part of 'fixed_page_note_editor.dart';

/// One place the search found in the open note.
class _FindMatch {
  final int page;
  final SearchPlace place;

  /// The text box it is in, or the line of the PDF page (-1: neither).
  final String? boxId;
  final int line;
  final int start, end;

  /// Where the writing lies that was found in handwriting.
  final Rect? area;

  /// The words around the match (the text before it and after it, on one line), for the list of matches beside the note.
  final String before, word, after;
  const _FindMatch(this.page, this.place, this.start, this.end, {this.boxId, this.line = -1, this.area, this.before = '', this.word = '', this.after = ''});
}

/// Draws the rectangles of the places a search found on a page.
class _FindPainter extends CustomPainter {
  final List<Rect> others;
  final List<Rect> current;
  const _FindPainter(this.others, this.current);

  @override
  void paint(Canvas canvas, Size size) {
    final soft = Paint()..color = const Color(0x66FFEB3B);
    final strong = Paint()..color = const Color(0xAAFF9800);
    for (final r in others) {
      canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(1), const Radius.circular(2)), soft);
    }
    for (final r in current) {
      canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(1), const Radius.circular(2)), strong);
    }
  }

  @override
  bool shouldRepaint(_FindPainter old) => !listEquals(old.others, others) || !listEquals(old.current, current);
}

/// Finding words in the open note: the written document, the text boxes, the text of the PDF and the handwriting (as far as it was read).
extension _EditorFind on _FixedPageNoteEditorState {
  /// Opens the bar for the search; [query] starts it (the search of all notes hands its words over), and the first match at or after
  /// [page] is the one shown.
  void _openFind({SearchQuery? query, int page = 0, bool replace = false}) {
    if (query != null) {
      _findQuery = query;
      _findField.text = query.text;
    } else {
      // text that is selected becomes the search
      final picked = _currentSelectedText?.trim() ?? '';
      if (picked.isNotEmpty && !picked.contains('\n')) {
        _findQuery = SearchQuery(picked, regex: _findQuery.regex, caseSensitive: _findQuery.caseSensitive, wholeWord: _findQuery.wholeWord);
        _findField.text = picked;
      }
    }
    setState(() {
      if (_roomForSidePanel) _closeSidePanels();
      _findOpen = true;
      if (replace) _replaceOpen = true;
    });
    // the words to replace them with are typed next once there is something to find
    if (replace && _findField.text.isNotEmpty) {
      _replaceFocus.requestFocus();
    } else {
      _findFocus.requestFocus();
      _findField.selection = TextSelection(baseOffset: 0, extentOffset: _findField.text.length);
    }
    _runFind(fromPage: page);
  }

  void _closeFind() {
    _findDebounce?.cancel();
    _findRun++;
    setState(() {
      _findOpen = false;
      _found = const [];
      _foundAt = -1;
    });
    _applyFoundMarks();
  }

  void _findChanged() {
    _findQuery = SearchQuery(_findField.text, regex: _findQuery.regex, caseSensitive: _findQuery.caseSensitive, wholeWord: _findQuery.wholeWord);
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 200), _runFind);
    setState(() {});
  }

  /// Finds again. The match shown is the first at or after [fromPage], or, after a replacement, the one that follows it: the one
  /// that is [resume] (its place in the list before) unless that is still in [past] before the end of what was put there.
  Future<void> _runFind({int fromPage = 0, int? resume, ({_FindMatch match, int end})? past}) async {
    final run = ++_findRun;
    final query = _findQuery;
    if (query.isEmpty || query.problem != null) {
      setState(() {
        _found = const [];
        _foundAt = -1;
        _findNote = null;
      });
      _applyFoundMarks();
      return;
    }
    // every piece of text there is, with where it is
    final pdf = await _readPdfPageTexts();
    if (!mounted || run != _findRun) return;
    final pieces = <_FindMatch>[];
    final texts = <String>[];
    for (var page = 0; page < _pageCount; page++) {
      final lines = pdf != null && page < pdf.length ? pdf[page].split('\n') : const <String>[];
      for (var l = 0; l < lines.length; l++) {
        if (lines[l].isEmpty) continue;
        pieces.add(_FindMatch(page, SearchPlace.pdfText, 0, 0, line: l));
        texts.add(lines[l]);
      }
      if (_isDocumentPage(page)) {
        pieces.add(_FindMatch(page, SearchPlace.document, 0, 0));
        texts.add(_documentController.text);
      }
      for (final box in _textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[]) {
        if (box.controller.text.isEmpty) continue;
        pieces.add(_FindMatch(page, SearchPlace.textBox, 0, 0, boxId: box.id));
        texts.add(box.controller.text);
      }
    }
    for (final t in await widget.repository.text.inkTexts(widget.noteId)) {
      if (t.text.isEmpty || t.page >= _pageCount) continue;
      pieces.add(_FindMatch(t.page, SearchPlace.handwriting, 0, 0, area: t.bounds));
      texts.add(t.text);
    }
    if (!mounted || run != _findRun) return;
    List<List<MatchRange>> ranges;
    try {
      ranges = await findInTexts(query, texts);
    } catch (e) {
      if (!mounted || run != _findRun) return;
      setState(() {
        _found = const [];
        _foundAt = -1;
        _findNote = e is SearchTooSlow ? tr('That pattern takes too long to try.') : tr('The search failed.');
      });
      _applyFoundMarks();
      return;
    }
    if (!mounted || run != _findRun) return;
    final found = <_FindMatch>[
      for (var i = 0; i < pieces.length; i++)
        for (final r in ranges[i])
          _FindMatch(pieces[i].page, pieces[i].place, r.start, r.end,
              boxId: pieces[i].boxId, line: pieces[i].line, area: pieces[i].area, before: _around(texts[i], math.max(0, r.start - 28), r.start), word: _around(texts[i], r.start, math.min(texts[i].length, r.end)), after: _around(texts[i], r.end, math.min(texts[i].length, r.end + 40))),
    ];
    // the match the person is at stays the one shown while they type; else the first one at or after the page asked for
    var at = found.isEmpty ? -1 : found.indexWhere((m) => m.page >= fromPage);
    if (found.isNotEmpty && at < 0) at = 0;
    if (resume != null && found.isNotEmpty) {
      at = resume.clamp(0, found.length - 1);
      if (past != null) {
        bool same(_FindMatch m) => m.page == past.match.page && m.place == past.match.place && m.boxId == past.match.boxId && m.line == past.match.line;
        while (at < found.length - 1 && same(found[at]) && found[at].start < past.end) {
          at++;
        }
      }
    }
    setState(() {
      _found = found;
      _foundAt = at;
      _findNote = null;
    });
    _showFoundMatch();
  }

  /// [from] to [to] of [text] on one line (a line break becomes a space).
  String _around(String text, int from, int to) => from >= to ? '' : text.substring(from, to).replaceAll(RegExp(r'\s+'), ' ');

  /// Can the words of this match be changed? (Those in the PDF and in handwriting cannot.)
  bool _replaceable(_FindMatch m) => m.place == SearchPlace.document || m.place == SearchPlace.textBox;

  RichInlineTextController? _controllerOf(_FindMatch m) {
    if (m.place == SearchPlace.document) return _documentController;
    return (_textBoxesPerPage[m.page] ?? const <TextBoxWidgetModel>[]).where((b) => b.id == m.boxId).firstOrNull?.controller;
  }

  /// Puts the replacement in place of the match being looked at, and goes on to the next one.
  Future<void> _replaceOne() async {
    if (_found.isEmpty) return;
    final at = _foundAt < 0 ? 0 : _foundAt;
    final m = _found[at];
    if (!_replaceable(m)) {
      // this one is in a place that cannot be changed: on to the one that can
      final next = [for (var k = 1; k <= _found.length; k++) (at + k) % _found.length].where((i) => _replaceable(_found[i])).firstOrNull;
      if (next == null) return;
      setState(() => _foundAt = next);
      _showFoundMatch();
      return;
    }
    final c = _controllerOf(m);
    final text = _replaceField.text;
    final now = c == null ? null : _findQuery.replacement(text, c.text, MatchRange(m.start, m.end));
    if (c == null || now == null) {
      // the text has changed since this was found
      await _runFind();
      return;
    }
    c.replaceRanges([(start: m.start, end: m.end, text: now)]);
    await _runFind(resume: at, past: (match: m, end: m.start + now.length));
  }

  /// Puts the replacement in place of every match in the note's own texts.
  Future<void> _replaceAll() async {
    final text = _replaceField.text;
    final byText = <RichInlineTextController, List<MatchRange>>{};
    for (final m in _found) {
      if (!_replaceable(m)) continue;
      final c = _controllerOf(m);
      if (c != null) (byText[c] ??= []).add(MatchRange(m.start, m.end));
    }
    var count = 0;
    for (final e in byText.entries) {
      final edits = <({int start, int end, String text})>[];
      for (final r in e.value) {
        final now = _findQuery.replacement(text, e.key.text, r);
        if (now != null) edits.add((start: r.start, end: r.end, text: now));
      }
      e.key.replaceRanges(edits);
      count += edits.length;
    }
    await _runFind();
    if (!mounted) return;
    setState(() => _findNote = trCount(count, '1 replaced', '{n} replaced'));
  }

  void _findStep(int direction) {
    if (_found.isEmpty) return;
    setState(() => _foundAt = (_foundAt + direction) % _found.length);
    if (_foundAt < 0) _foundAt += _found.length;
    _showFoundMatch();
  }

  /// The marks in the texts that are written (the document and the boxes).
  void _applyFoundMarks() {
    List<({int start, int end})> inText(bool Function(_FindMatch) pick, {required int now}) =>
        [for (final m in _found) if (pick(m)) (start: m.start, end: m.end)];
    int nowIn(bool Function(_FindMatch) pick) {
      var k = 0;
      for (var i = 0; i < _found.length; i++) {
        if (!pick(_found[i])) continue;
        if (i == _foundAt) return k;
        k++;
      }
      return -1;
    }

    bool doc(_FindMatch m) => m.place == SearchPlace.document;
    _documentController.showFound(inText(doc, now: 0), nowIn(doc));
    for (final boxes in _textBoxesPerPage.values) {
      for (final box in boxes) {
        bool mine(_FindMatch m) => m.place == SearchPlace.textBox && m.boxId == box.id;
        box.controller.showFound(inText(mine, now: 0), nowIn(mine));
      }
    }
  }

  Future<void> _showFoundMatch() async {
    _applyFoundMarks();
    if (_foundAt < 0 || _foundAt >= _found.length) return;
    final m = _found[_foundAt];
    double? y;
    switch (m.place) {
      case SearchPlace.textBox:
        final box = (_textBoxesPerPage[m.page] ?? const <TextBoxWidgetModel>[]).where((b) => b.id == m.boxId).firstOrNull;
        y = box?.position.dy;
        if (_infinite && box != null) _centerCanvasOn(box.position + Offset(box.size.width / 2, 20));
      case SearchPlace.document:
        _documentController.selection = TextSelection(baseOffset: m.start, extentOffset: m.end);
        final writing = _documentEditor.currentState;
        writing != null ? writing.show(m.start, above: 120) : _readHeading(m.start);
        return;
      case SearchPlace.pdfText:
        _scrollTo(m.page, 0);
        try {
          final data = await _pageWords(m.page, urgent: true);
          if (!mounted || _foundAt < 0 || _found[_foundAt] != m) return;
          if (m.line >= 0 && m.line < data.lines.length) y = data.lines[m.line].yMin * basePageWidth / data.pageWidth;
        } catch (_) {}
      case SearchPlace.handwriting:
        final area = m.area;
        if (area != null) {
          y = area.top;
          if (_infinite) _centerCanvasOn(area.center);
        }
      default:
        break;
    }
    _scrollTo(m.page, y ?? 0);
  }

  void _scrollTo(int page, double y) {
    if (_infinite || !_pageScroll.hasClients) return;
    final target = _pageTop(page) + _rulerExtent + y * _pageScale - 120;
    _pageScroll.jumpTo(target.clamp(0.0, _pageScroll.position.maxScrollExtent));
  }

  /// 0: nothing found in text box [id], 1: something, 2: the match being looked at.
  int _boxFound(String id) {
    if (!_findOpen) return 0;
    var any = false;
    for (var i = 0; i < _found.length; i++) {
      if (_found[i].place == SearchPlace.textBox && _found[i].boxId == id) {
        if (i == _foundAt) return 2;
        any = true;
      }
    }
    return any ? 1 : 0;
  }

  /// The handwriting that was found on a page, marked where it lies.
  Widget _inkFindOverlay(int pageIndex) {
    if (!_findOpen || _found.isEmpty) return const SizedBox.shrink();
    final others = <Rect>[], current = <Rect>[];
    for (var i = 0; i < _found.length; i++) {
      final m = _found[i];
      if (m.page != pageIndex || m.place != SearchPlace.handwriting || m.area == null) continue;
      (i == _foundAt ? current : others).add(m.area!);
    }
    if (others.isEmpty && current.isEmpty) return const SizedBox.shrink();
    return Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _FindPainter(others, current))));
  }

  /// What is found on a page of the PDF, drawn over it.
  Widget _findOverlay(int pageIndex, PdfPageWords page) {
    if (!_findOpen || _found.isEmpty) return const SizedBox.shrink();
    final k = basePageWidth / page.pageWidth;
    final others = <Rect>[], current = <Rect>[];
    for (var i = 0; i < _found.length; i++) {
      final m = _found[i];
      if (m.page != pageIndex || m.place != SearchPlace.pdfText || m.line < 0 || m.line >= page.lines.length) continue;
      final line = page.lines[m.line];
      for (final w in line.words) {
        if (w.endIndex <= m.start || w.startIndex >= m.end) continue;
        final length = w.endIndex - w.startIndex;
        if (length <= 0) continue;
        final from = (math.max(m.start, w.startIndex) - w.startIndex) / length;
        final to = (math.min(m.end, w.endIndex) - w.startIndex) / length;
        final width = w.xMax - w.xMin;
        (i == _foundAt ? current : others).add(Rect.fromLTRB((w.xMin + width * from) * k, w.yMin * k, (w.xMin + width * to) * k, w.yMax * k));
      }
    }
    if (others.isEmpty && current.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(child: CustomPaint(painter: _FindPainter(others, current), size: Size(basePageWidth, basePageWidth * page.pageHeight / page.pageWidth)));
  }

  Widget _toggleChip(String key, String label, String tip, bool on, SearchQuery Function(bool) change) => Tooltip(
        message: tr(tip),
        child: FilterChip(
          key: ValueKey(key),
          label: Text.verbatim(label),
          selected: on,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (v) {
            _findQuery = change(v);
            _runFind();
          },
        ),
      );

  /// The bar at the top of the note: the words, the switches, where the match is, and the arrows between matches.
  Widget _findBar() {
    final q = _findQuery;
    final problem = q.problem;
    final label = q.isEmpty
        ? ''
        : (_findNote ?? (problem != null ? tr('Not a valid expression') : (_found.isEmpty ? tr('No matches') : '${_foundAt + 1} / ${_found.length}')));
    final canReplace = _found.any(_replaceable);
    return Material(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconButton(
              key: const ValueKey('find-toggle-replace'),
              tooltip: tr('Replace'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              iconSize: 18,
              icon: Icon(_replaceOpen ? Icons.expand_more : Icons.chevron_right),
              onPressed: () {
                setState(() => _replaceOpen = !_replaceOpen);
                (_replaceOpen ? _replaceFocus : _findFocus).requestFocus();
              },
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 260,
              child: Focus(
                onKeyEvent: (_, e) {
                  if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                    _closeFind();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const ValueKey('find-field'),
                  controller: _findField,
                  focusNode: _findFocus,
                  autofocus: true,
                  decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: tr('Find in this note'), errorText: problem == null ? null : ' '),
                  onChanged: (_) => _findChanged(),
                  onSubmitted: (_) {
                    _findStep(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
                    _findFocus.requestFocus();
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            _toggleChip('find-case', 'Aa', 'Match the case', q.caseSensitive, (v) => SearchQuery(q.text, regex: q.regex, caseSensitive: v, wholeWord: q.wholeWord)),
            const SizedBox(width: 4),
            _toggleChip('find-word', 'ab', 'Whole words only', q.wholeWord, (v) => SearchQuery(q.text, regex: q.regex, caseSensitive: q.caseSensitive, wholeWord: v)),
            const SizedBox(width: 4),
            _toggleChip('find-regex', '.*', 'Regular expression', q.regex, (v) => SearchQuery(q.text, regex: v, caseSensitive: q.caseSensitive, wholeWord: q.wholeWord)),
            const SizedBox(width: 12),
            Text.verbatim(label, key: const ValueKey('find-count'), style: const TextStyle(fontSize: 12)),
            IconButton(key: const ValueKey('find-prev'), tooltip: tr('Previous match'), icon: const Icon(Icons.keyboard_arrow_up), onPressed: _found.isEmpty ? null : () => _findStep(-1)),
            IconButton(key: const ValueKey('find-next'), tooltip: tr('Next match'), icon: const Icon(Icons.keyboard_arrow_down), onPressed: _found.isEmpty ? null : () => _findStep(1)),
            const Spacer(),
            IconButton(key: const ValueKey('find-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: _closeFind),
          ]),
          if (_replaceOpen)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                const SizedBox(width: 34),
                SizedBox(
                  width: 260,
                  child: Focus(
                    onKeyEvent: (_, e) {
                      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                        _closeFind();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      key: const ValueKey('replace-field'),
                      controller: _replaceField,
                      focusNode: _replaceFocus,
                      decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: tr('Replace with')),
                      onSubmitted: (_) {
                        if (canReplace) _replaceOne();
                        _replaceFocus.requestFocus();
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(key: const ValueKey('replace-one'), onPressed: canReplace ? _replaceOne : null, child: Text(tr('Replace'))),
                TextButton(key: const ValueKey('replace-all'), onPressed: canReplace ? _replaceAll : null, child: Text(tr('Replace all'))),
              ]),
            ),
        ]),
      ),
    );
  }

  /// Shuts the search when another panel is to stand beside the note in its place (call it before the setState that opens the other).
  void _closeFindForPanel() {
    if (_findOpen && _roomForSidePanel) _closeFind();
  }

  /// The search beside the note on a wide screen: the same words, switches and replacing as the bar, and the list of what was found
  /// with the words around each match (a tap goes to it).
  Widget _findPanel() {
    final q = _findQuery;
    final problem = q.problem;
    final scheme = Theme.of(context).colorScheme;
    final label = q.isEmpty
        ? ''
        : (_findNote ?? (problem != null ? tr('Not a valid expression') : (_found.isEmpty ? tr('No matches') : '${_foundAt + 1} / ${_found.length}')));
    final canReplace = _found.any(_replaceable);
    KeyEventResult escape(FocusNode _, KeyEvent e) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
        _closeFind();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    return Material(
      key: const ValueKey('find-panel'),
      color: scheme.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(children: [
            Expanded(child: Text(tr('Find'), style: Theme.of(context).textTheme.titleMedium)),
            IconButton(key: const ValueKey('find-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: _closeFind),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Focus(
            onKeyEvent: escape,
            child: TextField(
              key: const ValueKey('find-field'),
              controller: _findField,
              focusNode: _findFocus,
              autofocus: true,
              decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: tr('Find in this note'), errorText: problem == null ? null : ' '),
              onChanged: (_) => _findChanged(),
              onSubmitted: (_) {
                _findStep(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
                _findFocus.requestFocus();
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(children: [
            _toggleChip('find-case', 'Aa', 'Match the case', q.caseSensitive, (v) => SearchQuery(q.text, regex: q.regex, caseSensitive: v, wholeWord: q.wholeWord)),
            const SizedBox(width: 4),
            _toggleChip('find-word', 'ab', 'Whole words only', q.wholeWord, (v) => SearchQuery(q.text, regex: q.regex, caseSensitive: q.caseSensitive, wholeWord: v)),
            const SizedBox(width: 4),
            _toggleChip('find-regex', '.*', 'Regular expression', q.regex, (v) => SearchQuery(q.text, regex: v, caseSensitive: q.caseSensitive, wholeWord: q.wholeWord)),
            const Spacer(),
            Flexible(child: Text.verbatim(label, key: const ValueKey('find-count'), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
            IconButton(key: const ValueKey('find-prev'), tooltip: tr('Previous match'), icon: const Icon(Icons.keyboard_arrow_up), onPressed: _found.isEmpty ? null : () => _findStep(-1)),
            IconButton(key: const ValueKey('find-next'), tooltip: tr('Next match'), icon: const Icon(Icons.keyboard_arrow_down), onPressed: _found.isEmpty ? null : () => _findStep(1)),
          ]),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('find-toggle-replace'),
            icon: Icon(_replaceOpen ? Icons.expand_more : Icons.chevron_right, size: 18),
            label: Text(tr('Replace')),
            onPressed: () {
              setState(() => _replaceOpen = !_replaceOpen);
              (_replaceOpen ? _replaceFocus : _findFocus).requestFocus();
            },
          ),
        ),
        if (_replaceOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Focus(
                onKeyEvent: escape,
                child: TextField(
                  key: const ValueKey('replace-field'),
                  controller: _replaceField,
                  focusNode: _replaceFocus,
                  decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: tr('Replace with')),
                  onSubmitted: (_) {
                    if (canReplace) _replaceOne();
                    _replaceFocus.requestFocus();
                  },
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(key: const ValueKey('replace-one'), onPressed: canReplace ? _replaceOne : null, child: Text(tr('Replace'))),
                TextButton(key: const ValueKey('replace-all'), onPressed: canReplace ? _replaceAll : null, child: Text(tr('Replace all'))),
              ]),
            ]),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('find-results'),
            itemCount: _found.length,
            itemBuilder: (context, i) {
              final m = _found[i];
              final now = i == _foundAt;
              return InkWell(
                key: ValueKey('find-result-$i'),
                onTap: () {
                  setState(() => _foundAt = i);
                  _showFoundMatch();
                },
                child: Container(
                  color: now ? scheme.secondaryContainer : null,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 30, child: Text.verbatim('${m.page + 1}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: m.before),
                          TextSpan(text: m.word, style: TextStyle(fontWeight: FontWeight.w700, backgroundColor: scheme.tertiaryContainer)),
                          TextSpan(text: m.after),
                        ]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
