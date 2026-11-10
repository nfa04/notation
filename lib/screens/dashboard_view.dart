import '../web/picked_file.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../data/pdf_note.dart';
import '../l10n/language.dart';

import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import '../previews/note_preview.dart';
import '../speech/speech_to_text.dart';
import 'speech_recorder.dart';
import 'sync_now_button.dart';
import '../devicesync/device_sync_service.dart';
import '../cloudsync/cloud_sync_service.dart';

import '../automations/automation_service.dart';
import '../data/note_data.dart';
import '../review/study_planner.dart';
import 'ask_card.dart';
import '../data/note_file_service.dart';
import '../data/note_repository.dart';
import '../collab/collab_service.dart';
import '../collab/shared_notes.dart';
import '../data/debounced_changes.dart';
import 'bulk_note_actions.dart';
import 'review_view.dart';
import 'reminders_screen.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import '../capture/capture_service.dart';
import '../data/audio_repository.dart';
import 'capture_dialogs.dart';
import '../review/weekly_review_service.dart';
import 'weekly_review_dialog.dart';
import '../data/card_repository.dart';
import 'note_file_actions.dart';
import 'template_picker.dart';
import '../templates/templates.dart';
import 'shared_badge.dart';
import 'share_people.dart';
import '../style/platform_dialog.dart';

/// The first screen: recent and starred notes, tasks, and the buttons that make a note (blank, from a PDF, a template,
/// a recording) or ask the assistant about all notes.
class DashboardView extends StatefulWidget {
  final NoteRepository repository;
  final ValueChanged<String> onOpenNote;
  final NoteFileService? noteFiles;

  /// Notes from templates; null hides the buttons.
  final TemplateService? templates;

  /// Asks for an invite link and joins its live session; null hides the button.
  final VoidCallback? onJoinSession;

  /// The sync of the devices of the profile, for the "Sync now" button on top.
  final DeviceSyncService? sync;

  /// Tells which notes are shared (a group symbol on them); null: none is.
  final CollabService? collab;

  /// Small pictures of the first page, drawn faintly on the cards; null: none.
  final NotePreviews? previews;

  /// Writes down what is said (a meeting is recorded into a note); null hides the button.
  final SpeechToText? speech;

  /// Flashcards kept for spaced repetition; null hides the review button.
  final CardRepository? cards;

  /// Reminders: a button on top and "Remind me" in a note's menu; null hides them.
  final ReminderService? reminders;

  /// Where the sound of a recorded meeting is kept; null: it is not offered to be kept.
  final AudioRepository? audio;

  /// Quick notes and clipped web pages (two buttons on top); null hides them.
  final CaptureService? capture;

  /// The weekly review (a button on top); null hides it.
  final WeeklyReviewService? review;

  /// The automations: notes that a rule asks about are listed on top; null: none.
  final AutomationService? automations;

  /// The plans for exams (a button in the review of the cards); null: none.
  final StudyPlanner? planner;

  const DashboardView({super.key, this.planner, required this.repository, required this.onOpenNote, this.noteFiles, this.templates, this.onJoinSession, this.collab, this.previews, this.speech, this.sync, this.cards, this.reminders, this.audio, this.capture, this.review, this.automations});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  late Future<List<NoteSummary>> _notes = widget.repository.listNotes();

  /// Loads the notes again when they change under the list (an agent, a sync, another window of the app).
  StreamSubscription<void>? _live;
  Offset _lastPress = Offset.zero;

  // ---- selecting several notes
  bool _selecting = false;
  final Set<String> _selected = {};
  List<NoteSummary> _shown = const [];

  List<String> get _selectedIds => [for (final n in _shown) if (_selected.contains(n.id)) n.id];

  void _toggleSelected(String id) => setState(() {
        _selecting = true;
        if (!_selected.remove(id)) _selected.add(id);
      });

  void _endSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _moveSelected() async {
    final ids = _selectedIds;
    if (ids.isEmpty) return;
    if (await moveNotesTo(context, widget.repository, ids)) _endSelecting();
    _reload();
  }

  Future<void> _trashSelected() async {
    final ids = _selectedIds;
    if (ids.isEmpty) return;
    if (await trashNotes(context, widget.repository, ids)) _endSelecting();
    _reload();
  }

  Future<void> _starSelected(bool value) async {
    for (final id in _selectedIds) {
      await widget.repository.setFavorite(id, value);
    }
    _reload();
  }

  static const _cardColors = [Color(0xFFE8F0FE), Color(0xFFFEF7E0), Color(0xFFFCE8E6), Color(0xFFE6F4EA)];

  // ---- reading the notes again after a sync (direct or through the cloud folder) has ended
  CloudSyncService? _cloud;
  bool _wasSyncing = false;

  bool get _syncing {
    final sync = widget.sync;
    if (sync == null) return false;
    return sync.activeSyncs > 0 || (_cloud?.running ?? false) || (widget.collab?.nativeShares?.running ?? false);
  }

  void _syncChanged() {
    final cloud = widget.sync?.cloud;
    if (cloud != _cloud) {
      _cloud?.removeListener(_syncChanged);
      _cloud = cloud?..addListener(_syncChanged);
    }
    final syncing = _syncing;
    if (_wasSyncing && !syncing && mounted) _reload();
    _wasSyncing = syncing;
  }

  @override
  void initState() {
    super.initState();
    widget.sync?.addListener(_syncChanged);
    widget.collab?.nativeShares?.addListener(_syncChanged); // (what is shared with people changes notes too)
    _syncChanged();
    _live = debouncedChanges([widget.repository.changes, widget.repository.created,]).listen((_) {
      if (mounted) _reload();
    });
  }

  @override
  void didUpdateWidget(DashboardView old) {
    super.didUpdateWidget(old);
    if (old.sync == widget.sync) return;
    old.sync?.removeListener(_syncChanged);
    widget.sync?.addListener(_syncChanged);
    _syncChanged();
  }

  @override
  void dispose() {
    _live?.cancel();
    widget.sync?.removeListener(_syncChanged);
    widget.collab?.nativeShares?.removeListener(_syncChanged);
    _cloud?.removeListener(_syncChanged);
    super.dispose();
  }

  void _reload() {
    final notes = widget.repository.listNotes();
    setState(() {
      _notes = notes; // (an arrow function would hand the Future to setState, which refuses it)
    });
  }

  Future<void> _createNote() async {
    final id = await widget.repository.createNote();
    widget.onOpenNote(id);
  }

  /// A note around a PDF that is picked (annotating it is what the app is for).
  Future<void> _fromPdf() async {
    try {
      final path = await pickedPath(await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf']));
      if (path == null) return;
      widget.onOpenNote(await createNoteFromPdf(widget.repository, path));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Error loading PDF: {error}', {'error': e}))));
    }
  }

  /// Records a meeting and makes a note of what was said.
  Future<void> _meeting() async {
    final recording = await showSpeechRecording(context, speech: widget.speech!, title: tr('Record a meeting'), offerKeep: widget.audio != null);
    final text = recording?.text;
    if (text == null || text.trim().isEmpty || !mounted) return;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final title = tr('Meeting {date}', {'date': '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}'});
    final id = await widget.repository.createNote(title: title);
    final note = (await widget.repository.loadNote(id))!;
    note.documentText = '# $title\n\n## ${tr('Transcript')}\n\n${text.trim()}\n';
    await widget.repository.saveNote(note);
    if (recording!.audio != null) await widget.audio?.add(id, recording.audio!, title: title, duration: recording.length);
    widget.onOpenNote(id);
  }

  /// A note to write in at once, in the Inbox.
  Future<void> _quickNote() async {
    final result = await showQuickNote(context, widget.capture!);
    if (result == null || !mounted) return;
    widget.onOpenNote(result.noteId);
  }

  Future<void> _clipPage() async {
    final result = await showClipPage(context, widget.capture!);
    if (result == null || !mounted) return;
    announceCaptured(context, result, () => widget.onOpenNote(result.noteId));
    _reload();
  }

  Future<void> _fromTemplate() async {
    final id = await newNoteFromTemplate(context, widget.templates!);
    if (id != null) widget.onOpenNote(id);
  }

  Future<void> _deleteNote(NoteSummary note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Move note to the trash?'),
        content: Text.verbatim(tr('"{title}" goes to the trash, where it stays for 30 days.', {'title': note.shownTitle})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.repository.trashNote(note.id);
    _reload();
  }

  Future<void> _toggleFavorite(NoteSummary note) async {
    await widget.repository.setFavorite(note.id, !note.favorite);
    _reload();
  }

  /// The card's menu, where a right click or a long press lands.
  Future<void> _showCardMenu(NoteSummary note, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        if (widget.templates != null && !note.locked) const PopupMenuItem(value: 'template', child: Text('Save as a template...')),
        PopupMenuItem(value: 'star', child: Text(note.favorite ? 'Remove from favourites' : 'Add to favourites')),
        if (widget.reminders != null) const PopupMenuItem(value: 'remind', child: Text('Remind me...')),
        const PopupMenuItem(value: 'select', child: Text('Select')),
        if (widget.noteFiles != null && !note.locked) const PopupMenuItem(value: 'file', child: Text('Save as a file...')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (choice == 'open') widget.onOpenNote(note.id);
    if (choice == 'star') await _toggleFavorite(note);
    if (choice == 'remind' && mounted) await showRemindDialog(context, widget.reminders!, kind: ReminderKind.note, refId: note.id, title: note.shownTitle);
    if (choice == 'select') _toggleSelected(note.id);
    if (choice == 'template' && mounted) await saveNoteAsTemplate(context, widget.templates!, note.id, note.title);
    if (choice == 'file' && mounted) await saveNoteAsFile(context, widget.noteFiles!, note.id, note.title);
    if (choice == 'delete') await _deleteNote(note);
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
    final collab = widget.collab;
    if (collab == null) return _page(context);
    return ListenableBuilder(listenable: Listenable.merge([collab, collab.shared]), builder: (context, _) => _page(context));
  }

  Widget _page(BuildContext context) {
    final selectedIds = _selectedIds;
    return Scaffold(
      appBar: _selecting
          ? SelectionBar(
              count: selectedIds.length,
              total: _shown.length,
              onClose: _endSelecting,
              onSelectAll: () => setState(() => _selected.addAll(_shown.map((n) => n.id))),
              onMove: _moveSelected,
              onDelete: _trashSelected,
              onFavorite: _starSelected,
              allFavorite: selectedIds.isNotEmpty && _shown.where((n) => _selected.contains(n.id)).every((n) => n.favorite),
            )
          : AppBar(
        title: const Text('Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (widget.sync != null) SyncNowButton(sync: widget.sync!, shares: widget.collab?.nativeShares),
          IconButton(
              key: const ValueKey('select-notes'),
              tooltip: tr('Select notes'),
              icon: const Icon(Icons.checklist_rtl),
              onPressed: () => setState(() => _selecting = true),
            ),
          if (widget.capture != null) ...[
            IconButton(key: const ValueKey('quick-note'), tooltip: tr('Quick note'), icon: const Icon(Icons.bolt_outlined), onPressed: _quickNote),
            IconButton(key: const ValueKey('clip-page'), tooltip: tr('Keep a web page'), icon: const Icon(Icons.language), onPressed: _clipPage),
          ],
          if (widget.review != null)
            IconButton(
              key: const ValueKey('weekly-review'),
              tooltip: tr('Weekly review'),
              icon: const Icon(Icons.event_note_outlined),
              onPressed: () => showWeeklyReview(context, service: widget.review!, reminders: widget.reminders, onOpenNote: widget.onOpenNote),
            ),
          if (widget.reminders != null) RemindersButton(service: widget.reminders!),
          if (widget.cards != null) ReviewButton(cards: widget.cards!, planner: widget.planner, repository: widget.repository),
          if (widget.speech != null)
            IconButton(
              key: const ValueKey('record-meeting'),
              tooltip: tr('Record a meeting'),
              icon: const Icon(Icons.mic_none),
              onPressed: _meeting,
            ),
          if (widget.templates != null)
            IconButton(
              key: const ValueKey('new-from-template'),
              tooltip: tr('New note from a template'),
              icon: const Icon(Icons.dashboard_customize_outlined),
              onPressed: _fromTemplate,
            ),
          if (widget.onJoinSession != null)
            IconButton(
              key: const ValueKey('join-session'),
              tooltip: tr('Join a live session or open a shared note (paste a link)'),
              icon: const Icon(Icons.group_add_outlined),
              onPressed: widget.onJoinSession,
            ),
          if (widget.noteFiles != null)
            IconButton(
              key: const ValueKey('open-note-file'),
              tooltip: tr('Open a note file (.uninote)'),
              icon: const Icon(Icons.file_open_outlined),
              onPressed: () async {
                final id = await openNoteFile(context, widget.noteFiles!);
                if (id != null && mounted) widget.onOpenNote(id);
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<List<NoteSummary>>(
        future: _notes,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text.verbatim(tr('Could not load notes: {error}', {'error': snapshot.error})));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator.adaptive());
          final notes = snapshot.data!;
          _shown = notes;
          final favourites = [for (final n in notes) if (n.favorite) n];
          final others = [for (final n in notes) if (!n.favorite) n];
          // (the cards are made as they come into view: a library of thousands of notes must not make all of them to show a few)
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(24.0),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.collab?.nativeShares != null) ShareInvitations(service: widget.collab!.nativeShares!),
                          if (widget.automations != null) AskCard(service: widget.automations!, repository: widget.repository, onOpenNote: widget.onOpenNote),
                          Text(
                            'Welcome back 👋',
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            notes.isEmpty ? 'No notes yet - create your first one.' : 'Here are your recent study notes:',
                            style: TextStyle(color: Theme.of(context,).colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                    if (favourites.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.star_rounded, color: Colors.amber),
                              const SizedBox(width: 8),
                              Text('Favourites', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                            ]),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      _grid(favourites),
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 24),
                            if (others.isNotEmpty) Text('Recent notes', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ],
                    _grid(others),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FloatingActionButton.small(
          key: const ValueKey('new-from-pdf'),
          heroTag: 'new-from-pdf',
          tooltip: tr('New note from a PDF'),
          onPressed: _fromPdf,
          child: const Icon(Icons.picture_as_pdf_outlined),
        ),
        FloatingActionButton.extended(
          heroTag: 'new-note',
          onPressed: _createNote,
          icon: const Icon(Icons.add),
          label: const Text('New Note'),
        ),
      ]),
    );
  }

  Widget _grid(List<NoteSummary> notes) => SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 280,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.85,
        ),
        itemCount: notes.length,
        itemBuilder: (context, index) => _card(notes[index], _cardColors[index % _cardColors.length]),
      );

  Widget _card(NoteSummary note, Color color) {
    return Card(
      elevation: 0,
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: _selected.contains(note.id)
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 3)
            : BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _selecting || selectModifierPressed ? _toggleSelected(note.id) : widget.onOpenNote(note.id),
        onSecondaryTapUp: (d) => _showCardMenu(note, d.globalPosition),
        onLongPress: () => _selecting ? _toggleSelected(note.id) : _showCardMenu(note, _lastPress),
        onTapDown: (d) => _lastPress = d.globalPosition,
        child: Stack(fit: StackFit.expand, children: [
          if (note.themeImage != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(
                File(note.themeImage!),
                key: ValueKey(note.themeImage),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ],
          if (widget.previews != null)
            Positioned.fill(
              child: NotePreviewImage(
                previews: widget.previews,
                noteId: note.id,
                changed: note.updatedAt,
                locked: note.locked,
                opacity: note.themeImage != null ? 0.65 : 0.9,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          if (note.themeImage != null) ...[
            // darkens the picture so that the title stays readable
            const DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(16)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x33000000)],
                ),
              ),
            ),
          ],
          Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text.verbatim(
                      note.shownTitle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: note.themeImage != null ? Colors.white : null),
                    ),
                  ),
                  if (_selecting)
                    Checkbox.adaptive(key: ValueKey('select-${note.id}'), value: _selected.contains(note.id), onChanged: (_) => _toggleSelected(note.id))
                  else ...[
                  IconButton(
                    key: ValueKey('star-${note.id}'),
                    tooltip: tr(note.favorite ? 'Remove from favourites' : 'Add to favourites'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                    icon: Icon(note.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                        size: 20, color: note.favorite ? Colors.amber : (note.themeImage != null ? Colors.white : null)),
                    onPressed: () => _toggleFavorite(note),
                  ),
                  PopupMenuButton<void>(
                    tooltip: tr('More'),
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.more_vert, size: 18, color: note.themeImage != null ? Colors.white : null),
                    itemBuilder: (_) => [
                      PopupMenuItem(onTap: () => _toggleFavorite(note), child: Text(note.favorite ? 'Remove from favourites' : 'Add to favourites')),
                      if (widget.noteFiles != null && !note.locked)
                        PopupMenuItem(onTap: () => saveNoteAsFile(context, widget.noteFiles!, note.id, note.title), child: const Text('Save as a file...')),
                      PopupMenuItem(onTap: () => _toggleSelected(note.id), child: const Text('Select')),
                      PopupMenuItem(onTap: () => _deleteNote(note), child: const Text('Delete')),
                    ],
                  ),
                  ],
                ],
              ),
              Text(_ago(note.updatedAt),
                  style: TextStyle(fontSize: 11, color: note.themeImage != null ? Colors.white70 : Colors.black54)),
              const Spacer(),
              Row(children: [
                SharedBadge(
                  key: ValueKey('shared-badge-${note.id}'),
                  kind: widget.collab?.shared.kindOf(note.id) ?? SharedKind.none,
                  from: widget.collab?.shared.fromWhom(note.id),
                  color: note.themeImage != null ? Colors.white : null,
                ),
                const Spacer(),
                Icon(note.locked ? Icons.lock_outline : (note.isPdf ? Icons.picture_as_pdf : Icons.edit_note_rounded), color: note.themeImage != null ? Colors.white70 : Colors.black54),
              ])
            ],
          ),
        ),
        ]),
      ),
    );
  }
}
