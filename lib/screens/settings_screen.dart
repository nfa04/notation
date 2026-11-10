
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import '../speech/speech_to_text.dart';
import '../mcp/mcp_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

import '../data/note_repository.dart';
import '../ink/glm_ocr_service.dart' show GlmQuality;
import '../ink/handwriting_service.dart';
import '../export/pdf_ink_text.dart' show pdfInkTextSetting;
import '../search/ink_indexer.dart';
import '../images/subject_service.dart';
import '../scan/ocr_service.dart';
import '../style/accessibility.dart';
import '../style/refresh_rate.dart' show refreshRateAdjustable;
import '../style/stylus_settings.dart';
import 'about_settings.dart';
import 'stylus_settings_card.dart';
import 'accessibility_settings.dart';
import 'pdf_quality_settings.dart';
import 'refresh_rate_settings.dart';
import '../ink/ink_recognizer.dart';
import '../ink/math_service.dart';
import '../ai/ai_prompt.dart';
import '../ai/ai_service.dart';
import '../ai/ai_switch.dart';
import '../ai/openai_provider.dart';
import '../ai/text_provider.dart';
import '../collab/collab_service.dart';
import '../collab/ice_settings.dart';
import '../data/note_file_service.dart';
import '../llm/embedding_service.dart';
import 'note_file_actions.dart';
import 'share_storage_settings.dart';
import 'shortcut_settings.dart';
import '../shortcuts/shortcut_service.dart';
import 'share_people.dart';
import 'profile_settings.dart';
import 'sync_settings.dart';
import '../devicesync/device_sync_service.dart';
import 'spell_settings.dart';
import 'extension_settings.dart';
import '../automations/automation_service.dart';
import '../extensions/extension_service.dart';
import '../spelling/spell_service.dart';
import '../citations/citation_library_screen.dart';
import '../citations/citation_service.dart';
import '../features/feature.dart';
import '../profile/user_profile.dart';
import '../llm/llm_service.dart';
import '../style/app_theme.dart';
import '../style/platform_look.dart';
import '../style/calendar_style.dart';

part 'settings_live.dart';
part 'settings_ai.dart';
part 'settings_mcp.dart';

/// Settings that apply to the whole app. (How the calendar is dressed up has
/// its own place: the palette button in the Calendar tab.)
class SettingsScreen extends StatelessWidget {
  final AppTheme theme;
  final HandwritingService? handwriting;

  /// Where the notes are kept (for the setting that makes handwriting searchable); null hides that setting.
  final NoteRepository? repository;

  /// The text reader for pictures (scanned pages).
  final OcrService? ocr;

  /// Finds the subject of a picture; null: not offered.
  final SubjectService? subject;

  /// Speech to text (Whisper); null hides the section.
  final SpeechToText? speech;

  /// Text size, contrast and motion; null hides the section.
  final AccessibilitySettings? accessibility;

  /// The pen; null hides the section.
  final StylusSettings? stylus;

  /// The keyboard shortcuts; null hides the section.
  final ShortcutService? shortcuts;
  final MathService? math;
  final LlmService? llm;
  final EmbeddingService? embeddings;
  final DeviceSyncService? sync;
  final NoteFileService? noteFiles;
  final CollabService? collab;

  /// Opens a note (after one was made from a file).
  final ValueChanged<String>? onOpenNote;
  final AiService? ai;

  /// The kill switch for all AI features; null hides it.
  final AiSwitch? aiSwitch;

  /// Which tools are on; null hides the section.
  final FeatureSettings? features;

  /// The library of sources and the citation style; null hides it.
  final CitationService? citations;

  /// Who the person is; null hides the section.
  final UserProfile? profile;

  /// The spelling dictionaries; null hides the section.
  final SpellService? spell;

  /// The extensions; null hides the section.
  final ExtensionService? extensions;

  /// Lets an AI agent on this computer use the notes; null hides the section (a phone, a test).
  final McpService? mcp;

  /// The automations (the rules *Create with AI* adds for the actions of a new extension); null: none.
  final AutomationService? automations;

  const SettingsScreen({super.key, required this.theme, this.handwriting, this.repository, this.math, this.llm, this.embeddings, this.noteFiles, this.collab, this.onOpenNote, this.ai, this.aiSwitch, this.features, this.citations, this.profile, this.spell, this.ocr, this.subject, this.speech, this.accessibility, this.stylus, this.shortcuts, this.extensions, this.automations, this.sync, this.mcp});

  /// The sections of the settings, by category: each is a tab (a category with nothing in it is left out).
  List<({String label, IconData icon, List<Widget> sections})> _categories(BuildContext context) {
    Widget title(String text) => Text(text, style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold));
    return [
      (
        label: 'General',
        icon: Icons.tune,
        sections: [
          title('Appearance'),
          const SizedBox(height: 16),
          const Text('Accent color'),
          const SizedBox(height: 4),
          Text(
            'Colors the buttons, selections and markers in every part of the app.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in [AppTheme.defaultAccent, ...swatchColors]) _swatch(context, c),
          ]),
          const SizedBox(height: 20),
          // what the accent looks like in use
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
            ),
            child: Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton(onPressed: () {}, child: const Text('Button')),
              OutlinedButton(onPressed: () {}, child: const Text('Button')),
              Switch.adaptive(value: true, onChanged: (_) {}),
              Checkbox.adaptive(value: true, onChanged: (_) {}),
              Chip(label: const Text('Chip'), backgroundColor: Theme.of(context,).colorScheme.primaryContainer),
            ]
            ),
          ),
          const SizedBox(height: 20),
          const Text('Platform look'),
          const SizedBox(height: 4),
          Text(
            'Automatic dresses the app like an iPhone app on an iPhone or iPad, and like a Material app elsewhere. Pick one to see it on any device.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<PlatformLook>(
            key: const ValueKey('platform-look'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: PlatformLook.automatic,
                label: Text(tr('Automatic')),
              ),
              ButtonSegment(
                value: PlatformLook.material,
                label: Text(tr('Material')),
              ),
              const ButtonSegment(
                value: PlatformLook.ios,
                label: Text.verbatim('iOS'),
              ),
            ],
            selected: {theme.look},
            onSelectionChanged: (v) => theme.setLook(v.first),
          ),
          if (repository != null && refreshRateAdjustable) ...[
            const SizedBox(height: 20),
            RefreshRateSettings(repository: repository!),
          ],
          const SizedBox(height: 28),
          const _LanguageSettings(),
          if (accessibility != null) ...[
            const SizedBox(height: 28),
            AccessibilitySettingsCard(settings: accessibility!),
          ],
          if (profile != null) ...[
            const SizedBox(height: 28),
            ProfileSettings(profile: profile!, onIntro: () => profile!.resetIntro()),
          ],
          if (sync != null) ...[
            const SizedBox(height: 28),
            SyncSettings(service: sync!),
          ],
          const SizedBox(height: 28),
          Text(
            'Colors, borders and emoji for the calendar itself are set in the Calendar tab, '
            'with the palette button at the top.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 28),
          const AboutSettings(),
        ],
      ),
      (
        label: 'Tools and writing',
        icon: Icons.build_outlined,
        sections: [
          if (stylus != null) ...[
            StylusSettingsCard(settings: stylus!),
            const SizedBox(height: 28),
          ],
          if (repository != null) ...[
            PdfQualitySettings(repository: repository!),
            const SizedBox(height: 28),
            const SizedBox(height: 28),
          ],
          if (features != null) ToolSettings(features: features!),
          if (citations != null && (features?.on(Feature.citations) ?? true)) ...[
            if (features != null) const SizedBox(height: 28),
            CitationSettings(service: citations!),
          ],
          if (spell != null && (features?.on(Feature.spelling) ?? true)) ...[
            if (features != null) const SizedBox(height: 28),
            SpellSettings(service: spell!),
          ],
        ],
      ),
      (
        label: 'Keyboard',
        icon: Icons.keyboard_outlined,
        sections: [if (shortcuts != null) ShortcutSettings(service: shortcuts!)],
      ),
      (
        label: 'AI and models',
        icon: Icons.auto_awesome_outlined,
        sections: [
          ..._spaced([
            if (aiSwitch != null) _AiSwitchCard(aiSwitch: aiSwitch!),
            if (handwriting != null) _HandwritingSettings(service: handwriting!, repository: repository),
            if (math != null) _MathSettings(service: math!),
            if (ocr != null) _OcrSettings(service: ocr!),
            if (subject != null && (features?.on(Feature.pictureEdit) ?? true))
              _ModelSettings(
                service: subject!,
                title: 'Subjects in pictures',
                description: 'Finds the person, animal or object in a photograph, so that "Find the subject" in the picture editor can take the '
                    'background out. It runs on this device (U²-Net, Apache-2.0 licence); nothing is sent away.',
              ),
            if (ai != null) _AiSettings(ai: ai!),
            if (llm != null)
              _ModelSettings(
                service: llm!,
                title: 'Language model',
                description: 'Writes short titles for the tasks that automations make from dates in a PDF '
                    '(Qwen3-0.6B, Apache-2.0 licence). It runs on this device and nothing is sent away; '
                    'it is loaded only while it works. It needs a fair amount of memory while it does.',
              ),
            if (embeddings != null) _EmbeddingSettings(service: embeddings!),
            if (speech != null) _SpeechSettings(service: speech!),
          ]),
        ],
      ),
      (
        label: 'Extensions',
        icon: Icons.extension_outlined,
        sections: [
          ..._spaced([
            if (extensions != null) ExtensionSettings(service: extensions!, ai: aiSwitch?.enabled ?? true ? ai : null, automations: automations),
            if (mcp != null) _McpSettings(service: mcp!),
          ]),
        ],
      ),
      (
        label: 'Sharing and files',
        icon: Icons.group_outlined,
        sections: [
          ..._spaced([
            if (collab != null) _LiveSettings(service: collab!),
            if (collab?.cloudShare != null) ShareStorageSettings(share: collab!.cloudShare!),
            if (collab?.nativeShares != null) NativeShareSettings(service: collab!.nativeShares!),
            if (noteFiles != null) _NoteFilesSettings(service: noteFiles!, onOpenNote: onOpenNote),
          ]),
        ],
      ),
    ].where((c) => c.sections.isNotEmpty).toList();
  }

  /// [sections] with space between them.
  static List<Widget> _spaced(List<Widget> sections) => [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 28),
          sections[i],
        ],
      ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) {
        final categories = _categories(context);
        Widget page(List<Widget> sections) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(padding: const EdgeInsets.all(24), children: sections),
              ),
            );
        return DefaultTabController(
          length: categories.length,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
              // (a single category needs no tabs)
              bottom: categories.length < 2
                  ? null
                  : TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [for (final c in categories) Tab(key: ValueKey('settings-tab-${c.label}'), icon: Icon(c.icon, size: 20), text: tr(c.label))],
                    ),
            ),
            body: TabBarView(
              key: const ValueKey('settings-tabs'),
              children: [for (final c in categories) page(c.sections)],
            ),
          ),
        );
      },
    );
  }

  Widget _swatch(BuildContext context, Color color) {
    final selected = color == theme.accent;
    return Tooltip(
      message: color == AppTheme.defaultAccent ? tr('Original blue') : '',
      child: InkWell(
        key: ValueKey('accent-${color.toARGB32()}'),
        customBorder: const CircleBorder(),
        onTap: () => theme.setAccent(color),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected ? Theme.of(context).colorScheme.onSurface : Colors.black26,
              width: selected ? 3 : 1,
            ),
          ),
          child: selected ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
        ),
      ),
    );
  }
}

/// Download, status and removal of a recognition model.
class _ModelSettings extends StatelessWidget {
  final DownloadableModel service;
  final String title;
  final String description;

  const _ModelSettings({required this.service, required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final installed = service.status == HandwritingStatus.installed;
        final downloading = service.status == HandwritingStatus.downloading;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text.verbatim(tr('{description} It needs a model of about {size} MB.', {'description': tr(description), 'size': service.sizeMb}),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 12),
          if (downloading)
            Row(children: [
              Expanded(child: LinearProgressIndicator(value: service.progress > 0 ? service.progress : null)),
              const SizedBox(width: 12),
              Text('${(service.progress * 100).round()}%'),
            ])
          else
            Row(children: [
              Icon(installed ? Icons.check_circle_outline : Icons.download_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(installed ? 'Model installed' : 'Model not installed')),
              if (installed)
                TextButton(onPressed: service.remove, child: const Text('Remove'))
              else
                FilledButton(onPressed: service.install, child: const Text('Download')),
            ]),
          if (service.error != null) ...[
            const SizedBox(height: 8),
            Text.verbatim(tr('Download failed: {error}', {'error': service.error}), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]);
      },
    );
  }
}

/// Note files (.uninote): what they are, and opening one.
class _NoteFilesSettings extends StatelessWidget {
  final NoteFileService service;
  final ValueChanged<String>? onOpenNote;

  const _NoteFilesSettings({required this.service, this.onOpenNote});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Note files', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'A note can be saved as one file (.uninote, a ZIP with the text, the strokes, pictures and the PDF) to keep, '
          'send, or open on another device: use "Save this note as a file" in the note, or the menu of a note. '
          'To have a file made by itself whenever a note was changed (into a folder that a sync program watches, '
          'say), add the automation "Save the note as a file" in the Automations tab.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('note-files-open'),
            onPressed: () async {
              final id = await openNoteFile(context, service);
              if (id != null) onOpenNote?.call(id);
            },
            icon: const Icon(Icons.file_open_outlined, size: 18),
            label: const Text('Open a note file...'),
          ),
        ),
      ]);
}

/// The sentence model that automations use to file notes by what they say, and which one.
class _EmbeddingSettings extends StatelessWidget {
  final EmbeddingService service;

  const _EmbeddingSettings({required this.service});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _ModelSettings(
            service: service,
            title: 'Sentence model',
            description: 'Reads the meaning of a note with a small language model (a sentence transformer, Apache-2.0 licence). '
                'It files notes by the automation "Move the note to the folder it fits best", finds the passages that answer a '
                'question across all notes, and makes the graph follow the meaning. It runs on this device; nothing is sent away.',
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
          showSelectedIcon: false,
            key: const ValueKey('embedding-model'),
            segments: [for (final s in service.specs) ButtonSegment(value: s.id, label: Text.verbatim('${tr(s.label)} (${s.modelMb + s.tokenizerMb} MB)'))],
            selected: {service.spec.id},
            onSelectionChanged: (v) => service.select(service.specs.firstWhere((s) => s.id == v.first)),
          ),
          const SizedBox(height: 6),
          Text(service.spec.description, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        ]),
      );
}

/// Writing down what is said: the Whisper model and the language.
class _SpeechSettings extends StatelessWidget {
  final SpeechToText service;

  const _SpeechSettings({required this.service});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _ModelSettings(
            service: service,
            title: 'Speech to text',
            description: 'Record a meeting on the dashboard, or dictate into a note, and what is said is written down. It happens on '
                'this device (Whisper, MIT and Apache-2.0 licences); the sound is never sent away and not kept.',
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
          showSelectedIcon: false,
            key: const ValueKey('speech-model'),
            segments: [for (final s in service.specs) ButtonSegment(value: s.id, label: Text.verbatim('${tr(s.label)} (${s.files.values.fold<int>(0, (a, f) => a + f.megabytes)} MB)'))],
            selected: {service.spec.id},
            onSelectionChanged: (v) => service.select(service.specs.firstWhere((s) => s.id == v.first)),
          ),
          const SizedBox(height: 6),
          Text(service.spec.description, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Language spoken'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<String?>(
                key: const ValueKey('speech-language'),
                isExpanded: true,
                value: service.language,
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(tr('Find out by listening'))),
                  for (final e in speechLanguages.entries) DropdownMenuItem<String?>(value: e.key, child: Text.verbatim(e.value)),
                ],
                onChanged: service.setLanguage,
              ),
            ),
          ]),
        ]),
      );
}

class _HandwritingSettings extends StatelessWidget {
  final HandwritingService service;
  final NoteRepository? repository;

  const _HandwritingSettings({required this.service, this.repository});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _ModelSettings(
          service: service,
          title: 'Handwriting',
          description: 'Select drawings with the lasso and choose "Convert handwriting to text". Reading happens on '
              'this device; nothing is sent away.',
        ),
        ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
            final readers = [
              HandwritingReader.glm,
              if (service.paddle != null) HandwritingReader.paddle,
            ];
            final busy = service.status == HandwritingStatus.downloading;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (readers.length > 1) ...[
                const SizedBox(height: 16),
                Text(tr('Which model reads the handwriting'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final r in readers)
                    ChoiceChip(
                      key: ValueKey('handwriting-reader-${r.name}'),
                      label: Text.verbatim(switch (r) {
                        HandwritingReader.glm => 'GLM-OCR',
                        HandwritingReader.paddle => 'PaddleOCR-VL',
                      }),
                      selected: service.reader == r,
                      onSelected: busy ? null : (_) => service.setReader(r),
                    ),
                ]),
              ],
              const SizedBox(height: 8),
              Text(
                switch (service.reader) {
                  HandwritingReader.glm => tr(
                      'GLM-OCR (MIT licence) reads each line of your writing as a picture, with the knowledge of a language model about which words are likely: far better than the others on German and English notes. About 800 MB to download and two to three gigabytes of memory while it reads; it may correct a word to English or write maths as LaTeX.',
                    ),
                  HandwritingReader.paddle => tr(
                      'PaddleOCR-VL (Apache 2.0 licence) is a much bigger model: about 900 MB to download, a gigabyte or two of memory while it reads, and slow on a tablet. It reads each line of your writing as a picture, with the knowledge of a language model about which words are likely.',
                    ),
                },
                style: muted,
              ),
              if (service.reader == HandwritingReader.glm) ...[
                const SizedBox(height: 12),
                Text(tr('How carefully it looks'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final q in GlmQuality.values)
                    ChoiceChip(
                      key: ValueKey('handwriting-quality-${q.name}'),
                      label: Text(switch (q) {
                        GlmQuality.standard => tr('Standard'),
                        GlmQuality.quick => tr('Quick'),
                        GlmQuality.light => tr('Light'),
                      }),
                      selected: service.quality == q,
                      onSelected: (_) => service.setQuality(q),
                    ),
                ]),
                const SizedBox(height: 8),
                Text(
                  tr('Quick takes about two thirds of the time and reads a little less exactly. Light takes less than half of it and reads clearly less exactly: for a slow device.'),
                  style: muted,
                ),
              ],
            ]);
          },
        ),
        if (repository != null) _InkIndexSwitch(repository: repository!),
        if (repository != null) _PdfInkTextSwitch(repository: repository!),
      ]);
}

/// Whether the handwriting of a note is read while it is open, so that the search finds it.
class _InkIndexSwitch extends StatefulWidget {
  final NoteRepository repository;
  const _InkIndexSwitch({required this.repository});

  @override
  State<_InkIndexSwitch> createState() => _InkIndexSwitchState();
}

class _InkIndexSwitchState extends State<_InkIndexSwitch> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    widget.repository.settings.get(inkIndexSetting).then((v) {
      if (mounted) setState(() => _on = v != '0');
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
        key: const ValueKey('index-handwriting'),
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Make handwriting searchable')),
        subtitle: Text(tr('Reads the writing of a note while it is open, so that the search finds it. Notes that were not opened since can be read all at once by an automation (when the app starts).')),
        value: _on,
        onChanged: (v) {
          setState(() => _on = v);
          widget.repository.settings.set(inkIndexSetting, v ? '1' : '0');
        },
      );
}

/// Whether an exported PDF has the text of the handwriting under it, so that a viewer can select and search it.
class _PdfInkTextSwitch extends StatefulWidget {
  final NoteRepository repository;
  const _PdfInkTextSwitch({required this.repository});

  @override
  State<_PdfInkTextSwitch> createState() => _PdfInkTextSwitchState();
}

class _PdfInkTextSwitchState extends State<_PdfInkTextSwitch> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    widget.repository.settings.get(pdfInkTextSetting).then((v) {
      if (mounted) setState(() => _on = v != '0');
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
        key: const ValueKey('pdf-handwriting-text'),
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Make handwriting selectable in exported PDFs')),
        subtitle: Text(tr('Puts what the writing says under it, out of sight, so that a PDF viewer can select, copy and search it. What was not read yet is read while the PDF is made (up to a minute).')),
        value: _on,
        onChanged: (v) {
          setState(() => _on = v);
          widget.repository.settings.set(pdfInkTextSetting, v ? '1' : '0');
        },
      );
}

/// The text reader for pictures: which script, and the models.
class _OcrSettings extends StatelessWidget {
  final OcrService service;

  const _OcrSettings({required this.service});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _ModelSettings(
            service: service,
            title: 'Text in pictures',
            description: 'Reads the printed text in a scanned page or a picture (scan from the picture button of a note). '
                'Reading happens on this device (PaddleOCR, Apache-2.0 licence); nothing is sent away.',
          ),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Script'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<OcrLanguage>(
                key: const ValueKey('ocr-language'),
                isExpanded: true,
                value: service.language,
                items: [for (final l in OcrLanguage.all) DropdownMenuItem(value: l, child: Text.verbatim(l.name, overflow: TextOverflow.ellipsis))],
                onChanged: service.status == HandwritingStatus.downloading ? null : (l) => service.setLanguage(l!),
              ),
            ),
          ]),
        ]),
      );
}

class _MathSettings extends StatelessWidget {
  final MathService service;

  const _MathSettings({required this.service});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final busy = service.status == HandwritingStatus.downloading;
          final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _ModelSettings(
              service: service,
              title: 'Formulas',
              description: 'Select a handwritten formula with the lasso and choose "Convert a handwritten formula to '
                  'LaTeX". Reading happens on this device; nothing is sent away.',
            ),
            const SizedBox(height: 16),
            Text(tr('Which model reads the formulas'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in FormulaModel.values)
                ChoiceChip(
                  key: ValueKey('math-model-${m.name}'),
                  label: Text.verbatim(m == FormulaModel.texteller ? 'TexTeller' : 'Pix2Text'),
                  selected: service.model == m,
                  onSelected: busy ? null : (_) => service.choose(m),
                ),
            ]),
            const SizedBox(height: 8),
            Text(
              service.model == FormulaModel.texteller
                  ? tr('TexTeller (Apache 2.0 licence) reads handwriting far better, but is bigger and slower. It suits a computer or a fast tablet.')
                  : tr('Pix2Text (MIT licence) is lighter and quicker, but made for printed formulas and poor at handwriting. Use it if the device is slow or short of memory.'),
              style: muted,
            ),
          ]);
        },
      );
}


/// Which language the app is shown in: the device's, or one of its own.
class _LanguageSettings extends StatelessWidget {
  const _LanguageSettings();

  @override
  Widget build(BuildContext context) {
    final language = AppLanguage.instance;
    return ListenableBuilder(
      listenable: language,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Language', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('The language of the menus and messages. By default the language of the device is used.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final choice in ['system', ...AppLanguage.names.keys])
            ChoiceChip(
              key: ValueKey('language-$choice'),
              label: Text.verbatim(choice == 'system' ? tr('Device language') : AppLanguage.names[choice]!),
              selected: language.choice == choice,
              onSelected: (_) => language.choose(choice),
            ),
        ]),
      ]),
    );
  }
}
