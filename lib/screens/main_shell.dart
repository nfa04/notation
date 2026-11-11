import 'window_close.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import '../capture/capture_link.dart';
import '../sync/calendar_access.dart';
import 'capture_dialogs.dart';
import 'weekly_review_dialog.dart';
import '../app_services.dart';
import '../mcp/mcp_service.dart' show McpActivity;
import 'dart:async';
import 'dart:io' show Platform, exit;
import '../l10n/language.dart';



import 'package:flutter/material.dart' hide Text;
import 'dart:ui' show AppExitResponse;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../l10n/text.dart';
import '../web/temporary_session.dart';
import '../features/feature.dart';
import '../shortcuts/shortcut_action.dart';
import '../shortcuts/shortcut_service.dart';
import '../history/note_history.dart';
import 'package:app_links/app_links.dart';
import '../devicesync/sync_link.dart';
import 'sync_settings.dart';
import 'account_panel.dart';

import '../collab/cloud_share.dart';
import '../nativeshare/native_share_provider.dart' show ShareNaming;
import '../collab/collab_service.dart';
import '../collab/invite.dart';
import 'settings_screen.dart';
import 'search_view.dart';
import '../speech/read_aloud.dart';
import 'graph_view.dart';
import '../graph/graph_service.dart';
import '../previews/note_preview.dart';
import '../ai/assistant_chat.dart';
import '../ai/note_knowledge.dart';
import '../automations/note_sorter.dart';
import '../templates/templates.dart';
import 'lock_dialogs.dart';
import '../search/search_query.dart';
import '../search/search_filter.dart';
import '../automations/automation.dart';
import '../events/event_bus.dart';
import '../events/event_sources.dart' show eventVars;
import '../automations/automation_service.dart';
import 'automations_view.dart';
import '../llm/embedding_service.dart';
import 'calendar_view.dart';
import 'collab_ui.dart';
import 'assistant_panel.dart';
import 'dashboard_view.dart';
import '../reminders/reminder.dart' show ReminderKind;
import '../widgets/notation_logo.dart';
import 'folder_view.dart';
import 'bulk_note_actions.dart' show selectionBarsShowing;
import 'fixed_page_note_editor.dart';
import '../style/platform_dialog.dart';

/// The channel to the window of the app (Linux: `hide`).
@visibleForTesting
const windowChannel = MethodChannel('notation/window');

/// Ends the process (the last resort when the window is closed and the app is still there); tests replace it.
@visibleForTesting
void Function(int code) endProcess = exit;

/// The frame of the app: the navigation (dashboard, folders, notes, calendar, ...) and the screen it is showing. It also owns
/// what lives longer than a screen: the editors that are open, the split view, the lock timer and the graph run.
class MainShellNavigation extends StatefulWidget {
  final AppServices services;

  const MainShellNavigation({super.key, required this.services});

  @override
  State<MainShellNavigation> createState() => _MainShellNavigationState();
}

class _MainShellNavigationState extends State<MainShellNavigation> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  AppServices get _app => widget.services;

  late final NotePreviews _previews = NotePreviews(_app.repository);

  /// Reads text out loud (the speech of the system).
  late final ReadAloud _reader = ReadAloud.forPlatform();

  late final GraphService _graphs = GraphService(_app.repository, ai: _app.ai, enabled: () => _aiOn, embedder: _app.embeddings, embedderReady: () => _aiOn && (_app.embeddings?.installed ?? false), joinByCitations: () => _app.citations?.enabled() ?? false, isSource: (key) => _app.citations?.has(key) ?? false);

  /// The assistant that answers from all notes (the words alone find the passages while there is no sentence model).
  late final NoteKnowledge _knowledge = () {
    final embedder = _app.embeddings;
    bool ready() => _aiOn && embedder != null && embedder.installed;
    final TextEmbedder model = embedder ?? const NoEmbedder();
    return NoteKnowledge(_app.repository, model, NoteSorter(_app.repository, model, ready: ready), ready: ready, citations: _app.citations);
  }();

  /// With the AI switched off, nothing that runs a model is handed to the screens.
  bool get _aiOn => _app.aiSwitch?.enabled ?? true;

  /// Whether a tool is on (all are when the person was never asked).
  bool _f(Feature f) => _app.features?.on(f) ?? true;

  /// The places of the menu on the left, by the index the rest of the shell goes by (the calendar and the
  /// automations go when they are off; the graph and the assistant go with the AI).
  List<int> get _navItems => [0, 1, 6, if (_assistantOn) 9, if (_aiOn) 8, if (_f(Feature.calendar)) 2, 3, if (_f(Feature.automations)) 4, 5];

  /// Whether the assistant that answers from all notes is offered (its own place in the menu).
  bool get _assistantOn => _app.ai != null && _aiOn && _f(Feature.assistant);

  /// The conversation about all notes; kept while the app runs, so that leaving the page and coming back loses nothing.
  AssistantChat? _notesChat;

  static const _destinations = {
    9: NavigationRailDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: Text('Assistant')),
    0: NavigationRailDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: Text('Dashboard')),
    1: NavigationRailDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: Text('Folders')),
    2: NavigationRailDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: Text('Calendar')),
    3: NavigationRailDestination(icon: Icon(Icons.note_alt_outlined), selectedIcon: Icon(Icons.note_alt), label: Text('Active Canvas')),
    4: NavigationRailDestination(icon: Icon(Icons.bolt_outlined), selectedIcon: Icon(Icons.bolt), label: Text('Automations')),
    6: NavigationRailDestination(icon: Icon(Icons.search), selectedIcon: Icon(Icons.search), label: Text('Search')),
    8: NavigationRailDestination(icon: Icon(Icons.hub_outlined), selectedIcon: Icon(Icons.hub), label: Text('Graph')),
    5: NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('Settings')),
  };

  void _aiSwitched() {
    if (!mounted) return;
    if (!_navItems.contains(_selectedNavIndex)) _selectedNavIndex = 0; // (the assistant page goes with the AI)
    setState(() {});
  }

  void _featuresChanged() {
    if (!mounted) return;
    // a place of the menu that goes away while it is shown: back to the dashboard
    if (!_navItems.contains(_selectedNavIndex)) _selectedNavIndex = 0;
    setState(() {});
  }

  /// The note shown beside the open one (a split view; wide windows only), the one the keyboard is for, and the width of the left part.
  String? _splitNoteId;
  bool _roomToSplit = false; // the note area is wide enough for two notes
  bool _splitShown = false; // two notes are on screen (the window is wide enough)
  final ValueNotifier<String?> _focusedPane = ValueNotifier(null);
  double _splitFraction = 0.5;

  /// New notes from templates (needs the note files, which it keeps templates in).
  late final TemplateService? _templates = _app.noteFiles == null ? null : TemplateService(_app.repository, _app.noteFiles!);

  int _selectedNavIndex = 0;
  String? _activeNoteId;

  /// The search of all notes as it was left, and the search a note is opened with (taken by that note once).
  SearchQuery? _searchQuery;
  SearchFilter? _searchFilter;
  ({String note, SearchQuery? query, int page})? _openWithFind;

  /// Opens a note at a page (an answer of the assistant points at it).
  Future<void> _openAtPage(String id, int? page) async {
    _openWithFind = page == null ? null : (note: id, query: null, page: page);
    await _go(index: 3, note: id);
  }

  Future<void> _openFromSearch(String id, SearchQuery query, int page) async {
    _openWithFind = (note: id, query: query, page: page);
    await _go(index: 3, note: id);
  }

  /// The left bar can be folded away to leave all the room to the page.
  bool _railHidden = false;
  final _railKey = GlobalKey();
  double? _railWidth;
  /// 1 while the bar is fully there, 0 once it is gone; the bar slides between the two.
  late final AnimationController _railSlide = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);
  static const _railHiddenKey = 'rail_hidden';

  /// One key per note, so that the open editor can be asked to export itself.
  final Map<String, GlobalKey> _editorKeys = {};
  bool _navigating = false;

  NoteEditorHandle? _editorOf(String id) {
    final state = _editorKeys[id]?.currentState;
    return state is NoteEditorHandle ? state as NoteEditorHandle : null;
  }

  /// Goes to another part of the app and/or another note. Leaving a note
  /// first runs the automations for closing it, while the editor is still
  /// there; arriving runs those for opening it once it has loaded.
  Future<void> _go({int? index, String? note}) async {
    if (_navigating) return;
    final from = _selectedNavIndex, activeId = _activeNoteId;
    final toIndex = index ?? from;
    final toNote = note ?? activeId;
    final wasOpen = from == 3 && activeId != null;
    final automations = _app.automations;

    // a note that is only listed here (a temporary browser) has to be fetched first
    if (toIndex == 3 && toNote != null && !(wasOpen && toNote == activeId)) {
      _navigating = true;
      try {
        if (!await _fetched(toNote) || !mounted) return;
      } finally {
        _navigating = false;
      }
    }

    // a locked note has to be opened first
    if (toIndex == 3 && toNote != null && !(wasOpen && toNote == activeId)) {
      if (!await _unlocked(toNote) || !mounted) return;
    }

    if (wasOpen && automations != null && (toIndex != 3 || toNote != activeId)) {
      _navigating = true;
      try {
        final handle = _editorOf(activeId);
        await handle?.saveNow(); // automations that read the note from the database see its latest state
        final info = await _app.repository.noteInfo(activeId);
        await automations.bus.emit(AppEvent(AutomationEvent.noteClosed.name,
            noteId: activeId, title: handle?.noteTitle ?? info?.title ?? '', folderId: info?.folderId, editor: handle));
      } finally {
        _navigating = false;
      }
    }
    if (!mounted) return;
    // a locked note that is left is put away (an encrypted one is taken out of the database again)
    if (wasOpen && (toIndex != 3 || toNote != activeId)) await _putAway(activeId);
    if (toIndex != 3 && _splitNoteId != null) await _putAway(_splitNoteId!);
    if (!mounted) return;
    if (toIndex != 3) _openWithFind = null;
    if (toNote == _splitNoteId) _splitNoteId = null; // it is the open note now
    setState(() {
      _selectedNavIndex = toIndex;
      _activeNoteId = toNote;
    });
    if (toIndex == 3 && toNote != null && !(wasOpen && toNote == activeId)) {
      unawaited(_app.repository.markOpened(toNote)); // for "not opened for a while"
    }
    if (wasOpen && (toIndex != 3 || toNote != activeId)) {
      // the note was left: once the editor has saved it, its shared copies are put up again (if it changed)
      final markers = _app.collab?.cloudShare?.markers;
      if (markers != null) unawaited(Future<void>.delayed(const Duration(seconds: 2), () => markers.refreshCopy(activeId)));
      // and a version of it is kept (if it changed since the last one)
      final history = _app.history;
      if (history != null) unawaited(Future<void>.delayed(const Duration(seconds: 2), () => history.snapshot(activeId, reason: VersionReason.left)).catchError((Object _) => null));
    }
    if (automations != null && toIndex == 3 && toNote != null && !(wasOpen && toNote == activeId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final handle = _editorOf(toNote);
        if (handle == null) return;
        await handle.ready;
        final info = await _app.repository.noteInfo(toNote);
        await automations.bus.emit(AppEvent(AutomationEvent.noteOpened.name,
            noteId: toNote, title: handle.noteTitle, folderId: info?.folderId, editor: handle));
        // dates in an imported PDF (in the background; the note is usable meanwhile)
        unawaited(_scanDates(toNote));
      });
    }
  }

  /// Makes sure the note is here in full. A temporary browser only lists the notes of the profile (see `DeviceSyncService.lazyNotes`) and asks
  /// the other devices for one when it is opened; false if it did not come.
  Future<bool> _fetched(String id) async {
    final sync = _app.sync;
    if (sync == null || !sync.lazyNotes || !await sync.library.isStub(id)) return true;
    if (!mounted) return false;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(tr('Fetching the note from your other device...')), persist: false, duration: const Duration(seconds: 45)));
    final got = await sync.fetchNote(id);
    messenger.hideCurrentSnackBar();
    if (!got && mounted) {
      messenger.showSnackBar(SnackBar(
        content: Text.verbatim(tr('The note could not be fetched. Is the device that has it online?')),
        persist: false,
        duration: const Duration(seconds: 6),
      ));
    }
    return got;
  }

  /// Opens a locked note by asking for its passcode (or passphrase); true if it can be shown.
  Future<bool> _unlocked(String id) async {
    final locks = _app.locks;
    if (locks == null) return true;
    return unlockNote(context, locks, id);
  }

  /// Puts a locked note away once the editor has saved it. (Notes that are not locked are not touched.)
  Future<void> _putAway(String id) async {
    final locks = _app.locks;
    if (locks == null || !locks.isOpen(id)) return;
    await _editorOf(id)?.saveNow();
    await locks.seal(id);
  }

  /// The second note of the split view goes away.
  Future<void> _closeSplit() async {
    final beside = _splitNoteId;
    if (beside != null) await _putAway(beside);
    if (!mounted) return;
    setState(() {
      _splitNoteId = null;
      _focusedPane.value = null;
    });
  }

  /// The first note of the split view goes away; the one beside it stays, alone.
  Future<void> _closeFirst() async {
    final first = _activeNoteId;
    final beside = _splitNoteId;
    if (first == null || beside == null) return;
    await _editorOf(first)?.saveNow();
    await _putAway(first);
    if (!mounted) return;
    setState(() {
      _activeNoteId = beside;
      _splitNoteId = null;
      _focusedPane.value = null;
    });
    unawaited(_app.repository.markOpened(beside));
  }

  /// Shows [other] beside the open note, if it can be opened.
  Future<void> _openBeside(String other) async {
    if (!await _fetched(other) || !mounted) return;
    if (!await _unlocked(other) || !mounted) return;
    final old = _splitNoteId;
    if (old != null && old != other) await _putAway(old);
    if (!mounted) return;
    setState(() {
      _splitNoteId = other;
      _focusedPane.value = other;
    });
  }

  /// Reads the dates of the PDF in note [id] for the automations, and says so
  /// when they made tasks.
  Future<void> _scanDates(String id) async {
    final automations = _app.automations;
    final handle = _editorOf(id);
    if (automations == null || handle == null || !_f(Feature.calendar)) return; // (the dates go to the calendar)
    final info = await _app.repository.noteInfo(id);
    final report = await automations.scanForDates(handle, noteId: id, folderId: info?.folderId);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (report.error != null) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not read the dates of this PDF: {error}', {'error': report.error}))));
    } else if (report.acted > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(report.acted == 1 ? report.results.single : tr('{n} automations ran for dates in this PDF', {'n': report.acted})),
      ));
    }
  }

  // ---- live sessions

  final Set<String> _asked = {};
  StreamSubscription<Uri>? _links;
  bool _joining = false;

  /// Someone asks to join a session of ours: the question comes up wherever we are in the app.
  void _collabChanged() {
    final collab = _app.collab;
    if (collab == null || !mounted) return;
    for (final r in collab.requests) {
      if (_asked.add(r.request.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showJoinRequest(context, r);
        });
      }
    }
  }

  StreamSubscription<ShareNotice>? _notices;
  StreamSubscription<McpActivity>? _agentActivity;

  /// Tells the person that an AI agent changed something (see `McpService`), with a way to the note. A note that is open shows the change as
  /// it happens; the lists look again on their own.
  Future<void> _showAgentNotice(McpActivity a) async {
    final id = a.noteId;
    final info = id == null ? null : await _app.repository.noteInfo(id);
    if (!mounted) return;
    final title = info == null ? null : (info.title.isEmpty ? tr('Untitled') : info.title);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text.verbatim(title == null ? tr('An agent changed your notes.') : tr('An agent changed "{title}".', {'title': title})),
        action: title == null || (_selectedNavIndex == 3 && _activeNoteId == id) ? null : SnackBarAction(label: tr('Open'), onPressed: () => _go(index: 3, note: id)),
        persist: false,
        duration: const Duration(seconds: 4),
      ));
  }

  /// Tells the person what happened with a note that was shared (someone opened it, someone joined, changes came in).
  void _showNotice(ShareNotice n) {
    if (!mounted) return;
    final who = n.who ?? tr('Someone');
    final title = n.title.isEmpty ? tr('Untitled') : n.title;
    final text = switch (n.kind) {
      ShareNoticeKind.opened => tr('Someone opened your shared note "{title}". A live session was started.', {'title': title}),
      ShareNoticeKind.joined => tr('{who} joined "{title}".', {'who': who, 'title': title}),
      ShareNoticeKind.merged => tr('The changes of {who} to "{title}" were taken in.', {'who': who, 'title': title}),
      ShareNoticeKind.joinedOwner => tr('{who} is online: you joined the live session on "{title}".', {'who': who, 'title': title}),
      ShareNoticeKind.ownerOnline => tr('{who} is online and working on "{title}".', {'who': who, 'title': title}),
    };
    final action = switch (n.kind) {
      ShareNoticeKind.ownerOnline => SnackBarAction(label: tr('Join'), onPressed: () => _joinOwner(n.noteId)),
      ShareNoticeKind.merged => null,
      _ => SnackBarAction(label: tr('Open'), onPressed: () => _go(index: 3, note: n.noteId)),
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(text), action: action, persist: false, duration: const Duration(seconds: 5)));
  }

  /// Leaves the note on screen and joins the session of the owner of the copy, then opens the note again.
  Future<void> _joinOwner(String noteId) async {
    final collab = _app.collab;
    if (collab == null || !mounted) return;
    await _go(index: 0); // (the note is saved on the way out)
    final attempt = await collab.joinOpenedCopy(noteId);
    if (attempt == null) return;
    await attempt.finished;
    if (mounted && attempt.noteId != null) await _go(index: 3, note: noteId);
  }

  void _onLink(Uri uri) {
    // the way back from signing in to a storage service
    if (uri.scheme == 'notation' && uri.host == 'oauth') {
      _app.collab?.cloudShare?.handleRedirect(uri).then((took) {
        if (took && mounted) _go(index: 5);
      });
      return;
    }
    // a share given by a person at the cloud service (the link that came with the invitation)
    if (uri.scheme == 'notation' && uri.host == 'share') {
      _addShareLink(uri.toString());
      return;
    }
    final capture = parseCaptureLink(uri);
    if (capture != null) {
      _keepFromLink(capture);
      return;
    }
    final connect = ConnectLink.parse(uri.toString());
    if (connect != null && _app.sync != null) {
      answerConnectCode(context, _app.sync!, connect);
      return;
    }
    final sync = SyncLink.parse(uri.toString());
    if (sync != null && _app.sync != null) {
      showJoinDialog(context, _app.sync!, initial: sync);
      return;
    }
    final invite = SessionInvite.parse(uri.toString());
    if (invite != null) {
      _joinSession(invite);
      return;
    }
    final copy = CopyInvite.parse(uri.toString());
    if (copy != null) _openCopy(copy);
  }

  /// Something another app or a web page handed over (text to keep, a page to clip, a file): kept in the Inbox once the person says so.
  Future<void> _keepFromLink(CaptureLink link) async {
    final capture = _app.capture;
    if (capture == null || !mounted) return;
    // a file is only taken from the cache folder, where the share of Android puts it: a link cannot name any file of the device
    if (link is QuickCaptureLink && link.file != null) {
      final cache = (await getTemporaryDirectory()).path;
      if (!captureFileAllowed(link.file!, cache, mobile: !kIsWeb && (Platform.isAndroid || Platform.isIOS))) return;
    }
    if (!mounted) return;
    final result = await showCaptureLink(context, capture, link);
    if (result == null || !mounted) return;
    if (link is QuickCaptureLink && link.text.trim().isEmpty && link.file == null) {
      await _go(index: 3, note: result.noteId); // a blank note: to write in
      return;
    }
    announceCaptured(context, result, () => _go(index: 3, note: result.noteId));
  }

  /// Adds a share from a link; it waits in the settings for the person to take it in.
  Future<void> _addShareLink(String link) async {
    final shares = _app.collab?.nativeShares;
    if (shares == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final p = await shares.addLink(link);
      messenger.showSnackBar(SnackBar(
        content: Text.verbatim(tr('"{name}" is shared with you by {who}. Take it in under Settings, Sharing and files.', {'name': ShareNaming.shown(p.share.name), 'who': p.share.owner})),
        action: SnackBarAction(label: tr('Open'), onPressed: () => _go(index: 5)),
        duration: const Duration(seconds: 10),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim('$e'.replaceFirst('Bad state: ', ''))));
    }
  }

  /// Asks, then fetches the copy of a note that a link points at and opens it as a new note. When the owner of the
  /// copy is in a live session on the note right now (the marker next to the copy says so), joining that is offered.
  Future<void> _openCopy(CopyInvite invite) async {
    final share = _app.collab?.cloudShare;
    if (share == null || _joining || !mounted) return;
    _joining = true;
    SessionInvite? live;
    try {
      live = await share.liveSession(invite);
      if (!mounted) return;
      final who = invite.from == null || invite.from!.isEmpty ? tr('someone') : invite.from!;
      // true: open the copy, false: join the live session, null: neither
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text(live == null ? 'Open a shared note?' : 'Someone is working on this note right now'),
          content: Text.verbatim(live == null
              ? tr('{who} shared a copy of a note with you. It is downloaded from {host} and opened as a new note of your own.', {'who': who, 'host': invite.url.host})
              : tr('{who} is in a live session on this note. Join it and work on the note together, or open a copy of your own?', {'who': who})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            if (live != null) TextButton(key: const ValueKey('copy-yes'), onPressed: () => Navigator.pop(context, true), child: const Text('Open a copy')),
            FilledButton(
              key: ValueKey(live == null ? 'copy-yes' : 'copy-live'),
              onPressed: () => Navigator.pop(context, live == null),
              child: Text(live == null ? 'Open' : 'Join the live session'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == false) {
        // the person chose to join: they hold the link of a copy, which lets them in without the owner being asked
        final id = await showJoining(context, _app.collab!, live!, proofKey: invite.key);
        if (id != null && mounted) await _go(index: 3, note: id);
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text('Downloading the note...'), duration: const Duration(seconds: 30)));
      try {
        final result = await share.openCopy(invite);
        await _app.collab!.rememberCopy(result.noteId, invite);
        messenger.hideCurrentSnackBar();
        if (mounted) await _go(index: 3, note: result.noteId);
      } catch (e) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text.verbatim(tr('Could not open the shared note: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')})), duration: const Duration(seconds: 8)));
      }
    } finally {
      _joining = false;
    }
  }

  /// Asks, then joins the session of [invite]; on success its note opens.
  Future<void> _joinSession(SessionInvite invite) async {
    final collab = _app.collab;
    if (collab == null || _joining || !mounted) return;
    _joining = true;
    try {
      final who = invite.from == null || invite.from!.isEmpty ? 'someone' : invite.from!;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: const Text('Join a live session?'),
          content: Text.verbatim(tr('Join {who} to work on a note together. You get a copy of the note, and what you both do shows up for both of you while the session lasts.', {'who': who})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
            FilledButton(key: const ValueKey('join-yes'), onPressed: () => Navigator.pop(context, true), child: const Text('Join')),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      final id = await showJoining(context, collab, invite);
      if (id != null && mounted) await _go(index: 3, note: id);
    } finally {
      _joining = false;
    }
  }

  Future<void> _joinByLink() async {
    final invite = await askForInvite(context);
    if (invite is SessionInvite) await _joinSession(invite);
    if (invite is CopyInvite) await _openCopy(invite);
  }

  late final WindowCloser _closer = WindowCloser(
    saveNote: () async {
      final id = _activeNoteId;
      if (_selectedNavIndex == 3 && id != null) {
        await _editorOf(id)?.saveNow();
        final beside = _splitNoteId;
        if (beside != null) await _editorOf(beside)?.saveNow();
      }
      await _app.locks?.sealAll(); // (locked notes are put away; nothing of them stays open)
    },
    hasCopies: () => _app.collab?.cloudShare?.markers.hasMarkers ?? false,
    putUpCopies: () async => await _app.collab?.cloudShare?.markers.retire(),
    hideWindow: _hideWindow,
    endProcess: (code) => endProcess(code),
    desktop: !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS),
  );

  /// The window is being closed (desktop): see [WindowCloser].
  @override
  Future<AppExitResponse> didRequestAppExit() => _closer.closeDown();

  /// Hides the window of the app (Linux); false where that is not possible.
  Future<bool> _hideWindow() async {
    if (kIsWeb || !Platform.isLinux) return false;
    try {
      await windowChannel.invokeMethod<void>('hide');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// How long an open locked note stays open when the app is not in front.
  static const lockGrace = Duration(seconds: 30);
  Timer? _lockTimer;
  DateTime? _leftAt;

  /// Puts away the locked notes that are open (the screen goes back to the dashboard).
  void _lockAway() {
    final locks = _app.locks;
    if (locks != null && locks.repository.locks.unlocked.isNotEmpty && mounted) {
      if (_selectedNavIndex == 3) {
        _go(index: 0);
      } else {
        unawaited(locks.sealAll());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inFront = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    _reportOpenNotes();
    // back from sending the link (or from anything else): live sessions get their connections back
    final share = _app.collab?.cloudShare;
    if (state == AppLifecycleState.resumed) {
      _app.collab?.wake();
      _app.sync?.wake();
      _app.sync?.cloud?.wake();
      _app.collab?.nativeShares?.wake();
      share?.markers.resume();
      // back after a short look elsewhere: the notes are as they were; after longer (a suspended app runs no timer) they are put away
      _lockTimer?.cancel();
      final left = _leftAt;
      _leftAt = null;
      if (left != null && DateTime.now().difference(left) >= lockGrace) _lockAway();
    } else {
      // out of sight: a locked note that is open stays so for a moment (a quick look at something else), then it is put away
      _leftAt ??= DateTime.now();
      _lockTimer?.cancel();
      if (state == AppLifecycleState.detached) {
        _lockAway();
      } else {
        _lockTimer = Timer(lockGrace, _lockAway);
      }
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // out of reach now: the markers of the shared copies say so (or run out, if there is no time)
      share?.markers.retire();
    }
  }

  bool _inFront = true;
  Set<String> _reportedOpen = const {};

  /// Tells the sync service which notes are on the screen (two devices of one person with the same note open work on it live).
  void _reportOpenNotes() {
    final sync = _app.sync;
    if (!mounted || (sync == null && _app.collab?.nativeShares == null)) return;
    final onScreen = _inFront && _selectedNavIndex == 3;
    final ids = <String>{
      if (onScreen && _activeNoteId != null) _activeNoteId!,
      if (onScreen && _splitShown && _splitNoteId != null) _splitNoteId!,
    };
    if (ids.length == _reportedOpen.length && ids.containsAll(_reportedOpen)) return;
    _reportedOpen = ids;
    sync?.setOpenNotes(ids);
    _app.collab?.nativeShares?.setOpenNotes(ids,); // (a note of a share is worked on live with the people it is shared with)
  }

  @override
  void dispose() {
    _notesChat?.dispose();
    _lockTimer?.cancel();
    _app.automations?.openEditor = null;
    WidgetsBinding.instance.removeObserver(this);
    _app.collab?.removeListener(_collabChanged);
    _links?.cancel();
    _notices?.cancel();
    _agentActivity?.cancel();
    _app.aiSwitch?.removeListener(_aiSwitched);
    _app.features?.removeListener(_featuresChanged);
    _shortcuts.removeHandler(_onShortcut);
    _focusedPane.dispose();
    _railSlide.dispose();
    super.dispose();
  }

  /// Web: the flag a landing page reads to send a signed-in visitor to the app (see setSignedInFlag).
  void _markSignedIn() => setSignedInFlag(_app.sync?.isSetUp ?? false);

  @override
  void initState() {
    super.initState();
    // a sync does not replace a note under an editor that has it open
    _app.sync?.library.busy = () => {
      if (_selectedNavIndex == 3 && _activeNoteId != null) _activeNoteId!,
      ?_splitNoteId,
    };
    if (kIsWeb) {
      _app.sync?.addListener(_markSignedIn);
      _markSignedIn();
    }
    _app.automations?.openEditor = _editorOf; // (a note that is open is changed through its editor)
    WidgetsBinding.instance.addObserver(this);
    _shortcuts.addHandler(_onShortcut);
    _app.repository.purgeTrash().catchError((Object _) => 0); // what lay in the trash for long enough
    _app.repository.listNotes().then((all) => _previews.tidy({for (final n in all) n.id})).catchError((Object _) {}); // pictures of notes that are gone
    // a tap on a reminder's notification opens what it was about
    _app.reminders?.onOpen = (kind, id) {
      if (!mounted) return;
      if (kind == ReminderKind.note && id != null) {
        _go(index: 3, note: id);
      } else if (kind == ReminderKind.task) {
        _go(index: 2);
      } else if (kind == ReminderKind.review && _app.review != null) {
        // the review is offered on the dashboard, where its button is
        _go(index: 0).then((_) {
          if (mounted) showWeeklyReview(context, service: _app.review!, reminders: _app.reminders, onOpenNote: (id) => _go(index: 3, note: id));
        });
      }
    };
    _app.aiSwitch?.addListener(_aiSwitched);
    _app.features?.addListener(_featuresChanged);
    _app.collab?.addListener(_collabChanged);
    _notices = _app.collab?.notices.listen(_showNotice);
    _agentActivity = _app.mcp?.activity.listen(_showAgentNotice);
    if (_app.collab != null) {
      try {
        // a link that opens the app (or that is clicked while it runs) is an invitation
        final links = AppLinks();
        _links = links.uriLinkStream.listen(_onLink, onError: (_) {});
        links.getInitialLink().then((uri) {
          if (uri != null) _onLink(uri);
        }, onError: (_) {});
      } catch (_) {
        // no way to receive links on this platform: pasting an invite still works
      }
    }
    final automations = _app.automations;
    if (automations != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => automations.bus.emit(AppEvent(AutomationEvent.appStarted.name)));
    }
    _app.repository.settings.get(_railHiddenKey).then((v) {
      if (!mounted || v != '1') return;
      _railSlide.value = 0; // (hidden from the start: no sliding out at launch)
      setState(() => _railHidden = true);
    });
  }

  ShortcutService get _shortcuts => _app.shortcuts ?? ShortcutService.fallback;

  /// The shortcuts for going places and for the frame of the app (those of the open note are handled by the note).
  /// The person pressed trigger [n] (a key, or the pen's button): the automations for it run for the note that is open, if there is one.
  Future<void> _fireTrigger(int n) async {
    final automations = _app.automations;
    if (automations == null || !mounted) return;
    final id = _selectedNavIndex == 3 ? _activeNoteId : null;
    final handle = id == null ? null : _editorOf(id);
    final info = id == null ? null : await _app.repository.noteInfo(id);
    final rules = automations.all.where((a) => a.enabled && a.event == AutomationEvent.triggerPressed && (a.params['trigger'] ?? '1') == '$n').length;
    await automations.bus.emit(AppEvent(AutomationEvent.triggerPressed.name,
        noteId: id,
        title: handle?.noteTitle ?? info?.title ?? '',
        folderId: info?.folderId,
        editor: handle,
        data: {'trigger': n, ...eventVars({'trigger': '$n'})}));
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 3),
      content: Text.verbatim(rules == 0
          ? tr('No automation is set for trigger {n} (see Automations)', {'n': n})
          : trCount(rules, 'Trigger {trigger}: ran 1 automation', 'Trigger {trigger}: ran {n} automations').replaceAll('{trigger}', '$n')),
    ));
  }

  bool _onShortcut(String id) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final trigger = RegExp(r'^automation\.trigger([123])$',).firstMatch(id)?.group(1);
    if (trigger != null) {
      unawaited(_fireTrigger(int.parse(trigger)));
      return true;
    }
    final place = navigationActions[id];
    if (place != null) {
      if (!_navItems.contains(place)) return false;
      unawaited(_go(index: place));
      return true;
    }
    if (id == 'app.sidebar' && MediaQuery.sizeOf(context).width >= 600) {
      _setRailHidden(!_railHidden);
      return true;
    }
    return false;
  }

  void _setRailHidden(bool hidden) {
    setState(() => _railHidden = hidden);
    unawaited(hidden ? _railSlide.reverse() : _railSlide.forward());
    _app.repository.settings.set(_railHiddenKey, hidden ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportOpenNotes();
      final measured = (_railKey.currentContext?.findRenderObject() as RenderBox?)?.size.width;
      if (mounted && measured != null && measured != _railWidth && !_railSlide.isAnimating) setState(() => _railWidth = measured);
    });
    if (MediaQuery.sizeOf(context).width < 600) return _phoneShell();
    final extended = MediaQuery.sizeOf(context).width > 900;
    // (the bar's width is whatever it measured the last time it was there, larger text makes it wider; until then NavigationRail's own 72 or 256, and the divider)
    final railWidth = _railWidth ?? (extended ? 256.0 : 72.0) + 1;
    final bar = RepaintBoundary(
      key: _railKey,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NavigationRail(
            selectedIndex: _navItems.contains(_selectedNavIndex) ? _navItems.indexOf(_selectedNavIndex) : null,
            extended: MediaQuery.of(context).size.width > 900,
            onDestinationSelected: (position) => _go(index: _navItems[position]),
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              child: MediaQuery.of(context).size.width > 900
                  ? Row(
                      children: [
                        const NotationLogo( size: 32),
                        const SizedBox(width: 12),
                        const Text(
                          'Notation',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 8),
                        _foldButton(),
                      ],
                    )
                  : Column(
                      children: [const NotationLogo( size: 32),
                        _foldButton()
                      ],
                    ),
            ),
            destinations: [for (final i in _navItems) _destinations[i]!],
            trailing: !kIsWeb || _app.sync == null
                ? null
                : Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: extended
                            ? TextButton.icon(
                                key: const ValueKey('rail-sign-out'),
                                onPressed: () =>
                                    confirmSignOut(context, _app.sync!),
                                icon: const Icon(Icons.logout),
                                label: Text(tr('Sign out')),
                              )
                            : IconButton(
                                key: const ValueKey('rail-sign-out'),
                                tooltip: tr('Sign out'),
                                onPressed: () =>
                                    confirmSignOut(context, _app.sync!),
                                icon: const Icon(Icons.logout),
                              ),
                      ),
                    ),
                  ),
          ),
        const VerticalDivider(width: 1, thickness: 1),
      ]),
    );
    final page = RepaintBoundary(child: _buildActiveView());
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: LayoutBuilder(builder: (context, box) {
            // The page is laid out once, at the size it ends up with, and is only moved while the bar slides: laying a whole page out again on every frame is what made it stutter.
            final pageWidth = box.maxWidth - (_railHidden ? 0 : railWidth);
            return AnimatedBuilder(
              animation: _railSlide,
              builder: (context, _) {
                final slid = Curves.easeInOutCubic.transform(_railSlide.value);
                return Stack(children: [
                  // (the page comes first and always: a page that changes its place in the list would be built anew)
                  Positioned(left: railWidth * slid, top: 0, bottom: 0, width: pageWidth, child: page),
                  if (_railSlide.value > 0) Positioned(left: -railWidth * (1 - slid), top: 0, bottom: 0, child: bar),
                ]);
              },
            );
          }),
        ),
        // a little tab at the left edge brings the bar back
        if (_railHidden)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Material(
                color: Theme.of(context).colorScheme.primaryContainer,
                elevation: 4,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(10))),
                child: InkWell(
                  key: const ValueKey('rail-show'),
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
                  onTap: () => _setRailHidden(false),
                  child: Tooltip(
                    message: tr('Show the menu'),
                    child: SizedBox(
                      width: 28,
                      height: 72,
                      child: Icon(Icons.chevron_right, size: 24, color: Theme.of(context,).colorScheme.onPrimaryContainer),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  final _phoneScaffold = GlobalKey<ScaffoldState>();

  /// A phone: the main places sit in a bar at the bottom, every place is in the menu (the button at the top left, or a swipe from the left edge); an open note gets the whole screen.
  Widget _phoneShell() {
    final inBar = [for (final i in const [0, 1, 6, 9, 3]) if (_navItems.contains(i)) i];
    final inBarNow = inBar.contains(_selectedNavIndex);
    NavigationDestination of(int i) {
      final d = _destinations[i]!;
      return NavigationDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: tr((d.label as Text).data!), tooltip: '');
    }

    final editing = _selectedNavIndex == 3 && _activeNoteId != null;
    return PopScope(
      // the system back gesture closes the open note instead of leaving the app
      canPop: !editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(index: 0);
      },
      child: Scaffold(
      key: _phoneScaffold,
      drawerEnableOpenDragGesture: !editing,
      drawer: NavigationDrawer(
        selectedIndex: _navItems.contains(_selectedNavIndex) ? _navItems.indexOf(_selectedNavIndex) : null,
        onDestinationSelected: (p) {
          Navigator.pop(context);
          _go(index: _navItems[p]);
        },
        children: [
          AccountPanel(
            profile: _app.profile,
            sync: _app.sync,
            onSettings: () {
              Navigator.pop(context);
              _go(index: 5);
            },
          ),
          const SizedBox(height: 8),
          for (final i in _navItems)
            NavigationDrawerDestination(icon: _destinations[i]!.icon, selectedIcon: _destinations[i]!.selectedIcon, label: Text(tr((_destinations[i]!.label as Text).data!))),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Stack(children: [
          // the pages bring their own bars: the title makes room for the menu button over their top left corner
          Theme(
            data: Theme.of(context).copyWith(appBarTheme: Theme.of(context,).appBarTheme.copyWith(titleSpacing: 56)),
            child: _selectedNavIndex == 9 ? Padding(padding: const EdgeInsets.only(top: 48), child: _buildActiveView()) : _buildActiveView(),
          ),
          if (!editing)
            Positioned(
              top: 4,
              left: 4,
              child: ValueListenableBuilder<int>(
                valueListenable: selectionBarsShowing,
                // selecting notes puts a bar with its own close button where the menu button sits
                builder: (context, selecting, _) => selecting > 0
                    ? const SizedBox.shrink()
                    : IconButton(key: const ValueKey('phone-menu'), tooltip: tr('Menu'), icon: const Icon(Icons.menu), onPressed: () => _phoneScaffold.currentState?.openDrawer()),
              ),
            ),
        ]),
      ),
      // reading and writing a note wants the height, so the bar steps aside there
      bottomNavigationBar: editing
          ? null
          : NavigationBar(
              // a place that is not in the bar (the calendar, say) leaves the bar without a mark
              selectedIndex: inBarNow ? inBar.indexOf(_selectedNavIndex) : 0,
              indicatorColor: inBarNow ? null : Colors.transparent,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              onDestinationSelected: (p) => _go(index: inBar[p]),
              destinations: [for (final i in inBar) of(i)],
            ),
    ));
  }

  Widget _foldButton() => IconButton(
        key: const ValueKey('rail-hide'),
        tooltip: tr('Hide the menu'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.chevron_left),
        onPressed: () => _setRailHidden(true),
      );

  Widget _buildActiveView() {
    switch (_selectedNavIndex) {
      case 1:
        return FolderView(
          collab: _app.collab,
          repository: _app.repository,
          noteFiles: _f(Feature.noteFiles) ? _app.noteFiles : null,
          templates: _templates,
          previews: _previews,
          sync: _app.sync,
          tags: _app.tags,
          reminders: _app.reminders,
          onOpenNote: (id) => _go(index: 3, note: id),
        );
      case 9:
        final ai = _app.ai;
        if (ai == null) return const SizedBox.shrink();
        final chat = _notesChat ??= AssistantChat(ai: ai, knowledge: _knowledge);
        return Material(
          color: Theme.of(context).colorScheme.surface,
          child: AssistantPanel(
            key: const ValueKey('notes-assistant'),
            ai: ai,
            chat: chat,
            flashcards: false,
            title: tr('Ask your notes'),
            invitation: tr('Ask anything: the notes that fit your question are found first, then the passages in them that answer it.'),
            suggestions: [tr('What did I write about deadlines?'), tr('Summarize my latest notes'), tr('Where did I note something about exams?')],
            onOpenSource: _openAtPage,
          ),
        );
      case 8:
        return GraphView(service: _graphs, onOpen: _openAtPage, cards: _app.cards);
      case 6:
        return SearchView(
          repository: _app.repository,
          initial: _searchQuery,
          onChanged: (q) => _searchQuery = q,
          tags: _app.tags,
          initialFilter: _searchFilter,
          onFilterChanged: (f) => _searchFilter = f,
          onOpen: _openFromSearch,
        );
      case 2:
        return CalendarView(reminders: _app.reminders, mirror: _app.mirror, repository: _app.tasks, caldav: _app.caldav, device: _app.device, ics: _app.ics, style: _app.style);
      case 3:
        final id = _activeNoteId;
        if (id == null) {
          return const Center(child: Text('Open a note from the dashboard or create a new one.'));
        }
        final beside = _splitNoteId;
        return LayoutBuilder(builder: (context, box) {
          // two notes need room; on a narrow window the second waits, and splitting is not offered
          _roomToSplit = box.maxWidth >= 900;
          if (beside == null || beside == id) return _editor(id);
          _splitShown = _roomToSplit;
          if (!_splitShown) return _editor(id);
          final left = (box.maxWidth * _splitFraction).clamp(380.0, box.maxWidth - 380);
          return Row(children: [
            SizedBox(width: left, child: _pane(id, _editor(id))),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                key: const ValueKey('split-divider'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => setState(() => _splitFraction = ((left + d.delta.dx) / box.maxWidth).clamp(0.2, 0.8)),
                child: Container(width: 10, color: Theme.of(context,).dividerColor.withValues(alpha: 0.3), child: Center(child: Container(width: 3, height: 40, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))))),
              ),
            ),
            Expanded(child: _pane(beside, _editor(beside, second: true))),
          ]);
        });
      case 4:
        final automations = _app.automations;
        if (automations == null) return const Center(child: Text('Automations are not available here.'));
        return AutomationsView(service: automations, repository: _app.repository, extensions: _app.extensions, ai: _aiOn ? _app.ai : null, templates: _templates);
      case 5:
        return SettingsScreen(repository: _app.repository, sync: _app.sync, speech: _app.speech, theme: _app.appTheme, handwriting: _app.handwriting, math: _app.math, llm: _app.llm, embeddings: _app.embeddings, noteFiles: _app.noteFiles, collab: _app.collab, onOpenNote: (id) => _go(index: 3, note: id), ai: _app.ai, aiSwitch: _app.aiSwitch, features: _app.features, citations: _app.citations, spell: _app.spell, ocr: _app.ocr, subject: _app.subject, accessibility: _app.accessibility, stylus: _app.stylus, shortcuts: _app.shortcuts, extensions: _app.extensions, automations: _app.automations, profile: _app.profile, mcp: _app.mcp);
      case 0:
      default:
        return DashboardView(
          tags: _app.tags,
          automations: _app.automations,
          planner: _f(Feature.flashcards) && _f(Feature.calendar) ? _app.planner : null,
          collab: _app.collab,
          repository: _app.repository,
          noteFiles: _f(Feature.noteFiles) ? _app.noteFiles : null,
          templates: _templates,
          previews: _previews,
          speech: _app.speech,
          cards: _f(Feature.flashcards) ? _app.cards : null,
          reminders: _app.reminders,
          audio: _app.audio,
          capture: _app.capture,
          review: _app.review,
          onJoinSession: _app.collab == null || !_f(Feature.live) ? null : _joinByLink,
          sync: _app.sync,
          onOpenNote: (id) => _go(index: 3, note: id),
        );
    }
  }

  /// One of the notes shown side by side: a click or a touch in it makes the keyboard shortcuts its own, and a bar on top says which.
  Widget _pane(String id, Widget child) => Listener(
        onPointerDown: (_) => _focusedPane.value = id,
        child: Column(children: [
          ValueListenableBuilder<String?>(
            valueListenable: _focusedPane,
            builder: (context, focused, _) => Container(height: 3, color: (focused ?? _activeNoteId) == id ? Theme.of(context).colorScheme.primary : Colors.transparent),
          ),
          // the note lays itself out for the room it has, not for the whole window
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => MediaQuery(data: MediaQuery.of(context,).copyWith(size: Size(box.maxWidth, box.maxHeight)), child: child),
            ),
          ),
        ]),
      );

  Widget _editor(String id, {bool second = false}) {
        return FixedPageNoteEditor(
          key: _editorKeys.putIfAbsent(id, () => GlobalKey()), // a different note gets a fresh editor
          noteId: id,
          repository: _app.repository,
          noteFiles: _f(Feature.noteFiles) ? _app.noteFiles : null,
          collab: _f(Feature.live) ? _app.collab : null,
          history: _f(Feature.history) ? _app.history : null,
          tags: _app.tags,
          tasks: _app.tasks,
          calendar: CalendarAccess.of(caldav: _app.caldav, device: _app.device, ics: _app.ics),
          pullLatest: _app.sync?.cloud == null && _app.collab?.nativeShares == null
              ? null
              : (noteId, allow) async {
                  final fromCloud = await _app.sync?.cloud?.refreshNote(noteId, allow: allow) ?? false;
                  return fromCloud || await (_app.collab?.nativeShares?.refreshNote(noteId, allow: allow) ?? Future.value(false));
                },
          handwriting: _aiOn && _f(Feature.handwriting) ? _app.handwriting : null,
          math: _aiOn && _f(Feature.mathInk) ? _app.math : null,
          onOpenNote: (other) => second ? _openBeside(other) : _go(note: other),
          onOpenBeside: second || !_roomToSplit ? null : _openBeside,
          onCloseSplit: second ? _closeSplit : (_splitShown && _splitNoteId != null && _splitNoteId != id ? _closeFirst : null),
          locks: _app.locks,
          onLeave: second ? _closeSplit : () => _go(index: 0),
          paneActive: _splitNoteId == null ? null : () => (_focusedPane.value ?? _activeNoteId) == id,
          onPdfImported: () => _scanDates(id),
          ai: _aiOn && _f(Feature.assistant) ? _app.ai : null,
          features: _app.features,
          spell: _f(Feature.spelling) ? _app.spell : null,
          ocr: _aiOn ? _app.ocr : null,
          subject: _app.subject,
          stylus: _app.stylus,
          shortcuts: _app.shortcuts,
          extensions: _app.extensions,
          onAddTask: (title, due) => _app.tasks.createTask(title, dueDate: due, auto: true),
          readAloud: _reader,
          speech: _app.speech,
          cards: _app.cards,
          bookmarks: _app.bookmarks,
          links: _app.links,
          reminders: _app.reminders,
          audio: _app.audio,
          onOpenNoteAt: second ? null : _openAtPage,
          onTrigger: _fireTrigger,
          initialFind: _openWithFind?.note == id ? _openWithFind!.query : null,
          initialPage: _openWithFind?.note == id ? _openWithFind!.page : 0,
        );
  }
}
