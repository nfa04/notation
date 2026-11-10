part of 'fixed_page_note_editor.dart';

/// Presenting the note: its pages one at a time, full screen.
extension _EditorPresent on _FixedPageNoteEditorState {
  Widget _presentButton() => IconButton(
        key: const ValueKey('present-note'),
        tooltip: tr('Present the note, page by page'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.slideshow_outlined, size: 20),
        onPressed: _present,
      );

  /// The button that plays the pages as a flipbook: the same screen as a presentation, but the pages follow each other by themselves.
  Widget _flipbookButton() => IconButton(
        key: const ValueKey('flipbook-note'),
        tooltip: tr('Play the pages as a flipbook'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.movie_filter_outlined, size: 20),
        onPressed: () => _present(flipbook: true),
      );

  /// Page [index] as it is shown in a presentation: the page itself, whatever the editor is doing.
  Widget _presentedPage(int index) {
    if (_isBlank || _nativePages.contains(index)) return index == 0 && _hasDocument ? _buildDocumentEditorPage() : _buildPageTile(index, null);
    return _BuiltPage(
      index: index,
      onShown: _pageBuilt,
      child: FutureBuilder<PdfPageData>(
        future: _getOrLoadPage(index),
        builder: (context, snapshot) => snapshot.hasData
            ? _buildPageTile(index, snapshot.data!)
            : SizedBox(width: _paperWidth, height: _heightOf(index), child: const _PageSpinner()),
      ),
    );
  }

  Future<void> _present({bool flipbook = false}) async {
    await ready;
    if (!mounted || _pageCount == 0 || _presenting) return;
    final from = _visiblePage().$1.clamp(0, _pageCount - 1);
    var last = from;
    _clearSelection();
    // the pages of the editor are taken away first: the page widgets hold keys that only one place may use
    setState(() {
      _activeSelectedBox = null;
      _presenting = true;
    });
    final immersive = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (immersive) await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await Navigator.of(context).push(PageRouteBuilder<void>(
        opaque: true,
        // no fade: the pages must be gone from this route before the editor draws its own again (they use the same keys)
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (route, _, _) => PresentationView(
          pageCount: _pageCount,
          initialPage: from,
          pageSize: (i) => Size(_paperWidth, _heightOf(i)),
          pageBuilder: (context, i) => _presentedPage(i),
          onPageChanged: (i) => last = i,
          onClose: () => Navigator.of(route).pop(),
          flipbook: flipbook,
        ),
      ));
      // the presentation is out of the tree after a frame or two
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (immersive) await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (mounted) {
        setState(() => _presenting = false);
        // the editor comes back at the page that was shown last
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpToPage(last);
        });
      }
    }
  }
}
