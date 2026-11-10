import 'package:flutter/material.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../ink/ink_recognizer.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../spelling/spell_service.dart';

/// Settings: the languages that are spell-checked (each is a dictionary downloaded on request) and the person's own words.
class SpellSettings extends StatefulWidget {
  final SpellService service;

  const SpellSettings({super.key, required this.service});

  @override
  State<SpellSettings> createState() => _SpellSettingsState();
}

class _SpellSettingsState extends State<SpellSettings> {
  final _word = TextEditingController();

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  Future<void> _addWord() async {
    final w = _word.text.trim();
    if (w.isEmpty) return;
    _word.clear();
    await widget.service.addWord(w);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final service = widget.service;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Spell checking', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Misspelled words get a wavy red line in text boxes and the written document; tap one for suggestions. A word is right if the dictionary of any language that is on takes it, '
            'so a note in two languages works. The dictionaries are the Hunspell dictionaries of the LibreOffice project, downloaded when you turn a language on (they are not part of the app and '
            'have licences of their own). Everything is checked on this device.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            'Suggestions are put in order with a list of the most common words of the language (FrequencyWords by Hermit Dave, from film and television subtitles, licence CC BY-SA 4.0), '
            'downloaded with the dictionary.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final pack in service.packs) _languageTile(context, service, pack),
          const SizedBox(height: 16),
          Text(tr('Your own words'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final w in service.checker.personal.toList()..sort())
              InputChip(
                key: ValueKey('spell-word-$w'),
                label: Text.verbatim(w),
                onDeleted: () => service.removeWord(w),
              ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('spell-new-word'),
                controller: _word,
                decoration: InputDecoration(hintText: tr('Add a word'), isDense: true),
                onSubmitted: (_) => _addWord(),
              ),
            ),
            IconButton(key: const ValueKey('spell-add-word'), onPressed: _addWord, icon: const Icon(Icons.add), tooltip: tr('Add a word')),
          ]),
        ]);
      },
    );
  }

  Widget _languageTile(BuildContext context, SpellService service, DictionaryPack pack) {
    final l = pack.language;
    final downloading = pack.status == HandwritingStatus.downloading;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      SwitchListTile.adaptive(
        key: ValueKey('spell-${l.id}'),
        contentPadding: EdgeInsets.zero,
        title: Text.verbatim(l.name),
        subtitle: Text.verbatim([
          if (!pack.installed) tr('Download about {size} MB', {'size': l.megabytes}) else tr('On this device'),
          tr('Licence: {licence}', {'licence': l.licence ?? tr('see the README')}),
          if (pack.error != null) pack.error!,
        ].join(' · ')),
        value: service.isOn(l),
        onChanged: downloading ? null : (v) => service.setOn(l, v),
        secondary: pack.installed
            ? IconButton(key: ValueKey('spell-delete-${l.id}'), icon: const Icon(Icons.delete_outline), tooltip: tr('Delete the dictionary'), onPressed: () => service.delete(l))
            : null,
      ),
      if (downloading) LinearProgressIndicator(value: pack.progress == 0 ? null : pack.progress),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: scheme.onSurfaceVariant),
          onPressed: () => launchUrl(Uri.parse(l.pageUrl), mode: LaunchMode.externalApplication),
          child: Text(tr('Licence and README')),
        ),
      ),
    ]);
  }
}
