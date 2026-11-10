import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../nativeshare/native_share_provider.dart';
import '../nativeshare/native_share_service.dart';
import '../nativeshare/share_model.dart';
import 'folder_picker.dart';
import '../style/platform_dialog.dart';

String _words(Object e) => '$e'.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');

/// "Share with a person": invite someone who has an account at the same cloud service to a note or a folder, with the right to view or to
/// edit, and see and change who has it. What is shared is kept in step like the sync of one's own devices (see `docs/native-sharing.md`).
class SharePeoplePanel extends StatefulWidget {
  final NativeShareService service;
  final ShareKind kind;

  /// The note or the folder.
  final String rootId;

  /// Done before the first share, so that the note as it is on screen is what goes up (the editor saves it).
  final Future<void> Function()? beforeShare;

  const SharePeoplePanel({super.key, required this.service, required this.kind, required this.rootId, this.beforeShare});

  @override
  State<SharePeoplePanel> createState() => _SharePeoplePanelState();
}

class _SharePeoplePanelState extends State<SharePeoplePanel> {
  final _query = TextEditingController();
  NativeShareProvider? _chosen;
  List<SharePerson> _found = const [];
  SharePerson? _person;
  ShareRole _role = ShareRole.editor;
  bool _working = false;
  String? _problem;
  Timer? _debounce;
  int _searchId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  NativeShareProvider? get _provider {
    final usable = widget.service.usable;
    return usable.contains(_chosen) ? _chosen : usable.firstOrNull;
  }

  void _typed(String text) {
    _person = null;
    _debounce?.cancel();
    final p = _provider;
    if (p == null || text.trim().isEmpty) {
      setState(() => _found = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final id = ++_searchId;
      try {
        final people = await p.searchPeople(text);
        if (mounted && id == _searchId) setState(() => _found = people);
      } catch (e) {
        if (mounted && id == _searchId) setState(() => _problem = _words(e));
      }
    });
  }

  Future<void> _share() async {
    final p = _provider;
    final typed = _query.text.trim();
    final person = _person ?? (typed.isEmpty ? null : SharePerson(typed, typed));
    if (p == null || person == null) return;
    setState(() {
      _working = true;
      _problem = null;
    });
    try {
      await widget.beforeShare?.call();
      if (widget.kind == ShareKind.note) {
        await widget.service.shareNote(widget.rootId, p, person, _role);
      } else {
        await widget.service.shareFolder(widget.rootId, p, person, _role);
      }
      unawaited(widget.service.syncNow());
      if (!mounted) return; // (the panel was closed while the invitation went out)
      _query.clear();
      _person = null;
      _found = const [];
    } catch (e) {
      _problem = _words(e);
    }
    if (mounted) setState(() => _working = false);
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _problem = null);
    try {
      await job();
    } catch (e) {
      if (mounted) setState(() => _problem = _words(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final service = widget.service;
        final usable = service.usable;
        final p = _provider;
        final given = service.givenFor(widget.kind, widget.rootId);
        final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.kind == ShareKind.note ? 'Share this note with a person' : 'Share this folder with a person', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Invites someone who has an account at the same cloud service. They see it in their own account and in the app, and can only do what '
            'you allow. Changes go both ways. The files are not sealed: the cloud service can read what you share.',
            style: muted,
          ),
          const SizedBox(height: 8),
          if (usable.isEmpty)
            for (final u in service.unsupported)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text.verbatim('${u.provider.label}: ${u.reason}', key: ValueKey('share-unsupported-${u.provider.id}'), style: TextStyle(color: scheme.error, fontSize: 13))),
          if (usable.isEmpty && service.unsupported.isEmpty)
            Text(tr('Connect a cloud service that can share (Nextcloud) in the settings first.'), key: const ValueKey('share-no-service'), style: TextStyle(color: scheme.onSurfaceVariant))
          else if (p != null) ...[
            if (usable.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(spacing: 8, children: [
                  for (final u in usable) ChoiceChip(label: Text.verbatim(u.label), selected: identical(u, p), onSelected: (_) => setState(() => _chosen = u)),
                ]),
              ),
            TextField(
              key: const ValueKey('share-person'),
              controller: _query,
              decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: tr('Name or address of the person'), prefixIcon: const Icon(Icons.person_search_outlined)),
              onChanged: _typed,
              onSubmitted: (_) => _share(),
            ),
            if (_found.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final f in _found)
                    ChoiceChip(
                      key: ValueKey('share-found-${f.id}'),
                      label: Text.verbatim(f.detail.isEmpty || f.detail == f.label ? f.label : '${f.label} (${f.detail})'),
                      selected: _person == f,
                      onSelected: (_) => setState(() {
                        _person = f;
                        _query.text = f.label;
                      }),
                    ),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              SegmentedButton<ShareRole>(
                key: const ValueKey('share-role'),
                showSelectedIcon: false,
                segments: [for (final r in ShareRole.values) ButtonSegment(value: r, label: Text(r.label))],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
              const Spacer(),
              FilledButton(key: const ValueKey('share-go'), onPressed: _working ? null : _share, child: Text(_working ? 'Sharing...' : 'Share')),
            ]),
          ],
          if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('share-problem'), style: TextStyle(color: scheme.error))),
          if (given != null) ...[
            const SizedBox(height: 12),
            Text(tr('Shared with'), style: Theme.of(context).textTheme.labelLarge),
            for (final r in given.recipients)
              Row(key: ValueKey('share-recipient-${r.person.id}'), children: [
                Expanded(child: Text.verbatim(r.person.label, overflow: TextOverflow.ellipsis)),
                DropdownButton<ShareRole>(
                  value: r.role,
                  isDense: true,
                  items: [for (final x in ShareRole.values) DropdownMenuItem(value: x, child: Text(x.label))],
                  onChanged: (x) {
                    if (x != null && x != r.role) _run(() => service.changeRole(given, r, x));
                  },
                ),
                if (r.link != null)
                  IconButton(
                    key: ValueKey('share-link-${r.person.id}'),
                    tooltip: tr('Copy the link to send to {name}', {'name': r.person.label}),
                    icon: const Icon(Icons.link, size: 20),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: r.link!));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Link copied. Send it to {name}: they add it under Settings, Sharing and files.', {'name': r.person.label}))));
                      }
                    },
                  ),
                IconButton(
                  key: ValueKey('share-remove-${r.person.id}'),
                  tooltip: tr('Remove {name}', {'name': r.person.label}),
                  icon: const Icon(Icons.person_remove_outlined, size: 20),
                  onPressed: () => _run(() => service.removePerson(given, r)),
                ),
              ]),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: Text.verbatim(service.statusOf(given.id).problem ?? service.statusOf(given.id).what ?? '', style: muted)),
              TextButton(key: const ValueKey('share-stop'), onPressed: () => _run(() => service.stopSharing(given)), child: const Text('Stop sharing')),
            ]),
          ],
        ]);
      },
    );
  }
}

/// A dialog with the panel for a folder (for a note it is part of the dialog of the note).
Future<void> showShareFolder(BuildContext context, NativeShareService service, {required String folderId, required String name}) => showDialog<void>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text.verbatim(name),
        content: SizedBox(width: 460, child: SingleChildScrollView(child: SharePeoplePanel(service: service, kind: ShareKind.folder, rootId: folderId))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );

/// Settings: the shares given to the person that wait for them, and every share given or received, with how it is going.
class NativeShareSettings extends StatefulWidget {
  final NativeShareService service;

  const NativeShareSettings({super.key, required this.service});

  @override
  State<NativeShareSettings> createState() => _NativeShareSettingsState();
}

class _NativeShareSettingsState extends State<NativeShareSettings> {
  bool _looking = false;
  String? _problem;
  final _link = TextEditingController();

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _addLink() async {
    final text = _link.text.trim();
    if (text.isEmpty) return;
    setState(() => _problem = null);
    try {
      await widget.service.addLink(text);
      _link.clear();
    } catch (e) {
      if (mounted) setState(() => _problem = _words(e));
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_look());
  }

  Future<void> _look() async {
    setState(() => _looking = true);
    await widget.service.refreshIncoming();
    if (mounted) setState(() => _looking = false);
  }

  Future<void> _accept(PendingShare p) async {
    final folders = await widget.service.folders();
    if (!mounted) return;
    final where = await pickFolder(context, folders: folders, title: tr('Where should "{name}" go?', {'name': ShareNaming.shown(p.share.name)}));
    if (where == null) return;
    setState(() => _problem = null);
    try {
      await widget.service.accept(p, targetFolderId: where.$1);
    } catch (e) {
      if (mounted) setState(() => _problem = _words(e));
    }
  }

  Future<void> _do(Future<void> Function() job) async {
    setState(() => _problem = null);
    try {
      await job();
    } catch (e) {
      if (mounted) setState(() => _problem = _words(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final service = widget.service;
        final muted = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Shared with people', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Notes and folders you share with people at the same cloud service (Nextcloud), and the ones they share with you. Share from a note '
            '(the live button) or from the menu of a folder. What is shared is kept in step in the background. The cloud service can read these '
            'files: they are not sealed.',
            style: muted,
          ),
          for (final u in service.unsupported)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text.verbatim('${u.provider.label}: ${u.reason}', style: TextStyle(color: scheme.error, fontSize: 13))),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              key: const ValueKey('shares-look'),
              onPressed: _looking ? null : _look,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(_looking ? 'Looking...' : 'Look for shares'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('shares-sync'),
              onPressed: service.running || service.shares.isEmpty ? null : () => service.syncNow(),
              icon: const Icon(Icons.sync, size: 18),
              label: const Text('Sync now'),
            ),
          ]),
          if (service.providers.any((p) => p.acceptsLinks && p.available))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('shares-link'),
                    controller: _link,
                    decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: tr('A link to a share (OneDrive)'), prefixIcon: const Icon(Icons.link)),
                    onSubmitted: (_) => _addLink(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(key: const ValueKey('shares-link-add'), onPressed: _addLink, child: const Text('Add')),
              ]),
            ),
          if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('shares-problem'), style: TextStyle(color: scheme.error))),
          if (service.incomingProblem != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(tr('Could not look for shares given to you. {why}', {'why': service.incomingProblem}), key: const ValueKey('shares-incoming-problem'), style: TextStyle(color: scheme.error))),
          if (service.pending.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr('Waiting for you'), style: Theme.of(context).textTheme.labelLarge),
            for (final p in service.pending)
              ListTile(
                key: ValueKey('pending-${p.share.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.inbox_outlined),
                title: Text.verbatim(ShareNaming.shown(p.share.name)),
                subtitle: Text.verbatim('${p.provider.label} · ${tr('from {who}', {'who': p.share.owner})}${p.share.roleKnown ? ' · ${p.share.role.label}' : ''}'),
                trailing: FilledButton(key: ValueKey('pending-accept-${p.share.id}'), onPressed: () => _accept(p), child: const Text('Accept')),
              ),
          ],
          if (service.shares.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final s in service.shares) _tile(context, s),
          ] else if (service.pending.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(tr('Nothing is shared yet.'), style: muted)),
        ]);
      },
    );
  }

  Widget _tile(BuildContext context, NativeShare s) {
    final scheme = Theme.of(context).colorScheme;
    final service = widget.service;
    final status = service.statusOf(s.id);
    final who = s.outgoing
        ? (s.recipients.isEmpty ? tr('nobody yet') : s.recipients.map((r) => '${r.person.label} (${r.role.label.toLowerCase()})').join(', '))
        : tr('from {who} · {role}', {'who': s.owner, 'role': s.role.label.toLowerCase()});
    final detail = s.state == ShareState.ended ? tr('Ended') : (status.problem ?? status.what ?? (s.lastSync == null ? '' : tr('Synced {when}', {'when': _ago(s.lastSync!)})));
    return ListTile(
      key: ValueKey('share-${s.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(s.kind == ShareKind.folder ? Icons.folder_shared_outlined : Icons.note_outlined, color: s.state == ShareState.ended ? scheme.outline : null),
      title: Text.verbatim(s.name),
      subtitle: Text.verbatim('$who${detail.isEmpty ? '' : '\n$detail'}', style: status.problem == null && s.state == ShareState.active ? null : TextStyle(color: scheme.error)),
      isThreeLine: detail.isNotEmpty,
      trailing: PopupMenuButton<VoidCallback>(
        key: ValueKey('share-menu-${s.id}'),
        onSelected: (a) => a(),
        itemBuilder: (_) => [
          if (s.state == ShareState.active) PopupMenuItem(value: () => _do(() => service.syncShare(s.id)), child: const Text('Sync now')),
          if (s.state == ShareState.ended)
            PopupMenuItem(value: () => _do(() => service.remove(s)), child: const Text('Remove from the list'))
          else
            PopupMenuItem(value: () => _do(() => service.leave(s)), child: Text(s.outgoing ? 'Stop sharing' : 'Leave')),
        ],
      ),
    );
  }

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return tr('just now');
    if (d.inHours < 1) return tr('{n} min ago', {'n': d.inMinutes});
    if (d.inDays < 1) return tr('{n} h ago', {'n': d.inHours});
    return tr('{n} days ago', {'n': d.inDays});
  }
}

/// The shares that people gave to this person and that wait to be taken in: a card that is hard to miss, with Accept on each (and why the
/// look for them failed, if it did). Shows nothing when nothing waits.
class ShareInvitations extends StatefulWidget {
  final NativeShareService service;

  const ShareInvitations({super.key, required this.service});

  @override
  State<ShareInvitations> createState() => _ShareInvitationsState();
}

class _ShareInvitationsState extends State<ShareInvitations> {
  String? _problem;
  String? _busy;

  Future<void> _accept(PendingShare p) async {
    final folders = await widget.service.folders();
    if (!mounted) return;
    final where = await pickFolder(context, folders: folders, title: tr('Where should "{name}" go?', {'name': ShareNaming.shown(p.share.name)}));
    if (where == null) return;
    setState(() {
      _problem = null;
      _busy = p.share.id;
    });
    try {
      await widget.service.accept(p, targetFolderId: where.$1);
    } catch (e) {
      if (mounted) setState(() => _problem = _words(e));
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          final waiting = widget.service.pending;
          if (waiting.isEmpty && _problem == null) return const SizedBox.shrink();
          return Card(
            key: const ValueKey('share-invitations'),
            color: scheme.primaryContainer,
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.mail_outline, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Text(waiting.length == 1 ? tr('Someone shared something with you') : tr('{n} things were shared with you', {'n': waiting.length}),
                      style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer)),
                ]),
                for (final p in waiting)
                  ListTile(
                    key: ValueKey('invitation-${p.share.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text.verbatim(ShareNaming.shown(p.share.name), style: TextStyle(color: scheme.onPrimaryContainer)),
                    subtitle: Text.verbatim('${p.provider.label} · ${tr('from {who}', {'who': p.share.owner})}', style: TextStyle(color: scheme.onPrimaryContainer)),
                    trailing: FilledButton(
                      key: ValueKey('invitation-accept-${p.share.id}'),
                      onPressed: _busy == null ? () => _accept(p) : null,
                      child: const Text('Accept'),
                    ),
                  ),
                if (_problem != null) Text.verbatim(_problem!, style: TextStyle(color: scheme.error)),
              ]),
            ),
          );
        },
      );
}
