part of 'fixed_page_note_editor.dart';

/// The written document and files: pictures put into it, a Word document read into it, and the document exported as a paged PDF,
/// a Word document, a web page, Markdown or plain text.
extension _EditorDocumentFiles on _FixedPageNoteEditorState {
  /// Asks for a picture and puts it into the document at the caret.
  Future<void> _insertDocumentPicture() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.image);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final isJpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
      final isGif = bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49;
      final target = await DocumentImages.keep(widget.noteId, bytes, isJpeg ? 'jpeg' : (isGif ? 'gif' : 'png'));
      if (!mounted) return;
      final alt = file.name.replaceAll(RegExp(r'\.[^.]*$'), '').replaceAll(RegExp(r'[\[\]|]'), '');
      _documentController.value = insertText(_documentController.value, '![$alt]($target)');
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not add the picture: {error}', {'error': e}))));
      }
    }
  }

  /// A picture the keyboard put in (a sticker, a GIF): it is kept with the note and written into the document at the caret.
  Future<void> _insertKeyboardPicture(KeyboardInsertedContent content) async {
    try {
      final data = content.data;
      if (data == null || data.isEmpty) throw tr('the keyboard sent no picture');
      final picture = await DocumentImages.forKeeping(data);
      final target = await DocumentImages.keep(widget.noteId, picture.bytes, picture.ext);
      if (!mounted) return;
      _documentController.value = insertText(_documentController.value, '![${tr('Picture')}]($target)');
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not add the picture: {error}', {'error': e}))));
      }
    }
  }

  /// Asks for a file (Word, web page, Markdown, plain text or PDF) and reads it into the written document (in place of an empty one,
  /// else after it).
  Future<void> _importWordDocument() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: documentImportExtensions);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final read = await importDocumentFile(file.name, bytes, keepPicture: (b, ext) => DocumentImages.keep(widget.noteId, b, ext));
      if (!mounted) return;
      _readIntoDocument(read);
    } on FormatException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr(e.message))));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not read the file: {error}', {'error': e}))));
      }
    }
  }

  /// Puts what was read from a Word document into the written document.
  void _readIntoDocument(DocxImport read) {
    final c = _documentController;
    final empty = c.text.trim().isEmpty;
    final at = empty ? 0 : c.text.length + 2;
    final text = empty ? read.text : '${c.text}\n\n${read.text}';
    final spans = [if (!empty) ...c.attributes.map((a) => a.copy()), for (final s in read.spans) s.moved(s.start + at, s.end + at)];
    c.text = text;
    c.attributes
      ..clear()
      ..addAll(spans);
    c.selection = TextSelection.collapsed(offset: text.length);
    setState(() => _mode = CanvasInteractionMode.document);
  }

  /// How the pages of the document are, for an export.
  DocumentPages get _documentPages => DocumentPages(
        format: _pageFormat.isInfinite ? PageFormat.a4 : _pageFormat,
        landscape: _landscape,
        marginLeft: _marginLeft,
        marginRight: _marginRight,
        marginTop: _marginTop,
        marginBottom: _marginBottom,
        title: _titleController.text.trim(),
        date: DateTime.now(),
      );

  /// The bytes of the pictures in the document, by where they are.
  Future<Map<String, Uint8List>> _documentPictures() async {
    final out = <String, Uint8List>{};
    for (final b in parseMarkdown(_documentController.text)) {
      for (final r in b.runs) {
        final target = r.image;
        if (target == null || out.containsKey(target)) continue;
        final bytes = await DocumentImages.read(target);
        if (bytes != null) out[target] = bytes;
      }
    }
    return out;
  }

  /// Shows the pages of the document as they will be printed, to print or save them.
  Future<void> _printPreview() async {
    try {
      _setLoadingPdf(true);
      final text = _documentController.text;
      final pictures = await _documentPictures();
      if (!mounted) return;
      final math = await renderMathImages(context, mathIn([text]), fontSize: DocumentSheet.fontSize);
      final bytes = await documentPdf(_documentController, _documentPages,
          fontSize: DocumentSheet.fontSize, math: math, citations: _citationsFor(text), pictures: pictures);
      if (!mounted) return;
      _setLoadingPdf(false);
      await PrintPreview.show(context, pdf: bytes, title: _titleController.text.trim(), onSave: () => unawaited(_saveDocumentFile(bytes, 'pdf')));
    } catch (e) {
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not export the document: {error}', {'error': e}))));
      }
    }
  }

  /// Exports the written document as [kind]: `pdf` (cut into pages), `docx`, `html`, `md` or `txt`.
  Future<void> _exportDocument(String kind) async {
    if (kind == 'preview') return _printPreview();
    try {
      _setLoadingPdf(true);
      final text = _documentController.text;
      final pages = _documentPages;
      final cites = _citationsFor(text);
      final pictures = kind == 'md' || kind == 'txt' ? const <String, Uint8List>{} : await _documentPictures();
      if (!mounted) return;
      final Uint8List bytes;
      var extension = kind;
      switch (kind) {
        case 'pdf':
          final math = await renderMathImages(context, mathIn([text]), fontSize: DocumentSheet.fontSize);
          bytes = await documentPdf(_documentController, pages, fontSize: DocumentSheet.fontSize, math: math, citations: cites, pictures: pictures);
        case 'docx':
          bytes = documentDocx(text, _documentController.attributes, pages, citations: cites, pictures: pictures);
        case 'html':
          bytes = utf8.encode(documentHtml(text, _documentController.attributes, title: pages.title, citations: cites, pictures: pictures));
        case 'md':
          bytes = utf8.encode(documentMarkdown(text));
        case 'tex':
          // (a ZIP of the file and its pictures when there are any)
          final packed = documentLatex(text, _documentController.attributes, title: pages.title, citations: cites, pictures: pictures)
              .pack(_safeFileName(_titleController.text));
          bytes = packed.bytes;
          extension = packed.extension;
        default:
          bytes = utf8.encode(documentPlainText(text, citations: cites));
      }
      if (mounted) _setLoadingPdf(false);
      await _saveDocumentFile(bytes, extension);
    } catch (e) {
      _exportError = '$e';
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not export the document: {error}', {'error': e}))));
      }
    }
  }

  Future<void> _saveDocumentFile(Uint8List bytes, String ext) async {
    final target = _exportTo;
    if (target != null) {
      await File(target).writeAsBytes(bytes);
      return;
    }
    final savePath = await saveWithDialog(
      dialogTitle: tr('Export the document'),
      fileName: '${_safeFileName(_titleController.text)}.$ext',
      extension: ext,
      bytes: bytes,
    );
    if (savePath == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Successfully exported to {path}', {'path': savePath}))));
    }
  }

  /// [title] as the name of a file (what a file name cannot hold is made an underscore).
  String _safeFileName(String title) => (title.trim().isEmpty ? 'Document' : title.trim()).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// The menu of the ways the written document can be exported.
  Widget _documentExportMenu() => PopupMenuButton<String>(
        key: const ValueKey('export-document'),
        tooltip: tr('Export the document'),
        enabled: !_isLoadingPdf,
        icon: const Icon(Icons.description_outlined, size: 20),
        onSelected: (kind) => unawaited(_exportDocument(kind)),
        itemBuilder: (_) => [
          PopupMenuItem(key: const ValueKey('export-document-preview'), value: 'preview', child: Text('Print preview...')),
          const PopupMenuDivider(),
          for (final (kind, label) in const [
            ('pdf', 'PDF, cut into pages'),
            ('docx', 'Word document (.docx)'),
            ('html', 'Web page (.html)'),
            ('md', 'Markdown (.md)'),
            ('tex', 'LaTeX (.tex)'),
            ('txt', 'Plain text (.txt)'),
          ])
            PopupMenuItem(key: ValueKey('export-document-$kind'), value: kind, child: Text(label)),
        ],
      );
}
