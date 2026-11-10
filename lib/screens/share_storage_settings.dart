import 'package:flutter/material.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../collab/cloud_share.dart';
import '../collab/nextcloud_storage.dart';
import '../collab/dropbox_storage.dart';
import '../collab/onedrive_storage.dart';
import '../collab/oauth.dart';
import '../collab/s3_storage.dart';
import '../collab/share_storage.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'nextcloud_settings.dart';

/// Where copies of notes that are shared with a link are kept: each service that is offered, with what it
/// needs to be set up. (A new [ShareStorage] gets its section here.)
class ShareStorageSettings extends StatelessWidget {
  final CloudShare share;

  const ShareStorageSettings({super.key, required this.share});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Sharing copies of notes', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(
        'A copy of a note can be put on a storage service you have an account with, and opened by anyone with the link, '
        'also while you are offline. The copy is sealed with a key that is only in the link: the service stores a file '
        'it cannot read. Several services can be set up; the one chosen when you share is used.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
      ),
      for (final s in share.storages) ...[
        const SizedBox(height: 12),
          storageAccountSection(s),
        ],
      ],
    );
  }
}

/// The login of one storage service, as it is set up in the settings (also used where a device signs in to a profile with the cloud
/// folder and has no account yet).
Widget storageAccountSection(ShareStorage s) =>
        ListenableBuilder(
          listenable: s,
          builder: (context, _) => switch (s) {
            NextcloudStorage() => _NextcloudSection(storage: s),
            S3Storage() => _S3Section(storage: s),
            OAuthShareStorage() => _OAuthSection(storage: s),
            _ => _GenericSection(storage: s),
          },
        );

Widget _title(BuildContext context, String name, bool ready) => Row(children: [
      Icon(ready ? Icons.check_circle_outline : Icons.circle_outlined, size: 18, color: ready ? Colors.green[700] : Colors.grey),
      const SizedBox(width: 8),
      Text.verbatim(name, style: const TextStyle(fontWeight: FontWeight.w600)),
    ]);

class _GenericSection extends StatelessWidget {
  final ShareStorage storage;

  const _GenericSection({required this.storage});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _title(context, storage.label, storage.available),
            if (!storage.available) Text.verbatim(storage.unavailableReason ?? '', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          ]),
        ),
      );
}

class _NextcloudSection extends StatelessWidget {
  final NextcloudStorage storage;

  const _NextcloudSection({required this.storage});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _title(context, storage.label, storage.available),
            const SizedBox(height: 4),
            NextcloudSettings(service: storage.caldav),
          ]),
        ),
      );
}

class _S3Section extends StatefulWidget {
  final S3Storage storage;

  const _S3Section({required this.storage});

  @override
  State<_S3Section> createState() => _S3SectionState();
}

class _S3SectionState extends State<_S3Section> {
  late final _endpoint = TextEditingController(text: widget.storage.config?.endpoint ?? '');
  late final _region = TextEditingController(text: widget.storage.config?.region ?? 'auto');
  late final _bucket = TextEditingController(text: widget.storage.config?.bucket ?? '');
  late final _access = TextEditingController(text: widget.storage.config?.accessKey ?? '');
  final _secret = TextEditingController();
  late bool _editing = !widget.storage.available;
  bool _busy = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    for (final c in [_endpoint, _region, _bucket, _access, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final endpoint = S3Config.normalizeEndpoint(_endpoint.text);
    if (endpoint == null) {
      setState(() {
        _ok = false;
        _result = tr('The address must start with https://');
      });
      return;
    }
    final config = S3Config(endpoint: endpoint, region: _region.text.trim(), bucket: _bucket.text.trim(), accessKey: _access.text.trim());
    // an account that is kept: the secret stays when the field is empty
    final secret = _secret.text.trim();
    setState(() {
      _busy = true;
      _result = null;
    });
    final problem = await widget.storage.check(config, secret);
    if (problem == null) await widget.storage.save(config, secret);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = problem == null;
      _result = problem ?? tr('It works. Copies can be shared through this bucket.');
      if (problem == null) {
        _editing = false;
        _secret.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final storage = widget.storage;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, storage.label, storage.available),
          const SizedBox(height: 4),
          Text(
            'Any S3-compatible service: Cloudflare R2, Backblaze B2, Wasabi, MinIO, Amazon S3. Make an access key that may '
            'read and write in one bucket. Links work for 7 days; the copies are deleted from the bucket after that, '
            'the next time you share.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (!_editing && storage.config != null) ...[
            Text.verbatim(tr('Bucket {bucket} at {host}', {'bucket': storage.config!.bucket, 'host': Uri.tryParse(storage.config!.endpoint)?.host ?? storage.config!.endpoint}),
                key: const ValueKey('s3-summary')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton(key: const ValueKey('s3-change'), onPressed: () => setState(() => _editing = true), child: const Text('Change')),
              TextButton(
                key: const ValueKey('s3-remove'),
                onPressed: () async {
                  await storage.remove();
                  if (mounted) {
                    setState(() {
                      _editing = true;
                      _result = null;
                      _access.clear();
                      _bucket.clear();
                      _endpoint.clear();
                    });
                  }
                },
                child: const Text('Remove'),
              ),
            ]),
          ] else ...[
            TextField(
              key: const ValueKey('s3-endpoint'),
              controller: _endpoint,
              decoration: InputDecoration(labelText: tr('Service address'), hintText: tr('https://<account>.r2.cloudflarestorage.com')),
              onChanged: (_) => setState(() {}),
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('s3-bucket'),
                  controller: _bucket,
                  decoration: InputDecoration(labelText: tr('Bucket')),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: TextField(
                  key: const ValueKey('s3-region'),
                  controller: _region,
                  decoration: InputDecoration(labelText: tr('Region'), helperText: tr('auto for R2')),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
            TextField(
              key: const ValueKey('s3-access'),
              controller: _access,
              decoration: InputDecoration(labelText: tr('Access key ID')),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('s3-secret'),
              controller: _secret,
              obscureText: true,
              decoration: InputDecoration(labelText: tr('Secret access key'), helperText: tr('Kept in the keystore of this device')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton(
                key: const ValueKey('s3-save'),
                onPressed: _busy || _endpoint.text.trim().isEmpty || _bucket.text.trim().isEmpty || _access.text.trim().isEmpty || _secret.text.trim().isEmpty ? null : _save,
                child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)) : const Text('Test and save'),
              ),
              if (storage.available) ...[
                const SizedBox(width: 8),
                TextButton(onPressed: () => setState(() => _editing = false), child: const Text('Cancel')),
              ],
            ]),
          ],
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text.verbatim(_result!, key: const ValueKey('s3-result'), style: TextStyle(color: _ok ? Colors.green[700] : scheme.error)),
            ),
        ]),
      ),
    );
  }
}

/// A service that is signed in to in the browser (Dropbox, OneDrive).
class _OAuthSection extends StatefulWidget {
  final OAuthShareStorage storage;

  const _OAuthSection({required this.storage});

  @override
  State<_OAuthSection> createState() => _OAuthSectionState();
}

class _OAuthSectionState extends State<_OAuthSection> {
  bool _opening = false;
  String? _problem;
  final _clientId = TextEditingController();
  bool _changingId = false;

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _opening = true;
      _problem = null;
    });
    try {
      final page = await widget.storage.beginSignIn();
      final ok = await launchUrl(page, mode: LaunchMode.externalApplication);
      if (!ok) _problem = tr('The browser could not be opened.');
    } catch (e) {
      _problem = '$e'.replaceFirst('Bad state: ', '');
    }
    if (mounted) setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    final storage = widget.storage;
    final scheme = Theme.of(context).colorScheme;
    final problem = _problem ?? storage.signInProblem;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, storage.label, storage.available),
          const SizedBox(height: 4),
          Text.verbatim(
            tr('Copies are put in a folder of the app on your {service}, and the link works for {days} days; the copies are deleted from it after that, the next time you share.',
                {'service': storage.label, 'days': storage.keeps.inDays}),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (!storage.configured || _changingId) ...[
            Text.verbatim(storage.setupHint, key: ValueKey('${storage.redirectName}-setup'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
            TextField(
              key: ValueKey('${storage.redirectName}-clientid'),
              controller: _clientId,
              decoration: InputDecoration(labelText: storage.clientIdLabel),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton(
                key: ValueKey('${storage.redirectName}-save-id'),
                onPressed: _clientId.text.trim().isEmpty
                    ? null
                    : () async {
                        await storage.setClientId(_clientId.text);
                        if (mounted) setState(() => _changingId = false);
                      },
                child: const Text('Save'),
              ),
              if (_changingId) TextButton(onPressed: () => setState(() => _changingId = false), child: const Text('Cancel')),
              if (_changingId && storage.defaultClientId.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    await storage.setClientId('');
                    if (mounted) setState(() => _changingId = false);
                  },
                  child: const Text('Use the one of the app'),
                ),
            ]),
          ] else if (storage.available) ...[
            Wrap(spacing: 8, children: [
              OutlinedButton(key: ValueKey('${storage.redirectName}-signout'), onPressed: storage.signOut, child: const Text('Sign out')),
              if (storage.customClientId)
                TextButton(key: ValueKey('${storage.redirectName}-change-id'), onPressed: () => setState(() {
                  _changingId = true;
                  _clientId.text = storage.customClientId ? storage.oauth.clientId : '';
                }), child: Text.verbatim(tr('Change the {field}', {'field': storage.clientIdLabel}))),
            ]),
          ] else ...[
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                key: ValueKey('${storage.redirectName}-signin'),
                icon: _opening ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)) : const Icon(Icons.login, size: 18),
                label: Text.verbatim(tr('Sign in to {service}', {'service': storage.label})),
                onPressed: _opening ? null : _signIn,
              ),
              TextButton(key: ValueKey('${storage.redirectName}-change-id'), onPressed: () => setState(() {
                  _changingId = true;
                  _clientId.text = storage.customClientId ? storage.oauth.clientId : '';
                }), child: Text.verbatim(tr('Change the {field}', {'field': storage.clientIdLabel}))),
            ]),
          ],
          if (storage is OneDriveStorage && storage.configured)
            SwitchListTile.adaptive(
              key: const ValueKey('onedrive-sharing'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Also allow sharing with people'),
              subtitle: const Text(
                'Sharing a folder with someone, and opening what they share with you, needs access to all your OneDrive files, not just the '
                "folder of the app. Changing this signs you out: sign in again afterwards. (Settings, Shared with people)",
              ),
              value: storage.sharingEnabled,
              onChanged: (v) => storage.setSharing(v),
            ),
          if (storage is DropboxStorage && storage.configured)
            SwitchListTile.adaptive(
              key: const ValueKey('dropbox-sharing'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Also allow sharing with people'),
              subtitle: const Text(
                'Sharing a folder with someone, and opening what they share with you, only works with a Dropbox app that has access to the whole '
                'Dropbox (not the app folder alone), and the sharing permissions. Turn this on only if the app key above is such an app. '
                'Changing this signs you out: sign in again afterwards.',
              ),
              value: storage.sharingEnabled,
              onChanged: (v) => storage.setSharing(v),
            ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text.verbatim(problem, key: ValueKey('${storage.redirectName}-problem'), style: TextStyle(color: scheme.error)),
            ),
        ]),
      ),
    );
  }
}
