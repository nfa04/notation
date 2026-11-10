part of 'fixed_page_note_editor.dart';

/// The sections of the toolbars, with what the list calls them.
const _toolbarSections = <String, String>{
  'edit': 'Undo and redo',
  'note': 'Pages, lock and favourite',
  'mode': 'Select, draw or document',
  'insert': 'Insert text, tables and pictures',
  'page': 'Page background and size',
  'tools': 'Dictate, read aloud and assistant',
  'history': 'History and live work',
  'files': 'PDF and files',
};

/// The room the button that changes the toolbar profile takes in the app bar.
const _profileMenuWidth = 150.0;

/// The sections that start in the bottom bar, until the user moves them.
const _defaultBottomSections = {'insert', 'page', 'files'};

typedef _ToolbarLayout = ({List<String> top, List<String> bottom, Set<String> hidden});

/// The saved layout; anything unreadable means the default.
_ToolbarLayout _decodeToolbarLayout(String? saved) {
  const none = (top: <String>[], bottom: <String>[], hidden: <String>{});
  if (saved == null) return none;
  try {
    final json = jsonDecode(saved) as Map<String, dynamic>;
    List<String> ids(String key) => [for (final id in (json[key] as List? ?? const [])) id as String];
    if (!json.containsKey('top')) {
      // the first version had one bar and called its order "order": keep that order, with the sections that now start below moved down
      final order = ids('order');
      return (
        top: [for (final id in order) if (!_defaultBottomSections.contains(id)) id],
        bottom: [for (final id in order) if (_defaultBottomSections.contains(id)) id],
        hidden: ids('hidden').toSet(),
      );
    }
    return (top: ids('top'), bottom: ids('bottom'), hidden: ids('hidden').toSet());
  } catch (_) {
    return none;
  }
}

/// [order] and [bottomOrder] as the top and bottom bars hold them: the sections of each in that order, then the ones in neither,
/// each in its default bar. No section is in both.
(List<String>, List<String>) _placeToolbarSections(List<String> order, List<String> bottomOrder) {
  final top = <String>[];
  final bottom = <String>[];
  for (final id in order) {
    if (_toolbarSections.containsKey(id) && !top.contains(id)) top.add(id);
  }
  for (final id in bottomOrder) {
    if (_toolbarSections.containsKey(id) && !top.contains(id) && !bottom.contains(id)) bottom.add(id);
  }
  for (final id in _toolbarSections.keys) {
    if (top.contains(id) || bottom.contains(id)) continue;
    (_defaultBottomSections.contains(id) ? bottom : top).add(id);
  }
  return (top, bottom);
}

/// Rearranging the toolbars: which sections show, in what order, and in which bar.
extension _EditorToolbar on _FixedPageNoteEditorState {
  /// What the top and bottom bars hold: the saved order, then the sections never placed, each in its default bar. No section is in both.
  (List<String>, List<String>) _toolbarPlaced() => _placeToolbarSections(_toolbarOrder, _toolbarBottom);

  List<String> _toolbarTopIds() => _toolbarPlaced().$1;
  List<String> _toolbarBottomIds() => _toolbarPlaced().$2;

  /// The bar at the bottom of the screen: the formatting bar for the Markdown being edited, and the bottom toolbar.
  Widget? _bottomBars() {
    final formatting = _bottomBar();
    final buttons = _toolbarBottomIds().isEmpty ? <Widget>[] : _toolbarButtons(context, bottom: true);
    if (buttons.isEmpty) return formatting;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ?formatting,
      Material(
        elevation: toolBarElevation(context, 3),
        color: isIosLook(context) ? toolBarColor(context) : null,
        shape: toolBarEdge(context, top: true),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            key: const ValueKey('bottom-toolbar'),
            constraints: const BoxConstraints(minHeight: 52),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
            ),
          ),
        ),
      ),
    ]);
  }


  Future<void> _saveToolbar() async {
    final settings = widget.repository.settings;
    await settings.set('toolbar_layout', jsonEncode({'top': _toolbarOrder, 'bottom': _toolbarBottom, 'hidden': _toolbarHidden.toList()}));
    if (_toolbarProfiles.isEmpty) {
      await settings.remove('toolbar_profiles');
    } else {
      await settings.set('toolbar_profiles', encodeToolbarProfiles(_toolbarProfiles, _activeToolbarProfile));
    }
  }

  /// Changes to the profile [id]: its bars and its tools replace the ones in use. The settings are not touched: the profile
  /// only leaves out tools that are on there.
  Future<void> _switchToolbarProfile(String id) async {
    final target = _toolbarProfiles.where((p) => p.id == id).firstOrNull;
    if (target == null || id == _activeToolbarProfile) return;
    final placed = _placeToolbarSections(target.top, target.bottom);
    setState(() {
      _activeToolbarProfile = id;
      _toolbarOrder = placed.$1;
      _toolbarBottom = placed.$2;
      _toolbarHidden = {...target.hidden};
    });
    _syncMathCheck(); // (the check of the maths is a tool too)
    await _saveToolbar();
  }

  /// Changes to the profile [step] places on in the list (the one before for -1), after the last the first, and says which it is.
  Future<void> _stepToolbarProfile(int step) async {
    final at = _toolbarProfiles.indexWhere((p) => p.id == _activeToolbarProfile);
    final next = _toolbarProfiles[(at + step) % _toolbarProfiles.length];
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 1), content: Text.verbatim(next.name)));
    await _switchToolbarProfile(next.id);
  }

  /// The button that changes the profile, once there is more than one. It stays in the app bar, outside the buttons that scroll.
  Widget? _toolbarProfileMenu() {
    if (_toolbarProfiles.length < 2) return null;
    final active = _toolbarProfiles.where((p) => p.id == _activeToolbarProfile).firstOrNull;
    return PopupMenuButton<String>(
      key: const ValueKey('toolbar-profile-menu'),
      tooltip: tr('Change the toolbar profile'),
      onSelected: _switchToolbarProfile,
      itemBuilder: (context) => [
        for (final p in _toolbarProfiles) CheckedPopupMenuItem(key: ValueKey('toolbar-profile-${p.id}'), value: p.id, checked: p.id == active?.id, child: Text(p.name)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.dashboard_customize_outlined, size: 20),
          const SizedBox(width: 4),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 110), child: Text(active?.name ?? '', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
        ]),
      ),
    );
  }

  /// Asks for the name of a profile; null if the question is dismissed or the name is empty.
  Future<String?> _askProfileName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(tr(title)),
        content: TextField(
          key: const ValueKey('toolbar-profile-name'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('Name')),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('OK'))),
        ],
      ),
    );
    // (not disposed: the dialog is still on screen while it closes)
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _customizeToolbar() async {
    final placed = _toolbarPlaced();
    var top = placed.$1;
    var bottom = placed.$2;
    final hidden = {..._toolbarHidden};
    var profiles = [..._toolbarProfiles];
    var active = _activeToolbarProfile;
    // the tools the profile uses (without profiles all of them: what the settings have on is what there is)
    var tools = {...(profiles.where((p) => p.id == active).firstOrNull?.tools ?? toolbarTools)};

    /// Puts what is being arranged into the profile in use.
    void commit() {
      final i = profiles.indexWhere((p) => p.id == active);
      if (i >= 0) profiles[i] = profiles[i].copyWith(top: top, bottom: bottom, hidden: {...hidden}, tools: {...tools});
    }

    void open(ToolbarProfile p) {
      final placed = _placeToolbarSections(p.top, p.bottom);
      top = placed.$1;
      bottom = placed.$2;
      hidden
        ..clear()
        ..addAll(p.hidden);
      tools = {...p.tools};
      active = p.id;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          Widget bar(String title, String keyName, List<String> ids, void Function(List<String>) set, void Function(String) move, IconData moveIcon, String moveTip) =>
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(tr(title), style: Theme.of(context).textTheme.titleSmall),
                ),
                if (ids.isEmpty)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('Nothing here. Move a section over from the other bar.'), style: Theme.of(context).textTheme.bodySmall))
                else
                  ReorderableListView(
                    key: ValueKey('toolbar-list-$keyName'),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: (from, to) => setDialog(() {
                      final moved = [...ids];
                      moved.insert(to, moved.removeAt(from));
                      set(moved);
                    }),
                    children: [
                      for (var i = 0; i < ids.length; i++)
                        ListTile(
                          key: ValueKey('toolbar-${ids[i]}'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                          title: Text(tr(_toolbarSections[ids[i]]!)),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              key: ValueKey('toolbar-move-${ids[i]}'),
                              tooltip: tr(moveTip),
                              icon: Icon(moveIcon),
                              onPressed: () => setDialog(() => move(ids[i])),
                            ),
                            Switch.adaptive(
                              value: !hidden.contains(ids[i]),
                              onChanged: (on) => setDialog(() => on ? hidden.remove(ids[i]) : hidden.add(ids[i])),
                            ),
                          ]),
                        ),
                    ],
                  ),
              ]);

          Future<void> newProfile() async {
            final name = await _askProfileName('New profile', '');
            if (name == null) return;
            setDialog(() {
              // the first profile is the arrangement in use until now
              if (profiles.isEmpty) {
                active = 'default';
                profiles.add(ToolbarProfile(id: active!, name: tr('Default'), top: top, bottom: bottom, hidden: {...hidden}, tools: {...tools}));
              }
              commit();
              // the new one starts as a copy of what is in front of the user
              final id = 'p${DateTime.now().microsecondsSinceEpoch}';
              profiles.add(ToolbarProfile(id: id, name: name, top: top, bottom: bottom, hidden: {...hidden}, tools: {...tools}));
              active = id;
            });
          }

          Future<void> renameProfile() async {
            final current = profiles.firstWhere((p) => p.id == active);
            final name = await _askProfileName('Rename the profile', current.name);
            if (name == null) return;
            setDialog(() => profiles[profiles.indexOf(current)] = current.copyWith(name: name));
          }

          void deleteProfile() => setDialog(() {
                profiles.removeWhere((p) => p.id == active);
                // the one before it takes its place; with a single profile left, the profiles are over
                open(profiles.first);
                if (profiles.length == 1) {
                  profiles.clear();
                  active = null;
                }
              });

          Widget profilesSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Profiles'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                if (profiles.isEmpty)
                  Text(tr('A profile keeps an arrangement of the toolbars with the tools it uses, so you can change between ways of working (drawing, maths...) in one tap.'), style: Theme.of(context).textTheme.bodySmall)
                else
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final p in profiles)
                      ChoiceChip(
                        key: ValueKey('profile-chip-${p.id}'),
                        label: Text(p.name),
                        selected: p.id == active,
                        onSelected: (_) => setDialog(() {
                          commit();
                          open(p);
                        }),
                      ),
                  ]),
                Wrap(spacing: 8, children: [
                  TextButton.icon(key: const ValueKey('profile-new'), onPressed: newProfile, icon: const Icon(Icons.add, size: 18), label: Text(tr('New profile'))),
                  if (active != null) TextButton.icon(key: const ValueKey('profile-rename'), onPressed: renameProfile, icon: const Icon(Icons.edit_outlined, size: 18), label: Text(tr('Rename'))),
                  if (active != null) TextButton.icon(key: const ValueKey('profile-delete'), onPressed: deleteProfile, icon: const Icon(Icons.delete_outline, size: 18), label: Text(tr('Delete'))),
                ]),
              ]);

          Widget toolsSection() {
            // only what is on in the settings: a tool that is off there is off in every profile
            final available = [for (final f in toolbarTools) if (_inSettings(f)) f];
            return ExpansionTile(
              key: const ValueKey('toolbar-tools'),
              tilePadding: EdgeInsets.zero,
              title: Text(tr('Tools in this profile'), style: Theme.of(context).textTheme.titleSmall),
              subtitle: Text(tr('The tools that are switched on in the settings. One that is off there is off in every profile.'), style: Theme.of(context).textTheme.bodySmall),
              children: [
                for (final f in available) ...[
                  if (f == available.firstWhere((t) => t.group == f.group))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Text(tr(f.group.title), style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                      ),
                    ),
                  SwitchListTile.adaptive(
                    key: ValueKey('toolbar-tool-${f.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(f.icon, size: 20),
                    title: Text(tr(f.title)),
                    value: tools.contains(f),
                    onChanged: (on) => setDialog(() => on ? tools.add(f) : tools.remove(f)),
                  ),
                ],
              ],
            );
          }

          return PlatformAlertDialog(
            title: Text(tr('Arrange the toolbars')),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  profilesSection(),
                  const Divider(),
                  bar('Top bar', 'top', top, (l) => top = l, (id) {
                    top = [...top]..remove(id);
                    bottom = [...bottom, id];
                  }, Icons.arrow_downward, 'Move to the bottom bar'),
                  const Divider(),
                  bar('Bottom bar', 'bottom', bottom, (l) => bottom = l, (id) {
                    bottom = [...bottom]..remove(id);
                    top = [...top, id];
                  }, Icons.arrow_upward, 'Move to the top bar'),
                  if (active != null) ...[const Divider(), toolsSection()],
                ]),
              ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('toolbar-reset'),
                onPressed: () => setDialog(() {
                  top = [for (final id in _toolbarSections.keys) if (!_defaultBottomSections.contains(id)) id];
                  bottom = [for (final id in _toolbarSections.keys) if (_defaultBottomSections.contains(id)) id];
                  hidden.clear();
                }),
                child: Text(tr('Reset')),
              ),
              FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Done'))),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    commit();
    setState(() {
      _toolbarOrder = top;
      _toolbarBottom = bottom;
      _toolbarHidden = hidden;
      _toolbarProfiles = profiles;
      _activeToolbarProfile = active;
    });
    _syncMathCheck();
    await _saveToolbar();
  }
}
