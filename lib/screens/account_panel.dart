import 'package:flutter/foundation.dart' show kIsWeb;import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../devicesync/device_sync_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../profile/user_profile.dart';
import 'sync_settings.dart';

/// The top of the phone's menu: who uses this device. A tap on it opens the account (name, id) and the state of the sync.
class AccountPanel extends StatefulWidget {
  final UserProfile? profile;
  final DeviceSyncService? sync;

  /// Opens the settings, where the name and the sync are set.
  final VoidCallback onSettings;

  const AccountPanel({super.key, required this.profile, required this.sync, required this.onSettings});

  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile, sync = widget.sync;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([?profile, ?sync, ?sync?.cloud]),
      builder: (context, _) {
        final name = profile?.name ?? '';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            key: const ValueKey('account-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
              child: Row(children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: name.isEmpty ? const Icon(Icons.person_outline) : Text.verbatim(name.characters.first.toUpperCase()),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text.verbatim(name.isEmpty ? 'Notation' : name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                    if (sync != null && sync.isSetUp) Text.verbatim(_status(sync), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant), overflow: TextOverflow.ellipsis),
                  ]),
                ),
                Icon(_open ? Icons.expand_less : Icons.expand_more),
              ]),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (profile != null)
                  Row(children: [
                    Expanded(child: Text.verbatim(tr('Your id: {id}', {'id': profile.id}), key: const ValueKey('profile-id'), style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                    IconButton(tooltip: tr('Copy'), icon: const Icon(Icons.copy, size: 18), onPressed: () => Clipboard.setData(ClipboardData(text: profile.id))),
                  ]),
                if (sync != null && sync.isSetUp) SyncPeers(service: sync),
                    if (kIsWeb && sync != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('account-sign-out'),
                          onPressed: () => confirmSignOut(context, sync),
                          icon: const Icon(Icons.logout),
                          label: Text(tr('Sign out')),
                        ),
                      ),
              ]),
            ),
          const Divider(height: 1),
        ]);
      },
    );
  }

  bool _viaCloud(DeviceSyncService sync) => sync.cloud != null && sync.cloud!.enabled && sync.cloud!.folderNow != null;

  /// One line: what the sync is doing or did last.
  String _status(DeviceSyncService sync) {
    if (_viaCloud(sync)) {
      final c = sync.cloud!;
      if (c.running) return tr('Syncing...');
      if (c.problem != null) return tr('Sync problem');
      return c.lastRun == null ? tr('Not synced yet') : tr('synced {when}', {'when': agoText(c.lastRun!)});
    }
    if (sync.lookingForDevices || sync.activeSyncs > 0) return tr('Looking for your other devices...');
    final times = [for (final p in sync.peers) ?p.lastSync]..sort();
    if (times.isEmpty) return sync.connected ? tr('Online') : tr('Not synced yet');
    return tr('synced {when}', {'when': agoText(times.last)});
  }
}
