import '../web/picked_file.dart';
import '../citations/citation_service.dart';
import '../citations/citation_style.dart';
import 'dart:async';
import 'dart:io';
import '../data/debounced_changes.dart';
import '../l10n/language.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/note_data.dart';
import '../previews/note_preview.dart';
import '../data/note_file_service.dart';
import '../data/note_repository.dart';
import '../data/note_sort.dart';
import '../collab/collab_service.dart';
import '../collab/shared_notes.dart';
import 'bulk_note_actions.dart';
import 'folder_picker.dart';
import 'share_people.dart';
import 'note_file_actions.dart';
import 'template_picker.dart';
import '../templates/templates.dart';
import 'shared_badge.dart';
import 'sync_now_button.dart';
import '../devicesync/device_sync_service.dart';
import 'trash_view.dart';
import 'tag_dialogs.dart';
import 'reminders_screen.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import '../data/tag_repository.dart';
import '../tags/tag_names.dart';
import '../style/platform_dialog.dart';

/// Folder tree on the left, the notes of the selected folder on the right.
class FolderView extends StatefulWidget {
  final NoteRepository repository;
  final ValueChanged<String> onOpenNote;
  final NoteFileService? noteFiles;

  /// Notes from templates; null hides the buttons.
  final TemplateService? templates;

  /// Tells which notes are shared (a group symbol on them, and the "Shared with me" folder); null: none is.
  final CollabService? collab;

  /// Small pictures of the first page, drawn faintly over the banners of the notes; null: none.
  final NotePreviews? previews;

  /// The sync of the devices of the profile, for the "Sync now" button on top.
  final DeviceSyncService? sync;

  /// The tags of notes (a Tags list beside the folders, a Tags entry in a note's menu); null: no tags.
  final TagRepository? tags;

  /// "Remind me" in a note's menu; null hides it.
  final ReminderService? reminders;

  const FolderView({super.key, required this.repository, required this.onOpenNote, this.noteFiles, this.templates, this.collab, this.previews, this.sync, this.tags, this.reminders});

  @override
  State<FolderView> createState() => _FolderViewState();
}

// pseudo folders of the tree
const _all = '__all__';
const _unfiled = '__unfiled__';
const _shared = '__shared__';
const _favorites = '__favorites__';
const _sortKey = 'notes_sort';
const _starredFirstKey = 'notes_starred_first';
const _trash = '__trash__';

/// A scope that shows the notes of a tag: this followed by the tag.
const _tagPrefix = '__tag__:';

/// What is being dragged.
sealed class _Dragged {
  final String id;
  const _Dragged(this.id);
}

class _DraggedNote extends _Dragged {
  const _DraggedNote(super.id);
}

class _DraggedFolder extends _Dragged {
  const _DraggedFolder(super.id);
}

class _FolderViewState extends State<FolderView> {
  List<FolderEntry> _foldersList = [];
  // (looked up by id and by parent, made when the list is set: a library with thousands of folders asks for these for every row and
  // every note shown, and a scan of the list each time made a screen quadratic)
  Map<String, FolderEntry> _folderById = {};
  Map<String?, List<FolderEntry>> _folderKids = {};

  List<FolderEntry> get _folders => _foldersList;

  set _folders(List<FolderEntry> list) {
    _foldersList = list;
    _folderById = {for (final f in list) f.id: f};
    _folderKids = {};
    for (final f in list) {
      (_folderKids[f.parentId] ??= []).add(f);
    }
  }
  List<NoteSummary> _notes = [];
  int _trashCount = 0;
  bool _loaded = false;
  String _scope = _all;
  final Set<String> _expanded = {};

  /// The tags of the notes (note id -> tags) and the tree they make.
  Map<String, Set<String>> _noteTags = {};
  List<TagNode> _tagTree = const [];

  /// How the notes are put in order, and whether starred ones come first (kept on this device).
  NoteSort _sort = NoteSort.changed;
  bool _starredFirst = true;
  bool _sortChosen = false;

  // ---- selecting several notes
  bool _selecting = false;
  final Set<String> _selected = {};

  /// The selected notes that are shown now, in the order shown.
  List<String> get _selectedHere => [
    for (final n in _visibleNotes)
      if (_selected.contains(n.id)) n.id,
  ];

  void _toggleSelected(String id) => setState(() {
    _selecting = true;
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _endSelecting() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  Future<void> _moveSelected() async {
    final ids = _selectedHere;
    if (ids.isEmpty) return;
    if (await moveNotesTo(context, _repo, ids)) _endSelecting();
    await _reload();
  }

  Future<void> _trashSelected() async {
    final ids = _selectedHere;
    if (ids.isEmpty) return;
    if (await trashNotes(context, _repo, ids)) _endSelecting();
    await _reload();
  }

  Future<void> _starSelected(bool value) async {
    for (final id in _selectedHere) {
      await _repo.setFavorite(id, value);
    }
    await _reload();
  }

  NoteRepository get _repo => widget.repository;

  /// Loads again when notes, folders or tags change under the list (an agent, a sync).
  StreamSubscription<void>? _live;

  @override
  void initState() {
    super.initState();
    _reload().then((_) => _loadSort());
    _live = debouncedChanges([_repo.changes, _repo.created, widget.tags?.changes,]).listen((_) {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  Future<void> _loadSort() async {
    final name = await _repo.settings.get(_sortKey);
    final starred = await _repo.settings.get(_starredFirstKey);
    if (!mounted || _sortChosen) return; // (a choice made while this was read wins)
    setState(() {
      _sort = NoteSort.values.where((s) => s.name == name).firstOrNull ?? NoteSort.changed;
      _starredFirst = starred != 'false';
    });
  }

  void _setSort({NoteSort? sort, bool? starredFirst}) {
    _sortChosen = true;
    setState(() {
      _sort = sort ?? _sort;
      _starredFirst = starredFirst ?? _starredFirst;
    });
    _repo.settings.set(_sortKey, _sort.name);
    _repo.settings.set(_starredFirstKey, '$_starredFirst');
  }

  String _sortLabel(NoteSort s) => switch (s) {
        NoteSort.changed => tr('Recently changed'),
        NoteSort.oldest => tr('Least recently changed'),
        NoteSort.titleAscending => tr('Title A to Z'),
        NoteSort.titleDescending => tr('Title Z to A'),
        NoteSort.type => tr('Notes before PDFs'),
      };

  /// The menu that sets the order of the notes.
  Widget _sortMenu() => PopupMenuButton<Object>(
        key: const ValueKey('folder-sort'),
        tooltip: tr('Sort notes'),
        onSelected: (v) => v is NoteSort ? _setSort(sort: v) : _setSort(starredFirst: !_starredFirst),
        itemBuilder: (_) => [
          for (final s in NoteSort.values)
            CheckedPopupMenuItem<Object>(key: ValueKey('folder-sort-${s.name}'), value: s, checked: _sort == s, child: Text.verbatim(_sortLabel(s))),
          const PopupMenuDivider(),
          CheckedPopupMenuItem<Object>(key: const ValueKey('folder-sort-starred'), value: 'starred', checked: _starredFirst, child: Text.verbatim(tr('Favourites first'))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.sort, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text.verbatim(_sortLabel(_sort), style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );

  Future<void> _reload() async {
    final folders = await _repo.listFolders();
    final notes = await _repo.listNotes();
    final trashed = (await _repo.listTrash()).length;
    final noteTags = await widget.tags?.all() ?? const <String, Set<String>>{};
    if (!mounted) return;
    setState(() {
      _noteTags = noteTags;
      _tagTree = buildTagTree(noteTags);
      _folders = folders;
      _notes = notes;
      _trashCount = trashed;
      _loaded = true;
      if (!_isTagScope && _scope != _all && _scope != _unfiled && _scope != _shared && _scope != _favorites && _scope != _trash && !folders.any((f) => f.id == _scope)) _scope = _all;
      if (_isTagScope && !noteTags.values.any((t) => t.any((x) => tagIsUnder(x, _scope.substring(_tagPrefix.length))))) _scope = _all;
    });
  }

  /// Runs a change, reloads and reports failures instead of failing silently.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context,).showSnackBar(SnackBar(content: Text.verbatim('$e')));
    }
    await _reload();
  }

  // ---- derived data --------------------------------------------------------

  List<FolderEntry> _childrenOf(String? parentId) => _folderKids[parentId] ?? const [];

  FolderEntry? _folder(String id) => _folderById[id];

  bool get _isTagScope => _scope.startsWith(_tagPrefix);

  bool get _inRealFolder => !_isTagScope && _scope != _all && _scope != _unfiled && _scope != _shared && _scope != _favorites && _scope != _trash;

  /// The tag of the tag scope shown, if one is.
  String? get _shownTag => _isTagScope ? _scope.substring(_tagPrefix.length) : null;

  Set<String> get _sharedWithMe => widget.collab?.shared.withMe ?? const {};

  String _path(String? folderId) {
    final names = <String>[];
    // (the count keeps a folder that is its own ancestor, which a damaged library may hold, from looping for ever)
    var steps = 0;
    for (var f = folderId == null ? null : _folder(folderId); f != null && steps <= _folders.length; f = f.parentId == null ? null : _folder(f.parentId!)) {
      names.insert(0, f.name);
      steps++;
    }
    return names.join(' / ');
  }

  Set<String> _subtreeOf(String id) {
    final ids = {id};
    final todo = [id];
    while (todo.isNotEmpty) {
      for (final c in _childrenOf(todo.removeLast())) {
        if (ids.add(c.id)) todo.add(c.id);
      }
    }
    return ids;
  }

  /// The notes of the place shown, in the order chosen.
  List<NoteSummary> get _visibleNotes {
    final list = switch (_scope) {
      _all => _notes,
      _unfiled => _notes.where((n) => n.folderId == null).toList(),
      _shared => _notes.where((n) => _sharedWithMe.contains(n.id)).toList(),
      _favorites => _notes.where((n) => n.favorite).toList(),
      _ when _isTagScope => _notes.where((n) => (_noteTags[n.id] ?? const <String>{}).any((t) => tagIsUnder(t, _shownTag!))).toList(),
      _ => _notes.where((n) => n.folderId == _scope).toList(),
    };
    return sortNotes(list, _sort, starredFirst: _starredFirst);
  }

  // ---- drag and drop ---------------------------------------------------------

  /// Whether [item] may be dropped into [target] (null = no folder / top
  /// level): not where it already is, and no folder into its own subtree.
  bool _canDrop(_Dragged item, String? target) {
    switch (item) {
      case _DraggedNote():
        final note = _notes.where((n) => n.id == item.id).firstOrNull;
        return note != null && (note.folderId != target || _draggedTogether(item).length > 1);
      case _DraggedFolder():
        final folder = _folder(item.id);
        return folder != null && folder.parentId != target && (target == null || !_subtreeOf(item.id).contains(target));
    }
  }

  /// A selected note that is dragged takes the other selected notes along.
  List<String> _draggedTogether(_DraggedNote item) {
    final here = _selectedHere;
    return here.length > 1 && here.contains(item.id) ? here : [item.id];
  }

  Future<void> _drop(_Dragged item, String? target) async {
    if (target != null) _expanded.add(target);
    await _run(() async {
      switch (item) {
        case _DraggedNote():
          for (final id in _draggedTogether(item)) {
            await _repo.moveNote(id, target);
          }
          _selecting = false;
          _selected.clear();
        case _DraggedFolder():
          await _repo.moveFolder(item.id, target);
      }
    });
  }

  /// Highlights [child] while something droppable hovers over it.
  Widget _dropTarget(String? folderId, Widget child, {BorderRadius? radius}) {
    return DragTarget<_Dragged>(
      onWillAcceptWithDetails: (d) => _canDrop(d.data, folderId),
      onAcceptWithDetails: (d) => _drop(d.data, folderId),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius ?? BorderRadius.circular(10),
          color: candidates.isEmpty ? null : Theme.of(context).colorScheme.primaryContainer,
        ),
        child: child,
      ),
    );
  }

  Widget _draggable(_Dragged data, String label, IconData icon, Widget child) {
    return Draggable<_Dragged>(
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    );
  }

  // ---- dialogs -------------------------------------------------------------

  Future<String?> _askName(String title, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Name')),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('OK')),
        ],
      ),
    ).then((name) => name == null || name.isEmpty ? null : name);
  }

  /// Picks a folder (see [pickFolder]).
  Future<(String?,)?> _pickFolder(String title, {Set<String> exclude = const {}, String? current}) =>
      pickFolder(context, folders: _folders, title: title, exclude: exclude, current: current);

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    return ok == true;
  }

  // ---- actions -------------------------------------------------------------

  /// Makes a note of a note file, in folder [folderId], and refreshes the list.
  Future<void> _openNoteFile(String folderId) async {
    await openNoteFile(context, widget.noteFiles!, folderId: folderId);
    if (mounted) _reload();
  }

  Future<void> _newFolder({String? parentId}) async {
    final name = await _askName(parentId == null ? tr('New folder') : tr('New subfolder in "{name}"', {'name': _folder(parentId)?.name}));
    if (name == null) return;
    await _run(() async {
      final id = await _repo.createFolder(name, parentId: parentId);
      if (parentId != null) _expanded.add(parentId);
      _scope = id;
    });
  }

  /// Asks in which style the notes of the folder cite their sources (those that have no style of their own).
  Future<void> _chooseCitationStyle(CitationService citations, FolderEntry f) async {
    final own = citations.ownStyleOfFolder(f.id);
    const none = '';
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text.verbatim(tr('Citation style of "{name}"', {'name': f.name})),
        children: [
          RadioGroup<String>(
            groupValue: own?.id ?? none,
            onChanged: (v) => Navigator.pop(context, v ?? none),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              RadioListTile<String>.adaptive(
                key: const ValueKey('folder-style-none'),
                value: none,
                title: Text.verbatim(tr('As the folder around it, or as every note ({name})', {'name': citations.style.name})),
              ),
              for (final s in citationStyles) RadioListTile<String>.adaptive(key: ValueKey('folder-style-${s.id}'), value: s.id, title: Text.verbatim(s.name)),
            ]),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await citations.setFolderStyle(f.id, chosen.isEmpty ? null : citationStyleById(chosen));
  }

  Future<void> _renameFolder(FolderEntry f) async {
    final name = await _askName('Rename folder', initial: f.name);
    if (name != null) await _run(() => _repo.renameFolder(f.id, name));
  }

  Future<void> _moveFolder(FolderEntry f) async {
    final target = await _pickFolder(tr('Move "{name}" to', {'name': f.name}), exclude: _subtreeOf(f.id), current: f.parentId);
    if (target != null) await _run(() => _repo.moveFolder(f.id, target.$1));
  }

  /// Lets the user pick an image for [f]. A copy is kept in the app's storage,
  /// so the banner survives the original being moved or deleted.
  Future<void> _pickThemeImage(FolderEntry f) async {
    final picked = await pickedPath(await FilePicker.pickFile(type: FileType.image));
    if (picked == null) return;
    await _run(() async {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'folder_images'));
      await dir.create(recursive: true);
      // a new name each time, so that the image widget does not show a cached old one
      final copy = p.join(dir.path, '${f.id}-${DateTime.now().millisecondsSinceEpoch}${p.extension(picked)}');
      await File(picked).copy(copy);
      await _repo.setFolderThemeImage(f.id, copy);
      _deleteImageFile(f.themeImage);
    });
  }

  Future<void> _removeThemeImage(FolderEntry f) => _run(() async {
    await _repo.setFolderThemeImage(f.id, null);
    _deleteImageFile(f.themeImage);
  });

  void _deleteImageFile(String? path) {
    if (path == null) return;
    File(path,).delete().catchError((Object _) => File(path)); // already gone is fine
  }

  Future<void> _deleteFolder(FolderEntry f) async {
    final subfolders = _subtreeOf(f.id).length - 1;
    final ok = await _confirm(
      tr('Delete folder?'),
      tr(
        subfolders > 0
            ? '"{name}" and its {n} subfolders will be deleted. The notes inside are kept, without a folder.'
            : '"{name}" will be deleted. The notes inside are kept, without a folder.',
        {'name': f.name, 'n': subfolders},
      ),
    );
    if (!ok) return;
    final images = [for (final id in _subtreeOf(f.id)) _folder(id)?.themeImage];
    await _run(() => _repo.deleteFolder(f.id));
    images.forEach(_deleteImageFile);
  }

  Future<void> _fromTemplate() async {
    final id = await newNoteFromTemplate(context, widget.templates!, folderId: _inRealFolder ? _scope : null);
    if (id != null) widget.onOpenNote(id);
  }

  Future<void> _newNote() async {
    final id = await _repo.createNote(folderId: _inRealFolder ? _scope : null);
    widget.onOpenNote(id);
  }

  Future<void> _moveNote(NoteSummary n) async {
    final target = await _pickFolder(tr('Move "{name}" to', {'name': n.shownTitle}), current: n.folderId);
    if (target != null) await _run(() => _repo.moveNote(n.id, target.$1));
  }

  Future<void> _deleteNote(NoteSummary n) async {
    final ok = await _confirm(tr('Move note to the trash?'), tr('"{title}" goes to the trash, where it stays for 30 days.', {'title': n.shownTitle}));
    if (ok) await _run(() => _repo.trashNote(n.id));
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final collab = widget.collab;
    if (collab == null) return _page(context);
    // the group symbols and the "Shared with me" folder follow what is shared
    return ListenableBuilder(listenable: Listenable.merge([collab, collab.shared, ?collab.nativeShares]), builder: (context, _) => _page(context));
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// On a phone the folder tree does not fit beside the notes: it slides in from the left instead.
  bool get _narrow => MediaQuery.sizeOf(context).width < 700;

  void _closeDrawer() {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) Navigator.of(context).pop();
  }

  Widget _page(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator.adaptive());
    final selectedHere = _selectedHere;
    final narrow = _narrow;
    return Scaffold(
      key: _scaffoldKey,
      drawer: narrow ? Drawer(child: SafeArea(child: _buildTree())) : null,
      appBar: _selecting
          ? SelectionBar(
              count: selectedHere.length,
              total: _visibleNotes.length,
              onClose: _endSelecting,
              onSelectAll: () => setState(() => _selected.addAll(_visibleNotes.map((n) => n.id))),
              onMove: _moveSelected,
              onDelete: _trashSelected,
              onFavorite: _starSelected,
              allFavorite: selectedHere.isNotEmpty && _visibleNotes.where((n) => _selected.contains(n.id)).every((n) => n.favorite),
            )
          : AppBar(
              title: const Text('Folders', style: TextStyle(fontWeight: FontWeight.bold)),
              actions: [
                if (narrow) IconButton(icon: const Icon(Icons.account_tree_outlined), tooltip: tr('Folders'), onPressed: () => _scaffoldKey.currentState?.openDrawer()),
                if (widget.sync != null) SyncNowButton(sync: widget.sync!, shares: widget.collab?.nativeShares),
                IconButton(
                  key: const ValueKey('select-notes'),
                  tooltip: tr('Select notes'),
                  icon: const Icon(Icons.checklist_rtl),
                  onPressed: () => setState(() => _selecting = true),
                ),
                if (widget.templates != null)
                  IconButton(
                    key: const ValueKey('new-from-template'),
                    tooltip: tr('New note from a template'),
                    icon: const Icon(Icons.dashboard_customize_outlined),
                    onPressed: _fromTemplate,
                  ),
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: tr(_inRealFolder ? 'New subfolder' : 'New folder'),
                  onPressed: () => _newFolder(parentId: _inRealFolder ? _scope : null),
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: narrow
          ? _buildContent()
          : Row(
              children: [
                SizedBox(width: 280, child: _buildTree()),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _buildContent()),
              ],
            ),
      floatingActionButton: _scope == _trash
          ? null
          : FloatingActionButton.extended(
              onPressed: _newNote,
              icon: const Icon(Icons.add),
              label: Text(_inRealFolder ? 'New note here' : 'New note'),
            ),
    );
  }

  Widget _buildTree() {
    final rows = <Widget>[
      _pseudoRow(_all, 'All notes', Icons.notes_rounded, _notes.length),
      _pseudoRow(_favorites, 'Favourites', Icons.star_outline_rounded, _notes.where((n) => n.favorite).length),
      _pseudoRow(_unfiled, 'No folder', Icons.inbox_outlined, _notes.where((n) => n.folderId == null).length),
      if (widget.collab != null)
        _pseudoRow(_shared, 'Shared with me', Icons.folder_shared_outlined, _notes.where((n) => _sharedWithMe.contains(n.id)).length,
            waiting: widget.collab?.nativeShares?.pending.length ?? 0),
      _pseudoRow(_trash, 'Trash', Icons.delete_outline, _trashCount),
      const Divider(height: 16),
    ];
    void add(String? parent, int depth) {
      for (final f in _childrenOf(parent)) {
        rows.add(_folderRow(f, depth));
        if (_expanded.contains(f.id)) add(f.id, depth + 1);
      }
    }

    add(null, 0);
    if (widget.tags != null) rows.addAll(_tagRows());
    if (_folders.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No folders yet. Use the button at the top to create one.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8), children: rows);
  }

  /// The Tags part of the tree: a heading with the manage button, then the tags nested as deep as they go (a tag with tags under it
  /// opens and closes like a folder).
  List<Widget> _tagRows() {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[
      const Divider(height: 16),
      Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(children: [
          Expanded(child: Text('Tags', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, letterSpacing: 0.5))),
          IconButton(
            key: const ValueKey('manage-tags'),
            tooltip: tr('Manage tags'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.sell_outlined, size: 18),
            onPressed: () => manageTags(context, widget.tags!, onChanged: _reload).then((_) => _reload()),
          ),
        ]),
      ),
    ];
    void add(List<TagNode> nodes) {
      for (final n in nodes) {
        final open = _expanded.contains('$_tagPrefix${n.tag}');
        rows.add(ListTile(
          key: ValueKey('tag-row-${n.tag}'),
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + 16 * n.depth, right: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          selected: _scope == '$_tagPrefix${n.tag}',
          leading: n.children.isEmpty
              ? const Icon(Icons.tag, size: 18)
              : InkWell(
                  key: ValueKey('tag-toggle-${n.tag}'),
                  onTap: () => setState(() => open ? _expanded.remove('$_tagPrefix${n.tag}') : _expanded.add('$_tagPrefix${n.tag}')),
                  child: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18),
                ),
          title: Text.verbatim(tagLeaf(n.tag), overflow: TextOverflow.ellipsis),
          trailing: Text('${n.notes}', style: const TextStyle(fontSize: 12)),
          onTap: () {
            setState(() => _scope = '$_tagPrefix${n.tag}');
            _closeDrawer();
          },
        ));
        if (open) add(n.children);
      }
    }

    add(_tagTree);
    if (_tagTree.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text('Give a note a tag from its menu to find it here.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ));
    }
    return rows;
  }

  Widget _pseudoRow(String scope, String label, IconData icon, int count, {int waiting = 0}) {
    final row = ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: _scope == scope,
      leading: Icon(icon, size: 20),
      title: Text(label),
      trailing: waiting > 0
          ? Badge(key: const ValueKey('invitations-badge'), label: Text('$waiting'), child: Text('$count', style: const TextStyle(fontSize: 12)))
          : Text('$count', style: const TextStyle(fontSize: 12)),
      onTap: () {
        setState(() => _scope = scope);
        _closeDrawer();
      },
    );
    // dropping on "No folder" takes a note out of its folder / a folder to the top
    return scope == _unfiled ? _dropTarget(null, row) : row;
  }

  Widget _folderRow(FolderEntry f, int depth) {
    final hasChildren = _childrenOf(f.id).isNotEmpty;
    final expanded = _expanded.contains(f.id);
    final row = ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: _scope == f.id,
      contentPadding: EdgeInsets.only(left: 4.0 + depth * 18, right: 0),
      leading: SizedBox(
        width: 48,
        child: Row(
          children: [
            hasChildren
                ? InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => expanded ? _expanded.remove(f.id) : _expanded.add(f.id)),
                    child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 22),
                  )
                : const SizedBox(width: 22),
            Icon(expanded ? Icons.folder_open : Icons.folder_outlined, size: 20),
          ],
        ),
      ),
      title: Row(children: [
        Flexible(child: Text.verbatim(f.name, overflow: TextOverflow.ellipsis)),
        // shared with people at the cloud service (the folder itself, or one below a shared one)
        if (widget.collab?.shared.folderKind(f.id).isShared ?? false)
          Padding(padding: const EdgeInsets.only(left: 6), child: SharedBadge(key: ValueKey('shared-badge-folder-${f.id}'), kind: widget.collab!.shared.folderKind(f.id), size: 14)),
      ]),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.verbatim('${f.noteCount}', style: const TextStyle(fontSize: 12)),
          PopupMenuButton<VoidCallback>(
            tooltip: tr('Folder actions'),
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: () => _newFolder(parentId: f.id),
                child: const Text('New subfolder'),
              ),
              if (widget.noteFiles != null) PopupMenuItem(value: () => _openNoteFile(f.id), child: const Text('Open a note file here...')),
              if (widget.collab?.nativeShares != null)
                PopupMenuItem(value: () => showShareFolder(context, widget.collab!.nativeShares!, folderId: f.id, name: f.name), child: const Text('Share with people...')),
              if (CitationScope.maybeOf(context) case final citations? when citations.enabled())
                PopupMenuItem(value: () => _chooseCitationStyle(citations, f), child: const Text('Citation style...')),
              PopupMenuItem(value: () => _renameFolder(f), child: const Text('Rename')),
              PopupMenuItem(value: () => _moveFolder(f), child: const Text('Move to...')),
              PopupMenuItem(value: () => _pickThemeImage(f), child: Text(f.themeImage == null ? 'Set theme image...' : 'Change theme image...')),
              if (f.themeImage != null) PopupMenuItem(value: () => _removeThemeImage(f), child: const Text('Remove theme image')),
              PopupMenuItem(value: () => _deleteFolder(f), child: const Text('Delete')),
            ],
          ),
        ],
      ),
      onTap: () {
        setState(() {
          _scope = f.id;
          if (hasChildren) _expanded.add(f.id);
        });
        _closeDrawer();
      },
    );
    return _dropTarget(f.id, _draggable(_DraggedFolder(f.id), f.name, Icons.folder_outlined, row));
  }

  Widget _buildContent() {
    if (_scope == _trash) return TrashView(key: const ValueKey('folder-trash'), repository: _repo, onChanged: _reload);
    final notes = _visibleNotes;
    final subfolders = _inRealFolder ? _childrenOf(_scope) : <FolderEntry>[];
    final title = switch (_scope) {
      _all => 'All notes',
      _unfiled => 'Notes without a folder',
      _shared => 'Shared with me',
      _favorites => 'Favourites',
      _ when _isTagScope => '#$_shownTag',
      _ => _path(_scope),
    };

    // (what comes before the notes is a few widgets; the notes are made as they scroll into view - a folder may hold thousands)
    final head = <Widget>[
      if (widget.collab?.nativeShares != null) ShareInvitations(service: widget.collab!.nativeShares!),
      _buildHeader(title),
      if (subfolders.isNotEmpty) ...[
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in subfolders)
              _dropTarget(
                f.id,
                ActionChip(
                  avatar: const Icon(Icons.folder_outlined, size: 18),
                  label: Text.verbatim('${f.name} (${f.noteCount})'),
                  onPressed: () => setState(() {
                    _expanded.add(_scope);
                    _scope = f.id;
                  }),
                ),
                radius: BorderRadius.circular(8),
              ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      if (notes.length > 1) Align(alignment: Alignment.centerRight, child: _sortMenu()),
      const SizedBox(height: 8),
      if (notes.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 32),
          child: Text(_inRealFolder ? 'This folder has no notes yet.' : 'No notes here.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
    ];
    return ListView.builder(
      padding: EdgeInsets.all(_narrow ? 12 : 24),
      itemCount: head.length + notes.length,
      itemBuilder: (_, i) => i < head.length ? head[i] : _noteTile(notes[i - head.length]),
    );
  }

  /// Folder title; with a theme image it becomes a banner with the title on it.
  Widget _buildHeader(String title) {
    final folder = _inRealFolder ? _folder(_scope) : null;
    final titleStyle = Theme.of(context,).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold);
    final image = folder?.themeImage;

    if (folder == null) return Text(title, style: titleStyle);
    if (image == null) {
      return Row(
        children: [
          Expanded(child: Text.verbatim(title, style: titleStyle)),
          OutlinedButton.icon(
            onPressed: () => _pickThemeImage(folder),
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('Theme image'),
          ),
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 180,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(image),
              key: ValueKey(image),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
            ),
            // darkens the bottom so the title stays readable on any picture
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xB3000000)]),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: Text.verbatim(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: titleStyle?.copyWith(
                  color: Colors.white,
                  shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: tr('Change theme image'),
                    icon: const Icon(Icons.image_outlined, size: 18),
                    onPressed: () => _pickThemeImage(folder),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: tr('Remove theme image'),
                    icon: const Icon(Icons.hide_image_outlined, size: 18),
                    onPressed: () => _removeThemeImage(folder),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFavorite(NoteSummary n) async {
    await widget.repository.setFavorite(n.id, !n.favorite);
    await _reload();
  }

  Widget _noteTile(NoteSummary n) {
    final kind = widget.collab?.shared.kindOf(n.id) ?? SharedKind.none;
    final where = (_scope == _all || _scope == _shared || _scope == _favorites) && n.folderId != null ? '  -  ${_path(n.folderId)}' : '';
    final card = Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      color: _selected.contains(n.id) ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        leading: _selecting
            ? Checkbox.adaptive(key: ValueKey('select-${n.id}'), value: _selected.contains(n.id), onChanged: (_) => _toggleSelected(n.id))
            : SizedBox(
                width: 44,
                height: 44,
                child: Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.center,
                  children: [
                    if (n.themeImage == null)
                      Icon(n.locked ? Icons.lock_outline : (n.isPdf ? Icons.picture_as_pdf : Icons.edit_note_rounded))
                    else
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(n.themeImage!),
                          key: ValueKey(n.themeImage),
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(n.isPdf ? Icons.picture_as_pdf : Icons.edit_note_rounded),
                        ),
                      ),
                    if (widget.previews != null)
                      NotePreviewImage(
                        previews: widget.previews,
                        noteId: n.id,
                        changed: n.updatedAt,
                        locked: n.locked,
                        opacity: n.themeImage == null ? 1.0 : 0.8,
                        borderRadius: BorderRadius.circular(8),
                      ),
                  ],
                ),
              ),
        title: Text.verbatim(n.shownTitle, overflow: TextOverflow.ellipsis),
        subtitle: Text.verbatim('${n.favorite && _narrow ? '★ ' : ''}${_ago(n.updatedAt)}$where${_tagLabel(n)}', overflow: TextOverflow.ellipsis),
        onTap: () => _selecting || selectModifierPressed ? _toggleSelected(n.id) : widget.onOpenNote(n.id),
        onLongPress: _selecting ? null : () => _toggleSelected(n.id),
        trailing: _selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_narrow) IconButton(
                    key: ValueKey('star-${n.id}'),
                    tooltip: tr(n.favorite ? 'Remove from favourites' : 'Add to favourites'),
                    icon: Icon(n.favorite ? Icons.star_rounded : Icons.star_outline_rounded, color: n.favorite ? Colors.amber : null),
                    onPressed: () => _toggleFavorite(n),
                  ),
                  SharedBadge(key: ValueKey('shared-badge-${n.id}'), kind: kind, from: widget.collab?.shared.fromWhom(n.id)),
                  PopupMenuButton<VoidCallback>(
                    tooltip: tr('Note actions'),
                    onSelected: (action) => action(),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: () => widget.onOpenNote(n.id), child: const Text('Open')),
                      PopupMenuItem(value: () => _toggleFavorite(n), child: Text(n.favorite ? 'Remove from favourites' : 'Add to favourites')),
                      PopupMenuItem(value: () => _toggleSelected(n.id), child: const Text('Select')),
                      PopupMenuItem(value: () => _moveNote(n), child: const Text('Move to...')),
                      if (widget.reminders != null)
                        PopupMenuItem(
                          key: ValueKey('remind-menu-${n.id}'),
                          value: () => showRemindDialog(context, widget.reminders!, kind: ReminderKind.note, refId: n.id, title: n.shownTitle),
                          child: const Text('Remind me...'),
                        ),
                      if (widget.tags != null)
                        PopupMenuItem(
                          key: ValueKey('tags-menu-${n.id}'),
                          value: () => editNoteTags(context, widget.tags!, n.id, title: n.shownTitle).then((_) => _reload()),
                          child: const Text('Tags...'),
                        ),
                      if (widget.templates != null && !n.locked)
                        PopupMenuItem(
                          value: () => saveNoteAsTemplate(context, widget.templates!, n.id, n.title),
                          child: const Text('Save as a template...'),
                        ),
                      if (widget.noteFiles != null && !n.locked)
                        PopupMenuItem(value: () => saveNoteAsFile(context, widget.noteFiles!, n.id, n.title), child: const Text('Save as a file...')),
                      PopupMenuItem(value: () => _deleteNote(n), child: const Text('Delete')),
                    ],
                  ),
                ],
              ),
      ),
    );
    final together = _selected.contains(n.id) ? _selectedHere.length : 1;
    return _draggable(
      _DraggedNote(n.id),
      together > 1 ? trCount(together, '1 note', '{n} notes') : n.shownTitle,
      n.locked ? Icons.lock_outline : (n.isPdf ? Icons.picture_as_pdf : Icons.edit_note_rounded),
      card,
    );
  }

  /// "  -  #a #b" for a note that has tags; nothing otherwise.
  String _tagLabel(NoteSummary n) {
    final tags = _noteTags[n.id];
    return tags == null || tags.isEmpty ? '' : '  -  ${(tags.toList()..sort()).map((t) => '#$t').join(' ')}';
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('just now');
    if (d.inMinutes < 60) return tr('{n} mins ago', {'n': d.inMinutes});
    if (d.inHours < 24) return tr('{n} hours ago', {'n': d.inHours});
    return tr('{n} days ago', {'n': d.inDays});
  }
}
