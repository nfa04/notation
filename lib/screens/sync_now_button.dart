import 'package:flutter/material.dart' hide Text;

import '../devicesync/device_sync_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../nativeshare/native_share_service.dart';
import '../nativeshare/share_model.dart' show ShareState;

/// "Sync now" for the top bar: syncs through the cloud folder when that is on (and has an account here), otherwise looks for the
/// other devices of the profile and syncs with those that are there (they have to be looking too, or have the automatic sync on).
/// Nothing is shown on a device that is not part of a sync profile.
///
/// The notes and folders shared with other people are synced too ([shares]): they are part of what "Sync now" brings up to date.
class SyncNowButton extends StatelessWidget {
  final DeviceSyncService sync;
  final NativeShareService? shares;

  const SyncNowButton({super.key, required this.sync, this.shares});

  @override
  Widget build(BuildContext context) {
    final cloud = sync.cloud;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, ?cloud, ?shares]),
      builder: (context, _) {
        if (!sync.isSetUp) return const SizedBox.shrink();
        final viaCloud = cloud != null && cloud.enabled && cloud.folderNow != null;
        final busy = (viaCloud ? cloud.running : (sync.lookingForDevices || sync.activeSyncs > 0)) || (shares?.running ?? false);
        return IconButton(
          key: const ValueKey('sync-now-top'),
          tooltip: tr(busy ? (viaCloud ? 'Syncing...' : 'Looking for your other devices...') : 'Sync now'),
          onPressed: busy ? null : () => _run(context, viaCloud),
          icon: busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
              : const Icon(Icons.sync),
        );
      },
    );
  }

  Future<void> _run(BuildContext context, bool viaCloud) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String text) => messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(text), duration: const Duration(seconds: 6)));
    final shared = shares;
    final sharing = shared != null && shared.shares.any((s) => s.state == ShareState.active);
    if (sharing) await shared.syncNow();
    final sharesProblem = sharing ? [for (final s in shared.shares) shared.statusOf(s.id).problem,].whereType<String>().firstOrNull : null;
    if (viaCloud) {
      final cloud = sync.cloud!;
      await cloud.syncNow();
      final problem = cloud.problem ?? sharesProblem;
      say(problem ?? cloud.what ?? tr('Synced'));
    } else {
      await sync.syncNow();
      say(sharesProblem ?? tr('Looking for your other devices. They have to be looking too: press "Sync now" there, or turn on the automatic sync.'));
    }
  }
}
