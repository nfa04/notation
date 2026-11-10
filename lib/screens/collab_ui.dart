import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import '../l10n/language.dart';

import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/authorship.dart' show Author;
import '../collab/cloud_share.dart';
import '../collab/collab_service.dart';
import '../collab/share_storage.dart';
import '../collab/invite.dart';
import '../collab/session.dart';
import '../nativeshare/share_model.dart' show ShareKind;
import 'link_signal.dart';
import 'presence.dart';
import 'share_people.dart';
import '../style/platform_dialog.dart';

/// The panel of a note's live session: start one, copy the invite, see who is there, answer requests, end it.
class LivePanel extends StatefulWidget {
  final CollabService service;
  final String noteId;

  /// Starts a session on this note (the editor gives its own state to it).
  final Future<void> Function() onStart;

  /// Writes the note down, so that a copy that is shared has what is on the screen.
  final Future<void> Function()? onBeforeShare;

  /// Takes the reader to the page (zero-based) somebody else has in view.
  final ValueChanged<int>? onShowPage;

  const LivePanel({super.key, required this.service, required this.noteId, required this.onStart, this.onBeforeShare, this.onShowPage});

  @override
  State<LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<LivePanel> {
  late final TextEditingController _server = TextEditingController(text: widget.service.server ?? '');
  bool _starting = false;
  String? _problem;

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _problem = null;
    });
    try {
      if (widget.service.server == null && _server.text.trim().isNotEmpty) await widget.service.setServer(_server.text);
      await widget.onStart();
    } catch (e) {
      _problem = '$e'.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final session = widget.service.sessionFor(widget.noteId);
        final live = session != null && session.state != SessionState.ended;
        return PlatformAlertDialog(
          title: Text(live ? (session.role == SessionRole.host ? 'Live session' : 'You are in a live session') : 'Work on this note together'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                live ? _active(context, session) : _inactive(context, session),
                if (widget.service.nativeShares != null) ...[
                  const Divider(height: 28),
                  SharePeoplePanel(service: widget.service.nativeShares!, kind: ShareKind.note, rootId: widget.noteId, beforeShare: widget.onBeforeShare),
                ],
                if (widget.service.cloudShare != null) ...[
                  const Divider(height: 28),
                  _CopyShare(service: widget.service, noteId: widget.noteId, beforeShare: widget.onBeforeShare),
                ],
              ]),
            ),
          ),
          actions: [
            if (live)
              TextButton(
                key: const ValueKey('live-end'),
                onPressed: () => widget.service.end(widget.noteId),
                child: Text(session.role == SessionRole.host ? 'End the session' : 'Leave'),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
    );
  }

  /// The signal of a person's link, and the button to their page. A guest has one link, to the host: it is shown on the guest's own row
  /// (and not again on the host's), a host shows the link of every guest.
  Widget? _trailing(CollabSession session, Participant p) {
    final showsLink = session.role == SessionRole.host ? p.site != session.site : p.site != session.hostSite;
    final signal = showsLink ? LinkSignal(key: ValueKey('live-signal-${p.site}'), band: session.bandOf(p.site), relayed: session.relayedVia(p.site)) : null;
    final go = p.site != session.site && session.viewing[p.site] != null && widget.onShowPage != null
        ? TextButton(key: ValueKey('live-go-${p.site}'), onPressed: () => widget.onShowPage!(session.viewing[p.site]!), child: const Text('Go to the page'))
        : null;
    if (signal == null && go == null) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: [?signal, ?go]);
  }

  Widget _inactive(BuildContext context, CollabSession? last) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (last != null) ...[
        Text(last.endReason ?? 'The session ended', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 12),
      ],
      const Text(
        'Start a live session and send the link to whoever should join. Everything that is drawn or written shows up '
        'for everyone at once. What is sent is sealed with a key that only the link contains: nobody in between '
        '(not even the server that introduces your devices to each other) can read it. The session lasts as long as you '
        'keep this note open and the app running.',
      ),
      const SizedBox(height: 12),
      if (widget.service.server == null)
        TextField(
          key: const ValueKey('live-server'),
          controller: _server,
          decoration: InputDecoration(
            labelText: tr('Signalling server'),
            hintText: tr('wss://signal.example.org'),
            helperText: tr('Only introduces your devices to each other (see tool/signaling in the source)'),
          ),
        )
      else
        Text(
          tr('Introduced through {server} (change in Settings, Live collaboration).', {'server': Uri.tryParse(widget.service.server!)?.host ?? widget.service.server}),
          key: const ValueKey('live-server-note'),
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      if (_problem != null) ...[
        const SizedBox(height: 8),
        Text(_problem!, key: const ValueKey('live-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('live-start'),
        onPressed: _starting ? null : _start,
        icon: _starting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator.adaptive(strokeWidth: 2)) : const Icon(Icons.podcasts),
        label: const Text('Start a live session'),
      ),
    ]);
  }

  Widget _active(BuildContext context, CollabSession session) {
    final invite = widget.service.inviteFor(widget.noteId);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (session.role == SessionRole.host && invite != null) ...[
          const Text('Send this link to the people who should join. It opens in Notation.'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
            child: SelectableText(invite.toLink(), key: const ValueKey('live-link'), style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows))
              FilledButton.icon(
                key: const ValueKey('live-share'),
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('Share the link'),
                onPressed: () => SharePlus.instance.share(ShareParams(
                  text: tr('Join my live note in Notation: {link}', {'link': invite.toLink()}),
                  subject: tr('Notation live session'),
                )),
              ),
            OutlinedButton.icon(
              key: const ValueKey('live-copy'),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy the link'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: invite.toLink()));
                messenger.showSnackBar(const SnackBar(content: Text('Link copied')));
              },
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Anyone who has the link can ask to join. You see who asks and a code to compare before you let them in.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
        ],
        if (session.pending.isNotEmpty) ...[
          const Text('Waiting for you', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final r in session.pending)
            ListTile(
              key: ValueKey('live-request-${r.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text.verbatim(tr('{name} wants to join', {'name': r.name})),
              subtitle: Text.verbatim(r.uid == null ? tr('Code {code}', {'code': r.code}) : tr('Code {code}, id {id}', {'code': r.code, 'id': Author.shortId(r.uid!)})),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(onPressed: () => session.deny(r.id), child: const Text('No')),
                FilledButton(onPressed: () => session.approve(r.id), child: const Text('Let in')),
              ]),
            ),
          const SizedBox(height: 8),
        ],
        if (session.role == SessionRole.host && widget.service.hostLog != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text.verbatim(tr('Last connection: {event}', {'event': tr(widget.service.hostLog ?? '')}),
                key: const ValueKey('live-hostlog'), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        const Text('In this session', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final p in session.participants)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: p.site == session.site ? const Icon(Icons.person_outline) : Icon(Icons.circle, color: presenceColor(p.site), size: 18),
            title: Text.verbatim(p.site == session.site
                ? tr('{name} (you)', {'name': Participant.labelOf(p, session.participants)})
                : Participant.labelOf(p, session.participants)),
            subtitle: session.viewing[p.site] == null ? null : Text.verbatim(tr('Page {n}', {'n': session.viewing[p.site]! + 1})),
            trailing: _trailing(session, p),
          ),
      ]),
    );
  }
}

/// Asks the host's answer to our request to join: shows the code to read out, waits, and returns the note's id (null if it did not work).
Future<String?> showJoining(BuildContext context, CollabService service, SessionInvite invite, {Uint8List? proofKey}) async {
  return showJoinAttempt(context, service.join(invite, proofKey: proofKey));
}

/// The dialog for a join that is under way; the id of the note once it is in, null if it was not.
Future<String?> showJoinAttempt(BuildContext context, JoinAttempt attempt) => showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _JoiningDialog(attempt: attempt),
    );

class _JoiningDialog extends StatefulWidget {
  final JoinAttempt attempt;

  const _JoiningDialog({required this.attempt});

  @override
  State<_JoiningDialog> createState() => _JoiningDialogState();
}

class _JoiningDialogState extends State<_JoiningDialog> {
  @override
  void initState() {
    super.initState();
    widget.attempt.addListener(_changed);
  }

  @override
  void dispose() {
    widget.attempt.removeListener(_changed);
    super.dispose();
  }

  /// Set once the dialog has closed itself: it stays mounted while it fades out, and later changes must not
  /// close what is under it.
  bool _closing = false;

  void _changed() {
    final a = widget.attempt;
    if (!mounted || _closing) return;
    if (a.noteId != null && !a.cancelled) {
      _closing = true;
      Navigator.pop(context, a.noteId);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attempt;
    final code = a.session?.verificationCode;
    final who = a.invite.from == null || a.invite.from!.isEmpty ? tr('the host') : a.invite.from!;
    return PlatformAlertDialog(
      title: const Text('Joining a live session'),
      content: SizedBox(
        width: 380,
        child: a.error != null
            ? Text(a.error!, key: const ValueKey('join-error'))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (code == null) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text.verbatim(tr('Connecting to {who}...', {'who': who})),
                  const SizedBox(height: 6),
                  Text(a.status, key: const ValueKey('join-status'), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ] else ...[
                  Text.verbatim(tr('Waiting for {who} to let you in. If they ask, read them this code:', {'who': who})),
                  const SizedBox(height: 12),
                  Center(child: Text(code, key: const ValueKey('join-code'), style: Theme.of(context,).textTheme.headlineMedium?.copyWith(letterSpacing: 4))),
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('join-cancel'),
          onPressed: () async {
            if (_closing) return;
            _closing = true;
            a.cancelled = true;
            await a.session?.end();
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(a.error != null ? 'Close' : 'Cancel'),
        ),
      ],
    );
  }
}

/// The question to the host: someone asks to join; accept or not.
Future<void> showJoinRequest(BuildContext context, JoinRequest r) async {
  final yes = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PlatformAlertDialog(
      key: ValueKey('join-request-${r.request.id}'),
      title: Text.verbatim(tr('{name} wants to join', {'name': r.request.name})),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.verbatim(tr('to work on "{title}" with you.', {'title': r.noteTitle.isEmpty ? tr('Untitled') : r.noteTitle})),
        const SizedBox(height: 12),
        const Text('If it is who you expect, the code on their screen is the same as this one:'),
        const SizedBox(height: 8),
        Center(child: Text(r.request.code, style: Theme.of(context,).textTheme.headlineMedium?.copyWith(letterSpacing: 4))),
        if (r.request.uid != null) ...[
          const SizedBox(height: 12),
          Text.verbatim(tr('Their id: {id}', {'id': Author.shortId(r.request.uid!)}), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ]),
      actions: [
        TextButton(key: const ValueKey('join-request-no'), onPressed: () => Navigator.pop(context, false), child: const Text('No')),
        FilledButton(key: const ValueKey('join-request-yes'), onPressed: () => Navigator.pop(context, true), child: const Text('Let them in')),
      ],
    ),
  );
  if (yes == true) {
    await r.session.approve(r.request.id);
  } else {
    await r.session.deny(r.request.id);
  }
}

/// "Share a copy that works offline": a sealed copy of the note on the person's Nextcloud, and a link to it.
class _CopyShare extends StatefulWidget {
  final CollabService service;
  final String noteId;
  final Future<void> Function()? beforeShare;

  const _CopyShare({required this.service, required this.noteId, this.beforeShare});

  @override
  State<_CopyShare> createState() => _CopyShareState();
}

class _CopyShareState extends State<_CopyShare> {
  bool _working = false;
  String? _link;
  String? _problem;
  ShareStorage? _chosen;
  bool _hasMarker = false;

  Future<void> _make() async {
    setState(() {
      _working = true;
      _problem = null;
      _link = null;
    });
    try {
      await widget.beforeShare?.call();
      final invite = await widget.service.cloudShare!.shareCopy(
        widget.noteId,
        from: widget.service.name == tr('Someone') ? null : widget.service.name,
        storage: _chosen,
      );
      _link = invite.toLink();
      _hasMarker = invite.marker != null;
    } catch (e) {
      _problem = '$e'.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final share = widget.service.cloudShare!;
    final usable = share.available;
    final storage = usable.contains(_chosen) ? _chosen! : (usable.isEmpty ? null : usable.first);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Share a copy that works offline', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text.verbatim(
        tr('Puts a sealed copy of this note on {service} and makes a link to it. Whoever opens the link gets their own copy, '
            'even while you are offline. Only the link can open the copy; {service} sees a file it cannot read. '
            'The link works for {days} days.', {'service': storage?.label ?? share.storages.firstOrNull?.label ?? '', 'days': (storage ?? share.storages.firstOrNull)?.keeps.inDays ?? 30}),
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      if (usable.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 8, children: [
            for (final s in usable)
              ChoiceChip(
                key: ValueKey('copy-service-${s.label}'),
                label: Text.verbatim(s.label),
                selected: identical(s, storage),
                onSelected: (_) => setState(() => _chosen = s),
              ),
          ]),
        ),
      if (storage == null)
        Text.verbatim(share.storages.firstOrNull?.unavailableReason ?? tr('There is no service to share through.'),
            key: const ValueKey('copy-unavailable'), style: TextStyle(color: scheme.onSurfaceVariant))
      else if (_link == null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('copy-make'),
            onPressed: _working ? null : _make,
            icon: _working
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                : const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Make a link to a copy'),
          ),
        )
      else ...[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
          child: SelectableText(_link!, key: const ValueKey('copy-link'), style: const TextStyle(fontSize: 12)),
        ),
        if (_hasMarker) ...[
          const SizedBox(height: 6),
          Text('While you work on this note in a live session, whoever opens this link is offered to join it.',
              key: const ValueKey('copy-marker-note'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows))
            FilledButton.icon(
              key: const ValueKey('copy-share'),
              icon: const Icon(Icons.ios_share, size: 16),
              label: const Text('Share the link'),
              onPressed: () => SharePlus.instance.share(ShareParams(text: tr('Here is a copy of my note for Notation: {link}', {'link': _link}), subject: tr('A note from Notation'))),
            ),
          OutlinedButton.icon(
            key: const ValueKey('copy-copy'),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy the link'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: _link!));
              messenger.showSnackBar(SnackBar(content: Text('Link copied')));
            },
          ),
          TextButton(onPressed: () => setState(() => _link = null), child: const Text('Make another')),
        ]),
      ],
      if (_problem != null) ...[
        const SizedBox(height: 8),
        Text.verbatim(_problem!, key: const ValueKey('copy-problem'), style: TextStyle(color: scheme.error)),
      ],
    ]);
  }
}

/// Asks for a link by hand (for when clicking a link does not open the app); a [SessionInvite] or a [CopyInvite], null if cancelled.
Future<Object?> askForInvite(BuildContext context) => showDialog<Object>(context: context, builder: (context) => const _InviteDialog());

class _InviteDialog extends StatefulWidget {
  const _InviteDialog();

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

/// (owns the text controller: it has to live until the dialog has finished closing)
class _InviteDialogState extends State<_InviteDialog> {
  final _controller = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Open a link'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('invite-text'),
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Paste the link'), errorText: _problem),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('invite-join'),
            onPressed: () {
              final invite = SessionInvite.parse(_controller.text) ?? CopyInvite.parse(_controller.text);
              if (invite == null) {
                setState(() => _problem = 'That is not a link from Notation');
              } else {
                Navigator.pop(context, invite);
              }
            },
            child: const Text('Join'),
          ),
        ],
      );
}
