part of 'fixed_page_note_editor.dart';

/// Translating the text of a note into another language, in place.
extension _EditorTranslate on _FixedPageNoteEditorState {
  Widget _translateButton() => IconButton(
        key: const ValueKey('translate-note'),
        tooltip: tr('Translate this note'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.translate, size: 20),
        onPressed: _translateNote,
      );

  Future<void> _translateNote() async {
    final ai = widget.ai;
    if (ai == null) return;
    await ready;
    if (!mounted) return;
    final boxes = [
      for (final e in _textBoxesPerPage.entries)
        for (final b in e.value)
          if (worthTranslating(b.controller.text)) b,
    ];
    final withDocument = _hasDocument && worthTranslating(_documentController.text);
    final withPdf = _pdfEditable && _pdfFilePath != null && _totalPages > 0;
    final code = await askTranslationLanguage(
      context,
      pieces: boxes.length + (withDocument ? 1 : 0),
      pdf: withPdf,
      ready: ai.provider?.state == ProviderState.ready,
    );
    if (code == null || !mounted) return;
    final language = translationTargets[code]!;

    final cancel = AiCancel();
    final progress = ValueNotifier<(int, int)>((0, boxes.length + (withDocument ? 1 : 0)));
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(context: context, barrierDismissible: false, builder: (_) => TranslateProgress(progress: progress, cancel: cancel)));

    final translator = NoteTranslator((prompt, {cancel}) => ai.generate(prompt, cancel: cancel, maxTokens: (prompt.user.length ~/ 2).clamp(200, 2400)));
    final results = <TextBoxWidgetModel, String>{};
    String? document;
    Object? failure;
    PdfContentEditor? pdfEditor;
    final pdfLines = <int, List<PdfEditObject>>{};
    final pdfTexts = <int, List<String>>{};
    try {
      for (final b in boxes) {
        if (cancel.cancelled) break;
        results[b] = await translator.translate(b.controller.text, language, cancel: cancel);
        progress.value = (progress.value.$1 + 1, progress.value.$2);
      }
      if (withDocument && !cancel.cancelled) {
        document = await translator.translate(_documentController.text, language, cancel: cancel);
        progress.value = (progress.value.$1 + 1, progress.value.$2);
      }
      if (withPdf && !cancel.cancelled) {
        // the lines of each page, as the PDF draws them, then their translation a page at a time
        pdfEditor = await PdfContentEditor.open(await File(_pdfFilePath!).readAsBytes(), fallbackFonts: await _standInFontsOrNone());
        for (var page = 0; page < _totalPages && !cancel.cancelled; page++) {
          final lines = [for (final o in await pdfEditor.objects(page)) if (o.kind == PdfObjectKind.text && worthTranslating(o.text ?? '')) o];
          if (lines.isEmpty) continue;
          pdfLines[page] = lines;
          progress.value = (progress.value.$1, progress.value.$2 + lines.length);
        }
        for (final page in pdfLines.keys) {
          if (cancel.cancelled) break;
          final before = progress.value.$1;
          pdfTexts[page] = await translator.translateLines(
            [for (final l in pdfLines[page]!) l.text!],
            language,
            cancel: cancel,
            onBatch: (n) => progress.value = (before + n, progress.value.$2),
          );
          progress.value = (before + pdfLines[page]!.length, progress.value.$2);
        }
      }
    } catch (e) {
      failure = e;
    }
    navigator.pop(); // the progress
    progress.dispose();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (failure != null) {
      unawaited(pdfEditor?.close().catchError((Object _) {}));
      messenger.showSnackBar(SnackBar(content: Text.verbatim('$failure'.replaceFirst('Bad state: ', ''))));
      return;
    }
    if (cancel.cancelled) {
      unawaited(pdfEditor?.close().catchError((Object _) {}));
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Stopped. Nothing in the note was changed.'))));
      return;
    }

    // a version to go back to, then the change itself as one step that can be taken back
    await _saveNow();
    await widget.history?.snapshot(widget.noteId, manual: true, label: tr('Before translating into {language}', {'language': language}));
    if (!mounted) return;
    final oldBox = {for (final b in results.keys) b: (text: b.controller.text, spans: List.of(b.controller.attributes))};
    final oldDocument = (text: _documentController.text, spans: List.of(_documentController.attributes));
    void set(RichInlineTextController c, String text, List<TextSpanAttribute> spans) {
      c.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 0));
      c.attributes
        ..clear()
        ..addAll(spans);
    }

    void apply(bool forward) {
      for (final e in results.entries) {
        forward ? set(e.key.controller, e.value, const []) : set(e.key.controller, oldBox[e.key]!.text, oldBox[e.key]!.spans);
      }
      if (document != null) forward ? set(_documentController, document, const []) : set(_documentController, oldDocument.text, oldDocument.spans);
      setState(() {});
    }

    // the PDF: its lines are set again in the translation and the result is the note's PDF from now on
    final oldPdf = (path: _pdfFilePath, sha: _pdfSha256 ?? '');
    ({String path, String sha})? newPdf;
    var unshown = 0;
    if (pdfEditor != null && pdfTexts.isNotEmpty) {
      try {
        unshown = await _rewritePdfLines(pdfEditor, pdfLines, pdfTexts);
        final bytes = await pdfEditor.save();
        final path = p.join(p.dirname(oldPdf.path!), '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}.pdf');
        await File(path).writeAsBytes(bytes);
        newPdf = (path: path, sha: await sha256Of(bytes));
      } catch (e) {
        failure = e;
      }
    }
    unawaited(pdfEditor?.close().catchError((Object _) {}));
    if (!mounted) return;
    if (failure != null) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim('$failure'.replaceFirst('Bad state: ', ''))));
      return;
    }
    if (newPdf != null) await _swapPdf(newPdf.path, newPdf.sha);
    if (!mounted) return;

    apply(true);
    _undoStack.push(UndoStep(() {
      apply(false);
      if (newPdf != null) unawaited(_swapPdf(oldPdf.path!, oldPdf.sha));
    }, () {
      apply(true);
      if (newPdf != null) unawaited(_swapPdf(newPdf.path, newPdf.sha));
    }));
    final left = translator.kept + unshown;
    messenger.showSnackBar(SnackBar(
      content: Text.verbatim(left == 0
          ? tr('Translated into {language}.', {'language': language})
          : tr('Translated into {language}; {n} passages could not be translated and were left as they were.', {'language': language, 'n': left})),
    ));
  }

  /// Sets the lines of the PDF again in [texts] (page -> a translation for each of [lines]); the number of lines that could not be
  /// shown (a character no font has) and stayed as they were.
  Future<int> _rewritePdfLines(PdfContentEditor editor, Map<int, List<PdfEditObject>> lines, Map<int, List<String>> texts) async {
    var unshown = 0;
    for (final page in texts.keys) {
      final originals = lines[page]!;
      var now = originals;
      for (var i = 0; i < originals.length; i++) {
        final text = texts[page]![i];
        final was = originals[i];
        if (text.trim() == was.text!.trim()) continue;
        // (editing shifts the numbers of the page's objects: the line is found again by its text and place)
        final line = now.firstWhere((o) => o.text == was.text && (o.rect.center - was.rect.center).distance < 1.5, orElse: () => was);
        try {
          final info = await editor.fontInfo(page, line);
          final base = fitStandIn(line, info);
          final longer = fitStandIn(line.copyWith(text: text), info, minFactor: 0.6);
          await editor.setText(page, line, text, family: base.family == 'system' ? null : base.family, sizeFactor: math.min(base.factor, longer.factor), uniform: true);
        } on PdfEditException {
          unshown++;
          continue;
        }
        now = [for (final o in await editor.objects(page)) if (o.kind == PdfObjectKind.text) o];
      }
    }
    return unshown;
  }

  /// The stand-in fonts, or none where the app was started before they were added to it (a line is then kept in the PDF's own font
  /// where that can show the translation, and left as it was where not).
  Future<Map<String, Uint8List>> _standInFontsOrNone() async {
    try {
      return await loadStandInFonts();
    } catch (e) {
      debugPrint('loading the stand-in fonts failed: $e');
      return const {};
    }
  }

  /// Shows the PDF at [path] as the note's PDF.
  Future<void> _swapPdf(String path, String sha) async {
    try {
      final doc = await openPdfFile(path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _closePdfEditor();
      _showPdf(path, sha, doc);
      _scheduleSave();
      if (_mode == CanvasInteractionMode.document) unawaited(_openPdfEditor());
    } catch (e) {
      _pdfEditMessage(e);
    }
  }
}
