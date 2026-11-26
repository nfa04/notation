part of 'fixed_page_note_editor.dart';

/// The tools of the extensions, in the menu of selected text: each runs in the sandbox of its extension with the selected text
/// and what it was given leave to do (see [ExtensionService]).
extension _EditorExtensions on _FixedPageNoteEditorState {
  /// How a tool is called in a menu: with the name of its extension in front ("Shout: Make it loud"), so that it can be found by
  /// the name the extension has in the settings.
  static String toolLabel(InstalledExtension e, ExtensionTool t) => t.title.toLowerCase().contains(e.manifest.name.toLowerCase()) ? t.title : '${e.manifest.name}: ${t.title}';

  /// The button with what extensions add for this note: their commands and their ways to export it. Null when there is none.
  Widget? _extensionsMenu() {
    final service = widget.extensions;
    if (service == null) return null;
    final commands = service.commands(CommandPlace.noteMenu);
    final exporters = service.exporters;
    if (commands.isEmpty && exporters.isEmpty) return null;
    return PopupMenuButton<Object>(
      key: const ValueKey('extensions-menu'),
      tooltip: tr('Commands and exports of your extensions'),
      icon: const Icon(Symbols.extension, size: 20),
      onSelected: (choice) {
        if (choice is CommandEntry) {
          unawaited(runExtensionCommand(context, service, choice, _EditorCommandApi(this, choice.extension.manifest.name), extra: {
            'note': {'id': widget.noteId, 'title': _titleController.text},
          }));
        } else if (choice is ({InstalledExtension extension, ExtensionExporter exporter})) {
          unawaited(_exportWithExtension(service, choice));
        }
      },
      itemBuilder: (context) => [
        for (final c in commands) PopupMenuItem<Object>(key: ValueKey('extension-command-${c.extension.id}-${c.command.id}'), value: c, child: Text.verbatim('${c.extension.manifest.name}: ${c.command.title}')),
        if (commands.isNotEmpty && exporters.isNotEmpty) const PopupMenuDivider(),
        for (final x in exporters)
          PopupMenuItem<Object>(key: ValueKey('extension-export-${x.extension.id}-${x.exporter.id}'), value: x, child: Text.verbatim(tr('Export: {name}', {'name': '${x.extension.manifest.name}: ${x.exporter.title}'}))),
      ],
    );
  }

  /// Makes the file an exporter of an extension makes of this note (its Markdown, its title and tags) and asks where to keep it.
  Future<void> _exportWithExtension(ExtensionService service, ({InstalledExtension extension, ExtensionExporter exporter}) choice) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _saveNow();
      final note = await widget.repository.loadNote(widget.noteId);
      if (note == null || !mounted) return;
      final text = widget.repository.text;
      final made = await noteToMarkdown(
        note,
        handwriting: await text.inkTexts(widget.noteId),
        formulas: await text.inkFormulas(widget.noteId),
        document: _hasDocument ? _documentController.text : null,
      );
      final tags = await (widget.tags?.tagsOf(widget.noteId) ?? Future.value(const <String>[]));
      if (!mounted) return;
      final file = await service.runExporter(
        choice.extension,
        choice.exporter,
        {'id': widget.noteId, 'title': _titleController.text, 'markdown': made.markdown, 'tags': tags},
        api: interactiveApiFor(context, choice.extension.manifest.name),
      );
      if (!mounted) return;
      final path = await saveWithDialog(dialogTitle: tr('Export'), fileName: file.name, extension: choice.exporter.extension, bytes: file.bytes);
      if (path != null && mounted) messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Successfully exported to {path}', {'path': path}))));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('{name}: {error}', {'name': choice.extension.manifest.name, 'error': e}))));
    }
  }

  /// One entry for each tool of an extension that is on.
  List<ContextMenuButtonItem> _extensionItems(TextEditingController controller, TextSelection selection, VoidCallback hide) {
    final service = widget.extensions;
    if (service == null || selection.isCollapsed || selection.textInside(controller.text).trim().isEmpty) return const [];
    return [
      for (final t in service.tools)
        ContextMenuButtonItem(
          label: toolLabel(t.extension, t.tool),
          onPressed: () {
            hide();
            _runExtensionTool(service, t.extension, t.tool, controller, selection);
          },
        ),
    ];
  }

  /// Hands a drag of the pen to the drawing [tool] of an extension, and draws what it returns in place of the drag (one step to take
  /// back).
  Future<void> _runDrawTool(({InstalledExtension extension, ExtensionDrawTool tool}) t, int page, List<Offset> points, List<int>? pressures, Size pageSize) async {
    final service = widget.extensions;
    if (service == null || points.length < 2) return;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await service.runDrawTool(
      t.extension,
      t.tool,
      DrawGesture(
        points: points,
        pressures: pressures == null || pressures.length != points.length ? null : [for (final v in pressures) v / 255],
        color: _selectedPenColor,
        width: _strokeWidth,
        page: pageSize,
        shift: HardwareKeyboard.instance.isShiftPressed,
      ),
      onMessage: (text) {
        if (mounted) messenger.showSnackBar(SnackBar(content: Text.verbatim(text)));
      },
    );
    if (!mounted) return;
    if (!outcome.ok) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('{name}: {error}', {'name': t.extension.manifest.name, 'error': outcome.error}))));
      return;
    }
    final strokes = outcome.strokes;
    for (final s in strokes) {
      s.author = Authorship.current;
    }
    if (strokes.isNotEmpty) {
      setState(() {
        _strokesPerPage.putIfAbsent(page, () => []).addAll(strokes);
        _undoStack.push(UndoStep(
          () => _strokesPerPage[page]?.removeWhere(strokes.contains),
          () => _strokesPerPage.putIfAbsent(page, () => []).addAll(strokes),
        ));
      });
      _scheduleSave();
    }
    final message = outcome.message;
    if (message != null && message.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text.verbatim(message)));
  }

  /// The tools in the menu of text that can only be read (a PDF page, a shown note): a tool runs on the selected text, and what it
  /// gives back (the text that would replace it) is put on the clipboard, since there is nothing to change.
  List<ContextMenuButtonItem> _extensionItemsForReading(String? picked, VoidCallback hide) {
    final service = widget.extensions;
    if (service == null || picked == null || picked.trim().isEmpty) return const [];
    return [
      for (final t in service.tools)
        ContextMenuButtonItem(
          label: toolLabel(t.extension, t.tool),
          onPressed: () {
            hide();
            _runExtensionToolOnReadOnly(service, t.extension, t.tool, picked);
          },
        ),
    ];
  }

  Future<void> _runExtensionToolOnReadOnly(ExtensionService service, InstalledExtension extension, ExtensionTool tool, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final scratch = TextEditingController(text: text);
    final api = _EditorExtensionApi(service, this, scratch, TextSelection(baseOffset: 0, extentOffset: text.length));
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text.verbatim('${extension.manifest.name}: ${tool.title}...'), duration: const Duration(seconds: 20)));
    final outcome = await service.runTool(extension, tool, text: text, api: api);
    scratch.dispose();
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    if (!outcome.ok) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('{name}: {error}', {'name': extension.manifest.name, 'error': outcome.error}))));
      return;
    }
    final result = [if (outcome.replace != null) outcome.replace!, if (outcome.insert != null) outcome.insert!].join('\n');
    if (result.isNotEmpty) await Clipboard.setData(ClipboardData(text: result));
    final message = outcome.message;
    messenger.showSnackBar(SnackBar(
      content: Text.verbatim([if (message != null && message.isNotEmpty) message, if (result.isNotEmpty) tr('The result is on the clipboard (the text here cannot be changed).')].join('\n')),
    ));
  }

  Future<void> _runExtensionTool(ExtensionService service, InstalledExtension extension, ExtensionTool tool, TextEditingController controller, TextSelection selection) async {
    final messenger = ScaffoldMessenger.of(context);
    final text = selection.textInside(controller.text);
    final api = _EditorExtensionApi(service, this, controller, selection, extension.manifest.name);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text.verbatim('${extension.manifest.name}: ${tool.title}...'), duration: const Duration(seconds: 20)));
    final outcome = await service.runTool(extension, tool, text: text, api: api);
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    if (!outcome.ok) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('{name}: {error}', {'name': extension.manifest.name, 'error': outcome.error}))));
      return;
    }
    // what is returned goes where the selection was, if the text is still as it was
    var end = api.selection.end;
    final reply = outcome.replace;
    if (reply != null) {
      if (api.selection.textInside(controller.text) == text) {
        controller.value = TextEditingValue(
          text: controller.text.replaceRange(api.selection.start, api.selection.end, reply),
          selection: TextSelection.collapsed(offset: api.selection.start + reply.length),
        );
        end = api.selection.start + reply.length;
      } else {
        messenger.showSnackBar(SnackBar(content: Text(tr('The text changed meanwhile: the result was not put in'))));
        return;
      }
    }
    final more = outcome.insert;
    if (more != null) {
      final at = end.clamp(0, controller.text.length);
      controller.value = TextEditingValue(
        text: controller.text.replaceRange(at, at, more),
        selection: TextSelection.collapsed(offset: at + more.length),
      );
    }
    final message = outcome.message;
    if (message != null && message.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text.verbatim(message)));
  }
}

/// What an extension can do from the text of the editor: read the note, change the selection and the title.
class _EditorExtensionApi extends SharedExtensionApi with LibraryApi, NotesReadApi, ManageNotesApi, MoreApi, _EditorWideApi {
  @override
  final _FixedPageNoteEditorState _editor;
  final TextEditingController _controller;

  /// Where the selected text is now (it moves as text is put in before it).
  TextSelection selection;

  _EditorExtensionApi(super.service, this._editor, this._controller, this.selection, [this._extensionName = '']);

  /// Who is asking, for the questions that are put to the person.
  final String _extensionName;

  @override
  NoteRepository? get moreNotes => _editor.widget.repository;
  @override
  LinkRepository? get moreLinks => _editor.widget.links;
  @override
  TagRepository? get moreTags => _editor.widget.tags;
  @override
  CardRepository? get moreCards => _editor.widget.cards;
  @override
  CitationRepository? get moreCitations => CitationScope.maybeOf(_editor.context)?.repository;
  @override
  AiService? get moreAi => _editor.widget.ai;
  @override
  String? get moreNoteId => _editor.widget.noteId;

  @override
  Future<Object?> askPerson(String kind, Map<String, Object?> args) async {
    if (!_editor.mounted) return null;
    return askPersonDialog(_editor.context, _extensionName, kind, args);
  }

  @override
  Future<Map<String, Object?>> note() async {
    await _editor._saveNow();
    final id = _editor.widget.noteId;
    return {'id': id, 'title': _editor._titleController.text, 'text': await _editor.widget.repository.text.noteText(id, limit: 20000)};
  }

  @override
  Future<void> replaceSelection(String text) async {
    final s = selection;
    if (s.end > _controller.text.length) throw ExtensionError('The text is not there any more.');
    _controller.value = TextEditingValue(
      text: _controller.text.replaceRange(s.start, s.end, text),
      selection: TextSelection.collapsed(offset: s.start + text.length),
    );
    selection = TextSelection(baseOffset: s.start, extentOffset: s.start + text.length);
  }

  @override
  Future<void> insertText(String text) async {
    final at = selection.end.clamp(0, _controller.text.length);
    _controller.value = TextEditingValue(
      text: _controller.text.replaceRange(at, at, text),
      selection: TextSelection.collapsed(offset: at + text.length),
    );
  }

  @override
  Future<int> replaceText(String find, String replacement, {bool all = false}) async {
    final c = _controller;
    if (c is! RichInlineTextController) throw ExtensionError('Text cannot be replaced here.');
    return replaceNoteText([c], find, replacement, all: all);
  }

  @override
  Future<String> formatText(Map<String, Object?> options) async {
    final c = _controller;
    if (c is! RichInlineTextController) throw ExtensionError('Text cannot be formatted here.');
    return formatNoteText([c], NoteFormat.fromJson(options));
  }

  @override
  Future<void> setTitle(String title) async {
    _editor._titleController.text = title;
    _editor._scheduleSave();
  }

  @override
  void message(String text) {
    if (_editor.mounted) ScaffoldMessenger.of(_editor.context,).showSnackBar(SnackBar(content: Text.verbatim(text)));
  }
}

/// What a command of an extension can do inside the open note: all that the assistant can do with it (read, write, format, pages,
/// text boxes, drawing), the rest of the library, and the questions to the person.
class _EditorCommandApi extends _EditorAgentApi with MoreApi {
  final String _name;
  _EditorCommandApi(super.editor, this._name);

  @override
  NoteRepository? get moreNotes => _editor.widget.repository;
  @override
  LinkRepository? get moreLinks => _editor.widget.links;
  @override
  TagRepository? get moreTags => _editor.widget.tags;
  @override
  CardRepository? get moreCards => _editor.widget.cards;
  @override
  CitationRepository? get moreCitations => CitationScope.maybeOf(_editor.context)?.repository;
  @override
  AiService? get moreAi => _editor.widget.ai;
  @override
  String? get moreNoteId => _editor.widget.noteId;

  @override
  Future<Object?> askPerson(String kind, Map<String, Object?> args) async => _editor.mounted ? askPersonDialog(_editor.context, _name, kind, args) : null;

  @override
  void message(String text) {
    if (_editor.mounted) ScaffoldMessenger.of(_editor.context).showSnackBar(SnackBar(content: Text.verbatim(text)));
  }
}
