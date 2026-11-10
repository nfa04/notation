import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import '../cloudsync/cloud_sync_service.dart';
import '../devicesync/device_sync_service.dart';
import '../devicesync/sync_link.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'cloud_sign_in_ui.dart';
import 'qr_code_view.dart';
import 'scan_link_screen.dart';
import '../style/platform_dialog.dart';

String agoText(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return tr('just now');
  if (d.inMinutes < 60) return tr('{n} mins ago', {'n': d.inMinutes});
  if (d.inHours < 24) return tr('{n} hours ago', {'n': d.inHours});
  return tr('{n} days ago', {'n': d.inDays});
}

/// Settings: the profile on several devices - which devices are in it, adding one, syncing now, and the opt-in automatic sync.
class SyncSettings extends StatefulWidget {
  final DeviceSyncService service;

  const SyncSettings({super.key, required this.service});

  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}

/// Browser with a temporary session: asks, then signs out (the button in the menu and the one in the sync settings both come here).
Future<void> confirmSignOut(
  BuildContext context,
  DeviceSyncService service,
) async {
  final unsynced = service.unsynced;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: const Text('Sign out of this browser?'),
      content: Text(
        unsynced
            ? 'There are changes here that no other device has yet. They are lost when you sign out. Press "Sync now" first and wait until it is done to keep them. '
                  'This browser forgets the notes and the profile either way.'
            : service.temporary || service.peers.isNotEmpty
            ? 'This browser forgets the notes and the profile. Your other devices keep everything.'
            : 'This browser forgets the notes and the profile. No other device is connected, so notes that are only here are lost.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('sync-sign-out-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  if (yes == true) await service.signOutTemporary();
}

class _SyncSettingsState extends State<SyncSettings> {
  late final _deviceName = TextEditingController(text: widget.service.deviceName);
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // while this is in front, who is online is asked again every half minute
    widget.service.refreshStatus();
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => widget.service.refreshStatus());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Leave this profile?'),
        content: const Text('This device stops syncing and forgets the other devices. The notes on it stay. The other devices keep the profile.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('sync-leave-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (yes == true) await widget.service.leave();
  }

  Future<void> _signOut() => confirmSignOut(context, widget.service
    );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final s = widget.service;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sync profile', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Use Notation on several devices as one person: the same id and name, the same notes and folders, the same settings. '
            'The devices connect directly to each other; the signalling server only introduces them.',
            style: muted,
          ),
          const SizedBox(height: 12),
          if (!s.isSetUp)
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(key: const ValueKey('sync-add'), onPressed: () => showAddDeviceDialog(context, s), icon: const Icon(Icons.add_link, size: 18), label: const Text('Add a device')),
              OutlinedButton.icon(key: const ValueKey('sync-join'), onPressed: () => showJoinDialog(context, s), icon: const Icon(Icons.link, size: 18), label: const Text('Use a link from another device'),
                  ),
                  if (s.cloud != null)
                    OutlinedButton.icon(
                      key: const ValueKey('sync-signin'),
                      onPressed: () => showCloudSignInDialog(context, s.cloud!),
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: const Text('Sign in with your cloud folder')),
              if (kIsWeb)
                OutlinedButton.icon(key: const ValueKey('sync-connect'), onPressed: () => showConnectDialog(context, s), icon: const Icon(Icons.qr_code_2, size: 18), label: const Text('Connect temporarily')),
              if (canScanQr)
                OutlinedButton.icon(key: const ValueKey('sync-scan-web'), onPressed: () => scanAndAnswerConnect(context, s), icon: const Icon(Icons.qr_code_scanner, size: 18), label: const Text('Scan the code of the web version')),
            ]),
            if (kIsWeb) ...[
              const SizedBox(height: 8),
              Text(
                'On a computer that is not yours: "Connect temporarily" shows a code that you scan with your phone. Your notes are listed here, and each one comes when you open it. This browser forgets them '
                'again when the tab is closed.',
                style: muted,
              ),
            ],
          if (!s.isSetUp && s.cloud != null) ...[
            const Divider(height: 28),
            _CloudSyncCard(service: s.cloud!),
          ],
          if (s.isSetUp) ...[
            TextField(
              key: const ValueKey('sync-device-name'),
              controller: _deviceName,
              decoration: InputDecoration(labelText: tr('Name of this device'), border: const OutlineInputBorder(), isDense: true),
              onSubmitted: s.setDeviceName,
              onTapOutside: (_) => s.setDeviceName(_deviceName.text),
            ),
            const SizedBox(height: 12),
            if (s.temporary) ...[
              Container(
                key: const ValueKey('sync-temporary'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  s.unsynced
                      ? 'This browser is connected temporarily. There are changes that no other device has yet: they are lost if you close the tab before the next sync.'
                      : 'This browser is connected temporarily. Everything here is on your other devices; it is forgotten when you sign out or close the tab.',
                  style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 13),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SyncPeers(service: s),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                key: const ValueKey('sync-now'),
                onPressed: s.lookingForDevices ? null : s.syncNow,
                icon: const Icon(Icons.sync, size: 18),
                label: Text(s.lookingForDevices ? 'Looking for your other devices...' : 'Sync now'),
              ),
              OutlinedButton.icon(key: const ValueKey('sync-add'), onPressed: () => showAddDeviceDialog(context, s), icon: const Icon(Icons.add_link, size: 18), label: const Text('Add a device')),
              if (canScanQr)
                OutlinedButton.icon(key: const ValueKey('sync-scan-web'), onPressed: () => scanAndAnswerConnect(context, s), icon: const Icon(Icons.qr_code_scanner, size: 18), label: const Text('Scan the code of the web version')),
            ]),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              key: const ValueKey('sync-auto'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep my devices in sync automatically'),
              subtitle: Text(
                'Syncs by itself whenever two of your devices are online at the same time. This needs the signalling server: '
                'the device stays connected to it, which tells it that a device of yours is online (it cannot tell which, or what is in your notes). Off: '
                'only when you press "Sync now".',
                style: muted,
              ),
              value: s.auto,
              onChanged: s.setAuto,
            ),
            // (staying connected already finds the others, so looking from time to time is offered only without it)
            if (!s.auto)
              SwitchListTile.adaptive(
                key: const ValueKey('sync-check'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Look for my other devices from time to time'),
                subtitle: Text(
                  'When the app starts, when it comes to the front and every ten minutes, this device joins the meeting room for a minute and syncs if another device of yours is there. '
                  'The server only learns of these short visits. Two devices that both only look from time to time meet only when their visits overlap; one that stays connected is always found.',
                  style: muted,
                ),
                value: s.check,
                onChanged: s.setCheck,
              ),
            SwitchListTile.adaptive(
              key: const ValueKey('sync-live'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Work on a note on two devices at the same time'),
              subtitle: Text(
                'While a note is open, this device is connected to the signalling server and tells your other devices which notes are open; a note that is '
                'open on two of them is edited together live. What it tells them is encrypted: the server cannot see which note it is, nor that the same '
                'note is opened again. Off: the server hears nothing from this device while a note is open, and a note changed on two devices is brought '
                'together at the next sync.',
                style: muted,
              ),
              value: s.liveTogether,
              onChanged: s.setLiveTogether,
            ),
            if (s.cloudCarries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Your notes are also kept in sync through the cloud folder below, also when your devices are not online at the same time.',
                  key: const ValueKey('sync-by-cloud'),
                  style: muted,
                ),
              ),
            if (s.problem != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text.verbatim(s.problem!, key: const ValueKey('sync-problem'), style: TextStyle(color: scheme.error, fontSize: 13))),
            if (s.cloud != null) ...[
              const Divider(height: 28),
              _CloudSyncCard(service: s.cloud!),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: s.temporary || kIsWeb
                  ? FilledButton.tonal(key: const ValueKey('sync-sign-out'), onPressed: _signOut, child: const Text('Sign out and forget everything here'))
                  : TextButton(key: const ValueKey('sync-leave'), onPressed: _leave, child: const Text('Leave this profile')),
            ),
          ],
        ]);
      },
    );
  }
}

/// Makes the link that adds a device and waits for it: shows the link, and when a device asks, the code to compare.
Future<void> showAddDeviceDialog(BuildContext context, DeviceSyncService service) async {
  SyncLink? link;
  String? problem;
  try {
    link = await service.offerLink();
  } catch (e) {
    problem = '$e'.replaceFirst('Bad state: ', '');
  }
  if (!context.mounted) return;
  // when a device has asked and been answered, the dialog shows "Done" for a moment and closes itself
  final navigator = Navigator.of(context);
  var open = true, sawRequest = false, closing = false;
  void watch() {
    if (service.requests.isNotEmpty) sawRequest = true;
    if (link != null && sawRequest && !closing && service.offeredLink == null && service.requests.isEmpty) {
      closing = true;
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (open && navigator.mounted) navigator.pop();
      });
    }
  }

  service.addListener(watch);
  await showDialog<void>(
    context: context,
    builder: (context) => _AddDeviceDialog(service: service, link: link, problem: problem),
  );
  open = false;
  service.removeListener(watch);
  service.stopOffering();
}

/// The other devices of the profile with their state, and the progress of a sync that runs: in the settings and in the phone's menu.
class SyncPeers extends StatelessWidget {
  final DeviceSyncService service;

  const SyncPeers({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final s = service;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (s.peers.isEmpty)
              Text('No other device yet. Add one with a link.', key: const ValueKey('sync-no-peers'), style: muted)
            else
              for (final p in s.peers)
                ListTile(
                  key: ValueKey('sync-peer-${p.id}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.circle, size: 14, color: p.syncing ? scheme.primary : (p.online ? Colors.green : scheme.outline)),
                  title: Text.verbatim(p.name),
                  subtitle: Text.verbatim([
                    if (p.temporary) tr('temporary'),
                    if (s.cloud?.signIn.signedIn.containsKey(p.id) ?? false)
                      tr('signed in with the recovery key'),
                    if (p.syncing) tr('Syncing...') else if (p.online) tr('Online') else if (s.connected) tr('Not online') else tr('Online status not known'),
                    if (p.lastSync != null) tr('synced {when}', {'when': agoText(p.lastSync!)}),
                    if (p.problem != null) p.problem!,
                  ].join(' - ')),
                  trailing: IconButton(
                    key: ValueKey('sync-remove-${p.id}'),
                    tooltip: tr('Take this device out of the profile'),
                    icon: const Icon(Icons.link_off, size: 20),
                    onPressed: () => s.removeDevice(p.id),
                  ),
                ),
            if (!s.connected && s.peers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'This device is not in the meeting room, so it cannot see which of your other devices are online. Turn on the automatic sync below, or press "Sync now" on both devices.',
                  key: const ValueKey('sync-status-unknown'),
                  style: muted,
                ),
              ),
            if (s.progress != null) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(value: s.fraction),
              Text.verbatim(s.progress!, style: muted),
            ],
      ]),
    );
  }
}

class _AddDeviceDialog extends StatelessWidget {
  final DeviceSyncService service;
  final SyncLink? link;
  final String? problem;

  const _AddDeviceDialog({required this.service, this.link, this.problem});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final done = link != null && service.offeredLink == null && service.requests.isEmpty;
        return PlatformAlertDialog(
          title: const Text('Add a device'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (problem != null)
                  Text.verbatim(problem!, key: const ValueKey('sync-add-problem'), style: TextStyle(color: scheme.error))
                else if (done)
                  const Text('Done: the device is part of your profile now.', key: ValueKey('sync-add-done'))
                else ...[
                  const Text('On the other device open Notation, go to Settings → Sync profile → "Use a link from another device" (or the first screen of the app) and enter this link:'),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
                    child: SelectableText(link!.toLink(), key: const ValueKey('sync-link'), style: const TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(height: 12),
                  Center(child: QrCodeView(key: const ValueKey('sync-qr'), data: link!.toLink())),
                  const SizedBox(height: 4),
                  Center(child: Text('Or scan this code with the camera of the other device.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows))
                      FilledButton.icon(
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Share the link'),
                        onPressed: () => SharePlus.instance.share(ShareParams(text: link!.toLink(), subject: tr('Notation: add a device'))),
                      ),
                    OutlinedButton.icon(
                      key: const ValueKey('sync-copy'),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy the link'),
                      onPressed: () => Clipboard.setData(ClipboardData(text: link!.toLink())),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'The link holds the secret of your profile: send it only to yourself. It works for ten minutes, and a device in it still has to be let in here.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
                for (final r in service.requests) ...[
                  const Divider(height: 24),
                  Text.verbatim(tr('{name} wants to join your profile', {'name': r.deviceName}), key: ValueKey('sync-request-${r.id}'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Is this the code on that device?'),
                  const SizedBox(height: 6),
                  Text.verbatim(r.code, key: const ValueKey('sync-request-code'), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2, fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  Row(children: [
                    TextButton(key: const ValueKey('sync-deny'), onPressed: () => service.answer(r.id, false), child: const Text('No, that is not my device')),
                    const Spacer(),
                    FilledButton(key: const ValueKey('sync-allow'), onPressed: () => service.answer(r.id, true), child: const Text('Yes, let it in')),
                  ]),
                ],
              ]),
            ),
          ),
          actions: [TextButton(key: const ValueKey('sync-add-close'), onPressed: () => Navigator.pop(context), child: Text(done ? 'Close' : 'Cancel'))],
        );
      },
    );
  }
}

/// Asks for a link from another device (or takes [initial]) and joins its profile: shows the code to compare, and the result.
Future<bool> showJoinDialog(BuildContext context, DeviceSyncService service, {SyncLink? initial}) async {
  final joined = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _JoinDialog(service: service, initial: initial),
  );
  return joined ?? false;
}

class _JoinDialog extends StatefulWidget {
  final DeviceSyncService service;
  final SyncLink? initial;

  const _JoinDialog({required this.service, this.initial});

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  late final _link = TextEditingController(text: widget.initial?.toLink() ?? '');
  String? _error;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final link = await scanSyncLink(context);
    if (link == null || !mounted) return;
    _link.text = link.toLink();
    await _start();
  }

  Future<void> _start() async {
    final link = SyncLink.parse(_link.text);
    if (link == null) {
      setState(() => _error = tr('That is not a link to add a device.'));
      return;
    }
    setState(() {
      _error = null;
      _started = true;
    });
    await widget.service.joinWith(link);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.service;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final waiting = _started && s.joining;
        final failed = _started && !s.joining && !s.joined;
        return PlatformAlertDialog(
          title: const Text('Use a link from another device'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (s.joined)
                const Text('Done: this device is part of the profile now. Its notes, folders and settings are being brought together.', key: ValueKey('sync-join-done'))
              else if (waiting) ...[
                Row(children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(s.joinCode == null ? 'Looking for the device that made the link...' : 'Waiting for the other device to say yes')),
                ]),
                if (s.joinCode == null && s.problem != null)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(s.problem!, key: const ValueKey('sync-join-trouble'), style: TextStyle(fontSize: 12, color: scheme.error))),
                if (s.joinCode != null) ...[
                  const SizedBox(height: 14),
                  const Text('This code must be the same on the other device:'),
                  const SizedBox(height: 6),
                  Text.verbatim(s.joinCode!, key: const ValueKey('sync-join-code'), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 2, fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  Text('If it differs, say so: someone else may be in the way. Nothing of the other device is taken over until you say it is the same.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  if (s.joinCodeNeedsAnswer) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      OutlinedButton(key: const ValueKey('sync-join-different'), onPressed: () => s.confirmJoinCode(false), child: const Text('It is different')),
                      const Spacer(),
                      FilledButton(key: const ValueKey('sync-join-same'), onPressed: () => s.confirmJoinCode(true), child: const Text('It is the same')),
                    ]),
                  ],
                ],
              ] else ...[
                const Text('On a device that is already in the profile, go to Settings → Sync profile → "Add a device". Scan the code it shows or paste the link:'),
                const SizedBox(height: 10),
                if (canScanQr) ...[
                  FilledButton.icon(key: const ValueKey('sync-join-scan'), onPressed: _scan, icon: const Icon(Icons.qr_code_scanner, size: 18), label: const Text('Scan the code')),
                  const SizedBox(height: 10),
                ],
                TextField(
                  key: const ValueKey('sync-join-link'),
                  controller: _link,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(hintText: 'notation://sync?...', border: const OutlineInputBorder(), errorText: _error),
                ),
                const SizedBox(height: 8),
                Text(
                  'This device takes over the id and name of that profile. Its own notes stay and are brought together with the others.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                if (failed && s.joinProblem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(s.joinProblem!, key: const ValueKey('sync-join-problem'), style: TextStyle(color: scheme.error))),
              ],
            ]),
          ),
          actions: [
            TextButton(
              key: const ValueKey('sync-join-cancel'),
              onPressed: () {
                if (waiting) s.cancelJoin();
                Navigator.pop(context, s.joined);
              },
              child: Text(s.joined ? 'Close' : 'Cancel'),
            ),
            if (!waiting && !s.joined) FilledButton(key: const ValueKey('sync-join-go'), onPressed: _start, child: const Text('Connect')),
          ],
        );
      },
    );
  }
}

/// Settings: syncing through a folder on cloud storage that all the devices of the profile can reach.
class _CloudSyncCard extends StatefulWidget {
  final CloudSyncService service;

  const _CloudSyncCard({required this.service});

  @override
  State<_CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends State<_CloudSyncCard> {
  late final _folder = TextEditingController(text: widget.service.folderName);

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final c = widget.service;
        if (_folder.text != c.folderName && !FocusScope.of(context).hasFocus) _folder.text = c.folderName;
        final usable = c.usable;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile.adaptive(
            key: const ValueKey('cloud-on'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Sync through a cloud folder'),
            subtitle: Text(
              'For devices that are not online at the same time: each puts what changed in a folder on your cloud storage and takes in what the others put there, '
              'without the signalling server. Two things still need it: handing the cloud accounts to your other devices (when two of them sync directly; '
              'or connect the account on each device yourself), and working on one note on two devices at the same time.',
              style: muted,
            ),
            value: c.enabled,
            onChanged: c.setEnabled,
          ),
          if (c.enabled) ...[
            const SizedBox(height: 4),
            if (usable.isEmpty && c.provider == null)
              Text('No cloud account is connected on this device. Connect one (Nextcloud in the settings under Sharing and files, or S3, Dropbox or OneDrive under sharing), or sync directly with the device that has one.',
                  key: const ValueKey('cloud-no-account'), style: TextStyle(color: scheme.error, fontSize: 13))
            else
              DropdownButtonFormField<String>(
                key: const ValueKey('cloud-provider'),
                initialValue: c.providerId != null && c.providers.any((p) => p.id == c.providerId) ? c.providerId : null,
                decoration: InputDecoration(labelText: tr('Service'), border: const OutlineInputBorder(), isDense: true),
                items: [
                  for (final p in c.providers)
                    DropdownMenuItem(value: p.id, enabled: p.available(), child: Text.verbatim(p.available() ? p.label : '${p.label} (${tr('not connected')})')),
                ],
                onChanged: (id) => id == null ? null : c.setProvider(id),
              ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('cloud-folder'),
              controller: _folder,
              decoration: InputDecoration(labelText: tr('Folder name'), border: const OutlineInputBorder(), isDense: true),
              onSubmitted: c.setFolderName,
              onTapOutside: (_) => c.setFolderName(_folder.text),
            ),
            const SizedBox(height: 10),
            RadioGroup<bool>(
              groupValue: c.encrypted,
              onChanged: (v) => v == null ? null : c.setEncrypted(v),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                RadioListTile<bool>.adaptive(
                  key: const ValueKey('cloud-encrypted'),
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  title: const Text('Encrypted'),
                  subtitle: Text('Every file is sealed with a key from your profile, and the names say nothing. The cloud holds files nobody can read; only your devices can.', style: muted),
                ),
                RadioListTile<bool>.adaptive(
                  key: const ValueKey('cloud-plain'),
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  title: const Text('Not encrypted'),
                  subtitle: Text('Notes are normal .uninote files and the list is readable text, so you can open them yourself from the cloud. Anyone who can see the folder can read your notes.', style: muted),
                ),
              ]),
            ),
            const SizedBox(height: 4),
            Row(children: [
              FilledButton.icon(
                key: const ValueKey('cloud-now'),
                onPressed: c.running ? null : c.syncNow,
                icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                label: Text(c.running ? 'Syncing...' : 'Sync through the folder now'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text.verbatim(
                  [if (c.what != null) c.what!, if (c.lastRun != null) tr('last run {when}', {'when': agoText(c.lastRun!)})].join(' - '),
                  key: const ValueKey('cloud-status'),
                  style: muted,
                ),
              ),
            ]),
            if (c.problem != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text.verbatim(c.problem!, key: const ValueKey('cloud-problem'), style: TextStyle(color: scheme.error, fontSize: 13))),
          ],
            if (c.enabled || c.signIn.enabled) ...[
              const SizedBox(height: 8),
              CloudSignInCard(cloud: c),
            ],
        ]);
      },
    );
  }
}


/// Browser: shows the code of a temporary connection, and when the phone has answered it goes on with the usual join (the six digits
/// to compare, then the notes come over). True when the browser joined.
Future<bool> showConnectDialog(BuildContext context, DeviceSyncService service) async {
  ConnectLink? code;
  String? problem;
  try {
    code = await service.startConnect();
  } catch (e) {
    problem = '$e'.replaceFirst('Bad state: ', '');
  }
  if (!context.mounted) return false;
  final answered = await showDialog<bool>(
    context: context,
    builder: (context) => _ConnectDialog(service: service, code: code, problem: problem),
  );
  if (answered != true) {
    service.stopConnect();
    return false;
  }
  final link = service.takeConnectedLink();
  if (link == null || !context.mounted) return false;
  return showJoinDialog(context, service, initial: link);
}

class _ConnectDialog extends StatefulWidget {
  final DeviceSyncService service;
  final ConnectLink? code;
  final String? problem;

  const _ConnectDialog({required this.service, this.code, this.problem});

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_check);
  }

  @override
  void dispose() {
    widget.service.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (widget.service.connectArrived != null && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return PlatformAlertDialog(
      title: const Text('Connect temporarily'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.problem != null)
              Text.verbatim(widget.problem!, key: const ValueKey('sync-connect-problem'), style: TextStyle(color: scheme.error))
            else ...[
              const Text('Scan this code with your phone: with the camera, or in Notation under Settings → Sync profile → "Scan the code of the web version".'),
              const SizedBox(height: 12),
              Center(child: QrCodeView(key: const ValueKey('sync-connect-qr'), data: widget.code!.toLink())),
              const SizedBox(height: 12),
              Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2)),
                const SizedBox(width: 10),
                const Expanded(child: Text('Waiting for your phone...')),
              ]),
              const SizedBox(height: 10),
              Text(
                'This browser is signed in until you sign out or close the tab, and then forgets your notes. The code works for ten minutes and only once; '
                'your phone still asks you before it lets this browser in.',
                style: muted,
              ),
            ],
          ]),
        ),
      ),
      actions: [TextButton(key: const ValueKey('sync-connect-close'), onPressed: () => Navigator.pop(context, false), child: const Text('Cancel'))],
    );
  }
}

/// Phone: scans the code that the web version shows and hands the browser a link of this profile; then the usual "let it in?" dialog.
Future<void> scanAndAnswerConnect(BuildContext context, DeviceSyncService service) async {
  final code = await scanConnectLink(context);
  if (code == null || !context.mounted) return;
  await answerConnectCode(context, service, code);
}

/// Phone: the code of a browser is known (scanned, or opened from the camera app).
Future<void> answerConnectCode(BuildContext context, DeviceSyncService service, ConnectLink code) async {
  try {
    await service.answerConnect(code);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim('$e'.replaceFirst('Bad state: ', ''))));
    return;
  }
  if (!context.mounted) return;
  await showAddDeviceDialog(context, service);
}
