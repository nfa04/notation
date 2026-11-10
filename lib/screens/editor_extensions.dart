part of 'fixed_page_note_editor.dart';

/// The tools of the extensions, in the menu of selected text: each runs in the sandbox of its extension with the selected text
/// and what it was given leave to do (see [ExtensionService]).
extension _EditorExtensions on _FixedPageNoteEditorState {
  /// How a tool is called in a menu: with the name of its extension in front ("Shout: Make it loud"), so that it can be found by
  /// the name the extension has in the settings.
  static String toolLabel(InstalledExtension e, ExtensionTool t) => t.title.toLowerCase().contains(e.manifest.name.toLowerCase()) ? t.title : '${e.manifest.name}: ${t.title}';

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
    final api = _EditorExtensionApi(service, this, controller, selection);
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
class _EditorExtensionApi extends SharedExtensionApi with LibraryApi, NotesReadApi, _EditorWideApi {
  @override
  final _FixedPageNoteEditorState _editor;
  final TextEditingController _controller;

  /// Where the selected text is now (it moves as text is put in before it).
  TextSelection selection;

  _EditorExtensionApi(super.service, this._editor, this._controller, this.selection);

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
