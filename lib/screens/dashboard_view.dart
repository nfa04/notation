import 'package:material_symbols_icons/symbols.dart';
import '../widgets/bounded_image.dart';
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
import 'learning_hub.dart';
import 'study_session_screen.dart' show OpenNoteAt;
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
import 'import_from_apps.dart';
import '../data/tag_repository.dart';
import 'template_picker.dart';
import '../templates/templates.dart';
import 'shared_badge.dart';
import 'share_people.dart';
import '../widgets/paper.dart';

/// The first screen: recent and starred notes, tasks, and the buttons that make a note (blank, from a PDF, a template,
/// a recording) or ask the assistant about all notes.
typedef _DashboardTool = ({String key, IconData icon, String label, VoidCallback onTap, Widget? widget});

class DashboardView extends StatefulWidget {
  /// Tells the page it was brought to the front again (it was kept, out of sight): it reads what changed meanwhile.
  final Listenable? refresh;
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

  /// Flashcards kept for spaced repetition; null: the "Learn today" row says nothing of cards.
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

  /// The plans for exams (today's session in the "Learn today" row); null: none.
  final StudyPlanner? planner;

  /// Opens the learning hub (a tap on the "Learn today" row); null: not offered.
  final VoidCallback? onOpenLearning;

  /// Opens a note at a page (an item of a study session).
  final OpenNoteAt? onOpenNoteAt;

  /// The tags notes can have (the tags of imported notes are set through it); null: none are set.
  final TagRepository? tags;

  const DashboardView({super.key, this.tags, this.planner, this.onOpenNoteAt, required this.repository, required this.onOpenNote, this.noteFiles, this.templates, this.onJoinSession, this.collab, this.previews, this.speech, this.sync, this.cards, this.reminders, this.audio, this.capture, this.review, this.automations, this.refresh, this.onOpenLearning});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

/// The settings key that holds the id of the note the intro made to show the tools.
const welcomeNoteKey = 'welcome_note';

class _DashboardViewState extends State<DashboardView> {
  late Future<List<NoteSummary>> _notes = widget.repository.listNotes();

  /// The note the intro made (null: none, or not known yet): while it is the only note, this is a first visit.
  String? _welcomeId;

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
    if (await trashNotes(context, widget.repository, ids, onRestored: _reload)) _endSelecting();
    _reload();
  }

  Future<void> _starSelected(bool value) async {
    for (final id in _selectedIds) {
      await widget.repository.setFavorite(id, value);
    }
    _reload();
  }

  // (paper: the sheets are always light, like the page they show; white, cream and sand, as the paper tones of the pages)
  static const _cardColors = [Color(0xFFFFFFFF), Color(0xFFFBF6E8), Color(0xFFF3EADA)];

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
    widget.repository.settings.get(welcomeNoteKey).then((id) {
      if (mounted && id != null) setState(() => _welcomeId = id);
    }, onError: (Object _) {});
    widget.refresh?.addListener(_reload);
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
    widget.refresh?.removeListener(_reload);
    widget.sync?.removeListener(_syncChanged);
    widget.collab?.nativeShares?.removeListener(_syncChanged);
    _cloud?.removeListener(_syncChanged);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
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
    await trashNotes(context, widget.repository, [note.id], onRestored: _reload);
    _reload();
  }

  Future<void> _toggleFavorite(NoteSummary note) async {
    await widget.repository.setFavorite(note.id, !note.favorite);
    _reload();
  }

  /// What a note's menu holds: the same for the ⋮ button on the card and for a right click or a long press on it.
  List<PopupMenuEntry<String>> _cardMenuItems(NoteSummary note) => [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        if (widget.templates != null && !note.locked) const PopupMenuItem(value: 'template', child: Text('Save as a template...')),
        PopupMenuItem(value: 'star', child: Text(note.favorite ? 'Remove from favourites' : 'Add to favourites')),
        if (widget.reminders != null) const PopupMenuItem(value: 'remind', child: Text('Remind me...')),
        const PopupMenuItem(value: 'select', child: Text('Select')),
        if (widget.noteFiles != null && !note.locked) const PopupMenuItem(value: 'file', child: Text('Save as a file...')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ];

  Future<void> _cardChoice(NoteSummary note, String? choice) async {
    if (choice == 'open') widget.onOpenNote(note.id);
    if (choice == 'star') await _toggleFavorite(note);
    if (choice == 'remind' && mounted) await showRemindDialog(context, widget.reminders!, kind: ReminderKind.note, refId: note.id, title: note.shownTitle);
    if (choice == 'select') _toggleSelected(note.id);
    if (choice == 'template' && mounted) await saveNoteAsTemplate(context, widget.templates!, note.id, note.title);
    if (choice == 'file' && mounted) await saveNoteAsFile(context, widget.noteFiles!, note.id, note.title);
    if (choice == 'delete') await _deleteNote(note);
  }

  /// The card's menu, where a right click or a long press lands.
  Future<void> _showCardMenu(NoteSummary note, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      items: _cardMenuItems(note),
    );
    await _cardChoice(note, choice);
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
    final phone = MediaQuery.sizeOf(context).width < 600;
    final tools = <_DashboardTool>[
      (key: 'select-notes', icon: Symbols.checklist_rtl, label: tr('Select notes'), onTap: () => setState(() => _selecting = true), widget: null),
      if (widget.capture != null) ...[
        (key: 'quick-note', icon: Symbols.bolt, label: tr('Quick note'), onTap: _quickNote, widget: null),
        (key: 'clip-page', icon: Symbols.language, label: tr('Keep a web page'), onTap: _clipPage, widget: null),
      ],
      if (widget.review != null)
        (
          key: 'weekly-review',
          icon: Symbols.event_note,
          label: tr('Weekly review'),
          onTap: () => showWeeklyReview(context, service: widget.review!, reminders: widget.reminders, onOpenNote: widget.onOpenNote),
          widget: null,
        ),
      if (widget.reminders != null)
        (
          key: 'open-reminders',
          icon: Symbols.notifications_none,
          label: tr('Reminders'),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RemindersScreen(service: widget.reminders!))),
          widget: RemindersButton(service: widget.reminders!),
        ),
      if (widget.speech != null) (key: 'record-meeting', icon: Symbols.mic_none, label: tr('Record a meeting'), onTap: _meeting, widget: null),
      if (widget.templates != null) (key: 'new-from-template', icon: Symbols.dashboard_customize, label: tr('New note from a template'), onTap: _fromTemplate, widget: null),
      if (widget.onJoinSession != null)
        (key: 'join-session', icon: Symbols.group_add, label: tr('Join a live session or open a shared note (paste a link)'), onTap: widget.onJoinSession!, widget: null),
      if (widget.noteFiles != null)
        (
          key: 'open-note-file',
          icon: Symbols.file_open,
          label: tr('Open a note file (.uninote)'),
          onTap: () async {
            final id = await openNoteFile(context, widget.noteFiles!);
            if (id != null && mounted) widget.onOpenNote(id);
          },
          widget: null,
        ),
      (key: 'new-from-pdf', icon: Symbols.picture_as_pdf, label: tr('New note from a PDF'), onTap: _fromPdf, widget: null),
      (
        key: 'import-from-apps',
        icon: Symbols.move_to_inbox,
        label: tr('Bring your notes from another app'),
        onTap: () async {
          await showImportFromApps(context, repository: widget.repository, tags: widget.tags, onOpenNote: widget.onOpenNote);
          if (mounted) _reload();
        },
        widget: null,
      ),
    ];
    // (what makes a note is in the menu of the "New Note" button; the title bar keeps what is about the notes you have)
    const makers = {'quick-note', 'clip-page', 'record-meeting', 'new-from-template', 'open-note-file', 'new-from-pdf', 'import-from-apps'};
    final makes = [for (final t in tools) if (makers.contains(t.key)) t];
    final about = [for (final t in tools) if (!makers.contains(t.key)) t];
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
        title: const Text('Dashboard'),
        actions: [
          if (widget.sync != null) SyncNowButton(sync: widget.sync!, shares: widget.collab?.nativeShares),
          // the one with a badge keeps its place on a wide screen; on a phone it goes in the menu
          for (final t in about)
            if (t.widget != null && !phone) t.widget!,
          PopupMenuButton<String>(
            key: const ValueKey('dashboard-more'),
            tooltip: tr('More'),
            onSelected: (key) => about.firstWhere((t) => t.key == key).onTap(),
            itemBuilder: (_) => [
              for (final t in about)
                if (t.widget == null || phone) PopupMenuItem(key: ValueKey('menu-${t.key}'), value: t.key, child: ListTile(leading: Icon(t.icon), title: Text.verbatim(t.label), contentPadding: EdgeInsets.zero)),
            ],
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
          final firstVisit = notes.length == 1 && notes.single.id == _welcomeId;
          final favourites = [for (final n in notes) if (n.favorite) n];
          final others = [for (final n in notes) if (!n.favorite) n];
          // (the cards are made as they come into view: a library of thousands of notes must not make all of them to show a few)
          return CustomScrollView(
            slivers: [
              SliverPadding(
                // (a phone: less margin, and room under the last cards for the button)
                padding: phone ? const EdgeInsets.fromLTRB(16, 12, 16, 96) : const EdgeInsets.fromLTRB(24, 24, 24, 96),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.collab?.nativeShares != null) ShareInvitations(service: widget.collab!.nativeShares!),
                          if (widget.automations != null) AskCard(service: widget.automations!, repository: widget.repository, onOpenNote: widget.onOpenNote),
                          if (widget.planner != null || widget.cards != null)
                            LearnTodayRow(planner: widget.planner, cards: widget.cards, repository: widget.repository, onOpenNoteAt: widget.onOpenNoteAt, onOpenHub: widget.onOpenLearning),
                          if (notes.isEmpty)
                            _emptyState(context)
                          else ...[
                            Text(
                              firstVisit ? 'Welcome' : 'Welcome back',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w300),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              firstVisit ? 'Open the note below for a short tour, or start your own with New Note.' : 'Here are your recent notes:',
                              style: TextStyle(color: Theme.of(context,).colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 24),
                          ],
                        ],
                      ),
                    ),
                    if (favourites.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Text('Favourites', style: _sectionLabel(context)),
                            ]),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      _grid(favourites, phone),
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 24),
                            if (others.isNotEmpty) Text('Recent notes', style: _sectionLabel(context)),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ],
                    _grid(others, phone),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      // (while there are no notes the box on the page has the buttons)
      floatingActionButton: FutureBuilder<List<NoteSummary>>(future: _notes, builder: (context, snapshot) => snapshot.hasData && snapshot.data!.isEmpty ? const SizedBox.shrink() : _newNoteButton(makes)),
    );
  }

  /// "New Note", which makes a blank note at once, with two small buttons beside it: one for a PDF (its own button, as a PDF is what the
  /// app is for as much as a blank page) and one for the other ways to start a note (a template, a quick note, a recording, another
  /// app's notes).
  Widget _newNoteButton(List<_DashboardTool> makes) {
    final scheme = Theme.of(context).colorScheme;
    final on = scheme.onPrimary;
    Widget small(Widget child) => Material(
          color: scheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: scheme.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(width: 44, height: 44, child: child),
        );
    final pdf = small(IconButton(key: const ValueKey('new-from-pdf'), tooltip: tr('New note from a PDF'), onPressed: _fromPdf, icon: const Icon(Symbols.picture_as_pdf, size: 22)));
    final more = small(PopupMenuButton<String>(
      key: const ValueKey('new-note-more'),
      tooltip: tr('Other ways to start a note'),
      icon: const Icon(Symbols.more_horiz, size: 22),
      onSelected: (key) => makes.firstWhere((t) => t.key == key).onTap(),
      itemBuilder: (_) => [
        for (final t in makes) if (t.key != 'new-from-pdf') PopupMenuItem(key: ValueKey('make-${t.key}'), value: t.key, child: ListTile(leading: Icon(t.icon), title: Text.verbatim(t.label), contentPadding: EdgeInsets.zero)),
      ],
    ));
    final primary = Material(
      color: scheme.primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('new-note'),
        onTap: _createNote,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 20, 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Symbols.add, color: on),
            const SizedBox(width: 8),
            Text('New Note', style: TextStyle(color: on, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [more, const SizedBox(width: 8), pdf, const SizedBox(width: 12), primary]);
  }

  /// What the page says while there are no notes: where to start, with the one thing to do first made plain. (A call to act, so a
  /// hairline box; the buttons at the foot of the page wait until there is a first note.)
  Widget _emptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('dashboard-empty'),
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('No notes yet', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w300)),
        const SizedBox(height: 4),
        Text('Write or draw on a blank page, or start from something you already have.', style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(key: const ValueKey('empty-new-note'), onPressed: _createNote, icon: const Icon(Symbols.add), label: const Text('Create your first note')),
          OutlinedButton.icon(key: const ValueKey('empty-from-pdf'), onPressed: _fromPdf, icon: const Icon(Symbols.picture_as_pdf), label: const Text('Annotate a PDF')),
          TextButton.icon(
            key: const ValueKey('empty-import'),
            onPressed: () async {
              await showImportFromApps(context, repository: widget.repository, tags: widget.tags, onOpenNote: widget.onOpenNote);
              if (mounted) _reload();
            },
            icon: const Icon(Symbols.move_to_inbox),
            label: const Text('Bring notes from another app'),
          ),
        ]),
      ]),
    );
  }

  /// A small quiet label above a group of notes (letter-spaced, muted).
  TextStyle _sectionLabel(BuildContext context) => PaperSection.style(context);

  Widget _grid(List<NoteSummary> notes, bool phone) => SliverGrid.builder(
        // (a phone shows two cards side by side, not one as big as the screen)
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: phone ? 200 : 280,
          mainAxisSpacing: phone ? 12 : 16,
          crossAxisSpacing: phone ? 12 : 16,
          childAspectRatio: phone ? 0.68 : 0.74,
        ),
        itemCount: notes.length,
        itemBuilder: (context, index) => _card(notes[index], _cardColors[index % _cardColors.length]),
      );

  /// A note: its page (with the cover picture behind it, if it has one) and under it, on the plain ground, its title and when it changed.
  /// Nothing is written over the page, so the handwriting stays clear.
  Widget _card(NoteSummary note, Color color) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected.contains(note.id);
    final corners = BorderRadius.circular(6);
    return Card(elevation: 0, color: Colors.transparent, margin: EdgeInsets.zero, shape: const RoundedRectangleBorder(), child: InkWell(
      borderRadius: corners,
      onTap: () => _selecting || selectModifierPressed ? _toggleSelected(note.id) : widget.onOpenNote(note.id),
      onSecondaryTapUp: (d) => _showCardMenu(note, d.globalPosition),
      onLongPress: () => _selecting ? _toggleSelected(note.id) : _showCardMenu(note, _lastPress),
      onTapDown: (d) => _lastPress = d.globalPosition,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: DecoratedBox(
            // a page on the ground: a faint shadow lifts it, and a hairline drawn over the picture (not under it) keeps its edge in light mode
            decoration: BoxDecoration(
              color: color,
              borderRadius: corners,
              boxShadow: selected || scheme.brightness == Brightness.dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            position: DecorationPosition.background,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(borderRadius: corners, border: Border.all(color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.13), width: selected ? 2 : 1)),
              child: ClipRRect(
              borderRadius: corners,
              child: Stack(fit: StackFit.expand, children: [
                if (note.themeImage != null)
                  BoundedFileImage(File(note.themeImage!), key: ValueKey(note.themeImage), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                if (widget.previews != null)
                  NotePreviewImage(previews: widget.previews, noteId: note.id, changed: note.updatedAt, locked: note.locked, opacity: note.themeImage != null ? 0.75 : 0.95, borderRadius: corners),
                // the star on the page's corner: a target of 44 pixels, which the title line has no room for
                if (!_selecting)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      key: ValueKey('star-${note.id}'),
                      tooltip: tr(note.favorite ? 'Remove from favourites' : 'Add to favourites'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
                      icon: Icon(note.favorite ? Symbols.star_rounded : Symbols.star_outline_rounded, size: 20, color: note.favorite ? scheme.primary : Colors.black45),
                      onPressed: () => _toggleFavorite(note),
                    ),
                  ),
                Positioned(
                  right: 8,
                  bottom: 6,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    SharedBadge(
                      key: ValueKey('shared-badge-${note.id}'),
                      kind: widget.collab?.shared.kindOf(note.id) ?? SharedKind.none,
                      from: widget.collab?.shared.fromWhom(note.id),
                      color: Colors.black54,
                    ),
                    if (note.locked || note.isPdf) Icon(note.locked ? Symbols.lock_outline : Symbols.picture_as_pdf, size: 16, color: Colors.black54),
                  ]),
                ),
              ]),
            )),
          ),
        ),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.verbatim(note.shownTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.25, color: scheme.onSurface)),
              const SizedBox(height: 2),
              Text(_ago(note.updatedAt), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (_selecting)
            Checkbox.adaptive(key: ValueKey('select-${note.id}'), value: selected, onChanged: (_) => _toggleSelected(note.id))
          else ...[
            PopupMenuButton<String>(
              tooltip: tr('More'),
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: Icon(Symbols.more_vert, size: 18, color: scheme.onSurfaceVariant),
              onSelected: (choice) => _cardChoice(note, choice),
              itemBuilder: (_) => _cardMenuItems(note),
            ),
          ],
        ]),
      ]),
    ));
  }
}
