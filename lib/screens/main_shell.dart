import 'package:material_symbols_icons/symbols.dart';
import 'window_close.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import '../capture/capture_link.dart';
import '../sync/calendar_access.dart';
import 'capture_dialogs.dart';
import 'weekly_review_dialog.dart';
import '../app_services.dart';
import '../ai/extension_agent_tools.dart';
import '../extensions/extension_templates.dart';
import '../markdown/extension_block.dart';
import '../extensions/command_api.dart';
import '../extensions/extension_doors.dart' show CommandPlace;
import 'extension_commands.dart';
import 'extension_dialogs.dart';
import '../mcp/mcp_service.dart' show McpActivity;
import 'dart:async';
import 'dart:convert';
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
import 'note_picker_dialog.dart';
import 'workspace_tabs.dart';
import '../speech/read_aloud.dart';
import 'graph_view.dart';
import '../graph/graph_service.dart';
import '../previews/note_preview.dart';
import '../ai/assistant_chat.dart';
import '../ai/citations.dart' show quoteQuery;
import '../ai/note_agent.dart';
import '../ai/note_knowledge.dart';
import '../ai/note_lookup.dart';
import '../extensions/extension_manifest.dart' show ExtensionPermission;
import '../automations/note_sorter.dart';
import '../templates/templates.dart';
import 'lock_dialogs.dart';
import '../lock/note_lock_service.dart' show LockMode;
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
import 'graph_study.dart';
import 'learning_hub.dart';
import 'study_session_screen.dart';
import '../review/study_material_reader.dart' show readPageTexts;
import '../review/study_generate.dart';
import '../review/study_topics.dart';
import '../reminders/reminder.dart' show ReminderKind;
import '../widgets/notation_logo.dart';
import '../widgets/notation_sidebar.dart';
import 'folder_view.dart';
import '../data/note_data.dart' show NoteSummary, isUntitled;
import '../data/debounced_changes.dart';
import 'bulk_note_actions.dart' show selectionBarsShowing;
import 'fixed_page_note_editor.dart';
import '../style/motion.dart';
import '../style/platform_dialog.dart';
import 'phone_nav_settings.dart';

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
  /// (3, the open note, is not among them: notes open as tabs, and on a phone from the dashboard, so it has no place of its own in the menu)
  List<int> get _navItems => [0, 1, 6, if (_assistantOn) 9, if (_aiOn) 8, if (_f(Feature.calendar)) 2, if (_learnOn) 10, if (_f(Feature.automations)) 4, 5];

  /// Whether the study plans are offered (they go by the calendar).
  bool get _studyOn => _app.planner != null && _f(Feature.calendar);

  /// Whether the cards kept for review are offered (reviewing needs no AI; making them does).
  bool get _cardsOn => _app.cards != null && _f(Feature.flashcards);

  /// Whether the learning hub has a place in the menu: it holds the study plans and the cards.
  bool get _learnOn => _studyOn || _cardsOn;

  /// Whether the assistant that answers from all notes is offered (its own place in the menu).
  bool get _assistantOn => _app.ai != null && _aiOn && _f(Feature.assistant);

  /// The conversation about all notes; kept while the app runs, so that leaving the page and coming back loses nothing.
  AssistantChat? _notesChat;

  /// A question for the assistant about all notes, put in its field from the graph ("Ask the assistant" on a topic).
  final _notesDraft = ValueNotifier<String?>(null);

  static const _destinations = {
    9: NavigationRailDestination(icon: Icon(Symbols.auto_awesome), selectedIcon: Icon(Symbols.auto_awesome), label: Text('Assistant')),
    0: NavigationRailDestination(icon: Icon(Symbols.home), selectedIcon: Icon(Symbols.home), label: Text('Dashboard')),
    1: NavigationRailDestination(icon: Icon(Symbols.folder), selectedIcon: Icon(Symbols.folder), label: Text('Folders')),
    2: NavigationRailDestination(icon: Icon(Symbols.calendar_month), selectedIcon: Icon(Symbols.calendar_month), label: Text('Calendar')),
    10: NavigationRailDestination(icon: Icon(Symbols.school), selectedIcon: Icon(Symbols.school), label: Text('Learning hub')),
    3: NavigationRailDestination(icon: Icon(Symbols.note_alt), selectedIcon: Icon(Symbols.note_alt), label: Text('Note')),
    4: NavigationRailDestination(icon: Icon(Symbols.bolt), selectedIcon: Icon(Symbols.bolt), label: Text('Automations')),
    6: NavigationRailDestination(icon: Icon(Symbols.search), selectedIcon: Icon(Symbols.search), label: Text('Search')),
    8: NavigationRailDestination(icon: Icon(Symbols.hub), selectedIcon: Icon(Symbols.hub), label: Text('Graph')),
    5: NavigationRailDestination(icon: Icon(Symbols.settings), selectedIcon: Icon(Symbols.settings), label: Text('Settings')),
  };

  static const _sidebarOrderKey = 'sidebar_order';

  /// The order of the menu the person gave by dragging (a place keeps to its group).
  List<int> _sidebarOrder = const [];

  Future<void> _restoreSidebarOrder() async {
    try {
      final raw = await _app.repository.settings.get(_sidebarOrderKey);
      if (raw == null || !mounted) return;
      setState(() => _sidebarOrder = [for (final v in jsonDecode(raw) as List) v as int]);
    } catch (_) {}
  }

  void _sidebarReordered(List<int> ids) {
    setState(() => _sidebarOrder = ids);
    _app.repository.settings.set(_sidebarOrderKey, jsonEncode(ids));
  }

  SidebarItem _sidebarItem(int i) {
    final d = _destinations[i]!;
    return SidebarItem(id: i, icon: (d.icon as Icon).icon!, selectedIcon: (d.selectedIcon as Icon).icon!, label: (d.label as Text).data!);
  }

  void _aiSwitched() {
    if (!mounted) return;
    _pruneTabs(); // (the assistant and the graph go with the AI)
    setState(() {});
  }

  void _featuresChanged() {
    if (!mounted) return;
    _pruneTabs(); // a place of the menu that goes away while it is shown: its tab goes
    setState(() {});
  }

  static const _tabsKey = 'workspace_tabs';

  /// Keeps the open tabs, the ones on screen and the one with the keyboard for the next launch.
  void _saveTabs() {
    _app.repository.settings.set(_tabsKey, jsonEncode({'tabs': _tabs, 'shown': _shown, 'focused': _focused}));
  }

  /// Opens the tabs of the last run again (what is gone since, a note that was deleted or a place that was switched off, is left out;
  /// a locked note stays a tab but is not opened before it is asked for). Not if something was opened in the meantime.
  Future<void> _restoreTabs() async {
    try {
      final raw = await _app.repository.settings.get(_tabsKey);
      if (raw == null || !mounted) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final saved = [for (final k in data['tabs'] as List) k as String];
      final live = <String>[], openable = <String>{};
      // (a graph deleted since, here or on another device, is not brought back)
      Set<int>? graphIds;
      if (saved.any(_isGraph)) {
        await _graphs.refresh();
        if (!mounted) return;
        if (_graphs.listed) graphIds = {for (final g in _graphs.graphs) g.id};
      }
      for (final k in saved) {
        final gid = _graphIdOf(k);
        if (gid != null && graphIds != null && !graphIds.contains(gid)) continue;
        if (live.contains(k)) continue;
        if (_isNote(k)) {
          if (!await _app.repository.noteExists(k)) continue;
          live.add(k);
          if (await _app.locks?.modeOf(k) == LockMode.none || _app.locks == null) openable.add(k);
        } else {
          final p = _isGraph(k) ? 8 : _pageOf(k);
          if (p != null && p != 3 && !_navItems.contains(p)) continue;
          live.add(k);
          openable.add(k);
        }
      }
      if (!mounted || live.isEmpty || _tabs.length != 1 || _tabs.first != _homeKey || _shown.length != 1 || _navigating) return;
      final shown = [for (final k in data['shown'] as List) if (openable.contains(k)) k as String];
      if (shown.isEmpty) shown.add(openable.contains(_homeKey) ? _homeKey : openable.first);
      final focus = data['focused'];
      await _transition(tabs: live, shown: shown, focus: focus is String && shown.contains(focus) ? focus : shown.last);
    } catch (_) {
      // an unreadable record: start with the dashboard
    }
  }

  /// A tab of a place that is not in the menu any more (the AI is off, a tool was switched off) goes.
  void _pruneTabs() {
    bool stale(String k) {
      final p = _isGraph(k) ? 8 : _pageOf(k);
      return p != null && p != 3 && !_navItems.contains(p);
    }

    if (_tabs.any(stale)) {
      _tabs = [..._tabs]..removeWhere(stale);
      _shown = [..._shown]..removeWhere(stale);
      if (_tabs.isEmpty) _tabs = [_homeKey];
      if (_shown.isEmpty) _shown = [_tabs.first];
      if (!_shown.contains(_focused)) _focused = _shown.last;
      _focusedPane.value = _focused;
    }
    _selectedNavIndex = _navOf(_focused);
  }

  /// The work area: the tabs that are open (notes, graphs, and the places of the menu, `page:<n>`: `graph:<id>` holds one kept graph, [_graphKey] the view that has none yet), the ones that are on screen next to
  /// each other (wide windows hold several), and the one the keyboard is for. A place of the menu opens as a tab too (once).
  static const _graphKey = 'graph';
  List<String> _tabs = [_homeKey];
  List<String> _shown = [_homeKey];
  String? _focused = _homeKey;
  final List<String> _recent = []; // the tabs that had the keyboard, the last one first
  List<String> _visible = const []; // what the last layout had room for
  int _maxPanes = 1; // how many fit next to each other
  final Map<String, double> _weights = {}; // the share of the width of a pane
  final Map<String, String> _titles = {}; // the titles of the tabs (a note that is open gives its own)
  final Map<String, GlobalKey> _graphWidgetKeys = {};

  /// The places and graphs that were on screen once: they stay built (out of sight, not painted, no animations) while their tab is
  /// not on screen, so that coming back to one is a move, not a build from scratch (and the scroll place, the search, the open graph stay).
  final Set<String> _alive = {};

  /// Notes that were left but whose editors are kept for a while (out of sight), so that coming back is instant: when they were left.
  /// At most [_keptMax] of them, each for [_keptFor]; a locked note is never kept (it is put away when left).
  final Map<String, DateTime> _kept = {};
  static const _keptMax = 4;
  static const _keptFor = Duration(minutes: 10);
  Timer? _keptTimer;

  /// A kept editor is let go (a note that is to open at a page, or with a search, starts anew).
  void _forgetKept(String id) {
    if (_kept.remove(id) == null || !mounted) return;
    setState(() => _editorKeys.remove(id));
  }

  /// Drops the kept notes that are too many or too old (their editors go with them).
  void _expireKept() {
    final now = DateTime.now();
    final old = [for (final e in _kept.entries) if (now.difference(e.value) >= _keptFor) e.key];
    final ordered = _kept.keys.toList()..sort((a, b) => _kept[b]!.compareTo(_kept[a]!));
    final surplus = ordered.skip(_keptMax);
    final drop = {...old, ...surplus};
    if (drop.isNotEmpty && mounted) {
      setState(() {
        for (final k in drop) {
          _kept.remove(k);
          _editorKeys.remove(k);
        }
      });
    }
    _keptTimer?.cancel();
    _keptTimer = _kept.isEmpty ? null : Timer(const Duration(seconds: 30), _expireKept);
  }


  /// Rung when a kept page (dashboard, folders, calendar) comes to the front again: what changed while it was away is read.
  final _pageRefresh = _Refresh();

  /// The starred notes the bar shows under the places (the newest first), and the request to show them all in the folder view.
  List<NoteSummary> _sideFavourites = const [];
  final _showFavourites = ValueNotifier<bool>(false);
  StreamSubscription<void>? _favouritesLive;

  Future<void> _loadSideFavourites() async {
    final all = await _app.repository.listNotes();
    final favs = [for (final n in all) if (n.favorite) n]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    final ids = [for (final n in favs.take(5)) '${n.id}|${n.title}'];
    if (ids.join('\n') == [for (final n in _sideFavourites) '${n.id}|${n.title}'].join('\n')) return;
    setState(() => _sideFavourites = favs.take(5).toList());
  }

  /// What the bar shows in its empty room: a few favourites (as many as fit, at most five) and a button for all of them.
  Widget _favouritesFill(double room) {
    const rowHeight = 34.0, head = 17.0 + 36.0;
    final fit = ((room - head - 8) / rowHeight).floor().clamp(0, 5);
    if (_sideFavourites.isEmpty || fit < 1) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final quiet = scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8), child: Divider(height: 1, thickness: 1, color: scheme.outlineVariant)),
        SizedBox(
          height: 36,
          child: InkWell(
            key: const ValueKey('side-favourites'),
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              _showFavourites.value = true;
              _go(index: 1);
            },
            child: Row(children: [
              const SizedBox(width: 10),
              Icon(Symbols.star, size: 20, color: quiet),
              const SizedBox(width: 12),
              Expanded(child: Text.verbatim(tr('Favourites'), style: TextStyle(fontSize: 14, color: quiet))),
              Icon(Symbols.chevron_right, size: 18, color: quiet),
              const SizedBox(width: 6),
            ]),
          ),
        ),
        for (final n in _sideFavourites.take(fit))
          SizedBox(
            height: rowHeight,
            child: InkWell(
              key: ValueKey('side-fav-${n.id}'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => _go(index: 3, note: n.id),
              child: Padding(
                padding: const EdgeInsets.only(left: 42, right: 8),
                child: Align(alignment: Alignment.centerLeft, child: Text.verbatim(isUntitled(n.title) ? tr('Untitled') : n.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: _focused == n.id ? scheme.onSurface : quiet, fontWeight: _focused == n.id ? FontWeight.w500 : FontWeight.w400))),
              ),
            ),
          ),
      ]),
    );
  }
  final Map<String, GlobalKey> _pageKeys = {};
  String? _lastGraph;
  static const _homeKey = 'page:0'; // the dashboard
  static bool _isPage(String? k) => k != null && k.startsWith('page:');
  static int? _pageOf(String? k) => _isPage(k) ? int.tryParse(k!.substring(5)) : null;
  static bool _isNote(String? k) => k != null && !_isGraph(k) && !_isPage(k);

  /// The place of the menu a tab belongs to (a note: the place of the notes).
  static int _navOf(String? k) => k == null ? 0 : (_pageOf(k) ?? (_isGraph(k) ? 8 : 3));
  static bool _isGraph(String? k) => k != null && (k == _graphKey || k.startsWith('graph:'));
  static int? _graphIdOf(String k) => k.startsWith('graph:') ? int.tryParse(k.substring(6)) : null;
  final ValueNotifier<String?> _focusedPane = ValueNotifier(_homeKey);

  /// New notes from templates (needs the note files, which it keeps templates in).
  late final TemplateService? _templates = _app.noteFiles == null ? null : TemplateService(_app.repository, _app.noteFiles!, extra: _app.extensions == null ? null : () => extensionTemplates(_app.extensions!));

  int _selectedNavIndex = 0;

  /// The note the keyboard is for (null when the graph has it, or nothing is open).
  String? get _activeNoteId => _isNote(_focused) ? _focused : null;

  /// The notes among the tabs that are on screen.
  Set<String> _liveNotes(List<String> shown) => {for (final k in shown) if (_isNote(k)) k};

  /// The notes whose editors exist: on screen, or kept.
  Set<String> get _heldNotes => {..._liveNotes(_shown), ..._kept.keys};

  /// The search of all notes as it was left, and the search a note is opened with (taken by that note once).
  SearchQuery? _searchQuery;
  SearchFilter? _searchFilter;
  ({String note, SearchQuery? query, int page})? _openWithFind;

  /// Opens a note at a page (an answer of the assistant points at it).
  Future<void> _openAtPage(String id, int? page, {String? quote}) async {
    _openWithFind = page == null ? null : (note: id, query: quote == null ? null : quoteQuery(quote), page: page);
    if (page != null) _forgetKept(id);
    await _go(index: 3, note: id);
  }

  Future<void> _openFromSearch(String id, SearchQuery query, int page) async {
    _openWithFind = (note: id, query: query, page: page);
    _forgetKept(id);
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

  /// Goes to another part of the app and/or another note. A note (or the graph, place 8) opens in the work area: as a tab if it is
  /// not one yet, and on screen in place of the one that has the keyboard (or as it was, if it is on screen already).
  Future<void> _go({int? index, String? note, String? tab}) async {
    var key = tab ?? note;
    if (key == null) {
      final to = index ?? _selectedNavIndex;
      key = to == 8 ? await _defaultGraphKey() : (to == 3 ? (_activeNoteId ?? _lastNote ?? 'page:3') : 'page:$to');
    }
    if (!mounted) return;
    final tabs = _tabs.contains(key) ? _tabs : [..._tabs, key];
    var shown = _shown;
    if (!shown.contains(key)) {
      final at = shown.indexOf(_focused ?? '');
      shown = [...shown];
      if (at >= 0) {
        shown[at] = key;
      } else {
        shown.add(key);
      }
    }
    return _transition(tabs: tabs, shown: shown, focus: key);
  }

  String? _lastNote;

  /// The one step of everything that changes what is on screen: the menu place, the tabs, the ones shown, the one with the keyboard.
  /// A note that leaves the screen runs the automations for closing it (while its editor is still there) and is put away if locked; one
  /// that comes onto it is fetched and unlocked first, and the automations for opening it run once it has loaded.
  Future<void> _transition({List<String>? tabs, List<String>? shown, String? focus}) async {
    if (_navigating) return;
    final automations = _app.automations;
    var newTabs = tabs ?? _tabs;
    var newShown = shown ?? _shown;
    if (newTabs.isEmpty) {
      newTabs = [_homeKey];
      newShown = [_homeKey];
      focus = _homeKey;
    }
    final oldLive = _liveNotes(_shown);
    final newLive = _liveNotes(newShown);
    final entering = [for (final n in newLive) if (!oldLive.contains(n)) n];
    final leaving = [for (final n in oldLive) if (!newLive.contains(n)) n];

    // a note that is only listed here (a temporary browser) has to be fetched first, a locked one opened
    if (entering.isNotEmpty) {
      _navigating = true;
      try {
        for (final n in entering) {
          if (!await _fetched(n) || !mounted) return;
        }
      } finally {
        _navigating = false;
      }
      for (final n in entering) {
        if (!await _unlocked(n) || !mounted) return;
      }
    }

    if (leaving.isNotEmpty && automations != null) {
      _navigating = true;
      try {
        for (final id in leaving) {
          final handle = _editorOf(id);
          await handle?.saveNow(); // automations that read the note from the database see its latest state
          final info = await _app.repository.noteInfo(id);
          await automations.bus.emit(AppEvent(AutomationEvent.noteClosed.name, noteId: id, title: handle?.noteTitle ?? info?.title ?? '', folderId: info?.folderId, editor: handle));
        }
      } finally {
        _navigating = false;
      }
    }
    if (!mounted) return;
    // a locked note that is left is put away (an encrypted one is taken out of the database again)
    final sealed = {for (final id in leaving) if (_app.locks?.isOpen(id) == true) id};
    for (final id in leaving) {
      await _putAway(id);
    }
    if (!mounted) return;
    final back = [for (final id in entering) if (_kept.containsKey(id)) id]; // (editors that were kept out of sight)
    final before = _visible.contains(_focused) ? _focused : null;
    var focused = focus ?? _focused;
    if (!newShown.contains(focused)) focused = newShown.isEmpty ? null : newShown.last;
    if (!newTabs.contains(focused)) focused = null;
    if (_openWithFind != null && !newShown.contains(_openWithFind!.note)) _openWithFind = null;
    final lost = {..._tabs}.difference({...newTabs});
    setState(() {
      _tabs = newTabs;
      _shown = newShown;
      _focused = focused;
      _selectedNavIndex = _navOf(focused);
      for (final k in lost) {
        _weights.remove(k);
        _titles.remove(k);
        _editorKeys.remove(k);
        _graphWidgetKeys.remove(k);
        _recent.remove(k);
        _alive.remove(k);
        _pageKeys.remove(k);
        _kept.remove(k);
      }
      for (final id in entering) {
        _kept.remove(id);
      }
      for (final id in leaving) {
        if (!sealed.contains(id) && newTabs.contains(id) && _app.locks?.repository.locks.unlocked.contains(id) != true) _kept[id] = DateTime.now();
      }
      if (focused != null) {
        _recent.remove(focused);
        _recent.insert(0, focused);
      }
      if (_isNote(focused)) _lastNote = focused;
      if (back.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final id in back) {
            final editor = _editorOf(id);
            if (editor is StoreRefreshable) unawaited((editor as StoreRefreshable).refreshFromStore());
          }
        });
      }
      if (_kept.length > _keptMax) WidgetsBinding.instance.addPostFrameCallback((_) => _expireKept());
      if (focused != null && focused != before && _alive.contains(focused) && const {0, 1, 2}.contains(_pageOf(focused))) WidgetsBinding.instance.addPostFrameCallback((_) => _pageRefresh.ring());
      // (sessions moved or deleted in the calendar app are seen as soon as the study plans come to the front)
      if (focused != null && focused != before && _pageOf(focused) == 10) unawaited(_app.planner?.refresh(lookAtCalendar: true));
      if (focused != null && _isGraph(focused)) _lastGraph = focused;
      if (_lastGraph != null && !newTabs.contains(_lastGraph)) _lastGraph = null;
      if (_lastNote != null && !newTabs.contains(_lastNote)) _lastNote = null;
    });
    _focusedPane.value = focused;
    _saveTabs();
    final graphId = focused == null ? null : _graphIdOf(focused);
    if (graphId != null) _graphs.selectedId = graphId; // (the one looked at last is the one the menu opens)
    for (final k in newTabs) {
      if (_isNote(k) && !_titles.containsKey(k)) unawaited(_loadTitle(k));
    }
    for (final id in entering) {
      unawaited(_app.repository.markOpened(id)); // for "not opened for a while"
    }
    for (final id in leaving) {
      // the note was left: once the editor has saved it, its shared copies are put up again (if it changed)
      final markers = _app.collab?.cloudShare?.markers;
      if (markers != null) unawaited(Future<void>.delayed(const Duration(seconds: 2), () => markers.refreshCopy(id)));
      // and a version of it is kept (if it changed since the last one)
      final history = _app.history;
      if (history != null) unawaited(Future<void>.delayed(const Duration(seconds: 2), () => history.snapshot(id, reason: VersionReason.left)).catchError((Object _) => null));
      unawaited(_loadTitle(id));
    }
    if (automations != null) {
      for (final id in entering) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final handle = _editorOf(id);
          if (handle == null) return;
          await handle.ready;
          final info = await _app.repository.noteInfo(id);
          await automations.bus.emit(AppEvent(AutomationEvent.noteOpened.name, noteId: id, title: handle.noteTitle, folderId: info?.folderId, editor: handle));
          // dates in an imported PDF (in the background; the note is usable meanwhile)
          unawaited(_scanDates(id));
        });
      }
    }
  }

  Future<void> _loadTitle(String id) async {
    final info = await _app.repository.noteInfo(id);
    if (!mounted || info == null) return;
    // (a locked note's tab says what its list says, never its title)
    final locked = await _app.repository.locks.lockModeOf(id) != 0;
    final title = locked ? tr('Locked note') : info.title;
    if (!mounted || _titles[id] == title) return;
    setState(() => _titles[id] = title);
  }

  /// A tab was clicked: it comes onto the screen in place of the one that has the keyboard, or, with [beside] (Ctrl or Shift), next to
  /// the ones that are there (or out of them, if it is there already).
  Future<void> _selectTab(String key, {required bool beside}) async {
    if (!beside || _maxPanes < 2) return _go(tab: key);
    if (_shown.contains(key)) {
      if (_shown.length > 1) return _unshow(key);
      return _go(tab: key);
    }
    return _showBeside(key);
  }

  /// Puts [key] (a tab, or a note that gets one) next to the ones on screen; when they are too many for the width, the oldest goes.
  Future<void> _showBeside(String key) async {
    final tabs = _tabs.contains(key) ? _tabs : [..._tabs, key];
    final shown = [..._shown.where((k) => k != key), key];
    while (shown.length > _maxPanes && shown.length > 1) {
      shown.remove(shown.firstWhere((k) => k != key));
    }
    return _transition(tabs: tabs, shown: shown, focus: key);
  }

  /// The pane of [key] leaves the screen (its tab stays).
  Future<void> _unshow(String key) async {
    if (_shown.length < 2) return;
    final shown = [..._shown]..remove(key);
    return _transition(shown: shown, focus: _focused == key ? shown.last : _focused);
  }

  Future<void> _showAlone(String key) => _transition(shown: [key], focus: key);

  Future<void> _closeOthers(String key) => _transition(tabs: [key], shown: [key], focus: key);

  /// A tab is closed: when it was the only one on screen, the one that had the keyboard before it takes its place.
  Future<void> _closeTab(String key) async {
    final at = _tabs.indexOf(key);
    if (at < 0) return;
    final tabs = [..._tabs]..remove(key);
    if (tabs.isEmpty) return _transition(tabs: tabs);
    var shown = [..._shown]..remove(key);
    var focus = _focused;
    if (shown.isEmpty) {
      focus = _recent.firstWhere((k) => k != key && tabs.contains(k), orElse: () => tabs[at.clamp(0, tabs.length - 1)]);
      shown = [focus];
    } else if (_focused == key) {
      focus = shown.last;
    }
    return _transition(tabs: tabs, shown: shown, focus: focus);
  }

  Future<void> _toggleAll() {
    if (_shown.length > 1) {
      final keep = _focused ?? _shown.first;
      return _transition(shown: [keep], focus: keep);
    }
    final focus = _focused ?? (_tabs.isEmpty ? null : _tabs.first);
    var all = [..._tabs];
    while (all.length > _maxPanes && all.length > 1) {
      all.remove(all.firstWhere((k) => k != focus));
    }
    return _transition(shown: all, focus: focus);
  }

  /// "+": a note of the list opens in a tab of its own.
  Future<void> _newTab() async {
    final notes = await _app.repository.listNotes();
    if (!mounted) return;
    final picked = await showDialog<String>(context: context, builder: (_) => NotePickerDialog(notes: notes, title: 'Open a note in a new tab'));
    if (picked != null && mounted) await _go(index: 3, note: picked);
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

  /// Shows [other] next to the open note, if it can be opened.
  Future<void> _openBeside(String other) => _showBeside(other);

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
    final title = info == null ? null : (isUntitled(info.title) ? tr('Untitled') : info.title);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text.verbatim(title == null ? tr('An agent changed your notes.') : tr('An agent changed "{title}".', {'title': title})),
        action: title == null || _shown.contains(id) ? null : SnackBarAction(label: tr('Open'), onPressed: () => _go(index: 3, note: id)),
        persist: false,
        duration: const Duration(seconds: 4),
      ));
  }

  /// Tells the person what happened with a note that was shared (someone opened it, someone joined, changes came in).
  void _showNotice(ShareNotice n) {
    if (!mounted) return;
    final who = n.who ?? tr('Someone');
    final title = isUntitled(n.title) ? tr('Untitled') : n.title;
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
        content: Text.verbatim(tr('"{name}" is shared with you by {who}. Take it in under Settings, Sync and sharing.', {'name': ShareNaming.shown(p.share.name), 'who': p.share.owner})),
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
      for (final id in _heldNotes) {
        await _editorOf(id)?.saveNow();
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
      if (_liveNotes(_shown).isNotEmpty) {
        unawaited(_transition(tabs: _tabs.contains(_homeKey) ? _tabs : [..._tabs, _homeKey], shown: [_homeKey], focus: _homeKey));
      } else {
        unawaited(locks.sealAll());
      }
    }
  }

  /// The system is short of memory: the editors kept out of sight (each holds a whole note, its PDF and page pictures) are let go now,
  /// not when their time runs out. (Flutter empties its own cache of pictures by itself.) Their notes are saved as the editors close.
  @override
  void didHaveMemoryPressure() {
    if (_kept.isEmpty || !mounted) return;
    setState(() {
      for (final id in _kept.keys) {
        _editorKeys.remove(id);
      }
      _kept.clear();
    });
    _keptTimer?.cancel();
    _keptTimer = null;
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
      unawaited(_app.planner?.refresh()); // (back from the calendar app: sessions moved there are followed, at most every few minutes)
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
    final ids = <String>{if (_inFront) for (final k in _visible) if (_isNote(k)) k};
    if (ids.length == _reportedOpen.length && ids.containsAll(_reportedOpen)) return;
    _reportedOpen = ids;
    sync?.setOpenNotes(ids);
    _app.collab?.nativeShares?.setOpenNotes(ids,); // (a note of a share is worked on live with the people it is shared with)
  }

  @override
  void dispose() {
    phoneNavItems.removeListener(_navChosen);
    _favouritesLive?.cancel();
    _showFavourites.dispose();
    _notesChat?.dispose();
    _notesDraft.dispose();
    _lockTimer?.cancel();
    _keptTimer?.cancel();
    _app.automations?.openEditor = null;
    WidgetsBinding.instance.removeObserver(this);
    _app.collab?.removeListener(_collabChanged);
    _links?.cancel();
    _notices?.cancel();
    _agentActivity?.cancel();
    _app.aiSwitch?.removeListener(_aiSwitched);
    _app.features?.removeListener(_featuresChanged);
    _shortcuts.removeHandler(_onShortcut);
    _app.extensions?.removeListener(_syncCommandKeys);
    _graphs.removeListener(_graphsChanged);
    _focusedPane.dispose();
    _pageRefresh.dispose();
    _railSlide.dispose();
    super.dispose();
  }

  /// Web: the flag a landing page reads to send a signed-in visitor to the app (see setSignedInFlag).
  void _markSignedIn() => setSignedInFlag(_app.sync?.isSetUp ?? false);

  @override
  void initState() {
    super.initState();
    // a sync does not replace a note under an editor that has it open
    _app.sync?.library.busy = () => _heldNotes;
    if (kIsWeb) {
      _app.sync?.addListener(_markSignedIn);
      _markSignedIn();
    }
    _app.automations?.openEditor = _editorOf; // (a note that is open is changed through its editor)
    _graphs.addListener(_graphsChanged);
    _app.planner?.facts = GraphStudyFacts(_graphs); // (the quizzes of study sessions)
    // (runs of pages cut by their topics, where the person asks for it)
    _app.planner?.topics = StudyTopicSplitter(pageTexts: (id) => readPageTexts(_app.repository.text, id), model: () => _app.ai?.provider, enabled: () => _aiOn);
    // (the summaries and cards of a plan's parts, where the person asks for them)
    _app.planner?.maker = StudyMaterialMaker(
      pageTexts: (id) => readPageTexts(_app.repository.text, id),
      documentText: (id) async => (await _app.planner?.readNote?.call(id))?.documentText ?? '',
      model: () => _app.ai?.provider,
      enabled: () => _aiOn,
    );
    WidgetsBinding.instance.addObserver(this);
    _shortcuts.addHandler(_onShortcut);
    _app.extensions?.addListener(_syncCommandKeys);
    _syncCommandKeys();
    _app.repository.purgeTrash().catchError((Object _) => 0); // what lay in the trash for long enough
    _app.repository.listNotes().then((all) => _previews.tidy({for (final n in all) n.id})).catchError((Object _) {}); // pictures of notes that are gone
    // a tap on a reminder's notification opens what it was about
    _app.reminders?.onOpen = (kind, id) {
      if (!mounted) return;
      if (kind == ReminderKind.note && id != null) {
        _go(index: 3, note: id);
      } else if (kind == ReminderKind.task) {
        _go(index: 2);
      } else if (kind == ReminderKind.study && id != null && _app.planner != null) {
        final found = _app.planner!.findByTask(id);
        if (found == null) {
          _go(index: 2); // (a session that is not in a plan any more: its to-do)
        } else {
          openStudySession(context, _app.planner!, found.plan.id, found.session.key,
              cards: _cardsOn ? _app.cards : null, onOpenNoteAt: (note, page) => _openAtPage(note, page));
        }
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
    _app.repository.settings.get(phoneNavKey).then((v) {
      if (mounted) phoneNavItems.value = decodePhoneNav(v);
    });
    phoneNavItems.addListener(_navChosen);
    _loadSideFavourites();
    _favouritesLive = debouncedChanges([_app.repository.changes, _app.repository.created]).listen((_) => _loadSideFavourites());
    unawaited(_restoreTabs());
    unawaited(_restoreSidebarOrder());
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
    final id = _activeNoteId;
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

  /// The commands of the extensions that are on are actions of the shortcuts, so they can be given keys.
  void _syncCommandKeys() {
    final service = _app.extensions;
    if (service == null) return;
    ExtensionBlocks.languages = {for (final l in service.blocks.keys) l.toLowerCase()};
    ExtensionBlocks.draw = (language, code, width) => service.drawBlock(language, code, width: width);
    _shortcuts.setExtraActions([
      for (final c in service.commands())
        ShortcutAction('ext.${c.extension.id}/${c.command.id}', '${c.extension.manifest.name}: ${c.command.title}', ShortcutGroup.extensions),
    ]);
  }

  /// Where a command that is run from here can reach: all the notes by their ids, the library, the AI; no editor.
  CommandApi _commandApi(CommandEntry entry) => CommandApi(
        _app.repository,
        tasks: _app.tasks,
        tags: _app.tags,
        reminders: _app.reminders,
        calendar: CalendarAccess.of(caldav: _app.caldav, device: _app.device, ics: _app.ics),
        planner: _app.planner,
        isOpen: (id) => _tabs.contains(id),
        noteId: _activeNoteId,
        links: _app.links,
        cards: _app.cards,
        citations: _app.citations?.repository,
        ai: _aiOn ? _app.ai : null,
        onMessage: (text) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(text)));
        },
        onAsk: (kind, args) async => mounted ? askPersonDialog(context, entry.extension.manifest.name, kind, args) : null,
      );

  Future<void> _openCommands() async {
    final service = _app.extensions;
    if (service == null) return;
    await showExtensionCommands(context, service: service, apiFor: _commandApi, place: CommandPlace.dashboard);
  }

  bool _onShortcut(String id) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (id.startsWith('ext.')) {
      final service = _app.extensions;
      final entry = service?.commands().where((c) => 'ext.${c.extension.id}/${c.command.id}' == id).firstOrNull;
      if (service == null || entry == null) return false;
      unawaited(runExtensionCommand(context, service, entry, _commandApi(entry)));
      return true;
    }
    final trigger = RegExp(r'^automation\.trigger([123])$',).firstMatch(id)?.group(1);
    if (trigger != null) {
      unawaited(_fireTrigger(int.parse(trigger)));
      return true;
    }
    final place = navigationActions[id];
    if (place != null) {
      // (the open note has no place in the menu, but its shortcut still goes back to it, when there is one)
      if (place == 3 ? _activeNoteId == null && _lastNote == null : !_navItems.contains(place)) return false;
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
        NotationSidebar(
          items: [for (final i in _navItems) _sidebarItem(i)],
          selected: _navItems.contains(_selectedNavIndex) ? _selectedNavIndex : null,
          wide: extended,
          pinned: 5,
          order: _sidebarOrder,
          onReorder: _sidebarReordered,
          fill: _favouritesFill,
          onSelect: (i) => _go(index: i),
          header: extended
              ? Row(children: [
                  const SizedBox(width: 4),
                  const NotationLogo(size: 28),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Notation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w300, letterSpacing: 0.2))),
                  _foldButton(),
                ])
              : Column(children: [const NotationLogo(size: 28), const SizedBox(height: 4), _foldButton()]),
          footer: !kIsWeb || _app.sync == null
              ? null
              : (extended
                  ? TextButton.icon(key: const ValueKey('rail-sign-out'), onPressed: () => confirmSignOut(context, _app.sync!), icon: const Icon(Symbols.logout, size: 18), label: Text(tr('Sign out')))
                  : IconButton(key: const ValueKey('rail-sign-out'), tooltip: tr('Sign out'), onPressed: () => confirmSignOut(context, _app.sync!), icon: const Icon(Symbols.logout))),
        ),
        VerticalDivider(width: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant),
      ]),
    );
    final page = RepaintBoundary(child: _workspace());
    return Scaffold(
      // (the system bar of a tablet - clock, battery - must not lie over the tabs; on a desktop the padding is zero)
      body: SafeArea(bottom: false, child: Stack(children: [
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
      ])),
    );
  }

  final _phoneScaffold = GlobalKey<ScaffoldState>();

  /// A phone: the main places sit in a bar at the bottom, every place is in the menu (the button at the top left, or a swipe from the left edge); an open note gets the whole screen.
  void _navChosen() {
    if (mounted) setState(() {});
  }

  Widget _phoneShell() {
    final chosen = [for (final i in phoneNavItems.value) if (_navItems.contains(i)) i];
    final inBar = chosen.length >= 2 ? chosen : [for (final i in defaultPhoneNav) if (_navItems.contains(i)) i];
    final inBarNow = inBar.contains(_selectedNavIndex);
    NavigationDestination of(int i) {
      final d = _destinations[i]!;
      return NavigationDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: tr((d.label as Text).data!), tooltip: '');
    }

    final editing = _activeNoteId != null;
    return PopScope(
      // the system back gesture closes the open note instead of leaving the app
      canPop: !editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _activeNoteId != null) _closeTab(_activeNoteId!);
      },
      child: Scaffold(
      key: _phoneScaffold,
      drawerEnableOpenDragGesture: !editing,
      drawer: Drawer(
        width: 300,
        shape: const RoundedRectangleBorder(),
        backgroundColor: NotationSidebar.groundOf(context),
        surfaceTintColor: Colors.transparent,
        child: NotationSidebar(
          roomy: true,
          order: _sidebarOrder,
          onReorder: _sidebarReordered,
          items: [for (final i in _navItems) _sidebarItem(i)],
          selected: _navItems.contains(_selectedNavIndex) ? _selectedNavIndex : null,
          pinned: 5,
          onSelect: (i) {
            Navigator.pop(context);
            _go(index: i);
          },
          header: AccountPanel(
            profile: _app.profile,
            sync: _app.sync,
            onSettings: () {
              Navigator.pop(context);
              _go(index: 5);
            },
          ),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Stack(children: [
          // the pages bring their own bars: the title makes room for the menu button over their top left corner
          Theme(
            data: Theme.of(context).copyWith(appBarTheme: Theme.of(context,).appBarTheme.copyWith(titleSpacing: 56)),
            child: _workspace(),
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
                    : IconButton(key: const ValueKey('phone-menu'), tooltip: tr('Menu'), icon: const Icon(Symbols.menu), onPressed: () => _phoneScaffold.currentState?.openDrawer()),
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
        icon: const Icon(Symbols.chevron_left),
        onPressed: () => _setRailHidden(true),
      );

  /// What a tab shows: a note, a graph, or a place of the menu.
  final _navKeys = <String, GlobalKey<NavigatorState>>{};

  Widget _viewFor(String key) {
    if (_isNote(key)) return _editor(key);
    if (_isGraph(key)) return _graphView(key);
    final page = KeyedSubtree(key: _pageKeys.putIfAbsent(key, () => GlobalKey()), child: _pageView(_pageOf(key) ?? 0));
    // (on a phone the button of the menu sits over the top left corner of the assistant's page)
    final shown = MediaQuery.sizeOf(context).width < 600 && _pageOf(key) == 9 ? Padding(padding: const EdgeInsets.only(top: 48), child: page) : page;
    // a screen opened from the page (a study session, the reminders) lies over this tab only, not over the whole window
    final navKey = _navKeys.putIfAbsent(key, () => GlobalKey<NavigatorState>()); // (a global key: the tab moves between the row and the hidden stack with its screens)
    // (the system's back goes to the window's navigator only: this hands it to the tab's, so a screen opened in the tab closes first)
    return NavigatorPopHandler(
      onPopWithResult: (_) => navKey.currentState?.maybePop(),
      child: Navigator(
        key: navKey,
        pages: [MaterialPage<void>(key: const ValueKey('tab-page'), child: shown)],
        onDidRemovePage: (_) {},
      ),
    );
  }

  Widget _pageView(int place) {
    switch (place) {
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
          refresh: _pageRefresh,
          showFavourites: _showFavourites,
        );
      case 9:
        final ai = _app.ai;
        if (ai == null) return const SizedBox.shrink();
        final chat = _notesChat ??= AssistantChat(
          ai: ai,
          knowledge: _knowledge,
          lookup: NoteLookup.of(_app.repository),
          agent: NoteAgent(
            more: _app.extensions == null ? null : () => extensionAgentTools(_app.extensions!),
            api: CommandApi(_app.repository,
                tasks: _app.tasks,
                tags: _app.tags,
                reminders: _app.reminders,
                calendar: CalendarAccess.of(caldav: _app.caldav, device: _app.device, ics: _app.ics),
                planner: _app.planner,
                isOpen: (id) => _tabs.contains(id),
                links: _app.links,
                cards: _app.cards,
                citations: _app.citations?.repository,
                ai: _app.ai),
          ),
          // (every question reads all the notes: reading one more by its id is not asked about)
          granted: const {ExtensionPermission.notesReadAll},
          onChanged: _pageRefresh.ring,
          loadChat: () => _app.repository.settings.get('assistant_chat:all'),
          saveChat: (json) => json == null ? _app.repository.settings.remove('assistant_chat:all') : _app.repository.settings.set('assistant_chat:all', json),
        )
          ..restoreChat();
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
            draft: _notesDraft,
          ),
        );
      case 8:
        return const SizedBox.shrink();
      case 6:
        return SearchView(
          repository: _app.repository,
          initial: _searchQuery,
          onChanged: (q) => _searchQuery = q,
          tags: _app.tags,
          knowledge: _aiOn ? _knowledge : null,
          initialFilter: _searchFilter,
          onFilterChanged: (f) => _searchFilter = f,
          onOpen: _openFromSearch,
        );
      case 2:
        return CalendarView(reminders: _app.reminders, mirror: _app.mirror, repository: _app.tasks, caldav: _app.caldav, device: _app.device, ics: _app.ics, style: _app.style, refresh: _pageRefresh);
      case 10:
        if (!_learnOn) return const SizedBox.shrink();
        return LearningHub(repository: _app.repository, planner: _studyOn ? _app.planner : null, cards: _cardsOn ? _app.cards : null, onOpenNoteAt: (id, page) => _openAtPage(id, page));
      case 3:
        return const Center(child: Text('Open a note from the dashboard or create a new one.'));
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
          planner: _f(Feature.calendar) ? _app.planner : null,
          onOpenNoteAt: (id, page) => _openAtPage(id, page),
          collab: _app.collab,
          repository: _app.repository,
          noteFiles: _f(Feature.noteFiles) ? _app.noteFiles : null,
          extensions: _app.extensions,
          templates: _templates,
          previews: _previews,
          speech: _app.speech,
          cards: _cardsOn ? _app.cards : null,
          onOpenLearning: _learnOn ? () => _go(index: 10) : null,
          onCommands: _app.extensions == null ? null : _openCommands,
          reminders: _app.reminders,
          audio: _app.audio,
          capture: _app.capture,
          review: _app.review,
          onJoinSession: _app.collab == null || !_f(Feature.live) ? null : _joinByLink,
          sync: _app.sync,
          onOpenNote: (id) => _go(index: 3, note: id),
          refresh: _pageRefresh,
        );
    }
  }

  /// The tabs and under them the notes (or the graph) that are on screen, side by side as far as the width allows.
  Widget _workspace() {
    return Column(children: [
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          // several tabs need room each; on a narrow window one is shown and the others wait
          _maxPanes = (box.maxWidth / 450).floor().clamp(1, 6);
          final visible = [..._shown];
          while (visible.length > _maxPanes) {
            visible.remove(visible.firstWhere((k) => k != _focused, orElse: () => visible.first));
          }
          _visible = visible;
          if (visible.isEmpty) return Column(children: [_strip(null), const Expanded(child: Center(child: Text('Open a note from the dashboard or create a new one.')))]);
          const gap = 10.0;
          final share = box.maxWidth - gap * (visible.length - 1);
          final weights = [for (final k in visible) _weights[k] ?? 1.0];
          final total = weights.fold(0.0, (a, b) => a + b);
          final row = Row(children: [
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0)
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: ValueKey('split-divider${i == 1 ? '' : '-$i'}'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      // the two panes next to the divider trade width; neither gets narrower than a fifth of the average
                      final left = visible[i - 1], right = visible[i];
                      final move = d.delta.dx / share * total;
                      final l = (_weights[left] ?? 1.0) + move, r = (_weights[right] ?? 1.0) - move;
                      final least = total / visible.length * 0.4;
                      if (l < least || r < least) return;
                      setState(() {
                        for (final k in visible) {
                          _weights[k] ??= 1.0;
                        }
                        _weights[left] = l;
                        _weights[right] = r;
                      });
                    },
                    child: Container(width: gap, color: Theme.of(context).dividerColor.withValues(alpha: 0.3), child: Center(child: Container(width: 3, height: 40, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))))),
                  ),
                ),
              SizedBox(
                key: ValueKey('pane-${visible[i]}'),
                width: share * weights[i] / total,
                child: _pane(visible[i], FadeOnChange(token: visible[i], child: _viewFor(visible[i]))),
              ),
            ],
          ]);
          _alive.addAll(visible.where((k) => !_isNote(k)));
          final hidden = [for (final k in _tabs) if ((_alive.contains(k) || _kept.containsKey(k)) && !visible.contains(k)) k];
          if (_kept.isNotEmpty && _keptTimer == null) _keptTimer = Timer(const Duration(seconds: 30), _expireKept);
          return Stack(fit: StackFit.expand, children: [
            Positioned.fill(child: row),
            for (final k in hidden)
              Offstage(key: ValueKey('off-$k'), child: TickerMode(enabled: false, child: SizedBox(width: box.maxWidth, height: box.maxHeight, child: _viewFor(k)))),
          ]);
        }),
      ),
    ]);
  }

  /// The tab strip of one pane (every pane has its own, with all the tabs: a click shows that tab in this pane); [pane] null: nothing is
  /// on screen yet.
  Widget _strip(String? pane) {
    if (_tabs.isEmpty || MediaQuery.sizeOf(context).width < 600) return const SizedBox.shrink(); // (a phone has its bar and its menu)
    return ListenableBuilder(
      listenable: Listenable.merge([_focusedPane, _graphs]),
      builder: (context, _) => WorkspaceTabStrip(
        tabs: [for (final k in _tabs) _tabOf(k)],
        shown: {..._shown},
        focused: pane,
        onSelect: (key, {required beside}) => pane == null || beside ? _selectTab(key, beside: beside) : _selectInPane(pane, key),
        onClose: _closeTab,
        onShowAlone: _showAlone,
        onCloseOthers: _closeOthers,
        onNewTab: () {
          if (pane != null) _focusPane(pane);
          _newTab();
        },
        onReorder: (keys) {
          setState(() => _tabs = keys);
          _saveTabs();
        },
        onToggleAll: _toggleAll,
        allShown: _shown.length > 1,
        // the menu button comes back where the menu was hidden: at the left end of the first strip
        leading: _railHidden && (pane == null || pane == _shown.first)
            ? IconButton(key: const ValueKey('rail-show'), tooltip: tr('Show the menu'), visualDensity: VisualDensity.compact, icon: const Icon(Symbols.menu, size: 20), onPressed: () => _setRailHidden(false))
            : null,
      ),
    );
  }

  /// The title the open editor has, or null while it has none yet (an editor that is still loading answers "", which must not hide the stored title).
  String? _liveTitle(String k) {
    if (!_visible.contains(k)) return null;
    final t = _editorOf(k)?.noteTitle;
    return t == null || t.isEmpty ? null : t;
  }

  WorkspaceTab _tabOf(String k) {
    if (_isNote(k)) return WorkspaceTab(key: k, icon: Symbols.note_alt, title: _liveTitle(k) ?? _titles[k] ?? "", untitled: true); // (an editor that is leaving still answers during that very build)
    if (_isGraph(k)) {
      final name = _graphName(k);
      return WorkspaceTab(key: k, icon: Symbols.hub, title: name.isEmpty ? tr('Graph') : name);
    }
    final d = _destinations[_pageOf(k)] ?? _destinations[3]!;
    return WorkspaceTab(key: k, icon: (d.icon as Icon).icon!, title: tr((d.label as Text).data!));
  }

  /// A tab was clicked in the strip of [pane]: it is shown in that pane (if it is in another pane, the two swap places).
  Future<void> _selectInPane(String pane, String key) {
    if (key == pane) {
      _focusPane(pane);
      return Future.value();
    }
    final shown = [..._shown];
    final at = shown.indexOf(pane), other = shown.indexOf(key);
    if (at < 0) return _go(tab: key);
    if (other >= 0) {
      shown[other] = pane;
      shown[at] = key;
    } else {
      shown[at] = key;
    }
    return _transition(shown: shown, focus: key);
  }

  Widget _graphView(String key) => GraphView(
        key: _graphWidgetKeys.putIfAbsent(key, () => GlobalKey()),
        service: _graphs,
        onOpen: _openAtPage,
        cards: _app.cards,
        graphId: _graphIdOf(key),
        pinned: true,
        onOpenGraph: (id) => _showGraph(id, from: key),
        onAsk: _assistantOn
            ? (topic) {
                _notesDraft.value = tr('What do my notes say about {topic}? ', {'topic': topic});
                _go(index: 9);
              }
            : null,
      );

  String _graphName(String key) {
    final id = _graphIdOf(key);
    return _graphs.graphs.where((g) => g.id == id).map((g) => g.name).firstOrNull ?? '';
  }

  /// Which graph the menu place opens: the one that was in front last, or the one that was looked at last, or (none was made yet) the view that makes one.
  Future<String> _defaultGraphKey() async {
    await _graphs.refresh();
    if (_lastGraph != null && _tabs.contains(_lastGraph)) return _lastGraph!;
    final id = _graphs.selectedId;
    return id == null ? _graphKey : 'graph:$id';
  }

  /// A graph tab asks for another graph (one it made, one picked in the library): the tab that has no graph yet becomes that graph's,
  /// else the graph gets a tab of its own.
  Future<void> _showGraph(int id, {required String from}) async {
    final target = 'graph:$id';
    if (from != _graphKey || !_tabs.contains(from)) return _go(tab: target);
    List<String> swap(List<String> l) => [for (final k in l) if (k == from) ...(l.contains(target) ? const <String>[] : [target]) else k];
    return _transition(tabs: swap(_tabs), shown: swap(_shown), focus: target);
  }

  /// A graph that was deleted loses its tab.
  void _graphsChanged() {
    if (!mounted || !_graphs.listed) return;
    final ids = {for (final g in _graphs.graphs) g.id};
    for (final k in _tabs.toList()) {
      final id = _graphIdOf(k);
      if (id != null && !ids.contains(id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _tabs.contains(k)) unawaited(_closeTab(k));
        });
      }
    }
  }

  /// One of the tabs on screen: a click or a touch in it makes the keyboard shortcuts its own, and a bar on top says which.
  Widget _pane(String key, Widget child) => Listener(
        onPointerDown: (_) => _focusPane(key),
        child: Column(children: [
          // ends the split view: the same place in every pane, notes included
          if (_visible.length > 1)
            Row(children: [
              Expanded(child: _strip(key)),
              IconButton(
                key: ValueKey('close-split-$key'),
                tooltip: tr('Close this pane (end the split view)'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Symbols.close_fullscreen, size: 20),
                onPressed: () => _unshow(key),
              ),
            ])
          else
            _strip(key),
          ValueListenableBuilder<String?>(
            valueListenable: _focusedPane,
            builder: (context, focused, _) => Container(height: 3, color: _visible.length > 1 && focused == key ? Theme.of(context).colorScheme.primary : Colors.transparent),
          ),
          // the note lays itself out for the room it has, not for the whole window
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => MediaQuery(data: MediaQuery.of(context,).copyWith(size: Size(box.maxWidth, box.maxHeight)), child: child),
            ),
          ),
        ]),
      );

  /// The keyboard goes to the pane that was touched (the menu follows when that is the graph or a note).
  void _focusPane(String key) {
    if (_focused == key) return;
    _focused = key;
    _focusedPane.value = key;
    if (_isGraph(key)) {
      _lastGraph = key;
    } else {
      _lastNote = key;
    }
    final index = _navOf(key);
    if (_selectedNavIndex != index) setState(() => _selectedNavIndex = index);
  }

  Widget _editor(String id) {
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
          onOpenNote: (other) => _go(note: other),
          onOpenBeside: _maxPanes < 2 ? null : _openBeside,
          onCloseSplit: _visible.length > 1 ? () => _unshow(id) : null,
          locks: _app.locks,
          onLeave: () => _closeTab(id),
          paneActive: _visible.length < 2 ? null : () => _focused == id,
          onPdfImported: () => _scanDates(id),
          ai: _aiOn && _f(Feature.assistant) ? _app.ai : null,
          knowledge: _aiOn && _f(Feature.assistant) ? _knowledge : null,
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
          onOpenNoteAt: _openAtPage,
          onTrigger: _fireTrigger,
          initialFind: _openWithFind?.note == id ? _openWithFind!.query : null,
          initialPage: _openWithFind?.note == id ? _openWithFind!.page : 0,
        );
  }
}

class _Refresh extends ChangeNotifier {
  void ring() => notifyListeners();
}
