import 'package:flutter/material.dart' hide Text;

import '../extensions/extension_store.dart';
import '../extensions/store_defaults.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'advanced_section.dart';

/// Advanced: use another extension store than the built-in one. A store is an address and the public key its catalogue is signed with; the
/// app only believes a catalogue signed by that key. Only enter a store you trust: what it lists is what you are offered to install (each
/// extension still shows what it asks for before it is installed).
class ExtensionStoreSourceSettings extends StatefulWidget {
  const ExtensionStoreSourceSettings({super.key});

  @override
  State<ExtensionStoreSourceSettings> createState() => _ExtensionStoreSourceSettingsState();
}

class _ExtensionStoreSourceSettingsState extends State<ExtensionStoreSourceSettings> {
  final _address = TextEditingController();
  final _key = TextEditingController();
  StoreSource _saved = StoreSource.builtIn;
  bool _loaded = false;
  String? _problem;
  String? _note;

  @override
  void initState() {
    super.initState();
    StoreSource.load().then((s) {
      if (!mounted) return;
      setState(() {
        _saved = s;
        _address.text = s.address;
        _key.text = s.publicKey;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = _address.text.trim(), k = _key.text.trim();
    final problem = StoreSource.problem(a, k);
    if (problem != null) {
      setState(() {
        _problem = problem;
        _note = null;
      });
      return;
    }
    final s = StoreSource(a, k);
    await StoreSource.save(s);
    if (mounted) {
      setState(() {
        _saved = s;
        _problem = null;
        _note = 'Saved. The store page uses this store now.';
      });
    }
  }

  Future<void> _reset() async {
    await StoreSource.save(StoreSource.builtIn);
    if (!mounted) return;
    _address.clear();
    _key.clear();
    setState(() {
      _saved = StoreSource.builtIn;
      _problem = null;
      _note = 'The built-in store is used again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AdvancedSection(
      label: 'Extension store',
      initiallyOpen: !_saved.isBuiltIn,
      children: [
        Text(
          'The store the app browses. By default this is ${Uri.parse(extensionStoreAddress).host}. To use your own, enter its address and the public key '
          '(store.pub) its catalogue is signed with. Only use a store you trust.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (_loaded) ...[
          TextField(key: const ValueKey('store-address'), controller: _address, decoration: InputDecoration(labelText: tr('Store address'), hintText: 'https://store.example.org', isDense: true, border: const OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(key: const ValueKey('store-key'), controller: _key, decoration: InputDecoration(labelText: tr('Public key (base64)'), isDense: true, border: const OutlineInputBorder())),
          if (_problem != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(tr(_problem!), style: TextStyle(color: scheme.error, fontSize: 13))),
          if (_note != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(tr(_note!), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton(key: const ValueKey('store-source-save'), onPressed: _save, child: const Text('Use this store')),
            if (!_saved.isBuiltIn || _address.text.isNotEmpty || _key.text.isNotEmpty) OutlinedButton(key: const ValueKey('store-source-reset'), onPressed: _reset, child: const Text('Use the built-in store')),
          ]),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}
