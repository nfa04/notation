import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../extensions/extension_manifest.dart';
import '../extensions/extension_service.dart';
import '../extensions/extension_store.dart';
import '../extensions/store_defaults.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';
import 'extension_review.dart';

/// The names of the store's categories as the person sees them.
const _categoryNames = {
  'writing': 'Writing',
  'study': 'Study',
  'productivity': 'Productivity',
  'math': 'Maths',
  'code': 'Code',
  'drawing': 'Drawing',
  'import': 'Import',
  'automation': 'Automation',
  'other': 'Other',
};

/// Opens the store: what extensions there are, with what each says about itself, and a button to install one. Installing goes the
/// way a file does (the same checks, the same dialog that shows what the extension asks to be allowed to do): the store only fetches the file.
Future<void> showExtensionStore(BuildContext context, ExtensionService service, {ExtensionStoreClient? client}) async {
  final use = client ?? await ExtensionStoreClient.forSettings();
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExtensionStorePage(service: service, client: use)));
}

class ExtensionStorePage extends StatefulWidget {
  final ExtensionService service;
  final ExtensionStoreClient client;
  const ExtensionStorePage({super.key, required this.service, required this.client});

  @override
  State<ExtensionStorePage> createState() => _ExtensionStorePageState();
}

class _ExtensionStorePageState extends State<ExtensionStorePage> {
  Future<StoreCatalogue>? _catalogue;
  String _query = '';
  String? _category;
  final _logos = <String, Future<Uint8List?>>{};
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _logos.clear();
    _catalogue = widget.client.configured ? widget.client.catalogue() : null;
    setState(() {});
  }

  Future<Uint8List?> _logo(StoreEntry e) => _logos.putIfAbsent(e.id, () => widget.client.logo(e));

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(text), duration: const Duration(seconds: 8)));
  }

  /// Fetches the zip, checks that it is the one listed and what the listing says it is, shows the person what it asks for, installs.
  Future<void> _install(StoreEntry e) async {
    if (_busy.contains(e.id)) return;
    setState(() => _busy.add(e.id));
    try {
      final bytes = await widget.client.zip(e);
      final package = widget.service.inspectZip(bytes);
      final m = package.manifest;
      // the catalogue is signed, but what is in the zip is what runs: it has to be what was promised
      final asked = {for (final p in m.permissions) p.id};
      if (m.id != e.id || m.version != e.version || asked.length != e.permissions.length || !asked.containsAll(e.permissions)) {
        throw StoreException(tr('The extension in the download is not the one the store listed (a different id, version or permissions). Nothing was installed.'));
      }
      if (!mounted) return;
      if (!await confirmInstall(context, m, before: widget.service.byId(m.id)?.manifest)) return;
      await widget.service.installZip(bytes);
      _say(tr('Installed {name}. It is off until you switch it on in Settings → Extensions.', {'name': m.name}));
    } on StoreException catch (x) {
      _say(tr(x.message));
    } on ManifestException catch (x) {
      _say(tr('Could not install it: {error}', {'error': x.message}));
    } catch (x) {
      _say(tr('Could not install it: {error}', {'error': x}));
    } finally {
      if (mounted) setState(() => _busy.remove(e.id));
    }
  }

  bool _matches(StoreEntry e) {
    if (_category != null && e.category != _category) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [e.name, e.author, e.summary, e.category, ...e.tags].any((s) => s.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: widget.client.base.host == Uri.parse(extensionStoreAddress).host ? const Text('Extension store') : Text.verbatim('${tr('Extension store')} · ${widget.client.base.host}'),
        actions: [IconButton(key: const ValueKey('store-reload'), tooltip: tr('Reload'), onPressed: _reload, icon: const Icon(Symbols.refresh))],
      ),
      body: ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final catalogue = _catalogue;
          if (catalogue == null) return _message(tr('No extension store is set up in this version of the app.'), icon: Symbols.storefront);
          return FutureBuilder<StoreCatalogue>(
            future: catalogue,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
              if (snap.hasError) {
                final x = snap.error;
                return _message(x is StoreException ? tr(x.message) : tr('The store could not be reached.'), icon: Symbols.cloud_off, retry: true);
              }
              return _list(context, snap.data!);
            },
          );
        },
      ),
    );
  }

  Widget _message(String text, {required IconData icon, bool retry = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text.verbatim(text, textAlign: TextAlign.center),
            if (retry) ...[
              const SizedBox(height: 12),
              OutlinedButton(key: const ValueKey('store-retry'), onPressed: _reload, child: const Text('Try again')),
            ],
          ]),
        ),
      );

  Widget _list(BuildContext context, StoreCatalogue catalogue) {
    final categories = {for (final e in catalogue.entries) e.category}.where((c) => c.isNotEmpty).toList()..sort();
    final shown = catalogue.entries.where(_matches).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (!widget.service.canRun)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(tr('The script engine is not available on this device: extensions can be installed but not run.'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        TextField(
          key: const ValueKey('store-search'),
          decoration: InputDecoration(prefixIcon: const Icon(Symbols.search, size: 18), hintText: tr('Search extensions'), isDense: true, border: const OutlineInputBorder()),
          onChanged: (v) => setState(() => _query = v),
        ),
        if (categories.length > 1) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ChoiceChip(key: const ValueKey('store-category-all'), label: const Text('All'), selected: _category == null, onSelected: (_) => setState(() => _category = null)),
            for (final c in categories)
              ChoiceChip(key: ValueKey('store-category-$c'), label: Text.verbatim(tr(_categoryNames[c] ?? c)), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
          ]),
        ],
        const SizedBox(height: 8),
        if (catalogue.entries.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr('The store has no extensions yet.'))))
        else if (shown.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr('Nothing matches.'))))
        else
          for (final e in shown) _card(context, e),
      ],
    );
  }

  Widget _logoBox(StoreEntry e, double size) => SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size / 5),
          child: FutureBuilder<Uint8List?>(
            future: _logo(e),
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes == null) return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: Icon(Symbols.extension, size: size * 0.5));
              return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const Icon(Symbols.extension));
            },
          ),
        ),
      );

  Widget _button(StoreEntry e) {
    final installed = widget.service.byId(e.id);
    final busy = _busy.contains(e.id);
    final upToDate = installed != null && installed.manifest.version == e.version;
    final label = upToDate ? tr('Installed') : installed != null ? tr('Update') : tr('Install');
    return FilledButton.tonal(
      key: ValueKey('store-install-${e.id}'),
      onPressed: busy || upToDate ? null : () => _install(e),
      child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text.verbatim(label),
    );
  }

  Widget _card(BuildContext context, StoreEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final asks = e.permissions.isEmpty ? tr('Asks for no permission') : tr('Asks for {count} permissions', {'count': e.permissions.length});
    return Card(
      key: ValueKey('store-entry-${e.id}'),
      margin: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _details(e),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _logoBox(e, 56),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.verbatim('${e.name}  ·  ${e.version}', style: Theme.of(context).textTheme.titleSmall),
                if (e.author.isNotEmpty) Text.verbatim(e.author, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                const SizedBox(height: 2),
                Text.verbatim(e.summary),
                const SizedBox(height: 4),
                Text.verbatim(asks, style: TextStyle(color: e.permissions.isEmpty ? scheme.onSurfaceVariant : scheme.error, fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 8),
            _button(e),
          ]),
        ),
      ),
    );
  }

  /// A longer page for one extension: what it says about itself and what it asks for, before anything is downloaded.
  void _details(StoreEntry e) {
    showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return PlatformAlertDialog(
          key: ValueKey('store-details-${e.id}'),
          title: Row(children: [_logoBox(e, 40), const SizedBox(width: 12), Expanded(child: Text.verbatim(e.name))]),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.verbatim([e.version, if (e.author.isNotEmpty) e.author, if (e.updated.isNotEmpty) e.updated, '${(e.size / 1024).ceil()} KB'].join('  ·  '), style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Text.verbatim(e.description.isEmpty ? e.summary : e.description),
                const SizedBox(height: 12),
                Text(tr('It asks to be allowed to:'), style: Theme.of(context).textTheme.labelLarge),
                if (e.permissions.isEmpty) Text(tr('Nothing: it only works on the text it is given.')),
                for (final id in e.permissions)
                  Text.verbatim('• ${ExtensionPermission.byId(id) == null ? id : tr(ExtensionPermission.byId(id)!.description)}${id == 'network' && e.hosts.isNotEmpty ? ' (${e.hosts.join(', ')})' : ''}',
                      style: TextStyle(color: scheme.error)),
                if (e.tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text.verbatim(e.tags.map((t) => '#$t').join('  '), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            ListenableBuilder(
              listenable: widget.service,
              builder: (context, _) => _button(e),
            ),
          ],
        );
      },
    );
  }
}
