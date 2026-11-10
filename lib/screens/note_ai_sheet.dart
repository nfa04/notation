import 'dart:async';
import 'dart:ui' as ui;

import '../export/file_dialogs.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import 'add_to_note.dart';
import '../ai/note_ai.dart';
import '../ai/text_provider.dart';
import '../data/note_data.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// What the AI can make of the whole note, listed: made once, kept with the note, shown from then on (made again on request).
/// [prepare] runs before something is made, to have the note as it is now in the database. [onAddText] puts a text on the note,
/// [onAddTask] adds a task to the calendar.
Future<void> showNoteAiSheet(
  BuildContext context, {
  required NoteAi noteAi,
  required String noteId,
  required String title,
  NoteAiKind? initial,
  required Future<void> Function() prepare,
  AddToNote? onAddText,
  Future<void> Function(String title, DateTime? due)? onAddTask,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
          child: _NoteAiSheet(noteAi: noteAi, noteId: noteId, title: title, initial: initial, prepare: prepare, onAddText: onAddText, onAddTask: onAddTask),
        ),
      ),
    );

class _NoteAiSheet extends StatefulWidget {
  final NoteAi noteAi;
  final String noteId, title;

  /// Shown (or made) at once instead of the list.
  final NoteAiKind? initial;
  final Future<void> Function() prepare;
  final AddToNote? onAddText;
  final Future<void> Function(String title, DateTime? due)? onAddTask;

  const _NoteAiSheet({required this.noteAi, required this.noteId, required this.title, this.initial, required this.prepare, this.onAddText, this.onAddTask});

  @override
  State<_NoteAiSheet> createState() => _NoteAiSheetState();
}

class _NoteAiSheetState extends State<_NoteAiSheet> {
  final Map<NoteAiKind, NoteAiRow?> _rows = {};
  final Map<NoteAiKind, bool> _stale = {};
  NoteAiKind? _working;
  String _partial = '';
  AiCancel? _cancel;
  String? _problem;
  NoteAiKind? _open;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final k in NoteAiKind.values) {
      final row = await widget.noteAi.saved(widget.noteId, k);
      _rows[k] = row;
      _stale[k] = row != null && await widget.noteAi.isStale(row);
    }
    if (!mounted) return;
    setState(() {});
    final first = widget.initial;
    if (first != null && !_started) {
      _started = true;
      if (_rows[first] != null) {
        setState(() => _open = first);
      } else {
        _make(first);
      }
    }
  }

  bool _started = false;

  Future<void> _make(NoteAiKind kind, {bool again = false}) async {
    if (_working != null) return;
    final provider = widget.noteAi.ai.provider;
    if (provider == null || provider.state != ProviderState.ready) {
      setState(() => _problem = provider?.reason ?? tr('The AI is not ready: choose and download a model in the Settings.'));
      return;
    }
    final cancel = _cancel = AiCancel();
    setState(() {
      _working = kind;
      _partial = '';
      _problem = null;
    });
    try {
      await widget.prepare();
      final row = await widget.noteAi.get(widget.noteId, kind, again: again, cancel: cancel, onPartial: (p) {
        if (mounted) setState(() => _partial = p);
      });
      _rows[kind] = row;
      _stale[kind] = false;
      if (mounted) setState(() => _open = kind);
    } catch (e) {
      if (mounted) setState(() => _problem = '$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('just now');
    if (d.inMinutes < 60) return tr('{n} mins ago', {'n': d.inMinutes});
    if (d.inHours < 24) return tr('{n} hours ago', {'n': d.inHours});
    return tr('{n} days ago', {'n': d.inDays});
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null && _rows[open] != null) {
      return _Viewer(
        kind: open,
        row: _rows[open]!,
        title: widget.title,
        onBack: () => setState(() => _open = null),
        onAgain: () {
          setState(() => _open = null);
          _make(open, again: true);
        },
        onAddText: widget.onAddText,
        onAddTask: widget.onAddTask,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(children: [
          const Icon(Icons.auto_awesome, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('What the AI can make of this note', style: Theme.of(context).textTheme.titleSmall)),
          IconButton(key: const ValueKey('note-ai-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ]),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'It is made once and kept with the note (it is in the note file too). Make it again when the note has changed.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      ),
      if (_problem != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text.verbatim(_problem!, key: const ValueKey('note-ai-problem'), style: TextStyle(color: scheme.error)),
        ),
      Expanded(
        child: ListView(children: [
          for (final kind in NoteAiKind.values) _tile(kind),
          if (_working != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)),
                  const SizedBox(width: 8),
                  Expanded(child: Text.verbatim(tr('Writing: {what}', {'what': tr(_working!.label)}))),
                  TextButton(key: const ValueKey('note-ai-stop'), onPressed: _cancel?.cancel, child: const Text('Stop')),
                ]),
                if (_partial.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SelectableText(_partial, key: const ValueKey('note-ai-streaming')), // (read while it is written)
                  ),
              ]),
            ),
        ]),
      ),
    ]);
  }

  Widget _tile(NoteAiKind kind) {
    final row = _rows[kind];
    final stale = _stale[kind] ?? false;
    final busy = _working != null;
    return ListTile(
      key: ValueKey('note-ai-${kind.id}'),
      leading: Icon(switch (kind) {
        NoteAiKind.summary => Icons.short_text,
        NoteAiKind.presentation => Icons.slideshow_outlined,
        NoteAiKind.studyGuide => Icons.menu_book_outlined,
        NoteAiKind.quiz => Icons.quiz_outlined,
        NoteAiKind.actions => Icons.checklist,
      }),
      title: Text(kind.label),
      subtitle: Text.verbatim(row == null ? tr(kind.description) : '${tr('Made')} ${_ago(row.createdAt)}${stale ? ' - ${tr('the note has changed since')}' : ''}'),
      trailing: row == null
          ? FilledButton.tonal(key: ValueKey('note-ai-make-${kind.id}'), onPressed: busy ? null : () => _make(kind), child: const Text('Make'))
          : PopupMenuButton<String>(
              key: ValueKey('note-ai-menu-${kind.id}'),
              enabled: !busy,
              tooltip: tr('More'),
              onSelected: (v) async {
                if (v == 'again') {
                  _make(kind, again: true);
                } else {
                  await widget.noteAi.delete(widget.noteId, kind);
                  await _refresh();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'again', child: Text('Make it again')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
      onTap: row == null || busy ? null : () => setState(() => _open = kind),
    );
  }
}

// ---- the viewers ----------------------------------------------------------------------

class _Viewer extends StatelessWidget {
  final NoteAiKind kind;
  final NoteAiRow row;
  final String title;
  final VoidCallback onBack, onAgain;
  final AddToNote? onAddText;
  final Future<void> Function(String title, DateTime? due)? onAddTask;

  const _Viewer({required this.kind, required this.row, required this.title, required this.onBack, required this.onAgain, this.onAddText, this.onAddTask});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Row(children: [
          IconButton(key: const ValueKey('note-ai-back'), tooltip: tr('Back'), icon: const Icon(Icons.arrow_back), onPressed: onBack),
          Expanded(child: Text(kind.label, style: Theme.of(context).textTheme.titleSmall)),
          TextButton.icon(key: const ValueKey('note-ai-again'), onPressed: onAgain, icon: const Icon(Icons.refresh, size: 18), label: const Text('Make it again')),
          IconButton(tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: switch (kind) {
          NoteAiKind.presentation => _SlidesView(presentation: parseSlides(row.content), fileName: title),
          NoteAiKind.quiz => _QuizView(questions: parseQuiz(row.content)),
          NoteAiKind.actions => _ActionsView(items: parseActions(row.content), onAddTask: onAddTask),
          _ => _TextView(text: row.content, title: kind.label, onAddText: onAddText),
        },
      ),
    ]);
  }
}

class _TextView extends StatelessWidget {
  final String text;

  /// What it is (Summary, Study guide): the heading it gets when it is put in the written document.
  final String title;
  final AddToNote? onAddText;
  const _TextView({required this.text, required this.title, this.onAddText});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(text, key: const ValueKey('note-ai-text')))),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: text)), icon: const Icon(Icons.copy, size: 18), label: const Text('Copy')),
          if (onAddText != null)
            AddToNoteMenu(
              canKeep: false, // (it is kept already, in the list of what was made)
              buttonKey: const ValueKey('note-ai-add-text'),
              onSelected: (target) {
                Navigator.pop(context);
                // (when the dialog has left: the page below is not changed while it is going)
                WidgetsBinding.instance.addPostFrameCallback((_) => onAddText!(text, target, title: title));
              },
              child: const Chip(avatar: Icon(Icons.note_add_outlined, size: 18), label: Text('Add to the note')),
            ),
        ]),
      ),
    ]);
  }
}

class _SlidesView extends StatefulWidget {
  final Presentation presentation;
  final String fileName;
  const _SlidesView({required this.presentation, required this.fileName});

  @override
  State<_SlidesView> createState() => _SlidesViewState();
}

class _SlidesViewState extends State<_SlidesView> {
  final _controller = PageController();
  int _page = 0;
  bool _exporting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final bytes = await slidesToPdf(widget.presentation);
      final name = '${widget.fileName.trim().isEmpty ? 'Presentation' : widget.fileName.trim()}.pdf';
      final path = await saveWithDialog(dialogTitle: tr('Export PDF'), fileName: name, extension: 'pdf', bytes: bytes);
      if (path != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Successfully exported to {path}', {'path': path}))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context,).showSnackBar(SnackBar(content: Text.verbatim('$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.presentation.slides;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Expanded(
        child: PageView(
          key: const ValueKey('slides'),
          controller: _controller,
          onPageChanged: (i) => setState(() => _page = i),
          children: [
            for (var i = 0; i < slides.length; i++)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      key: ValueKey('slide-$i'),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: scheme.outlineVariant)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text.verbatim(slides[i].title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87)),
                        const SizedBox(height: 12),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              for (final b in slides[i].bullets)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    const Text.verbatim('•  ', style: TextStyle(color: Colors.black87)),
                                    Expanded(child: Text.verbatim(b, style: const TextStyle(fontSize: 16, color: Colors.black87))),
                                  ]),
                                ),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  if (slides[i].notes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text.verbatim(slides[i].notes, style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
                    ),
                ]),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          IconButton(key: const ValueKey('slide-prev'), tooltip: tr('Previous'), icon: const Icon(Icons.chevron_left), onPressed: _page == 0 ? null : () => _controller.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut)),
          Text.verbatim('${_page + 1} / ${slides.length}'),
          IconButton(key: const ValueKey('slide-next'), tooltip: tr('Next'), icon: const Icon(Icons.chevron_right), onPressed: _page >= slides.length - 1 ? null : () => _controller.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut)),
          const Spacer(),
          FilledButton.tonalIcon(
            key: const ValueKey('slides-export'),
            onPressed: _exporting ? null : _export,
            icon: _exporting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)) : const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('Export as PDF'),
          ),
        ]),
      ),
    ]);
  }
}

/// The slides as a PDF, one landscape page each. The slides are drawn as pictures, so that any script of the text shows.
Future<Uint8List> slidesToPdf(Presentation presentation) async {
  final document = pw.Document(title: presentation.title);
  final slides = presentation.slides;
  for (var i = 0; i < slides.length; i++) {
    final png = await renderSlide(slides[i], i == 0 ? presentation.title : null, i + 1, slides.length);
    document.addPage(pw.Page(
      pageFormat: const pdf.PdfPageFormat(960, 540),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
    ));
  }
  return document.save();
}

/// One slide as a PNG, 1920 x 1080.
Future<Uint8List> renderSlide(Slide slide, String? deckTitle, int number, int count) async {
  const w = 1920.0, h = 1080.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 24, h), Paint()..color = const Color(0xFF3F51B5));
  double y = 90;
  final head = TextPainter(
    text: TextSpan(text: slide.title, style: const TextStyle(color: Colors.black87, fontSize: 76, fontWeight: FontWeight.bold)),
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: w - 220);
  head.paint(canvas, Offset(110, y));
  y += head.height + 50;
  for (final b in slide.bullets) {
    if (y > h - 120) break;
    final p = TextPainter(
      text: TextSpan(text: b, style: const TextStyle(color: Colors.black87, fontSize: 50, height: 1.25)),
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: w - 300);
    canvas.drawCircle(Offset(130, y + 34), 9, Paint()..color = const Color(0xFF3F51B5));
    p.paint(canvas, Offset(170, y));
    y += p.height + 26;
  }
  final foot = TextPainter(
    text: TextSpan(text: '$number / $count', style: const TextStyle(color: Colors.black45, fontSize: 32)),
    textDirection: TextDirection.ltr,
  )..layout();
  foot.paint(canvas, Offset(w - foot.width - 50, h - 70));
  final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

class _QuizView extends StatefulWidget {
  final List<QuizQuestion> questions;
  const _QuizView({required this.questions});

  @override
  State<_QuizView> createState() => _QuizViewState();
}

class _QuizViewState extends State<_QuizView> {
  int _i = 0;
  int? _chosen;
  int _right = 0;
  bool _done = false;

  void _again() => setState(() {
        _i = 0;
        _chosen = null;
        _right = 0;
        _done = false;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_done) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text.verbatim(tr('{right} of {total} right', {'right': _right, 'total': widget.questions.length}), key: const ValueKey('quiz-score'), style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          FilledButton(key: const ValueKey('quiz-again'), onPressed: _again, child: const Text('Try again')),
        ]),
      );
    }
    final q = widget.questions[_i];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.verbatim(tr('Question {n} of {total}', {'n': _i + 1, 'total': widget.questions.length}), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
        const SizedBox(height: 8),
        Text.verbatim(q.question, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(children: [
            for (var c = 0; c < q.choices.length; c++)
              Card(
                key: ValueKey('quiz-choice-$c'),
                color: _chosen == null
                    ? null
                    : c == q.answer
                        ? Colors.green.withValues(alpha: 0.25)
                        : c == _chosen
                            ? Colors.red.withValues(alpha: 0.2)
                            : null,
                child: ListTile(
                  leading: Text.verbatim(String.fromCharCode(65 + c), style: const TextStyle(fontWeight: FontWeight.bold)),
                  title: Text.verbatim(q.choices[c]),
                  onTap: _chosen != null
                      ? null
                      : () => setState(() {
                            _chosen = c;
                            if (c == q.answer) _right++;
                          }),
                ),
              ),
            if (_chosen != null && q.why.isNotEmpty)
              Padding(padding: const EdgeInsets.all(8), child: Text.verbatim(q.why, key: const ValueKey('quiz-why'), style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant))),
          ]),
        ),
        if (_chosen != null)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('quiz-next'),
              onPressed: () => setState(() {
                if (_i + 1 >= widget.questions.length) {
                  _done = true;
                } else {
                  _i++;
                  _chosen = null;
                }
              }),
              child: Text(_i + 1 >= widget.questions.length ? 'Finish' : 'Next'),
            ),
          ),
      ]),
    );
  }
}

class _ActionsView extends StatefulWidget {
  final List<ActionItem> items;
  final Future<void> Function(String title, DateTime? due)? onAddTask;
  const _ActionsView({required this.items, this.onAddTask});

  @override
  State<_ActionsView> createState() => _ActionsViewState();
}

class _ActionsViewState extends State<_ActionsView> {
  late final Set<int> _picked = {for (var i = 0; i < widget.items.length; i++) i};
  final Set<int> _added = {};

  static String _day(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  Future<void> _addAll() async {
    for (final i in _picked.toList()) {
      if (_added.contains(i)) continue;
      await widget.onAddTask!(widget.items[i].title, widget.items[i].due);
      _added.add(i);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const Center(child: Text('The note has no tasks in it.', key: ValueKey('actions-none')));
    return Column(children: [
      Expanded(
        child: ListView(children: [
          for (var i = 0; i < widget.items.length; i++)
            CheckboxListTile.adaptive(
              key: ValueKey('action-$i'),
              value: _picked.contains(i),
              onChanged: _added.contains(i) ? null : (v) => setState(() => v == true ? _picked.add(i) : _picked.remove(i)),
              title: Text.verbatim(widget.items[i].title),
              subtitle: Text.verbatim(_added.contains(i) ? tr('Added to the calendar') : (widget.items[i].due == null ? tr('No day') : _day(widget.items[i].due!))),
            ),
        ]),
      ),
      if (widget.onAddTask != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey('actions-add'),
              onPressed: _picked.difference(_added).isEmpty ? null : _addAll,
              icon: const Icon(Icons.event_available_outlined, size: 18),
              label: const Text('Add to the calendar'),
            ),
          ),
        ),
    ]);
  }
}
