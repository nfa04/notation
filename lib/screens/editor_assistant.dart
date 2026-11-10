part of 'fixed_page_note_editor.dart';

/// The assistant for the whole document.
extension _EditorAssistant on _FixedPageNoteEditorState {
  /// Everything written in the note, in chunks: the PDF's text, the written
  /// document, the text boxes. Read again for every question.
  Future<DocumentIndex> _documentIndex() async {
    await ready;
    final chunks = <DocChunk>[];
    if (_titleController.text.trim().isNotEmpty) chunks.add(DocChunk('Title', null, _titleController.text.trim()));

    await _readPdfPageTexts();
    for (var i = 0; i < _pageCount; i++) {
      final label = tr('Page {n}', {'n': i + 1});
      final pdf = _pdfPageTexts != null && i < _pdfPageTexts!.length ? _pdfPageTexts![i] : '';
      chunks.addAll(chunkText(label, i, pdf));
      if (_isDocumentPage(i)) chunks.addAll(chunkText(label, i, withoutParagraphFormats(_documentController.text)));
      for (final box in _textBoxesPerPage[i] ?? const <TextBoxWidgetModel>[]) {
        final t = box.controller.text.trim();
        if (t.isNotEmpty) chunks.addAll(chunkText(label, i, t));
      }
    }
    return DocumentIndex(chunks);
  }

  /// The text of each page of the PDF, line by line (read once); null for a note without a PDF.
  Future<List<String>?> _readPdfPageTexts() async {
    await ready;
    final doc = _pdfDocument;
    if (doc != null && _pdfPageTexts == null) {
      final texts = <String>[];
      for (var i = 0; i < doc.pages.length && mounted && identical(doc, _pdfDocument); i++) {
        try {
          final text = await doc.pages[i].loadStructuredText();
          final lines = linesOf(text.fragments.map((f) => PdfFragment(f.text, [for (final r in f.charRects) r.toRect(page: doc.pages[i])])));
          texts.add(lines.map((l) => l.text).join('\n'));
        } catch (e) {
          debugPrint('reading the text of page $i failed: $e');
          texts.add('');
        }
      }
      if (identical(doc, _pdfDocument)) _pdfPageTexts = texts;
    }
    return _pdfPageTexts;
  }

  /// The conversation about this note; the flashcards made in it are kept with the note.
  AssistantChat _newAssistant() {
    final id = widget.noteId;
    final repo = widget.repository;
    final chat = AssistantChat(
      ai: widget.ai!,
      index: _documentIndex,
      loadCards: () async => (await repo.ai.get(id, 'flashcards'))?.content,
      saveCards: (json) => repo.ai.put(NoteAiRow(noteId: id, kind: 'flashcards', content: json, createdAt: DateTime.now())),
      dropCards: () => repo.ai.delete(id, 'flashcards'),
      agent: NoteAgent(api: _EditorAgentApi(this), selected: () => _currentSelectedText, copies: () => [for (final c in _agentTexts()) scratchCopy(c)],
        beforeChange: (what) => _keepVersion(VersionReason.assistantBefore, what),
        afterChange: (what) => _keepVersion(VersionReason.assistant, what),
      ),
      // (the choice between answering and acting is kept: it is easy to be in the one you did not mean in a note you just opened)
      acting: _agentMode,
      onActingChanged: (on) {
        _agentMode = on;
        repo.settings.set(_agentModeSetting, on ? '1' : '0');
      },
    )..restoreCards();
    return chat;
  }

  static const _agentModeSetting = 'assistant_agent_mode';

  /// Keeps the note as it is now as a version, with [what] the assistant does or did. A version that cannot be made does not hold up
  /// the assistant (the note may be one that keeps no versions, as an encrypted one).
  Future<void> _keepVersion(VersionReason reason, String what) async {
    final history = widget.history;
    if (history == null) return;
    try {
      await _saveNow();
      await history.snapshot(widget.noteId, reason: reason, label: what);
    } catch (e) {
      debugPrint('could not keep a version for the assistant: $e');
    }
  }

  /// The text of the note that the assistant can change: the written document and the text boxes on layers that can be changed (not
  /// the comments beside the page, nor the text of a PDF).
  List<RichInlineTextController> _agentTexts() => [for (final part in _agentParts()) part.text];

  /// The same, each with what to call it.
  List<({String label, RichInlineTextController text})> _agentParts() => [
        (label: tr('The written document'), text: _documentController),
        for (final page in _textBoxesPerPage.keys.toList()..sort())
          for (final box in _textBoxesPerPage[page]!)
            if (!_inGutter(box) && _layers.byId(box.layer).editable) (label: tr('Text box on page {n} (size {size})', {'n': page + 1, 'size': box.fontSize.round()}), text: box.controller),
      ];

  /// Does what the assistant does to the note as one step, to be taken back with the undo button of the note.
  T _agentEdit<T>(T Function() change) {
    if (!mounted) throw ExtensionError('The note was closed.');
    if (_documentController.readingView) throw ExtensionError('The note is shown for reading: it cannot be changed now.');
    _flushMeta();
    final result = change();
    setState(() {});
    _recordMeta();
    _scheduleSave();
    return result;
  }

  /// Text from the assistant: at the end of the written document, or where there is none and the page has other things on it, in a
  /// text box on the page in view.
  void _agentInsert(String text) => _agentEdit(() {
        final inDocument = _isBlank && !_infinite && (_hasDocument || _mode == CanvasInteractionMode.document || !_blankPageHasContent(0));
        if (inDocument) {
          final now = _documentController.text;
          final gap = now.trim().isEmpty ? '' : (now.endsWith('\n\n') ? '' : (now.endsWith('\n') ? '\n' : '\n\n'));
          final all = '$now$gap$text';
          _documentController.value = TextEditingValue(text: all, selection: TextSelection.collapsed(offset: all.length));
          return;
        }
        if (!_drawingLayer.editable) throw ExtensionError('The layer in use is hidden or locked: nothing can be added to it.');
        final (page, scrolled) = _visiblePage();
        _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text);
      });

  /// Records speech and puts what was said on the page in view as a text box.
  Future<void> _dictate() async {
    final speech = widget.speech;
    if (speech == null) return;
    final recording = await showSpeechRecording(context, speech: speech, title: tr('Dictate'), offerKeep: widget.audio != null, keepByDefault: false);
    final text = recording?.text;
    if (text == null || text.trim().isEmpty || !mounted) return;
    if (recording!.audio != null) {
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      await widget.audio?.add(widget.noteId, recording.audio!, title: tr('Dictation {date}', {'date': '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}'}), duration: recording.length);
    }
    // writing a document with a cursor in it: what was said goes in at the cursor
    final cursor = _documentController.selection;
    if (_mode == CanvasInteractionMode.document && cursor.isValid) {
      _documentController.value = insertSpoken(_documentController.value, text.trim());
      return;
    }
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text.trim());
  }

  /// Reads the selected text, or else the whole note (its title, written document, text boxes and the text of its PDF), aloud;
  /// pressed again while reading, it stops.
  Future<void> _readAloud() async {
    final reader = widget.readAloud;
    if (reader == null) return;
    if (reader.speaking) {
      await reader.stop();
      return;
    }
    final selected = _currentSelectedText?.trim() ?? '';
    String text;
    if (selected.isNotEmpty) {
      text = selected;
    } else {
      final index = await _documentIndex();
      text = index.chunks.map((c) => c.text).join('\n');
    }
    text = speakableText(text); // (no footnote marks, citations, links or formulas)
    if (text.trim().isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('There is nothing to read yet.'))));
      return;
    }
    try {
      if (!await reader.available) throw StateError(tr('This device has no speech program (install speech-dispatcher or espeak-ng).'));
      await reader.speak(text, language: AppLanguage.instance.code);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim('$e'.replaceFirst('Bad state: ', ''))));
    }
  }

  /// The list of what the AI can make of this note (summary, presentation, quiz...), kept with the note; with [kind], that one is
  /// shown (or made, when it has not been) at once.
  Future<void> _openNoteAi([NoteAiKind? kind]) async {
    final ai = widget.ai;
    if (ai == null) return;
    await showNoteAiSheet(
      context,
      noteAi: NoteAi(widget.repository, ai),
      noteId: widget.noteId,
      initial: kind,
      title: _titleController.text,
      // the note as it is now is in the database, with the text of its PDF
      prepare: () async {
        await _saveNow();
        final texts = await _readPdfPageTexts();
        if (texts != null && texts.isNotEmpty) await widget.repository.text.savePdfText(widget.noteId, texts);
      },
      onAddText: _addGenerated,
      onAddTask: widget.onAddTask,
    );
    _generatedTick.value++; // (something may have been made, or made again)
  }

  /// What the AI made of the note, beside it on a wide screen, else as a page over it.
  void _toggleGenerated() {
    final ai = widget.ai;
    if (ai == null) return;
    if (_roomForSidePanel) {
      _toggleSidePanel(_generatedOpen, () => _generatedOpen = true);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => Scaffold(
        body: SafeArea(
          child: _generatedPanel(
            onClose: () => Navigator.pop(context),
            onAdd: (text, target, {title}) {
              Navigator.pop(context);
              _addGenerated(text, target, title: title);
            },
          ),
        ),
      ),
    ));
  }

  Widget _generatedPanel({VoidCallback? onClose, AddToNote? onAdd}) => GeneratedPanel(
        store: widget.repository.ai,
        noteAi: widget.ai == null ? null : NoteAi(widget.repository, widget.ai!),
        noteId: widget.noteId,
        changed: _generatedTick,
        onAdd: onAdd ?? _addGenerated,
        onOpen: (kind) => _openNoteAi(kind),
        onClose: onClose,
      );

  void _toggleAssistant() {
    final chat = _assistant;
    if (chat == null) return;
    if (_roomForSidePanel) {
      _toggleSidePanel(_assistantOpen, () => _assistantOpen = true);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => Scaffold(
        body: SafeArea(
          child: AssistantPanel(
            ai: widget.ai!,
            chat: chat,
            onClose: () => Navigator.pop(context),
            onJumpToPage: (p) {
              Navigator.pop(context);
              _jumpToPage(p);
            },
            onAddToNote: (text, target, {title}) {
              Navigator.pop(context);
              _addGenerated(text, target, title: title);
            },
            flashcards: _on(Feature.flashcards),
            onKeepCards: widget.cards == null ? null : (cards) => widget.cards!.addAll(widget.noteId, cards),
              onMake: (kind) => _openNoteAi(kind),
          ),
        ),
      ),
    ));
  }

  /// Text the AI made, put in the note where the person chose: a text box, the end of the written document, or after a page break so
  /// that it has a page of its own. A note without a written document (a PDF, a canvas) takes it as a text box.
  void _addGenerated(String text, AddTarget target, {String? title}) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (target == AddTarget.keep) {
      unawaited(_keepWithNote(clean, title));
      return;
    }
    if (target == AddTarget.textBox || !_isBlank || _infinite) return _addAnswerToNote(clean);
    if (_documentController.readingView) {
      _showAdded(tr('The note is shown for reading: it cannot be changed now.'));
      return;
    }
    _flushMeta();
    final now = _documentController.text;
    final gap = now.trim().isEmpty ? '' : (now.endsWith('\n\n') ? '' : (now.endsWith('\n') ? '\n' : '\n\n'));
    final pageBreak = target == AddTarget.page && now.trim().isNotEmpty ? '\\pagebreak\n\n' : '';
    final heading = title == null || title.trim().isEmpty ? '' : '## ${title.trim()}\n\n';
    final all = '${now.trim().isEmpty ? '' : now}$gap$pageBreak$heading$clean\n';
    setState(() {
      _documentController.value = TextEditingValue(text: all, selection: TextSelection.collapsed(offset: all.length));
    });
    _recordMeta();
    _scheduleSave();
    _showAdded(target == AddTarget.page && pageBreak.isNotEmpty ? tr('Added on a page of its own') : tr('Added to the written document'));
  }

  /// Keeps [text] with the note and apart from it: not on a page and not in the written document, but in the store of what the AI made,
  /// which goes with the note (also in its file) and shows in the "Made by the AI" panel.
  Future<void> _keepWithNote(String text, String? title) async {
    final kept = title == null || title.trim().isEmpty ? text : '${title.trim()}\n\n$text';
    await widget.repository.ai.put(NoteAiRow(noteId: widget.noteId, kind: keptKind, key: DateTime.now().microsecondsSinceEpoch.toString(), content: kept, createdAt: DateTime.now()));
    _generatedTick.value++;
    if (!mounted) return;
    final wide = MediaQuery.of(context).size.width >= _sidePanelFrom;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text.verbatim(tr('Kept with the note')),
        action: wide && !_generatedOpen ? SnackBarAction(label: tr('Show'), onPressed: _toggleGenerated) : null,
      ));
  }

  void _showAdded(String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text.verbatim(message)));

  /// An answer of the assistant, as a text box near the top of the page on screen.
  void _addAnswerToNote(String text) {
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(_infinite ? tr('Added to the canvas') : tr('Added to page {n}', {'n': page + 1}))));
  }
}

/// What the assistant can do with the note that is open. It is the API of the extensions, for the whole note instead of a selection.
class _EditorAgentApi extends ExtensionApi with LibraryApi, NotesReadApi, _EditorWideApi {
  @override
  final _FixedPageNoteEditorState _editor;

  _EditorAgentApi(this._editor);

  @override
  Future<Map<String, Object?>> note() async {
    await _editor._saveNow();
    final id = _editor.widget.noteId;
    return {'id': id, 'title': _editor._titleController.text, 'text': await _editor.widget.repository.text.noteText(id, limit: 20000)};
  }

  @override
  Future<void> insertText(String text) async => _editor._agentInsert(text);

  @override
  Future<int> replaceText(String find, String replacement, {bool all = false}) async =>
      _editor._agentEdit(() => replaceNoteText(_editor._agentTexts(), find, replacement, all: all));

  @override
  Future<String> formatText(Map<String, Object?> options) async {
    final format = NoteFormat.fromJson(options);
    return _editor._agentEdit(() => formatNoteText(_editor._agentTexts(), format));
  }

  @override
  Future<void> setTitle(String title) async => _editor._agentEdit(() => _editor._titleController.text = title);

  @override
  Future<void> addTask(String title, {String? due}) async {
    final add = _editor.widget.onAddTask;
    if (add == null) throw ExtensionError('Tasks cannot be added here.');
    await add(title, due == null ? null : DateTime.parse(due));
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}

/// The calls of the extension API that reach past the selection: they work the same for the assistant and for the tools of extensions.
mixin _EditorWideApi on ExtensionApi, LibraryApi, NotesReadApi {
  _FixedPageNoteEditorState get _editor;

  @override
  NoteRepository get notesRepository => _editor.widget.repository;

  @override
  TaskRepository? get libraryTasks => _editor.widget.tasks;

  @override
  ReminderService? get libraryReminders => _editor.widget.reminders;

  @override
  CalendarAccess? get libraryCalendar => _editor.widget.calendar;

  @override
  String? get libraryNoteId => _editor.widget.noteId;

  @override
  Future<void> insertTextAt(String text, {String? after, String? before, bool atStart = false}) async {
    // (a note with no written text yet has nothing to be at the start of: the text goes where text goes in it)
    if (atStart && _editor._documentController.text.trim().isEmpty) return _editor._agentInsert(text);
    _editor._agentEdit(() => insertNoteText(_editor._agentTexts(), text, after: after, before: before, atStart: atStart));
  }

  @override
  Future<String> inspectText(String target) async {
    final parts = _editor._agentParts();
    return describeNoteFormatting([for (final p in parts) p.text], [for (final p in parts) p.label], target: target);
  }

  Future<String?> _folderId(String name) async {
    final folders = await _editor.widget.repository.listFolders();
    final found = folders.where((f) => f.name.toLowerCase() == name.trim().toLowerCase()).firstOrNull;
    if (found == null) throw ExtensionError('There is no folder "$name". The folders are: ${folders.map((f) => f.name).join(', ')}.');
    return found.id;
  }

  @override
  Future<String> createNote(String title, String text, {String? folder}) async {
    final repo = _editor.widget.repository;
    final folderId = folder == null ? null : await _folderId(folder);
    final id = await repo.createNote(title: title.trim().isEmpty ? 'Untitled Note' : title.trim(), folderId: folderId);
    if (text.trim().isNotEmpty) {
      final note = await repo.loadNote(id);
      if (note != null) await repo.saveNote(note..documentText = text);
    }
    return id;
  }

  @override
  Future<void> addTags(List<String> tags) async {
    final repository = _editor.widget.tags;
    if (repository == null) throw ExtensionError('Tags cannot be set here.');
    final id = _editor.widget.noteId;
    await repository.setTags(id, {...await repository.tagsOf(id), ...tags});
  }

  @override
  Future<void> moveToFolder(String? folder) async =>
      _editor.widget.repository.moveNote(_editor.widget.noteId, folder == null ? null : await _folderId(folder));

  // ---- pages

  @override
  Future<List<Map<String, Object?>>> pages() async {
    final e = _editor;
    if (e._infinite) throw ExtensionError('This note is an infinite canvas: it has no pages.');
    return [
      for (var i = 0; i < e._pageCount; i++)
        {
          'page': i + 1,
          'kind': e._isDocumentPage(i) ? 'written' : (e._isBlank ? 'notebook' : 'pdf'),
          'strokes': (e._strokesPerPage[i] ?? const []).length,
          'textBoxes': (e._textBoxesPerPage[i] ?? const []).length,
          'images': (e._imagesPerPage[i] ?? const []).length,
          'width': e._paperWidth.round(),
          'height': e._heightOf(i).round(),
        },
    ];
  }

  /// Makes sure the pages of the note can be shaped at all, and the page number [page] (from 1; one past the last when [end]) is one.
  void _shapable(int page, {bool end = false}) {
    final e = _editor;
    if (!e.mounted) throw ExtensionError('The note was closed.');
    if (!e._canShapePages) throw ExtensionError('The pages of this note cannot be changed (it is a canvas, or a PDF that cannot be rewritten).');
    if (page < 1 || page > e._pageCount + (end ? 1 : 0)) throw ExtensionError('There is no page $page: the note has ${e._pageCount} pages.');
  }

  @override
  Future<int> addPage({int? at}) async {
    final e = _editor;
    _shapable(at ?? 1, end: true);
    // (a notebook always ends with a blank page: adding one at its end is having it)
    if (at == null && e._isBlank) return e._pageCount;
    final index = at == null ? e._pageCount : at - 1;
    if (e._isDocumentPage(index)) throw ExtensionError('Page 1 holds the written document: add the page after it.');
    await e._insertPage(index);
    e._scheduleSave();
    return index + 1;
  }

  @override
  Future<void> deletePage(int page) async {
    final e = _editor;
    _shapable(page);
    if (e._isDocumentPage(page - 1)) throw ExtensionError('Page $page holds the written document: it cannot be deleted. Take the text out instead.');
    if (!e._isBlank && e._pageCount < 2) throw ExtensionError('A PDF cannot have no pages.');
    await e._deletePage(page - 1);
    e._scheduleSave();
  }

  @override
  Future<void> movePage(int page, int to) async {
    final e = _editor;
    _shapable(page);
    _shapable(to);
    if (e._isDocumentPage(page - 1) || e._isDocumentPage(to - 1)) throw ExtensionError('Page 1 holds the written document: it stays where it is.');
    await e._movePageTo(page - 1, to - 1);
    e._scheduleSave();
  }

  // ---- folders and the library

  /// The folder called [name] (as a name that is not in [folders] says which are).
  Future<FolderEntry> _folder(String name) async {
    final folders = await _editor.widget.repository.listFolders();
    final found = folders.where((f) => f.name.toLowerCase() == name.trim().toLowerCase()).firstOrNull;
    return found ?? (throw ExtensionError('There is no folder "$name". The folders are: ${folders.map((f) => f.name).join(', ')}.'));
  }

  @override
  Future<List<Map<String, Object?>>> listFolders() async {
    final folders = await _editor.widget.repository.listFolders();
    final names = {for (final f in folders) f.id: f.name};
    return [for (final f in folders) {'name': f.name, 'parent': names[f.parentId], 'notes': f.noteCount}];
  }

  @override
  Future<void> createFolder(String name, {String? parent}) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ExtensionError('"name" is empty.');
    final repo = _editor.widget.repository;
    if ((await repo.listFolders()).any((f) => f.name.toLowerCase() == clean.toLowerCase())) throw ExtensionError('There is a folder "$clean" already.');
    await repo.createFolder(clean, parentId: parent == null ? null : (await _folder(parent)).id);
  }

  @override
  Future<void> renameFolder(String name, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) throw ExtensionError('"newName" is empty.');
    await _editor.widget.repository.renameFolder((await _folder(name)).id, clean);
  }

  Future<NoteSummary> _noteOf(String id) async {
    final found = (await _editor.widget.repository.listNotes()).where((n) => n.id == id).firstOrNull;
    if (found == null) throw ExtensionError('There is no such note. notes.search and notes.list give the ids.');
    if (found.locked) throw ExtensionError('That note is locked: it cannot be changed from here.');
    return found;
  }

  @override
  Future<void> moveNoteTo(String id, String? folder) async {
    await _noteOf(id);
    await _editor.widget.repository.moveNote(id, folder == null ? null : (await _folder(folder)).id);
  }

  @override
  Future<void> tagNote(String id, List<String> tags) async {
    final repository = _editor.widget.tags;
    if (repository == null) throw ExtensionError('Tags cannot be set here.');
    await _noteOf(id);
    await repository.setTags(id, {...await repository.tagsOf(id), ...tags});
  }

  @override
  Future<void> trashNote(String id) async {
    if (id == _editor.widget.noteId) throw ExtensionError('That is the note that is open: close it first.');
    await _noteOf(id);
    await _editor.widget.repository.trashNote(id);
  }

  @override
  Future<void> restoreNote(String id) async {
    final repo = _editor.widget.repository;
    if (!(await repo.listTrash()).any((n) => n.id == id)) throw ExtensionError('There is no such note in the trash.');
    await repo.restoreNote(id);
  }

  // ---- flashcards

  @override
  Future<int> addCards(List<Map<String, String>> cards) async {
    final repository = _editor.widget.cards;
    if (repository == null) throw ExtensionError('Flashcards cannot be made here.');
    return repository.addAll(_editor.widget.noteId, [for (final c in cards) Flashcard(c['front']!, c['back']!)]);
  }

  // ---- text boxes, pictures, drawing and the paper

  /// The page number [page] (from 1) as an index; the page in view when null.
  int _pageIndexOf(int? page) {
    final e = _editor;
    if (!e.mounted) throw ExtensionError('The note was closed.');
    if (page == null) return e._visiblePage().$1.clamp(0, e._pageCount - 1);
    if (page < 1 || page > e._pageCount) throw ExtensionError('There is no page $page: the note has ${e._pageCount} pages.');
    return page - 1;
  }

  double _round(double v) => (v * 10).roundToDouble() / 10;

  TextBoxWidgetModel _boxOf(String id) {
    for (final boxes in _editor._textBoxesPerPage.values) {
      for (final b in boxes) {
        if (b.id == id && !_editor._inGutter(b)) return b;
      }
    }
    throw ExtensionError('There is no text box with the id "$id". textBoxes.list has the ids.');
  }

  @override
  Future<List<Map<String, Object?>>> textBoxes() async => [
        for (final page in _editor._textBoxesPerPage.keys.toList()..sort())
          for (final b in _editor._textBoxesPerPage[page]!)
            if (!_editor._inGutter(b))
              {
                'id': b.id,
                'page': page + 1,
                'x': _round(b.position.dx),
                'y': _round(b.position.dy),
                'width': _round(b.size.width),
                'text': b.controller.text.length > 200 ? '${b.controller.text.substring(0, 200)}...' : b.controller.text,
              },
      ];

  @override
  Future<String> addTextBox(String text, {int? page, double? x, double? y, double? width}) async {
    final e = _editor;
    final index = _pageIndexOf(page);
    if (!e._drawingLayer.editable) throw ExtensionError('The layer in use is hidden or locked: nothing can be added to it.');
    if (e._infinite && index != 0) throw ExtensionError('A canvas has one page.');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final at = page == null && x == null && y == null ? Offset(e._visibleLeft + 40, e._visiblePage().$2 + 40) : Offset(x ?? 40, y ?? 40);
    e._agentEdit(() => e._addTextBoxAt(index, at, initialText: text, id: id, width: width ?? 260));
    return id;
  }

  @override
  Future<void> moveTextBox(String id, {int? page, double? x, double? y, double? width}) async {
    final e = _editor;
    final box = _boxOf(id);
    final to = page == null ? null : _pageIndexOf(page);
    e._agentEdit(() {
      if (width != null) box.size = Size(width, box.size.height);
      box.position = Offset(math.max(0, x ?? box.position.dx), math.max(0, y ?? box.position.dy));
      if (to != null) {
        for (final boxes in e._textBoxesPerPage.values) {
          boxes.remove(box);
        }
        e._textBoxesPerPage.putIfAbsent(to, () => []).add(box);
      }
    });
  }

  @override
  Future<void> deleteTextBox(String id) async {
    final e = _editor;
    final box = _boxOf(id);
    e._agentEdit(() {
      for (final boxes in e._textBoxesPerPage.values) {
        boxes.remove(box);
      }
      if (e._activeSelectedBox == box) e._activeSelectedBox = null;
    });
  }

  ({int page, ImageItem image}) _imageOf(String id) {
    for (final entry in _editor._imagesPerPage.entries) {
      for (final m in entry.value) {
        if (m.id == id) return (page: entry.key, image: m);
      }
    }
    throw ExtensionError('There is no picture with the id "$id". images.list has the ids.');
  }

  @override
  Future<List<Map<String, Object?>>> images() async => [
        for (final page in _editor._imagesPerPage.keys.toList()..sort())
          for (final m in _editor._imagesPerPage[page]!)
            {'id': m.id, 'page': page + 1, 'x': _round(m.position.dx), 'y': _round(m.position.dy), 'width': _round(m.size.width), 'height': _round(m.size.height)},
      ];

  @override
  Future<void> moveImage(String id, {int? page, double? x, double? y, double? width}) async {
    final e = _editor;
    final found = _imageOf(id);
    final to = page == null ? null : _pageIndexOf(page);
    e._agentEdit(() {
      final m = found.image;
      if (width != null) {
        final w = math.max(ImageItemWidget.minWidth, width);
        m.size = Size(w, w / m.aspect);
      }
      m.position = Offset(math.max(0, x ?? m.position.dx), math.max(0, y ?? m.position.dy));
      if (to != null && to != found.page) {
        e._imagesPerPage[found.page]?.remove(m);
        e._imagesPerPage.putIfAbsent(to, () => []).add(m);
      }
    });
  }

  @override
  Future<void> deleteImage(String id) async {
    final e = _editor;
    final found = _imageOf(id);
    e._agentEdit(() => e._imagesPerPage[found.page]?.remove(found.image));
  }

  @override
  Future<int> drawStrokes(List<Map<String, Object?>> strokes, {int? page}) async {
    final e = _editor;
    final index = _pageIndexOf(page);
    if (!e._drawingLayer.editable) throw ExtensionError('The layer in use is hidden or locked: nothing can be drawn on it.');
    final drawn = parseDrawnStrokes(strokes, color: e._selectedPenColor, width: e._strokeWidth);
    for (final s in drawn) {
      s.author = Authorship.current;
    }
    if (drawn.isEmpty) return 0;
    e._agentEdit(() {
      e._strokesPerPage.putIfAbsent(index, () => []).addAll(drawn);
      e._undoStack.push(UndoStep(
        () => e._strokesPerPage[index]?.removeWhere(drawn.contains),
        () => e._strokesPerPage.putIfAbsent(index, () => []).addAll(drawn),
      ));
    });
    return drawn.length;
  }

  @override
  Future<String> setupPage(Map<String, Object?> options) async {
    final e = _editor;
    if (!e.mounted) throw ExtensionError('The note was closed.');
    if (!e._isBlank || e._infinite) throw ExtensionError('The paper of this note cannot be set up (it is a PDF or a canvas).');
    final said = <String>[];
    PageFormat? format;
    bool? landscape;
    PageBackground? background;
    final paper = options['paper'];
    if (paper != null) {
      format = PageFormat.papers.where((f) => f.name == '$paper'.toLowerCase().trim()).firstOrNull ??
          (throw ExtensionError('"paper" has to be one of: ${PageFormat.papers.map((f) => f.name).join(', ')}.'));
    }
    final orientation = options['orientation'];
    if (orientation != null) {
      if (orientation != 'portrait' && orientation != 'landscape') throw ExtensionError('"orientation" has to be portrait or landscape.');
      landscape = orientation == 'landscape';
    }
    final back = options['background'];
    if (back != null) {
      background = PageBackground.values.where((b) => b.name == '$back'.toLowerCase().trim()).firstOrNull ??
          (throw ExtensionError('"background" has to be one of: ${PageBackground.values.map((b) => b.name).join(', ')}.'));
    }
    final margins = options['margins'];
    final units = <String, double>{};
    if (margins != null) {
      if (margins is! Map) throw ExtensionError('"margins" has to be {left, right, top, bottom} in millimetres.');
      for (final entry in margins.entries) {
        final side = entry.key, mm = entry.value;
        if (!const ['left', 'right', 'top', 'bottom'].contains(side) || mm is! num || !mm.isFinite || mm < 0 || mm > 80) {
          throw ExtensionError('"margins" has to be {left, right, top, bottom}, each a number of millimetres from 0 to 80.');
        }
        units[side as String] = mm * PageFormat.a4Units / 210;
      }
    }
    if (format == null && landscape == null && background == null && units.isEmpty) throw ExtensionError('Say at least one of "paper", "orientation", "background" and "margins".');
    e._agentEdit(() {
      if (format != null) e._pageFormat = format;
      if (landscape != null) e._landscape = landscape;
      if (background != null) e._background = background;
      if (units['left'] != null) e._marginLeft = units['left']!;
      if (units['right'] != null) e._marginRight = units['right']!;
      if (units['top'] != null) e._marginTop = units['top']!;
      if (units['bottom'] != null) e._marginBottom = units['bottom']!;
    });
    if (format != null) said.add('paper ${format.label}');
    if (landscape != null) said.add(landscape ? 'landscape' : 'portrait');
    if (background != null) said.add('${background.label} paper');
    if (units.isNotEmpty) said.add('margins');
    return said.join(', ');
  }

  // ---- tracked changes and stars

  @override
  Future<int> resolveChanges({required bool accept}) async {
    final e = _editor;
    return e._agentEdit(() {
      var settled = 0;
      for (final text in e._agentTexts()) {
        final edits = decideChanges(text.text, accept: accept);
        if (edits.isEmpty) continue;
        text.replaceRanges(edits);
        settled += edits.length;
      }
      if (settled == 0) throw ExtensionError('The note has no tracked changes ({++put in++} or {--taken out--}).');
      return settled;
    });
  }

  @override
  Future<void> favoriteNote(String id, bool on) async {
    await _noteOf(id);
    await _editor.widget.repository.setFavorite(id, on);
  }

  // ---- the text of PDFs

  /// The page texts of the PDF of this note ([id] null: the open one, as it is shown; else as the app read it), or fails.
  Future<List<String>> _pdfPages(String? id) async {
    final e = _editor;
    if (id != null && id != e.widget.noteId) {
      final pages = await e.widget.repository.text.pdfPages(id);
      return pages ?? (throw ExtensionError('There is no PDF to read in that note (it is not a PDF note, it is locked, or the app has not read its text yet).'));
    }
    final pages = await e._readPdfPageTexts();
    if (pages != null && pages.isNotEmpty) return pages;
    final stored = await e.widget.repository.text.pdfPages(e.widget.noteId);
    return stored ?? (throw ExtensionError('This note has no PDF.'));
  }

  @override
  Future<String> readPdf({String? id, int? from, int? to}) async => readPdfPages(await _pdfPages(id), from: from, to: to);

  @override
  Future<List<Map<String, Object?>>> searchPdf(String query, {String? id}) async => searchPdfPages(await _pdfPages(id), query);
}
