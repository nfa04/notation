import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../cloudsync/cloud_sign_in.dart';
import '../cloudsync/cloud_sync_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

String _words(Object e) => '$e'.replaceFirst('Bad state: ', '');

/// The recovery key, shown once. The person has to say they kept it before the dialog lets go.
Future<void> showRecoveryKeyDialog(BuildContext context, RecoveryKey key) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RecoveryKeyDialog(keyText: key.text),
    );

class _RecoveryKeyDialog extends StatefulWidget {
  final String keyText;

  const _RecoveryKeyDialog({required this.keyText});

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _kept = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('Your recovery key'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'Keep it in a password manager or write it on paper. It is shown only now and the app does not keep it. '
            'With this key and your cloud account you can sign in to your profile on a new device; without it, only a link from one of your devices works.',
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(widget.keyText, key: const ValueKey('recovery-key'), style: const TextStyle(fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('recovery-key-copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: widget.keyText)),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
          ),
          CheckboxListTile.adaptive(
            key: const ValueKey('recovery-key-kept'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _kept,
            onChanged: (v) => setState(() => _kept = v ?? false),
            title: const Text('I have saved the key'),
          ),
        ]),
      ),
      actions: [
        FilledButton(key: const ValueKey('recovery-key-done'), onPressed: _kept ? () => Navigator.pop(context) : null, child: const Text('Done')),
      ],
    );
  }
}

/// Signing in to a profile with the cloud folder, on a device that is not part of one: choose the service, connect the account if it is
/// not connected, say which folder, type the recovery key. True when the device signed in.
Future<bool> showCloudSignInDialog(BuildContext context, CloudSyncService cloud) async {
  final done = await showDialog<bool>(context: context, builder: (context) => _SignInDialog(cloud: cloud));
  return done ?? false;
}

class _SignInDialog extends StatefulWidget {
  final CloudSyncService cloud;

  const _SignInDialog({required this.cloud});

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  late final _folder = TextEditingController(text: CloudSyncService.defaultFolder);
  final _key = TextEditingController();
  late String _providerId = (widget.cloud.providers.where((p) => p.available()).firstOrNull ?? widget.cloud.providers.first).id;
  bool _busy = false;
  String? _error;

  late final Listenable _accounts = Listenable.merge([for (final p in widget.cloud.providers) p.changes]);

  CloudProvider get _provider => widget.cloud.providers.firstWhere((p) => p.id == _providerId);

  @override
  void dispose() {
    _folder.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.cloud.signInWith(_provider, _folder.text, _key.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _words(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return PlatformAlertDialog(
      title: const Text('Sign in with your cloud folder'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: _accounts,
            builder: (context, _) {
              final p = _provider;
              final ready = p.available() && RecoveryKey.parse(_key.text) != null && !_busy;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'Use the folder your other devices sync through, and the recovery key that was shown when signing in was turned on there. '
                  'Your notes, folders and settings come to this device.',
                  style: muted,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  key: const ValueKey('signin-service'),
                  initialValue: _providerId,
                  decoration: InputDecoration(labelText: tr('Service'), border: const OutlineInputBorder(), isDense: true),
                  items: [for (final s in widget.cloud.providers) DropdownMenuItem(value: s.id, child: Text.verbatim(s.label))],
                  onChanged: _busy ? null : (id) => setState(() => _providerId = id ?? _providerId),
                ),
                const SizedBox(height: 10),
                if (p.available())
                  Row(children: [
                    Icon(Icons.check_circle_outline, size: 18, color: Colors.green[700]),
                    const SizedBox(width: 8),
                    Text.verbatim(tr('{service} is connected.', {'service': p.label})),
                  ])
                else ...[
                  Text('Connect your account first:', style: muted),
                  if (p.setup != null) p.setup!(context),
                ],
                if (kIsWeb && p.id == 'nextcloud') ...[
                  const SizedBox(height: 6),
                  Text('In a browser, your Nextcloud has to allow this website to talk to it (CORS headers); the documentation says which.', style: muted),
                ],
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('signin-folder'),
                  controller: _folder,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: tr('Folder name'), border: const OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('signin-key'),
                  controller: _key,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: InputDecoration(labelText: tr('Recovery key'), hintText: 'ABCDE-FGHJK-MNPQR-STUVW-XY234', border: const OutlineInputBorder(), isDense: true),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => ready ? _go() : null,
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_error!, key: const ValueKey('signin-error'), style: TextStyle(color: scheme.error, fontSize: 13))),
                if (kIsWeb) ...[
                  const SizedBox(height: 10),
                  Text('"Sign out" in the menu removes everything from this browser again.', style: muted),
                ],
                if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              ]);
            },
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        ListenableBuilder(
          listenable: Listenable.merge([_accounts, _key]),
          builder: (context, _) => FilledButton(
            key: const ValueKey('signin-go'),
            onPressed: _provider.available() && RecoveryKey.parse(_key.text) != null && !_busy ? _go : null,
            child: const Text('Sign in'),
          ),
        ),
      ],
    );
  }
}

/// In the sync settings, under the cloud folder: the switch that makes signing in with the folder possible, the recovery key, and the
/// devices that came in that way.
class CloudSignInCard extends StatelessWidget {
  final CloudSyncService cloud;

  const CloudSignInCard({super.key, required this.cloud});

  Future<bool> _ask(BuildContext context, {required String title, required String body, required String yes}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text.verbatim(title),
        content: Text.verbatim(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('signin-confirm'), onPressed: () => Navigator.pop(context, true), child: Text.verbatim(yes)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _turnOn(BuildContext context) async {
    final ok = await _ask(
      context,
      title: tr('Sign in with this folder?'),
      body: tr(
          'Anyone who has the recovery key and can open this cloud folder will be able to sign in to your profile and read your notes, without anyone saying yes on one of your other devices. '
          'Your devices show each device that signs in this way, and you can take it out. The key is shown once and not kept by the app. Adding a device with a link works as before.'),
      yes: tr('Turn on'),
    );
    if (!ok || !context.mounted) return;
    try {
      final key = await cloud.signIn.enable();
      if (context.mounted) await showRecoveryKeyDialog(context, key);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(_words(e))));
    }
  }

  Future<void> _turnOff(BuildContext context) async {
    final ok = await _ask(
      context,
      title: tr('Turn off signing in with the folder?'),
      body: tr('The sign-in file is taken out of the folder, so the recovery key stops working. Devices that are already in stay in.'),
      yes: tr('Turn off'),
    );
    if (!ok || !context.mounted) return;
    try {
      await cloud.signIn.disable();
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(_words(e))));
    }
  }

  Future<void> _renew(BuildContext context) async {
    final ok = await _ask(
      context,
      title: tr('Make a new recovery key?'),
      body: tr('The old key stops working at once. Devices that signed in with it stay in; to cut one off, take it out of the list of devices.'),
      yes: tr('Make a new key'),
    );
    if (!ok || !context.mounted) return;
    try {
      final key = await cloud.signIn.regenerate();
      if (context.mounted) await showRecoveryKeyDialog(context, key);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(_words(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: Listenable.merge([cloud, cloud.signIn]),
      builder: (context, _) {
        final on = cloud.signIn.enabled;
        final usable = cloud.folderNow != null;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile.adaptive(
            key: const ValueKey('cloud-signin-on'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Let me sign in with this folder'),
            subtitle: Text(
              'On a new device or in a browser, sign in with this cloud account and a recovery key instead of a link and a yes on another device. '
              'Off by default: adding a device with a link stays the careful way.',
              style: muted,
            ),
            value: on,
            onChanged: on || usable ? (v) => v ? _turnOn(context) : _turnOff(context) : null,
          ),
          if (!usable && !on) Text('Needs the sync through the folder to be on, with the account connected on this device.', key: const ValueKey('cloud-signin-needs'), style: muted),
          if (on) ...[
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                key: const ValueKey('cloud-signin-renew'),
                onPressed: usable ? () => _renew(context) : null,
                icon: const Icon(Icons.vpn_key_outlined, size: 18),
                label: const Text('Make a new recovery key'),
              ),
            ]),
            if (cloud.signIn.signedIn.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text.verbatim(
                  tr('Signed in with the recovery key: {devices}', {'devices': [for (final id in cloud.signIn.signedIn.keys) cloud.nameOfDevice(id)].join(', ')}),
                  key: const ValueKey('cloud-signin-devices'),
                  style: muted,
                ),
              ),
          ],
        ]);
      },
    );
  }
}
