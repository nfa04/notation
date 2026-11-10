part of 'fixed_page_note_editor.dart';

/// Working on the note together with others, live.
extension _EditorCollab on _FixedPageNoteEditorState {
  /// What a session needs of this editor: the note as it is, and ways to change it that redraw and save.
  CollabBinding _collabBinding() => CollabBinding(
        note: _snapshot,
        change: (f) {
          if (!mounted) return;
          setState(f);
          _absorbMeta();
          _scheduleSave();
          _warnMissingExtensionBrushes();
        },
        makeBox: (id) {
          final b = TextBoxWidgetModel(id: id, position: Offset.zero);
          _attachBox(b);
          return b;
        },
        saveImage: widget.collab!.saveImage,
        onNoteField: _takeNoteField,
        pdf: _pdfForGuests,
        onPages: _takeRemotePages,
        onPdf: _takeRemotePdf,
      );

  /// Says so when the note has lines of a brush of an extension this device does not have (not installed, or switched off): the lines
  /// are drawn as the pen draws them. Said once for each extension, whether the lines were in the note or came in a live session.
  void _warnMissingExtensionBrushes() {
    if (!mounted) return;
    final missing = extensionsMissingFor([
      for (final list in _strokesPerPage.values)
        for (final s in list) s.brush,
    ]).where(_toldAboutExtensions.add).toList();
    if (missing.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      key: const ValueKey('missing-extension-brush'),
      duration: const Duration(seconds: 8),
      content: Text(tr('Some lines of this note are drawn with a brush of the extension {names}, which is not installed or is switched off. They are drawn with the pen.', {'names': missing.join(', ')})),
    ));
  }

  /// Takes in changes that were made on a copy of this note while its owner (this device) was away.
  void _mergeOffline(List<CollabOp> ops) {
    final binding = _collabBinding();
    final raw = Replica('external');
    binding.change(() {
      final note = binding.note();
      for (final op in ops) {
        raw.apply(note, op, makeBox: binding.makeBox, saveImage: binding.saveImage, onNoteField: binding.onNoteField);
      }
    });
  }

  /// A change from another device to the title, the look of the pages or the written document.
  void _takeNoteField(String field, Map<String, Object?> data) {
    final n = _snapshot();
    Replica.applyNoteField(n, field, data);
    switch (field) {
      case 'title':
        if (_titleController.text != n.title) _titleController.text = n.title;
      case 'setup':
        _background = n.background;
        _layers = n.layers;
        _pageFormat = n.pageFormat;
        _landscape = n.landscape;
        _nativePages = Set.of(n.nativePages);
        _marginLeft = n.marginLeft;
        _marginRight = n.marginRight;
        _marginTop = n.marginTop;
        _marginBottom = n.marginBottom;
      case 'doc':
        if (_documentController.text != n.documentText) _documentController.text = n.documentText;
        _documentController.attributes
          ..clear()
          ..addAll(n.documentSpans);
    }
  }

  /// The PDF of this note, for someone who joins (null for a note that is not made from one).
  Future<SharedPdf?> _pdfForGuests() async {
    final path = _pdfFilePath;
    if (path == null) return null;
    return SharedPdf(_importedPdfName ?? 'document.pdf', _pdfSha256 ?? '', _totalPages, await File(path).readAsBytes());
  }

  /// Takes part in the session of this note, if there is one (it was started here before, or this note was made by joining one).
  void _bindLive() {
    final session = widget.collab?.sessionFor(widget.noteId);
    if (session == null || session.state == SessionState.ended || identical(session, _live)) return;
    _live?.removeListener(_liveChanged); // (a session that took the place of one whose host left)
    _live = session;
    session.addListener(_liveChanged);
    session.attach(_collabBinding());
  }

  Future<void> _startLive([SessionInvite? invite, HostTransport? transport, bool trustAll = false]) async {
    final session = await widget.collab!.startHosting(widget.noteId, _collabBinding(), title: _titleController.text, invite: invite, transport: transport, trustAll: trustAll);
    if (!identical(session, _live)) {
      _live?.removeListener(_liveChanged);
      _live = session;
      session.addListener(_liveChanged);
    }
    if (mounted) setState(() {});
  }

  void _liveChanged() {
    if (!mounted) return;
    final s = _live;
    if (s != null && s.state == SessionState.ended && _lastLiveState != SessionState.ended && !s.handedOver) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.endReason ?? 'The live session ended')));
    }
    _lastLiveState = s?.state;
    setState(() {});
    // someone new does not know the page yet (every message is sealed, so they are not sent for nothing)
    final people = s?.participants.length ?? 0;
    if (people != _announcedPeople) {
      _announcedPeople = people;
      _announceView(force: true);
    }
  }

  /// Lets go of the session when the editor goes away: it carries on with the note as it was saved.
  void _releaseLive() {
    final s = _live;
    if (s == null) return;
    s.removeListener(_liveChanged);
    if (s.state == SessionState.ended) return;
    s.suspend();
    _saveNow().whenComplete(() async {
      final saved = await widget.repository.loadNote(widget.noteId);
      if (saved != null) s.detach(saved);
    });
  }

  Future<void> _openLivePanel() => showDialog<void>(
        context: context,
        builder: (context) => LivePanel(service: widget.collab!, noteId: widget.noteId, onStart: _startLive, onBeforeShare: _saveNow, onShowPage: (p) {
          Navigator.pop(context);
          _jumpToPage(p);
        }),
      );

  /// Tells the others which page is in view here (when it changed, or with [force]).
  void _announceView({bool force = false}) {
    final session = _live;
    if (session == null || session.state != SessionState.live || !_pageScroll.hasClients) return;
    final ( page, scrolled) = _visiblePage();
    final sheet = _sheetInView(page, scrolled);
    if (!force && page == _announcedPage && sheet == _announcedSheet) return;
    _announcedPage = page;
    _announcedSheet = sheet;
    session.announcePage(page, sheet: sheet);
  }

  /// Which sheet of page [page] is in view when the screen starts [scrolled] down it: only the written document is shown as several
  /// sheets, any other page is one. The same rule as [_visiblePage]: the first one more than 100 pixels of which are still on screen.
  int _sheetInView(int page, double scrolled) {
    final sheets = _isDocumentPage(page) ? _sheetsOfDocument : 1;
    var k = 0;
    while (k < sheets - 1 &&
        (k + 1) * basePageHeight + k * _FixedPageNoteEditorState._sheetGap <=
            scrolled + 100 / _pageScale) {
      k++;
    }
    return k;
  }

  /// [page], framed in the colour of each person who has it in view. A page shown as several sheets has the frame around the sheet the
  /// person is on, not around all of them. Always the same widget around the page, framed or not (see [PresenceFrame]).
  Widget _presenceFrame(int index, Widget page) {
    final session = _live;
    final viewers = [for (final v in viewersOf(session)) if (v.page == index) v,];
    final sheets = _isDocumentPage(index) ? _sheetsOfDocument : 1;
    final List<PresenceRegion> frames;
    if (viewers.isEmpty) {
      frames = const [];
    } else if (sheets <= 1) {
      frames = [
        (viewers: [for (final v in viewers) v.who], top: 0.0, height: null),
      ];
    } else {
      final bySheet = <int, List<Participant>>{};
      for (final v in viewers) {
        bySheet.putIfAbsent(v.sheet.clamp(0, sheets - 1), () => []).add(v.who);
      }
      frames = [
        for (final e in bySheet.entries)
          (
            viewers: e.value,
            top:
                e.key *
                (basePageHeight + _FixedPageNoteEditorState._sheetGap) *
                _pageScale,
            height: basePageHeight * _pageScale,
          ),
      ];
    }
    return PresenceFrame(
      frames: frames, everyone: session?.participants ?? const [], bottomGap: 24 * _pageScale, child: page);
  }

  /// Dots beside the page scrollbar: who is on which of its stops (each sheet of the written document is one, see [_scrollStops]).
  List<({int page, Color color, String label})> _presenceMarkers() {
    final session = _live;
    final sheets = _sheetsOfDocument;
    return [
      for (final v in viewersOf(session)) (page: v.page == 0
              ? (_isDocumentPage(0) ? v.sheet.clamp(0, sheets - 1) : 0)
              : v.page + sheets - 1, color: presenceColor(v.who.site), label: Participant.labelOf(v.who, session!.participants)),
    ];
  }

  /// The button for it in the top bar: shows how many are in the session.
  Widget _liveButton() {
    final live = _live != null && _live!.state != SessionState.ended;
    final count = live ? _live!.participants.length : 0;
    return IconButton(
      key: const ValueKey('live-button'),
      tooltip: tr(live ? tr('Live session: {n} here', {'n': count}) : tr('Work on this note together, live')),
      icon: Stack(clipBehavior: Clip.none, children: [
        Badge(
          isLabelVisible: live && count > 1,
          label: Text('$count'),
          child: Icon(live ? Icons.group : Icons.group_add_outlined, size: 20, color: live ? Theme.of(context).colorScheme.primary : null),
        ),
        // (a link that is not good: seen without opening the panel; nothing while all is well)
        if (live) Positioned(left: -2, bottom: -1, child: LinkDot(band: _live!.linkBand)),
      ]),
      onPressed: _openLivePanel,
    );
  }
}
