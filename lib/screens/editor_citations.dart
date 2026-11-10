part of 'fixed_page_note_editor.dart';

/// The citation style of this note and citing the PDF it is made from.
extension _EditorCitations on _FixedPageNoteEditorState {
  /// All the text of the note: the written document, then the text boxes page by page. Its citations are numbered and listed as one.
  String _noteCitationText() => [
        _documentController.text,
        for (final page in _textBoxesPerPage.keys.toList()..sort())
          for (final box in _textBoxesPerPage[page]!) box.controller.text,
      ].join('\n');

  /// What the citations of [text] (a text of this note) read as in this note's style (null: none, or citations are off).
  CitationDocument? _citationsFor(String text) {
    final whole = _noteCitationText();
    return CitationScope.maybeOf(context)?.documentFor(whole.contains(text) ? whole : text, style: _citationStyle);
  }

  /// Changes (or takes out) the citation [run] of the text in [controller]: the sheet of sources opens with what it cites now.
  Future<void> _editCitation(TextEditingController controller, MdRun run) async {
    final service = CitationScope.maybeOf(context);
    if (service == null || run.cite == null) return;
    final citation = await showCitePicker(context, service, editing: run.cite);
    if (citation == null || !mounted) return;
    final end = run.src + run.text.length;
    // (the text may have been changed while the sheet was open)
    if (end > controller.text.length || controller.text.substring(run.src, end) != run.text) return;
    controller.value = replaceCitation(controller.value, CitationMark(run.src, end, run.cite!), citation);
    setState(() {});
  }

  /// Puts the list of the sources the note cites into the note: at the cursor in the text being edited (the written document, or the
  /// text box that is selected), else as a text box of its own on the page on screen.
  void _insertBibliography() {
    final inText = _mode == CanvasInteractionMode.document ? _documentController : _activeSelectedBox?.controller;
    if (inText != null) {
      inText.value = withBibliography(inText.value);
      setState(() {}); // (the preview shows it)
    } else {
      _citationBox('[bibliography]', width: 340);
    }
  }

  /// The button that puts the list of sources into the note; nothing when citations are off.
  Widget? _bibliographyButton() {
    if (CitationScope.maybeOf(context) == null || !_on(Feature.citations)) return null;
    return IconButton(
      key: const ValueKey('insert-bibliography'),
      tooltip: tr('Insert the list of sources'),
      icon: const Icon(Icons.menu_book_outlined, size: 20),
      onPressed: _insertBibliography,
    );
  }

  /// A text box with [text] on the page on screen (for the citations of a note that is written by hand).
  void _citationBox(String text, {double width = 220}) {
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text, width: width);
  }

  /// Reads which style the note is cited in (its own, its folder's), and again when the library or a choice changes.
  Future<void> _readCitationStyle() async {
    final service = CitationScope.maybeOf(context);
    if (service == null) return;
    final own = service.ownStyleOfNote(widget.noteId);
    final style = own ?? await service.styleOfNote(widget.noteId);
    if (mounted && (style?.id != _citationStyle?.id || own?.id != _ownCitationStyle?.id)) {
      setState(() {
        _citationStyle = style;
        _ownCitationStyle = own;
      });
    }
  }

  /// The button of the note's citation style, and of citing the PDF; nothing when citations are off.
  Widget? _citationsButton() {
    final service = CitationScope.maybeOf(context);
    if (service == null || !_on(Feature.citations)) return null;
    return PopupMenuButton<String>(
      key: const ValueKey('note-citations'),
      tooltip: tr('Citations of this note'),
      icon: const Icon(Icons.format_quote, size: 20),
      onSelected: (v) async {
        if (v == 'pdf') return _citePdf();
        if (v == 'cite-here') {
          final citation = await showCitePicker(context, service);
          if (citation != null && mounted) _citationBox(citation);
          return;
        }
        if (v == 'library') {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => CitationLibraryScreen(service: service)));
          return;
        }
        await service.setNoteStyle(widget.noteId, v == 'style:' ? null : citationStyleById(v.substring(6)));
        await _readCitationStyle();
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'style:',
          checked: _ownCitationStyle == null,
          child: Text.verbatim(tr('The style of the folder or of every note ({name})', {'name': (_citationStyle ?? service.style).name})),
        ),
        for (final s in citationStyles) CheckedPopupMenuItem(value: 'style:${s.id}', checked: _ownCitationStyle?.id == s.id, child: Text.verbatim(s.name)),
        const PopupMenuDivider(),
        // (in the written document a citation is typed or put in with the button above the keyboard, and the list comes by itself)
        if (_mode != CanvasInteractionMode.document) ...[
          PopupMenuItem(value: 'cite-here', child: Text('Cite a source on the page...')),
        ],
        if (_importedPdfName != null) PopupMenuItem(value: 'pdf', child: Text('Cite this PDF')),
        PopupMenuItem(value: 'library', child: Text('Open the library of sources')),
      ],
    );
  }

  /// Adds the PDF of this note to the library of sources: its DOI is looked for on the first pages and the details fetched;
  /// without one the form opens with the name of the file.
  Future<void> _citePdf() async {
    final service = CitationScope.maybeOf(context);
    if (service == null) return;
    final doi = CitationLookup.doiIn(await widget.repository.text.pdfStartText(widget.noteId));
    CitationSource? found;
    if (doi != null) {
      try {
        found = await CitationLookup().fromDoi(doi);
      } catch (_) {} // offline: the form opens without it
    }
    if (!mounted) return;
    final name = (_importedPdfName ?? '').replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '').replaceAll(RegExp(r'[_]+'), ' ');
    final made = await addSourceByHand(context, service, initial: found ?? CitationSource(id: '', title: name, doi: doi ?? ''));
    if (made == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: '[@${made.id}]'));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Added. [@{key}] is copied, paste it where you quote the PDF.', {'key': made.id}))));
  }
}
