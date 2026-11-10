part of 'fixed_page_note_editor.dart';

/// What the menu on some text is made from, whichever kind of editor that text is in.
class _MenuOn {
  final BuildContext context;
  final List<ContextMenuButtonItem> items;
  final TextEditingValue value;
  final VoidCallback hide;
  final TextSelectionToolbarAnchors anchors;

  /// Whether it comes out scaled with the page (see [menuAtScreenSize]).
  final bool scaled;

  _MenuOn.field(EditableTextState state)
      : context = state.context,
        items = state.contextMenuButtonItems,
        value = state.textEditingValue,
        hide = state.hideToolbar,
        anchors = state.contextMenuAnchors,
        scaled = true;

  _MenuOn.blocks(BlockMenu menu)
      : context = menu.context,
        items = menu.items,
        value = menu.value,
        hide = menu.hide,
        anchors = menu.anchors,
        scaled = false;
}

/// Links, the side panel for look-ups and web pages, the menus on selected text and solving equations in text.
extension _EditorLookup on _FixedPageNoteEditorState {
  /// Whether the written document's formatting bar stands at the right of the page (not along the bottom).
  bool get _documentBarAtSide => _mode == CanvasInteractionMode.document && _isBlank;

  /// The formatting bar for whatever Markdown is being edited, with the notes
  /// to link to while an `@` is being typed. The document's own bar is at the right of the page, see [_documentSideBar].
  Widget? _bottomBar() {
    final TextEditingController? controller = _mode == CanvasInteractionMode.document
        ? (_isBlank ? _documentController : null)
        : _activeSelectedBox?.controller;
    if (controller == null) return null;
    // a table has its own tools above it: bold and the like do not apply to its whole text
    if (_mode != CanvasInteractionMode.document && isTableText(controller.text)) return null;
    final atSide = identical(controller, _documentController) && _documentBarAtSide;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mention = mentionAt(controller.value);
        if (mention != null && !_choicesLoaded) _loadNoteChoices();
        if (atSide) return mention == null ? const SizedBox.shrink() : _mentionList(controller, mention);
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (mention != null) _mentionList(controller, mention),
          MarkdownToolbar(
            controller: controller,
            onSolve: _on(Feature.solve) ? () => _solveIn(controller) : null,
            onTable: _on(Feature.tables) ? _insertTable : null,
            onCite: _on(Feature.citations) && CitationScope.maybeOf(context) != null ? () => _citeIn(controller) : null,
            onBibliography: _on(Feature.citations) && CitationScope.maybeOf(context) != null ? _insertBibliography : null,
          ),
        ]);
      },
    );
  }

  /// The written document's formatting bar, in a column at the right of the page like the drawing tools.
  Widget _documentSideBar() {
    return FollowingToolbar(
      controller: _documentController,
      builder: (context) => DocumentToolbar(
          vertical: true,
          controller: _documentController,
          onSolve: _on(Feature.solve) ? () => _solveIn(_documentController) : null,
          onTable: _on(Feature.tables) ? _insertTable : null,
          onCite: _on(Feature.citations) && CitationScope.maybeOf(context) != null ? () => _citeIn(_documentController) : null,
          onBibliography: _on(Feature.citations) && CitationScope.maybeOf(context) != null ? _insertBibliography : null,
          onPicture: _on(Feature.images) ? _insertDocumentPicture : null,
          onImportWord: _importWordDocument,
      ),
    );
  }

  /// Asks which source to cite and writes the citation at the cursor.
  Future<void> _citeIn(TextEditingController controller) async {
    final service = CitationScope.maybeOf(context);
    if (service == null) return;
    // with the cursor in a citation, that one is changed
    final around = citationAround(controller.text, controller.selection.isValid ? controller.selection.baseOffset : -1);
    final citation = await showCitePicker(context, service, editing: around?.items);
    if (citation == null || !mounted) return;
    controller.value = around == null ? withCitation(controller.value, citation) : replaceCitation(controller.value, around, citation);
  }

  /// The notes a link can point to, read each time an `@` starts.
  Future<void> _loadNoteChoices() async {
    _choicesLoaded = true;
    final all = await widget.repository.listNotes();
    if (!mounted) return;
    setState(() => _noteChoices = all.where((n) => n.id != widget.noteId).toList());
  }

  Widget _mentionList(TextEditingController controller, Mention mention) {
    final query = mention.query.toLowerCase();
    final matches = _noteChoices.where((n) => !n.locked && n.title.toLowerCase().contains(query)).take(6).toList();
    final scheme = Theme.of(context).colorScheme;
    return ExcludeFocus(
      child: Material(
        key: const ValueKey('mention-list'),
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: matches.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text.verbatim(_noteChoices.isEmpty ? tr('No other notes to link to') : tr('No note matches "{query}"', {'query': mention.query}),
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in matches)
                      ListTile(
                        key: ValueKey('mention-${n.id}'),
                        dense: true,
                        leading: Icon(n.isPdf ? Icons.picture_as_pdf_outlined : Icons.description_outlined, size: 20),
                        title: Text.verbatim(n.title.isEmpty ? tr('Untitled') : n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          controller.value = withNoteLink(controller.value, mention, n.id, n.title);
                          _choicesLoaded = false; // read again next time
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  /// A tapped link: another note opens here, a web address in the browser.
  Future<void> _openLink(String target) async {
    if (target.startsWith('note:')) {
      final id = target.substring(5);
      if (!await widget.repository.noteExists(id)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That note no longer exists')));
        }
        return;
      }
      widget.onOpenNote?.call(id);
      return;
    }
    final uri = Uri.tryParse(target);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) await _openPage(uri);
  }

  /// A web page from a link in the note: in the panel beside (or over) the note
  /// where the platform can show one, else in the browser.
  Future<void> _openPage(Uri url) async {
    if (!(widget.webPage != null || webViewSupported)) {
      await openInBrowser(url);
      return;
    }
    final name = url.host.replaceFirst(RegExp(r'^www\.'), '');
    await _showPanel(name, LookupSource.web, address: url);
  }

  void _setTranslateTo(String code) {
    _translateTo = code;
    widget.repository.settings.set('translate_to', code);
  }

  /// Text selected in the web page, as a text box on the page on screen.
  void _addWebText(String text) {
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(_infinite ? tr('Added to the canvas') : tr('Added to page {n}', {'n': page + 1}))));
  }

  /// Puts a link to the web page being looked at on the page on screen.
  void _linkWebPage(Uri url, String? title) {
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: markdownLink(url, title));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(_infinite ? tr('Linked on the canvas') : tr('Linked on page {n}', {'n': page + 1}))));
  }

  Future<void> _openLookup(String term, LookupSource source) async {
    final url = source.urlFor(term.trim(), language: _translateTo);
    if (!(widget.webPage != null || webViewSupported)) {
      await openInBrowser(url);
      return;
    }
    await _showPanel(term, source);
  }

  Future<void> _showPanel(String term, LookupSource source, {Uri? address}) async {
    if (_roomForSidePanel) {
      _closeFindForPanel();
      setState(() {
        _closeSidePanels();
        _lookup = (term: term.trim(), source: source, address: address);
      });
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => Scaffold(
        body: SafeArea(
          child: LookupPanel(
            term: term.trim(),
            source: source,
            address: address,
            page: widget.webPage,
            onLinkPage: _linkWebPage,
            onAddText: _addWebText,
            language: _translateTo,
            onLanguage: _setTranslateTo,
            onClose: () => Navigator.pop(context),
          ),
        ),
      ),
    ));
  }

  /// "Search the web" / "Wikipedia" for one or two highlighted words.
  List<ContextMenuButtonItem> _lookupItems(String? selected, VoidCallback hide) {
    if (!_on(Feature.lookup)) return const [];
    ContextMenuButtonItem item(String label, LookupSource source) => ContextMenuButtonItem(
          label: label,
          onPressed: () {
            hide();
            _openLookup(selected!, source);
          },
        );
    return [
      if (isLookupTerm(selected)) ...[
        item('Search the web', LookupSource.web),
        item('Wikipedia', LookupSource.wikipedia),
      ],
      if (isTranslatable(selected)) item('Translate', LookupSource.translate),
      // (one word: what else to say for it)
      if (selected != null && RegExp(r'^\p{L}[\p{L}\-]{1,40}$', unicode: true).hasMatch(selected.trim())) item('Synonyms', LookupSource.synonyms),
    ];
  }

  /// "Summarize" (more than two words), "Tell me more" and "Ask a question" for
  /// highlighted text, when an AI provider can work here.
  ///
  /// [prepare] runs when an item is pressed, while the highlight is still there
  /// (the dialog takes it away), and returns what puts the answer in the note.
  List<ContextMenuButtonItem> _summarizeItems(
    String? selected,
    VoidCallback hide,
    FutureOr<void Function(String summary)> Function() prepare,
  ) {
    final ai = widget.ai;
    if (ai == null || !ai.canSummarize || !hasWords(selected)) return const [];
    ContextMenuButtonItem item(String label, AiTask? task) => ContextMenuButtonItem(
          label: label,
          onPressed: () async {
            hide();
            final place = await prepare();
            if (!mounted) return;
            final answer = await showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => AiSummaryDialog(ai: ai, text: selected!, task: task),
            );
            if (answer != null && mounted) place(answer);
          },
        );
    return [
      if (worthSummarizing(selected)) item('Summarize', null),
      item('Tell me more', AiTask.explain),
      item('Ask a question', AiTask.ask),
    ];
  }

  /// The usual cut/copy/paste menu, plus "Calculate" while text is highlighted.
  Widget _calculateMenu(_MenuOn state, TextEditingController controller) {
    final items = List.of(state.items);
    final selection = state.value.selection;
    if (widget.spell != null && controller is RichInlineTextController) {
      items.insertAll(0, spellMenuItems(controller, widget.spell!, selection, state.hide));
    }
    if (controller is LiveMarkdownController && controller.checkGrammar) {
      items.insertAll(0, grammarMenuItems(controller, controller.grammar, selection, state.hide));
    }
    if (!selection.isCollapsed) {
      final picked = selection.textInside(state.value.text);
      final lookups = _lookupItems(picked, state.hide);
      final summaries = _summarizeItems(picked, state.hide, () {
        // a paragraph of its own under the one that was highlighted
        final text = controller.text;
        final from = selection.end.clamp(0, text.length);
        final newline = text.indexOf('\n', from);
        final at = newline < 0 ? text.length : newline;
        return (summary) {
          final now = controller.text;
          final lineEnd = at.clamp(0, now.length);
          final insert = '\n\n$summary';
          controller.value = TextEditingValue(
            text: now.replaceRange(lineEnd, lineEnd, insert),
            selection: TextSelection.collapsed(offset: lineEnd + insert.length),
          );
        };
      });
      if (picked.trim().isNotEmpty && !isPlainWords(picked) && (canCalculate(picked) || canPlot(picked))) {
        items.insert(
          0,
          ContextMenuButtonItem(
            label: 'Calculate',
            onPressed: () {
              state.hide();
              // the dialog takes the focus, which would drop the highlight
              controller.selection = selection;
              _solveIn(controller);
            },
          ),
        );
      }
      // (the synonyms come after the tools of the extensions, which are looked for here by name)
      final synonyms = lookups.where((i) => i.label == 'Synonyms');
      items.insertAll(0, [
        ...lookups.where((i) => i.label != 'Synonyms'),
        ...summaries,
        ..._extensionItems(controller, selection, state.hide),
        ...synonyms,
      ]);
    }
    final menu = AdaptiveTextSelectionToolbar.buttonItems(anchors: state.anchors, buttonItems: items);
    return state.scaled ? menuAtScreenSize(state.context, menu) : menu;
  }

  /// Solves the equation in the text being edited and adds the answer below it.
  Future<void> _solveIn(TextEditingController controller) async {
    final target = equationTarget(controller.value);
    final solved = await _solveDialog(context, target?.latex ?? '');
    if (solved == null || target == null || !mounted) return;
    // the text may have been edited while the dialog was open
    final now = controller.value;
    final at = target.insertAt.clamp(0, now.text.length);
    controller.value = withSolution(now, (
      latex: target.latex,
      insertAt: at,
    ), solved);
  }

  /// Works out what to do with [latex] (solve, differentiate or integrate),
  /// asks for what is missing, and shows the result. Returns the result as
  /// LaTeX when the user wants it added, otherwise null.
  Future<String?> _solveDialog(BuildContext context, String latex) async {
    final plan = planCalculation(latex);
    final plot = planPlot(latex);
    if (plan.kind == CalcKind.none && plot == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: const Text('Nothing to calculate'),
          content: Text(plan.message ??
              'I need an equation like 2x + 3 = 11, or a formula with a letter to differentiate, integrate or plot.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      return null;
    }
    // what can be done with it; asked about only when there is a choice
    final options = <(String, String)>[
      if (plan.kind == CalcKind.solve) ('solve', 'Solve'),
      if (plan.kind == CalcKind.ask) ...[('derive', 'Differentiate'), ('integrate', 'Integrate')],
      if (plot != null) ('plot', 'Plot'),
    ];
    var choice = options.isEmpty ? '' : options.first.$1;
    if (plan.kind == CalcKind.derive) choice = 'derive';
    if (plan.kind == CalcKind.integrate) choice = 'integrate';
    if (options.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('What should I do?'),
          children: [
            for (final (key, label) in options)
              SimpleDialogOption(
                key: ValueKey('calc-$key'),
                onPressed: () => Navigator.pop(context, key),
                child: Text(label),
              ),
          ],
        ),
      );
      if (picked == null || !context.mounted) return null;
      choice = picked;
    }
    if (choice == 'plot') {
      await showDialog<void>(
        context: context,
        builder: (context) => PlotDialog(
          spec: plot!,
          onAdd: _mode == CanvasInteractionMode.document ? null : (png, size) => _placeImage(png),
        ),
      );
      return null;
    }
    var kind = switch (choice) {
      'derive' => CalcKind.derive,
      'integrate' => CalcKind.integrate,
      _ => plan.kind,
    };
    var variable = plan.variables.first;
    if (plan.variables.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(switch (kind) {
            CalcKind.derive => 'Differentiate with respect to...',
            CalcKind.integrate => 'Integrate with respect to...',
            _ => 'Solve for...',
          }),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in plan.variables)
                    ActionChip(
                      key: ValueKey('solve-for-$v'),
                      label: Math.tex(
                        v,
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                      onPressed: () => Navigator.pop(context, v),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
      if (picked == null || !context.mounted) return null;
      variable = picked;
    }
    EquationSolution? answer;
    String? problem;
    try {
      answer = calculate(latex, kind, variable);
    } on SolveException catch (e) {
      problem = e.message;
    }
    if (!context.mounted) return null;
    final text = answer?.solutions.isNotEmpty == true ? answer!.latex : null;
    final add = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(kind == CalcKind.solve ? 'Solution' : 'Result'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: text != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final s in answer!.solutions)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Math.tex(
                              s,
                              textStyle: const TextStyle(fontSize: 20),
                              onErrorFallback: (_) => Text.verbatim(s),
                            ),
                          ),
                        ),
                      if (answer.note != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text.verbatim(answer.note!),
                        ),
                    ],
                  )
                : Text(problem ?? answer?.note ?? 'No solution found.'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          if (text != null)
            FilledButton(
              key: const ValueKey('add-solution'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add below the equation'),
            ),
        ],
      ),
    );
    return add == true ? text : null;
  }
}
