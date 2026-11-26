import 'package:flutter/material.dart' hide Text;

import '../extensions/extension_gallery.dart';
import '../extensions/extension_manifest.dart';
import '../extensions/extension_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';
import 'extension_review.dart';

/// The gallery of extensions: the list from the repository, each with what it asks for, and a button to get it (or update it). What is
/// downloaded is checked against its checksum and then shown for the person to say yes to, exactly as an extension from a file is.
Future<void> showExtensionGallery(BuildContext context, {required ExtensionService service, required ExtensionGallery gallery}) =>
    showDialog<void>(context: context, builder: (_) => _GalleryDialog(service: service, gallery: gallery));

class _GalleryDialog extends StatefulWidget {
  final ExtensionService service;
  final ExtensionGallery gallery;
  const _GalleryDialog({required this.service, required this.gallery});

  @override
  State<_GalleryDialog> createState() => _GalleryDialogState();
}

class _GalleryDialogState extends State<_GalleryDialog> {
  late Future<List<GalleryEntry>> _entries = widget.gallery.list();
  String? _busy;

  Future<void> _get(GalleryEntry e) async {
    setState(() => _busy = e.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await widget.gallery.download(e);
      final package = widget.service.inspectZip(bytes);
      if (package.manifest.id != e.id) throw GalleryException(tr('The package is not the extension it was listed as.'));
      if (!mounted) return;
      final yes = await confirmInstall(context, package.manifest, before: widget.service.byId(e.id)?.manifest);
      if (!yes) return;
      await widget.service.installSource(package.manifestText, package.script, files: package.files);
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Installed {name}. It is off until you switch it on.', {'name': e.name}))));
    } on ManifestException catch (err) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not install it: {error}', {'error': err.message}))));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not install it: {error}', {'error': err}))));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Gallery of extensions'),
        content: SizedBox(
          width: 520,
          child: ListenableBuilder(
            listenable: widget.service,
            builder: (context, _) => FutureBuilder<List<GalleryEntry>>(
              future: _entries,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
                if (snapshot.hasError) {
                  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text.verbatim('${snapshot.error}'),
                    TextButton(key: const ValueKey('gallery-retry'), onPressed: () => setState(() => _entries = widget.gallery.list()), child: const Text('Try again')),
                  ]);
                }
                final entries = snapshot.data!;
                if (entries.isEmpty) return const Text('The gallery is empty.');
                return SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final e in entries) _row(context, e),
                  ]),
                );
              },
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      );

  Widget _row(BuildContext context, GalleryEntry e) {
    final have = widget.service.byId(e.id);
    final newer = have != null && versionIsNewer(e.version, have.manifest.version);
    final perms = [for (final id in e.permissions) ExtensionPermission.byId(id)?.description ?? id];
    return ListTile(
      key: ValueKey('gallery-${e.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text.verbatim('${e.name}  ·  ${e.version}'),
      subtitle: Text.verbatim([e.description, if (perms.isNotEmpty) '${tr('It asks to be allowed to:')} ${perms.join('; ')}'].join('\n')),
      isThreeLine: true,
      trailing: _busy == e.id
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : have == null
              ? FilledButton.tonal(key: ValueKey('gallery-get-${e.id}'), onPressed: _busy == null ? () => _get(e) : null, child: const Text('Get'))
              : newer
                  ? FilledButton(key: ValueKey('gallery-update-${e.id}'), onPressed: _busy == null ? () => _get(e) : null, child: const Text('Update'))
                  : Text(tr('Installed')),
    );
  }
}
