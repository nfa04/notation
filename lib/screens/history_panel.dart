import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:pdfrx/pdfrx.dart';

import '../data/note_data.dart';
import '../data/note_file.dart';
import '../history/note_history.dart';
import '../history/version_diff.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../collab/replica.dart' show CollabOp, ElementKind;
import '../markdown/markdown_view.dart';
import '../models/authorship.dart' show Author;
import '../models/canvas_models.dart';
import '../models/canvas_view.dart';
import '../models/image_item.dart';
import '../models/pdf_models.dart' show PdfHighlight;
import '../models/rich_text.dart';
import '../painters/canvas_painters.dart';
import '../pdf/pdf_page_loader.dart';
import 'document_sheet.dart';
import '../style/platform_dialog.dart';

part 'note_pages_view.dart';

/// The width of a page in the editor's page space (as `basePageWidth` of the editor).
const double _pdfPageWidth = 800;

/// The words for why a version was made.
String versionTitle(NoteVersion v) {
  if (v.manual) return v.label?.trim().isNotEmpty == true ? v.label! : tr('Saved version');
  return switch (v.reason) {
    VersionReason.edit => tr('While editing'),
    VersionReason.left => tr('When the note was left'),
    VersionReason.merge => v.who == null || v.who!.isEmpty
        ? tr('Before changes from someone else were taken in')
        : tr('Before changes from {who} were taken in', {'who': v.who}),
    VersionReason.restore => tr('Before an earlier version was restored'),
    VersionReason.joined => tr('Before joining a live session'),
    VersionReason.branch => tr('Before switching branch'),
    VersionReason.manual => tr('Saved version'),
    VersionReason.assistantBefore => v.label?.trim().isNotEmpty == true ? tr('Before the assistant: {what}', {'what': v.label}) : tr('Before the assistant changed the note'),
    VersionReason.assistant => v.label?.trim().isNotEmpty == true ? tr('Made by the assistant: {what}', {'what': v.label}) : tr('Made by the assistant'),
  };
}

/// Whether the assistant made the version, or was about to change the note when it was kept: shown apart from the others.
bool madeByAssistant(NoteVersion v) => !v.manual && (v.reason == VersionReason.assistant || v.reason == VersionReason.assistantBefore);

String _when(BuildContext context, DateTime t) {
  final l = MaterialLocalizations.of(context);
  return '${l.formatMediumDate(t)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}

/// Asks for the name of a version; null if cancelled.
Future<String?> _askName(BuildContext context, {String initial = '', required String title, String? hint}) =>
    showDialog<String>(context: context, builder: (context) => _NameDialog(initial: initial, title: title, hint: hint));

class _NameDialog extends StatefulWidget {
  final String initial;
  final String title;
  final String? hint;
  const _NameDialog({required this.initial, required this.title, this.hint});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: Text.verbatim(widget.title),
        content: TextField(
          key: const ValueKey('version-name'),
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Name'), hintText: widget.hint ?? tr('e.g. Before the exam')),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('version-name-ok'), onPressed: () => Navigator.pop(context, _controller.text.trim()), child: const Text('Save')),
        ],
      );
}

/// The history of a note, for the side of the editor (or a page of its own on a narrow screen): two tabs, the
/// versions the app made and the ones the person saved. Choosing one shows it in the panel, compared with the note
/// now or the version before, with Restore. [current] gives the note as it is now (saved first); [restore] restores
/// a version into the note.
class HistoryPanel extends StatefulWidget {
  final NoteHistory history;
  final String noteId;
  final Future<NoteData> Function() current;
  final Future<void> Function(NoteVersion version) restore;

  /// Makes the note what a version was without keeping the note first (as on switching to another branch), and puts changes into the
  /// note (a merged branch). With both, the panel offers branches.
  final Future<void> Function(NoteVersion version)? apply;
  final Future<void> Function(List<CollabOp> changes)? applyChanges;
  final VoidCallback onClose;

  const HistoryPanel(
      {super.key, required this.history, required this.noteId, required this.current, required this.restore, this.apply, this.applyChanges, required this.onClose});

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  late Future<List<NoteVersion>> _versions = widget.history.list(widget.noteId);
  bool get _canBranch => widget.apply != null && widget.applyChanges != null;
  NoteVersion? _shown;
  NoteVersion? _previous;
  List<NoteBranch> _branches = [NoteBranch(NoteHistory.mainBranch, null, DateTime.fromMillisecondsSinceEpoch(0), true)];
  String? _viewBranch; // the branch whose versions are listed (null: the one the note is on)
  CompareWith _compare = CompareWith.nothing;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.history.addListener(_reload);
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    final branches = await widget.history.branches(widget.noteId);
    if (!mounted) return;
    setState(() {
      _branches = branches;
      if (_viewBranch != null && !branches.any((b) => b.name == _viewBranch)) _viewBranch = null;
    });
  }

  String get _active => _branches.firstWhere((b) => b.active, orElse: () => _branches.first).name;
  String get _viewing => _viewBranch ?? _active;

  @override
  void didUpdateWidget(HistoryPanel old) {
    super.didUpdateWidget(old);
    if (old.noteId != widget.noteId || old.history != widget.history) {
      old.history.removeListener(_reload);
      widget.history.addListener(_reload);
      _shown = null;
      _reload();
    }
  }

  @override
  void dispose() {
    widget.history.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    final versions = widget.history.list(widget.noteId);
    setState(() {
      _versions = versions;
    });
    _loadBranches();
  }

  void _snack(String text) => ScaffoldMessenger.maybeOf(context,)?.showSnackBar(SnackBar(content: Text.verbatim(text)));

  Future<void> _saveNow() async {
    final name = await _askName(context, title: tr('Save this version'));
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.current(); // (the note on screen is saved first)
      await widget.history.snapshot(widget.noteId, manual: true, label: name.isEmpty ? null : name);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(NoteVersion v) async {
    final ok = await confirmRestore(context, v);
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.restore(v);
      if (!mounted) return;
      setState(() => _shown = null);
      _snack(tr('Restored "{name}"', {'name': versionTitle(v)}));
    } catch (e) {
      if (mounted) _snack(tr('Could not restore the version: {error}', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(NoteVersion v, List<NoteVersion> all, {CompareWith compare = CompareWith.nothing}) {
    // the version made before it on its branch (of either kind; a branch's first follows the version it began from), to compare with
    final line = [for (final x in all) if (x.branch == v.branch) x];
    final i = line.indexWhere((x) => x.id == v.id);
    final base = _branches.where((b) => b.name == v.branch).firstOrNull?.base;
    setState(() {
      _shown = v;
      _previous = i >= 0 && i + 1 < line.length ? line[i + 1] : (base == null ? null : all.where((x) => x.id == base).firstOrNull);
      _compare = compare;
    });
  }

  // ---- branches

  Future<void> _guarded(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on StateError catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A branch from the note as it is now, or from the earlier [from]; the note is then on it.
  Future<void> _newBranch({NoteVersion? from}) async {
    final name = await _askName(context, title: from == null ? tr('New branch from the note now') : tr('New branch from this version'), hint: tr('e.g. Second approach'));
    if (name == null || name.isEmpty || !mounted) return;
    await _guarded(() async {
      await widget.current(); // (the note on screen is saved first)
      await widget.history.createBranch(widget.noteId, name, from: from);
      if (from != null) await widget.apply!(from);
      if (!mounted) return;
      setState(() {
        _viewBranch = null;
        _shown = null;
      });
      _snack(tr('The note is on the branch "{name}" now', {'name': name}));
    });
  }

  Future<void> _switchTo(String name) async {
    await _guarded(() async {
      await widget.current();
      final head = await widget.history.switchTo(widget.noteId, name);
      if (head != null) await widget.apply!(head);
      if (!mounted) return;
      setState(() {
        _viewBranch = null;
        _shown = null;
      });
      _snack(tr('The note is on the branch "{name}" now', {'name': name}));
    });
  }

  Future<void> _merge(String source) async {
    final into = _active;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text.verbatim(tr('Merge "{from}" into "{into}"?', {'from': source, 'into': into})),
        content: Text.verbatim(tr(
            'What was changed on "{from}" since it was branched off (or last merged) is taken into the note. Where both were changed, the note keeps its own. The note as it is now is kept as a version first, so this can be undone.',
            {'from': source})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('branch-merge-ok'), onPressed: () => Navigator.pop(context, true), child: const Text('Merge')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _guarded(() async {
      final now = await widget.current();
      final merge = await widget.history.mergeChanges(widget.noteId, source, now);
      if (merge.changes.isEmpty) {
        await widget.history.completeMerge(widget.noteId, source, merge.head);
        if (mounted) _snack(merge.conflicts == 0 ? tr('Nothing to merge: the note has everything of "{name}" already', {'name': source}) : tr('Nothing could be merged: {n} things were changed on both sides, the note keeps its own', {'n': merge.conflicts}));
        return;
      }
      await widget.history.snapshot(widget.noteId, reason: VersionReason.merge, who: source);
      await widget.applyChanges!(merge.changes);
      await widget.history.completeMerge(widget.noteId, source, merge.head);
      if (!mounted) return;
      setState(() => _shown = null);
      _snack(merge.conflicts == 0
          ? tr('Merged {n} changes from "{name}"', {'n': merge.changes.length, 'name': source})
          : tr('Merged {n} changes from "{name}"; {k} things were changed on both sides and keep the note\'s version', {'n': merge.changes.length, 'name': source, 'k': merge.conflicts}));
    });
  }

  Future<void> _deleteBranch(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text.verbatim(tr('Delete the branch "{name}"?', {'name': name})),
        content: const Text('Its versions are deleted. The note itself stays as it is.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('branch-delete-ok'), onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _guarded(() async {
      await widget.history.deleteBranch(widget.noteId, name);
      if (mounted) setState(() => _viewBranch = null);
    });
  }

  Widget _branchBar(BuildContext context) {
    final viewing = _viewing, active = _active;
    return Padding(
      key: const ValueKey('branch-bar'),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
      child: Row(children: [
        Icon(Icons.account_tree_outlined, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<String>(
            key: const ValueKey('branch-select'),
            value: viewing,
            isExpanded: true,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final b in _branches) DropdownMenuItem(value: b.name, child: Text.verbatim(b.active ? '${b.name}  (${tr('the note is on it')})' : b.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (name) => setState(() => _viewBranch = name),
          ),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('branch-menu'),
          tooltip: tr('Branches'),
          onSelected: (c) {
            switch (c) {
              case 'new':
                _newBranch();
              case 'switch':
                _switchTo(viewing);
              case 'merge':
                _merge(viewing);
              case 'delete':
                _deleteBranch(viewing);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'new', enabled: !_busy, child: const Text('New branch from the note now')),
            if (viewing != active) PopupMenuItem(value: 'switch', enabled: !_busy, child: Text.verbatim(tr('Switch the note to "{name}"', {'name': viewing}))),
            if (viewing != active) PopupMenuItem(value: 'merge', enabled: !_busy, child: Text.verbatim(tr('Merge "{from}" into "{into}"', {'from': viewing, 'into': active}))),
            if (viewing != active && viewing != NoteHistory.mainBranch) PopupMenuItem(value: 'delete', enabled: !_busy, child: const Text('Delete this branch')),
          ],
        ),
      ]),
    );
  }

  Future<void> _menu(String choice, NoteVersion v, List<NoteVersion> all) async {
    switch (choice) {
      case 'preview':
        _show(v, all);
      case 'compare':
        _show(v, all, compare: CompareWith.now);
      case 'restore':
        await _restore(v);
      case 'branch':
        await _newBranch(from: v);
      case 'keep':
        final name = await _askName(context, title: tr('Keep this version'), initial: versionTitle(v));
        if (name != null) await widget.history.keep(v, name.isEmpty ? versionTitle(v) : name);
      case 'rename':
        final name = await _askName(context, title: tr('Rename the version'), initial: v.label ?? '');
        if (name != null && name.isNotEmpty) await widget.history.rename(v, name);
      case 'delete':
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => PlatformAlertDialog(
            title: const Text('Delete this version?'),
            content: Text.verbatim(tr('"{name}" from {when} is deleted. The note itself stays as it is.', {'name': versionTitle(v), 'when': _when(context, v.at)})),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(key: const ValueKey('version-delete-ok'), onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) {
          await widget.history.delete(v);
          if (mounted && _shown?.id == v.id) setState(() => _shown = null);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown;
    return Material(
      key: const ValueKey('history-panel'),
      color: scheme.surface,
      child: Column(children: [
        // the head: what is shown, and what can be done with it
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
          child: Row(children: [
            if (shown != null)
              IconButton(key: const ValueKey('history-back'), tooltip: tr('Back to the list'), icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _shown = null))
            else
              const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Icon(Icons.history)),
            Expanded(
              child: shown == null
                  ? Text('History', style: Theme.of(context).textTheme.titleMedium)
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.verbatim(versionTitle(shown), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                      Text.verbatim(_when(context, shown.at), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ]),
            ),
            if (shown != null)
              FilledButton.icon(
                key: const ValueKey('preview-restore'),
                onPressed: _busy ? null : () => _restore(shown),
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Restore'),
              ),
            IconButton(key: const ValueKey('history-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: widget.onClose),
          ]),
        ),
        if (_busy) const LinearProgressIndicator() else const Divider(height: 1),
        Expanded(
          child: shown == null
              ? _lists(context)
              : _VersionView(
                  key: ValueKey('version-view-${shown.id}'),
                  history: widget.history,
                  version: shown,
                  previous: _previous,
                  current: widget.current,
                  compare: _compare,
                  onCompare: (c) => setState(() => _compare = c),
                ),
        ),
      ]),
    );
  }

  Widget _lists(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: const ValueKey('version-save'),
              onPressed: _busy ? null : _saveNow,
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('Save this version'),
            ),
          ),
        ),
        if (_canBranch) _branchBar(context),
        TabBar(tabs: [
          Tab(key: const ValueKey('history-auto'), text: tr('Automatic')),
          Tab(key: const ValueKey('history-manual'), text: tr('Saved by you')),
        ]),
        Expanded(
          child: FutureBuilder<List<NoteVersion>>(
            future: _versions,
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text.verbatim('${snap.error}'));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator.adaptive(),);
              final all = snap.data!;
              return TabBarView(children: [
                _list([for (final v in all) if (!v.manual && (!_canBranch || v.branch == _viewing)) v], all, manual: false),
                _list([for (final v in all) if (v.manual && (!_canBranch || v.branch == _viewing)) v], all, manual: true),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  Widget _list(List<NoteVersion> versions, List<NoteVersion> all, {required bool manual}) {
    if (versions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            manual
                ? 'No saved versions yet. "Save this version" keeps the note as it is now, with a name, until you delete it.'
                : 'No versions yet. The app keeps one now and then while you work on the note, and before changes from others are taken in.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: versions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final v = versions[i];
        return ListTile(
          key: ValueKey('version-${v.id}'),
          dense: true,
          leading: Icon(manual ? Icons.bookmark_outline : _iconOf(v.reason), size: 20, color: madeByAssistant(v) ? Theme.of(context).colorScheme.tertiary : null),
          tileColor: madeByAssistant(v) ? Theme.of(context,).colorScheme.tertiaryContainer.withValues(alpha: 0.25) : null,
          title: Text.verbatim(versionTitle(v), maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text.verbatim(_when(context, v.at)),
          onTap: () => _show(v, all),
          trailing: PopupMenuButton<String>(
            key: ValueKey('version-menu-${v.id}'),
            tooltip: tr('More'),
            onSelected: (c) => _menu(c, v, all),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'preview', child: Text('Preview')),
              const PopupMenuItem(value: 'compare', child: Text('Compare with now')),
              const PopupMenuItem(value: 'restore', child: Text('Restore')),
              if (_canBranch) const PopupMenuItem(value: 'branch', child: Text('Branch from this version')),
              if (manual) const PopupMenuItem(value: 'rename', child: Text('Rename')) else const PopupMenuItem(value: 'keep', child: Text('Keep...')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        );
      },
    );
  }

  static IconData _iconOf(VersionReason r) => switch (r) {
        VersionReason.merge => Icons.call_merge,
        VersionReason.restore => Icons.restore,
        VersionReason.joined => Icons.group_outlined,
        VersionReason.left => Icons.logout,
        VersionReason.branch => Icons.account_tree_outlined,
        VersionReason.assistant => Icons.auto_awesome,
        VersionReason.assistantBefore => Icons.auto_awesome_outlined,
        _ => Icons.history,
      };
}

/// One version in the panel: what to compare it with, what differs, and its pages.
class _VersionView extends StatefulWidget {
  final NoteHistory history;
  final NoteVersion version;
  final NoteVersion? previous;
  final Future<NoteData> Function() current;
  final CompareWith compare;
  final ValueChanged<CompareWith> onCompare;

  const _VersionView(
      {super.key, required this.history, required this.version, this.previous, required this.current, required this.compare, required this.onCompare});

  @override
  State<_VersionView> createState() => _VersionViewState();
}

class _VersionViewState extends State<_VersionView> {
  ParsedNoteFile? _file;
  NoteData? _now;
  NoteData? _before;
  Object? _error;
  NoteBlame? _blame;
  double? _blaming; // how far the blame is (0 to 1) while it is worked out

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_VersionView old) {
    super.didUpdateWidget(old);
    if (widget.compare == CompareWith.blame && old.compare != CompareWith.blame) _loadBlame();
  }

  Future<void> _loadBlame() async {
    final file = _file;
    if (_blame != null || _blaming != null || file == null) return;
    setState(() => _blaming = 0);
    try {
      final blame = await widget.history.blame(widget.version.noteId, file.note, branch: widget.version.branch, upTo: widget.version, progress: (done, of) {
        if (mounted) setState(() => _blaming = of == 0 ? 1 : done / of);
      });
      if (mounted) setState(() => _blame = blame);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _blaming = null);
    }
  }

  Future<void> _load() async {
    try {
      final file = await widget.history.read(widget.version);
      final now = await widget.current();
      final before = widget.previous == null ? null : (await widget.history.read(widget.previous!, withPdf: false)).note;
      if (!mounted) return;
      setState(() {
        _file = file;
        _now = now;
        _before = before;
      });
      if (widget.compare == CompareWith.blame) unawaited(_loadBlame());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// The comparison chosen, as older → newer.
  VersionDiff? get _diff {
    final file = _file;
    if (file == null) return null;
    return switch (widget.compare) {
      CompareWith.nothing || CompareWith.authors || CompareWith.blame => null,
      CompareWith.now => _now == null ? null : VersionDiff.between(file.note, _now!),
      CompareWith.previous => _before == null ? null : VersionDiff.between(_before!, file.note),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text.verbatim(tr('This version cannot be read: {error}', {'error': '$_error'})));
    final file = _file;
    if (file == null) return const Center(child: CircularProgressIndicator.adaptive());
    final diff = _diff;
    return Column(children: [
      _compareBar(context, diff),
      Expanded(
        child: NotePagesView(
          file: file,
          diff: diff,
          newer: widget.compare == CompareWith.previous,
          byAuthor: widget.compare == CompareWith.authors,
          blame: widget.compare == CompareWith.blame ? _blame : null,
        ),
      ),
    ]);
  }

  /// The words for each author string in the versions shown: the name, and the start of the id where two people
  /// have one name.
  Map<String?, String> get _labels => Author.labels(
        {
          if (_file != null) ...NoteAuthors.keysOf(_file!.note),
          if (_now != null) ...NoteAuthors.keysOf(_now!),
          if (_before != null) ...NoteAuthors.keysOf(_before!),
        },
        unknown: tr('Unknown'),
        unnamed: tr('Unnamed'),
      );

  /// " (Anna 2, Ben 1)" for how many each person did; nothing when nobody has a name.
  String _by(Map<String?, int> counts) {
    if (counts.isEmpty || counts.keys.every((a) => a == null)) return '';
    final labels = Author.labels({...counts.keys, ..._labels.keys}, unknown: tr('Unknown'), unnamed: tr('Unnamed'));
    final parts = [for (final e in counts.entries) '${labels[e.key]} ${e.value}'];
    return ' (${parts.join(', ')})';
  }

  /// The colour of what comes from version [index] of [total]: from blue (old) to orange (new); grey: from before the oldest kept
  /// version; purple: not in a version yet.
  static Color blameColor(int index, int total) {
    if (index < 0) return const Color(0xFF9E9E9E);
    if (index >= total) return const Color(0xFF8E24AA);
    final t = total <= 1 ? 1.0 : index / (total - 1);
    return HSVColor.fromAHSV(1, 215 - 195 * t, 0.75, 0.85).toColor();
  }

  /// Which version each thing is from: the versions with how many things (and by whom) and a colour each, and the lines of the written text.
  Widget _blameLegend(BuildContext context) {
    final blame = _blame, file = _file;
    if (blame == null || file == null) {
      return Padding(key: const ValueKey('blame-working'), padding: const EdgeInsets.only(top: 8), child: LinearProgressIndicator(value: _blaming));
    }
    final total = blame.versions.length;
    final places = VersionDiff.placesOf(file.note);
    final byVersion = <int, Map<String?, int>>{};
    for (final e in blame.origin.entries) {
      final author = ElementChange.authorOf(places[e.key]?.item);
      final m = byVersion.putIfAbsent(e.value, () => {});
      m[author] = (m[author] ?? 0) + 1;
    }
    final order = byVersion.keys.toList()..sort((a, b) => b.compareTo(a));
    Widget chip(int i) {
      final n = byVersion[i]!.values.fold(0, (a, b) => a + b);
      final label = i < 0
          ? tr('Before the first kept version')
          : i >= total
              ? tr('Not in a version yet')
              : _when(context, blame.versions[i].at);
      final text = Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 4, decoration: BoxDecoration(color: blameColor(i, total), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Flexible(child: Text.verbatim('$label: $n${_by(byVersion[i]!)}', style: const TextStyle(fontSize: 12))),
      ]);
      return i >= 0 && i < total ? Tooltip(message: versionTitle(blame.versions[i]), child: text) : text;
    }

    final hasText = blame.lines.isNotEmpty;
    return Padding(
      key: const ValueKey('blame-legend'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (order.isEmpty && !hasText)
          Text('Nothing in this version to trace back.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))
        else
          Wrap(spacing: 14, runSpacing: 4, children: [for (final i in order) chip(i)]),
        if (hasText)
          Theme(
            data: Theme.of(context,).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('blame-text'),
              dense: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text.verbatim(tr('Written text, line by line'), style: const TextStyle(fontSize: 12)),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: blame.lines.length,
                    itemBuilder: (context, i) {
                      final from = blame.lineOrigin[i];
                      final color = blameColor(from, total);
                      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(width: 4, height: 18, margin: const EdgeInsets.only(right: 8), color: color),
                        Expanded(child: Text.verbatim(blame.lines[i].isEmpty ? ' ' : blame.lines[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                        if (from >= 0 && from < total)
                          Text.verbatim(_when(context, blame.versions[from].at), style: TextStyle(fontSize: 11, color: Theme.of(context,).colorScheme.onSurfaceVariant)),
                      ]);
                    },
                  ),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  /// " [12 drawings, 2 text boxes]" for what the things are.
  String _kinds(Map<ElementKind, int> counts) {
    if (counts.isEmpty) return '';
    String name(ElementKind k, int n) => switch (k) {
          ElementKind.stroke => trCount(n, '1 drawing', '{n} drawings'),
          ElementKind.box => trCount(n, '1 text box', '{n} text boxes'),
          ElementKind.image => trCount(n, '1 picture', '{n} pictures'),
          ElementKind.mark => trCount(n, '1 highlight', '{n} highlights'),
          ElementKind.note => '',
        };
    return ' [${[for (final e in counts.entries) name(e.key, e.value)].where((t) => t.isNotEmpty).join(', ')}]';
  }

  /// The people of the note, each with their colour and how many things they added.
  Widget _authorLegend(BuildContext context, NoteAuthors authors) {
    final names = [for (final p in authors.people) p.name];
    final labels = Author.labels({...names}, unknown: tr('Unknown'), unnamed: tr('Unnamed'));
    if (names.isEmpty && authors.unknown == 0) return const SizedBox.shrink();
    Widget chip(Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 14, height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Text.verbatim(text, style: const TextStyle(fontSize: 12)),
        ]);
    return Padding(
      key: const ValueKey('author-legend'),
      padding: const EdgeInsets.only(top: 6),
      child: names.isEmpty
          ? Text('Nobody put a name to what was added in this note, so there is nothing to tell apart.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))
          : Wrap(spacing: 14, runSpacing: 4, children: [
              for (final p in authors.people) chip(NoteAuthors.colorOf(p.name, names), '${labels[p.name]} ${p.count}'),
              if (authors.unknown > 0) chip(NoteAuthors.colorOf(null, names), '${tr('Unknown')} ${authors.unknown}'),
            ]),
    );
  }

  Widget _compareBar(BuildContext context, VersionDiff? diff) {
    final scheme = Theme.of(context).colorScheme;
    Widget legend(Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 14, height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Flexible(child: Text.verbatim(text, style: const TextStyle(fontSize: 12))),
        ]);
    final toNow = widget.compare == CompareWith.now;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Compare with', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(width: 8),
            Flexible(
              child: DropdownButton<CompareWith>(
                key: const ValueKey('preview-compare'),
                value: widget.compare,
                isExpanded: true,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: CompareWith.nothing, child: Text(tr('Nothing'))),
                  DropdownMenuItem(value: CompareWith.now, child: Text(tr('The note now'))),
                  if (widget.previous != null) DropdownMenuItem(value: CompareWith.previous, child: Text(tr('The version before'))),
                  DropdownMenuItem(value: CompareWith.authors, child: Text(tr('Who added what'))),
                  DropdownMenuItem(value: CompareWith.blame, child: Text(tr('Blame: when each thing came in'))),
                ],
                onChanged: (c) {
                  if (c != null) widget.onCompare(c);
                },
              ),
            ),
          ]),
          if (diff != null) ...[
            const SizedBox(height: 6),
            if (diff.isEmpty)
              Text(toNow ? 'The note now is the same as this version.' : 'Nothing changed from the version before.', key: const ValueKey('diff-none'), style: const TextStyle(fontSize: 12))
            else
              Wrap(spacing: 14, runSpacing: 4, children: [
                legend(Colors.green, (toNow ? tr('Added since: {n}', {'n': diff.count(ChangeKind.added)}) : tr('New in this version: {n}', {'n': diff.count(ChangeKind.added)})) + _kinds(diff.byKind(ChangeKind.added)) + _by(diff.byAuthor(ChangeKind.added))),
                legend(Colors.red, (toNow ? tr('Removed since: {n}', {'n': diff.count(ChangeKind.removed)}) : tr('Removed in this version: {n}', {'n': diff.count(ChangeKind.removed)})) + _kinds(diff.byKind(ChangeKind.removed)) + _by(diff.byAuthor(ChangeKind.removed))),
                legend(Colors.orange, tr('Changed: {n}', {'n': diff.count(ChangeKind.changed)}) + _kinds(diff.byKind(ChangeKind.changed)) + _by(diff.byAuthor(ChangeKind.changed))),
              ]),
            if (diff.linesAdded > 0 || diff.linesRemoved > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.verbatim(
                  tr('Written text: {added} lines new, {removed} lines gone', {'added': diff.linesAdded, 'removed': diff.linesRemoved}),
                  key: const ValueKey('diff-lines'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            if (diff.count(ChangeKind.changed) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('A changed drawing shows how it was in red and how it is in green.', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ),
            if (diff.fields.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.verbatim(
                  tr('Also changed: {what}', {
                    'what': [
                      if (diff.fields.contains('title')) tr('the title'),
                      if (diff.fields.contains('setup')) tr('the page setup'),
                      if (diff.fields.contains('doc')) tr('the written document'),
                    ].join(', ')
                  }),
                  key: const ValueKey('diff-fields'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          if (widget.compare == CompareWith.authors && _file != null) _authorLegend(context, NoteAuthors.of(_file!.note)),
          if (widget.compare == CompareWith.blame) _blameLegend(context),
        ]),
      ),
    );
  }
}

/// Asks before a version is restored.
Future<bool?> confirmRestore(BuildContext context, NoteVersion v,) => showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Restore this version?'),
        content: Text.verbatim(tr(
            'The note goes back to "{name}" from {when}. The note as it is now is kept as a version first, so this can be undone.',
            {'name': versionTitle(v), 'when': _when(context, v.at)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('version-restore-ok'), onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );

/// What a version is compared with in the preview.
enum CompareWith { nothing, now, previous, authors, blame }
