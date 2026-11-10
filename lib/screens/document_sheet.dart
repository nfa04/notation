import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import '../block_editor/block_editor.dart';
import '../l10n/language.dart';

import '../markdown/html_import.dart';
import '../markdown/live_markdown.dart';
import '../markdown/markdown_formatting.dart';
import '../markdown/markdown_parser.dart' show MdRun;
import '../markdown/markdown_view.dart';
import '../models/page_background.dart';
import '../models/rich_text.dart';
import '../painters/canvas_painters.dart';
import '../spelling/spell_menu.dart';
import '../spelling/spell_service.dart';

/// The written document: one flowing text instead of items placed on fixed pages, written the way it looks (see
/// [LiveMarkdownController]). With a controller that is not a [LiveMarkdownController], or not [editing], it is only shown.
class DocumentSheet extends StatefulWidget {
  final RichInlineTextController controller;
  final bool editing;
  final double width;
  final double minHeight;
  final PageBackground background;
  final double marginLeft;
  final double marginRight;
  final double marginTop;
  final double marginBottom;

  /// The menu on highlighted text (the editor adds "Calculate" to it).
  final BlockMenuBuilder? menuBuilder;

  /// The handles of a selection, when the sheet is drawn scaled (see selectionControlsAtZoom).
  final TextSelectionControls? selectionControls;

  /// Spell checking: a tap on a misspelled word offers what it may have been meant to be; null: none.
  final SpellService? spell;

  /// Called with the target of a tapped link.
  final ValueChanged<String>? onLink;

  /// Called with the citation that was tapped, to change it.
  final ValueChanged<MdRun>? onCitation;

  /// The height of a sheet of the paper: while the document is written, it goes on from one sheet to the next. Null: one long sheet.
  final double? pageHeight;

  /// The space between two sheets.
  final double sheetGap;

  /// Told how many sheets the text is on while it is written.
  final ValueChanged<int>? onSheets;

  /// The key of the editor, for what goes to a place in the text.
  final GlobalKey<BlockEditorState>? blocksKey;

  /// Takes a picture the keyboard puts in (a sticker, a GIF).
  final Future<void> Function(KeyboardInsertedContent content)? onContent;

  static const double fontSize = 16;

  const DocumentSheet({
    super.key,
    required this.controller,
    this.editing = true,
    required this.width,
    required this.minHeight,
    this.background = PageBackground.blank,
    this.marginLeft = 56,
    this.marginRight = 56,
    this.marginTop = 56,
    this.marginBottom = 56,
    this.menuBuilder,
    this.selectionControls,
    this.onLink,
    this.onCitation,
    this.spell,
    this.pageHeight,
    this.sheetGap = 24,
    this.onSheets,
    this.blocksKey,
    this.onContent,
  });

  @override
  State<DocumentSheet> createState() => _DocumentSheetState();
}

class _DocumentSheetState extends State<DocumentSheet> {
  final FocusNode _focus = FocusNode(debugLabel: 'document');
  late final GlobalKey<BlockEditorState> _blocksKey = widget.blocksKey ?? GlobalKey();

  /// How many sheets of paper the text is on.
  int _blockSheets = 1;

  /// Goes up when what the document cites may have changed.
  final ValueNotifier<int> _citations = ValueNotifier(0);

  /// What is built of the document, down from its top.
  final ValueNotifier<(double, double)> _nearby = ValueNotifier((0, 4000));

  LiveMarkdownController? get _live {
    final c = widget.controller;
    return widget.editing && c is LiveMarkdownController ? c : null;
  }

  /// Until then a caret that is not on the screen is not scrolled to: the text takes the focus by itself when document mode opens,
  /// and the page must not run off to wherever the caret was left.
  DateTime _quietUntil = DateTime.now().add(const Duration(milliseconds: 800));

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(DocumentSheet old) {
    super.didUpdateWidget(old);
    if (old.editing != widget.editing) _quietUntil = DateTime.now().add(const Duration(milliseconds: 800));
  }

  void _focusChanged() => scheduleMicrotask(() {
        if (mounted) _live?.revealing = _focus.hasFocus;
      });

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _citations.dispose();
    _nearby.dispose();
    super.dispose();
  }

  /// A change made by a shortcut: set directly (it is not typing, so it is not a tracked change).
  void _edit(TextEditingValue Function(TextEditingValue) change) {
    final c = widget.controller;
    c is LiveMarkdownController ? c.setDirectly(change(c.value)) : c.value = change(c.value);
  }

  /// A list item goes one step deeper or out; elsewhere Tab writes a tab.
  void _tab(bool back) {
    final c = widget.controller;
    final nested = nestListItems(c.value, deeper: !back);
    if (nested != null) {
      _edit((_) => nested);
    } else if (!back) {
      final s = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
      c.value = TextEditingValue(text: c.text.replaceRange(s.start, s.end, '\t'), selection: TextSelection.collapsed(offset: s.start + 1));
    }
  }

  /// One size step bigger or smaller for the selection.
  void _size(bool bigger) {
    const steps = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48, 72];
    final c = widget.controller;
    final s = c.selection;
    if (!s.isValid) return;
    final now = double.tryParse(c.attributeAt(AttributeType.size, s.isCollapsed ? s.start : s.start + 1)?.value ?? '') ?? documentPointSize;
    final next = bigger ? steps.firstWhere((x) => x > now, orElse: () => steps.last) : steps.lastWhere((x) => x < now, orElse: () => steps.first);
    c.setAttribute(AttributeType.size, next == documentPointSize ? null : '$next');
  }

  void _align(String align) => _edit((v) => changeParagraphFormat(v, (f) => f.copyWith(align: align)));

  /// Pastes what is on the clipboard: formatted text (HTML from a web page or another program) with its formatting, unless
  /// [plain]; else its text.
  Future<void> _paste({bool plain = false}) async {
    final c = widget.controller;
    String? html;
    if (!plain) {
      try {
        html = await Pasteboard.html;
      } catch (_) {
        html = null; // (not on this platform)
      }
    }
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    if (html != null && html.trim().isNotEmpty) {
      final read = importHtml(html);
      if (read.text.isNotEmpty) {
        final start = sel.start;
        _edit((v) => insertText(v, read.text));
        c.attributes.addAll([for (final s in read.spans) s.moved(s.start + start, s.end + start)]);
        c.attributesChanged();
        return;
      }
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return;
    c.value = insertText(c.value.copyWith(selection: sel), text);
  }

  Map<ShortcutActivator, VoidCallback> get _keys => {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => unawaited(_paste()),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () => unawaited(_paste()),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): () => unawaited(_paste(plain: true)),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true, shift: true): () => unawaited(_paste(plain: true)),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => _edit((v) => toggleInline(v, '**')),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () => _edit((v) => toggleInline(v, '**')),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () => _edit((v) => toggleInline(v, '*')),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () => _edit((v) => toggleInline(v, '*')),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () => widget.controller.toggleAttribute(AttributeType.underline),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true): () => widget.controller.toggleAttribute(AttributeType.underline),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () => _align('left'),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () => _align('center'),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () => _align('right'),
        const SingleActivator(LogicalKeyboardKey.period, control: true, shift: true): () => _size(true),
        const SingleActivator(LogicalKeyboardKey.comma, control: true, shift: true): () => _size(false),
        const SingleActivator(LogicalKeyboardKey.digit7, control: true, shift: true): () => _edit((v) => toggleLineStyle(v, LineStyle.numbered)),
        const SingleActivator(LogicalKeyboardKey.digit8, control: true, shift: true): () => _edit((v) => toggleLineStyle(v, LineStyle.bullet)),
        const SingleActivator(LogicalKeyboardKey.digit9, control: true, shift: true): () => _edit((v) => toggleLineStyle(v, LineStyle.task)),
        const SingleActivator(LogicalKeyboardKey.backslash, control: true): () {
          _edit(clearInlineMarkdown);
          widget.controller.clearAttributes();
        },
        for (final (key, style) in const [
          (LogicalKeyboardKey.digit0, null),
          (LogicalKeyboardKey.digit1, LineStyle.heading1),
          (LogicalKeyboardKey.digit2, LineStyle.heading2),
          (LogicalKeyboardKey.digit3, LineStyle.heading3),
          (LogicalKeyboardKey.digit4, LineStyle.heading4),
          (LogicalKeyboardKey.digit5, LineStyle.heading5),
          (LogicalKeyboardKey.digit6, LineStyle.heading6),
        ])
          SingleActivator(key, control: true, alt: true): () => _edit((v) => setLineStyle(v, style)),
        const SingleActivator(LogicalKeyboardKey.tab): () => _tab(false),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true): () => _tab(true),
      };

  /// The text got taller or shorter: how many sheets it is on.
  void _shapeChanged() {
    final blocks = _blocksKey.currentState;
    if (!mounted || blocks == null || blocks.sheetCount == _blockSheets) return;
    setState(() => _blockSheets = blocks.sheetCount);
    widget.onSheets?.call(_blockSheets);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    // (while it is written, each sheet is a page of its own, a space below the one before)
    final sheets = _live != null && w.pageHeight != null ? _blockSheets : 1;
    final one = sheets == 1;
    final tall = w.pageHeight ?? w.minHeight;
    return Container(
      width: w.width,
      constraints: BoxConstraints(minHeight: one ? w.minHeight : (sheets - 1) * (tall + w.sheetGap) + tall),
      decoration: one
          ? BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 16, offset: const Offset(0, 4))],
            )
          : null,
      child: Stack(clipBehavior: Clip.none, children: [
        if (one)
          Positioned.fill(child: CustomPaint(painter: PageBackgroundPainter(w.background)))
        else
          Positioned.fill(
            child: RepaintBoundary(
              // (only the sheets near the screen: a document can have hundreds of them)
              child: ValueListenableBuilder(
                valueListenable: _nearby,
                builder: (context, near, _) {
                  final step = tall + w.sheetGap;
                  return Stack(clipBehavior: Clip.none, children: [
                    for (var k = math.max(0, (near.$1 / step).floor() - 1); k < sheets && k * step <= near.$2 + step; k++)
                      Positioned(key: ValueKey('write-sheet-$k'), left: 0, right: 0, top: k * step, height: tall, child: _paper()),
                  ]);
                },
              ),
            ),
          ),
        Padding(padding: EdgeInsets.fromLTRB(w.marginLeft, w.marginTop, w.marginRight, w.marginBottom), child: _QuietReveal(quiet: () => DateTime.now().isBefore(_quietUntil), child: _content())),
      ]),
    );
  }

  Widget _paper() => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 16, offset: const Offset(0, 4))],
        ),
        child: CustomPaint(painter: PageBackgroundPainter(widget.background)),
      );

  Widget _content() {
    final live = _live;
    if (live == null) {
      return LiveMarkdownView(
        controller: widget.controller,
        fontSize: DocumentSheet.fontSize,
        actions: LiveMarkdownActions(onLink: widget.onLink, onCitation: widget.onCitation),
      );
    }
    live
      ..onLink = widget.onLink
      ..onCitation = widget.onCitation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CallbackShortcuts(
          bindings: _keys,
          child: SpellTapRegion(
            controller: live,
            service: widget.spell,
            wordRect: (range) => _blocksKey.currentState?.screenRectOf(range),
            child: BlockEditor(
              key: _blocksKey,
              controller: live,
              focusNode: _focus,
              style: documentTextStyle(DocumentSheet.fontSize),
              width: widget.width - widget.marginLeft - widget.marginRight,
              autofocus: true,
              hint: tr('Start writing...'),
              onPaste: _paste,
              onContent: widget.onContent,
              menuBuilder: widget.menuBuilder,
              selectionControls: widget.selectionControls,
              onShape: _shapeChanged,
              othersChanged: _citations,
              nearby: _nearby,
              sheets: widget.pageHeight == null || widget.pageHeight! - widget.marginTop - widget.marginBottom < 50
                  ? null
                  : (room: widget.pageHeight! - widget.marginTop - widget.marginBottom, step: widget.pageHeight! + widget.sheetGap),
            ),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: _citations,
          builder: (context, _, _) => ReferenceList(text: live.text, fontSize: DocumentSheet.fontSize, appended: true),
        ),
      ],
    );
  }
}

/// Passes on no request to bring something under it onto the screen (the caret of the text, when it takes the focus) while [quiet].
class _QuietReveal extends SingleChildRenderObjectWidget {
  final bool Function() quiet;
  const _QuietReveal({required this.quiet, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderQuietReveal(quiet);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderQuietReveal).quiet = quiet;
}

class _RenderQuietReveal extends RenderProxyBox {
  _RenderQuietReveal(this.quiet);
  bool Function() quiet;

  @override
  void showOnScreen({RenderObject? descendant, Rect? rect, Duration duration = Duration.zero, Curve curve = Curves.ease}) {
    if (quiet()) return;
    super.showOnScreen(descendant: descendant, rect: rect, duration: duration, curve: curve);
  }
}
