import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;

import '../data/settings_repository.dart';
import '../features/feature.dart';
import '../features/toolbar_profiles.dart';
import '../ink/ink_recognizer.dart' show HandwritingStatus;
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../profile/user_profile.dart';
import '../widgets/notation_logo.dart';
import '../devicesync/device_sync_service.dart';
import 'cloud_sign_in_ui.dart';
import 'intro_look.dart';
import 'intro_models.dart';
import 'sync_settings.dart';
import 'tool_list.dart';

/// What the app asks the first time it is opened: a name (for sessions and the history of notes), what it is used for,
/// and, from that, which tools to switch on, which can be adjusted before it starts. Skipping it at any point leaves
/// everything on. When it is done, [onDone] is called (the profile then says the intro is done).
class IntroScreen extends StatefulWidget {
  final UserProfile profile;
  final FeatureSettings features;

  /// Offers to take over the profile of another device instead of making a new one; null: not offered.
  final DeviceSyncService? sync;

  /// Where the toolbar profiles are kept; null: none are offered.
  final SettingsRepository? settings;

  /// The AI features and the models to download for them (a step of its own); null: not asked.
  final IntroSmart? smart;

  /// Makes the note that shows the tools (given the tools that are on); null: it is not offered.
  final Future<void> Function(Set<Feature> tools)? welcome;

  /// The language, colour and pen (a step of its own); null: not asked.
  final IntroLook? look;

  const IntroScreen({super.key, required this.profile, required this.features, this.sync, this.settings, this.smart, this.welcome, this.look});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

enum _Step { welcome, name, uses, tools, smart, look, storage }

class _IntroScreenState extends State<IntroScreen> {
  /// The steps, in order (the ones that need something the app was not given are left out).
  List<_Step> get _order => [
        _Step.welcome,
        _Step.name,
        _Step.uses,
        _Step.tools,
        if (widget.smart != null && widget.smart!.models.isNotEmpty) _Step.smart,
        if (widget.look != null) _Step.look,
        if (widget.sync != null && widget.look != null) _Step.storage,
      ];
  int get _steps => _order.length;
  int _step = 0;
  late final _name = TextEditingController(text: widget.profile.name);
  late final Set<UseArea> _areas = {...widget.features.areas};
  // (the intro again, from the settings: it starts from what is set)
  late Set<Feature> _tools = {...widget.features.enabled};
  late bool _everything = widget.features.allOn && widget.features.areas.isEmpty;
  bool _busy = false;

  /// The AI features on or off (the kill switch of the settings), and which models to download (null: not looked at yet, so
  /// what the tools call for).
  bool _ai = true;

  /// Whether to make the note that shows the tools.
  bool _welcomeNote = true;
  Set<String>? _download;
  Set<String> get _downloads => _download ??= widget.smart?.defaultsFor(_tools) ?? {};

  /// Whether to make a toolbar profile for each use (offered when the uses are of different kinds).
  bool _profiles = false;

  bool get _offerProfiles => widget.settings != null && UseArea.unrelated(_areas);

  /// Whether the device is on mobile data (the download is then better left for Wi-Fi); false until known.
  bool _mobile = false;

  @override
  void initState() {
    super.initState();
    widget.smart?.onMobileData?.call().then((v) {
      if (mounted && v) setState(() => _mobile = true);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Joins the profile of another device; the intro is then done.
  Future<void> _syncFromDevice() async {
    final joined = await showJoinDialog(context, widget.sync!);
    if (!joined) return;
    // the profile of the other device has its name, settings and tools already: nothing is left to ask
    await widget.profile.finishIntro();
  }

  /// Signs in to the profile with the cloud folder and the recovery key; the intro is then done.
  Future<void> _signInWithFolder() async {
    if (!await showCloudSignInDialog(context, widget.sync!.cloud!)) return;
    await widget.profile.finishIntro();
  }

  /// Web: a computer that is not the person's own, connected for a while through a code the phone scans.
  Future<void> _connectTemporarily() async {
    if (!await showConnectDialog(context, widget.sync!)) return;
    await widget.profile.finishIntro();
  }

  void _chooseAreas() {
    // the tools follow what was chosen; "everything" is the same as choosing nothing
    _tools = _areas.isEmpty ? FeaturePresets.everything : FeaturePresets.forAreas(_areas);
    _everything = _areas.isEmpty;
    _download = null;
  }

  Future<void> _finish({required bool skipped}) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.profile.setName(_name.text);
    if (!skipped) await widget.features.apply(_tools, areas: _areas);
    if (!skipped && _profiles && _offerProfiles) await _makeProfiles();
    if (!skipped) await widget.smart?.apply(aiOn: _ai, download: _downloads);
    if (!skipped && _welcomeNote) await widget.welcome?.call(_tools);
    await widget.profile.finishIntro();
  }

  /// A toolbar profile for each use. Profiles the person made before (the intro again, from the settings) stay, and so does the one
  /// in use; a profile made by an earlier intro for the same use is made again.
  Future<void> _makeProfiles() async {
    final settings = widget.settings!;
    final made = profilesForAreas(_areas, (a) => tr(a.shortTitle));
    final before = decodeToolbarProfiles(await settings.get('toolbar_profiles'));
    final ids = {for (final p in made) p.id};
    final all = [...before.profiles.where((p) => !ids.contains(p.id)), ...made];
    await settings.set('toolbar_profiles', encodeToolbarProfiles(all, before.profiles.isEmpty ? made.first.id : before.active));
  }

  void _next() {
    final here = _order[_step];
    if (here == _Step.name) widget.profile.setName(_name.text);
    // the downloads start when the models have been chosen, and go on while the next steps are answered
    if (here == _Step.smart) widget.smart?.apply(aiOn: _ai, download: _downloads);
    if (_step + 1 >= _steps) {
      _finish(skipped: false);
    } else {
      setState(() => _step++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = _step == _steps - 1;
    return Scaffold(
      key: const ValueKey('intro'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  for (var i = 0; i < _steps; i++)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: i <= _step ? scheme.primary : scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                ]),
                const SizedBox(height: 24),
                Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_page(context), if (last) _welcomeOffer()]))),
                if (widget.smart != null) _DownloadBanner(smart: widget.smart!),
                const SizedBox(height: 12),
                Row(children: [
                  TextButton(
                    key: const ValueKey('intro-skip'),
                    onPressed: _busy ? null : () => _finish(skipped: true),
                    child: const Text('Skip, show everything'),
                  ),
                  const Spacer(),
                  if (_step > 0) TextButton(key: const ValueKey('intro-back'), onPressed: _busy ? null : () => setState(() => _step--), child: const Text('Back')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('intro-next'),
                    onPressed: _busy ? null : _next,
                    child: Text(last ? 'Start' : (_step == 0 ? 'Get started' : 'Next')),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = Theme.of(context,).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold);
    final hint = TextStyle(color: scheme.onSurfaceVariant);
    switch (_order[_step]) {
      case _Step.welcome:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const NotationLogo( size: 72),
          const SizedBox(height: 16),
          Text('Welcome to Notation', style: title),
          const SizedBox(height: 12),
          Text('Notes you write and draw, PDFs you annotate, and notes you work on together with others.', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Text('Three quick questions make it fit you: what to call you, what you use it for, and which tools you want to see. You can change all of it later in the settings.', style: hint),
          if (widget.sync != null) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.devices_outlined, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Already use Notation on another device?', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('Sync this device with it: the same id and name, notes, folders and settings.', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('intro-sync'),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Use a link from that device'),
                      onPressed: _syncFromDevice,
                    ),
                          if (widget.sync!.cloud != null) ...[
                            const SizedBox(height: 6),
                            OutlinedButton.icon(
                              key: const ValueKey('intro-signin'),
                              icon: const Icon(
                                Icons.cloud_download_outlined,
                                size: 18,
                              ),
                              label: const Text(
                                'Sign in with your cloud folder',
                              ),
                              onPressed: _signInWithFolder,
                            ),
                          ],
                    if (kIsWeb) ...[
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        key: const ValueKey('intro-connect'),
                        icon: const Icon(Icons.qr_code_2, size: 18),
                        label: const Text('Connect temporarily'),
                        onPressed: _connectTemporarily,
                      ),
                    ],
                  ]),
                ),
              ]),
            ),
          ],
        ]);
      case _Step.name:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What should we call you?', style: title),
          const SizedBox(height: 12),
          Text('Other people see this name when you work on a note together, and it goes on what you add to a note, so the history can show who wrote what.', style: hint),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('intro-name'),
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr('Your name'), border: const OutlineInputBorder()),
            onSubmitted: (_) => _next(),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.fingerprint, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.verbatim(tr('Your id: {id}', {'id': widget.profile.id}), key: const ValueKey('intro-id'), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Made for you now and kept. If two people with the same name work together, it tells them apart. It is not a password.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Text('You can leave the name empty and set it later.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]);
      case _Step.uses:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What will you use Notation for?', style: title),
          const SizedBox(height: 12),
          Text('Choose as many as fit. What you will not need is put out of the way (you decide in the next step).', style: hint),
          const SizedBox(height: 20),
          UseAreaChips(
            chosen: _areas,
            onChanged: (area, chosen) => setState(() {
              chosen ? _areas.add(area) : _areas.remove(area);
              _chooseAreas();
            }),
          ),
          if (_offerProfiles) ...[
            const SizedBox(height: 20),
            Material(
              key: const ValueKey('intro-profiles-offer'),
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.dashboard_customize_outlined, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Do you use these one at a time?', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('Then give each its own toolbar profile: one tap changes the toolbars to the tools of that use only (drawing without the maths tools, and the other way around). All of them stay available; you can change the profiles whenever you like.', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  ]),
                  SwitchListTile.adaptive(
                    key: const ValueKey('intro-profiles'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(tr('Make a profile for each: {names}', {'names': [for (final a in UseArea.values) if (_areas.contains(a) && a != UseArea.together) tr(a.shortTitle)].join(', ')})),
                    value: _profiles,
                    onChanged: (v) => setState(() => _profiles = v),
                  ),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const ValueKey('intro-everything'),
            onPressed: _everything && _areas.isEmpty
                ? null
                : () => setState(() {
                      _areas.clear();
                      _chooseAreas();
                    }),
            icon: const Icon(Icons.done_all, size: 18),
            label: const Text('Show me everything'),
          ),
          if (_everything && _areas.isEmpty) ...[
            const SizedBox(height: 8),
            Text('Every tool stays on.', key: const ValueKey('intro-everything-on'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ]);
      case _Step.smart:
        return _smartPage(context, title, hint);
      case _Step.look:
        return IntroLookPage(look: widget.look!);
      case _Step.storage:
        return _storagePage(context, title, hint);
      case _Step.tools:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your tools', style: title),
          const SizedBox(height: 12),
          Text('Chosen from what you told us. Switch any of them on or off; the settings can change this whenever you like.', style: hint),
          if (_profiles && _offerProfiles) ...[
            const SizedBox(height: 8),
            Text('Each toolbar profile uses its own share of these tools; what you switch off here is off in all of them.', key: const ValueKey('intro-profiles-note'), style: hint),
          ],
          const SizedBox(height: 8),
          ToolList(
            selected: _tools,
            onChanged: (f, on) => setState(() {
              _download = null;
              _tools = {..._tools};
              on ? _tools.add(f) : _tools.remove(f);
            }),
          ),
        ]);
    }
  }

  /// Where the notes are kept, and the way to keep them on more than one device.
  Widget _storagePage(BuildContext context, TextStyle? title, TextStyle hint) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Where your notes live', style: title),
      const SizedBox(height: 12),
      Text('Your notes are kept on this device, in the app. Nothing is sent anywhere unless you set it up.', style: hint),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.devices_outlined, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Use it on more than one device?', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Link this device with your others to keep the notes, folders and settings the same on all of them.', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('intro-set-up-sync'),
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Set up syncing'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(tr('Syncing'))),
                    body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: SyncSettings(service: widget.sync!))),
                  ),
                )),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Text('Not now is fine: it is in the settings whenever you want it.', style: hint),
    ]);
  }

  /// The offer of a note that shows the tools, at the end of the last step.
  Widget _welcomeOffer() => widget.welcome == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 16),
          child: SwitchListTile.adaptive(
            key: const ValueKey('intro-welcome-note'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.note_add_outlined),
            title: Text('Make a note that shows the tools'),
            subtitle: Text('One page, with the tools you chose on it, to try them on. You can delete it.'),
            value: _welcomeNote,
            onChanged: (v) => setState(() => _welcomeNote = v),
          ),
        );

  /// The AI switch and the models behind it, each with its size and a box to tick.
  Widget _smartPage(BuildContext context, TextStyle? title, TextStyle hint) {
    final scheme = Theme.of(context).colorScheme;
    final smart = widget.smart!;
    final mb = [for (final m in smart.models) if (_downloads.contains(m.id)) m.service.sizeMb].fold<int>(0, (a, b) => a + b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Smart features', style: title),
      const SizedBox(height: 12),
      Text('Reading your handwriting, checking your maths and the assistant run on this device. Each needs a model that is downloaded once.', style: hint),
      const SizedBox(height: 16),
      Material(
        color: _ai ? scheme.surfaceContainerLow : scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile.adaptive(
              key: const ValueKey('intro-ai'),
              contentPadding: EdgeInsets.zero,
              title: Text('AI features', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(_ai ? 'On' : 'Off: nothing in the app uses AI'),
              value: _ai,
              onChanged: (v) => setState(() => _ai = v),
            ),
            Text(
              'Turn this off and no AI feature is offered and nothing is downloaded. You can turn it on later in the settings.',
              style: TextStyle(fontSize: 13, color: _ai ? scheme.onSurfaceVariant : scheme.onErrorContainer),
            ),
          ]),
        ),
      ),
      if (_ai) ...[
        const SizedBox(height: 16),
        for (final m in smart.models)
          ListenableBuilder(
            listenable: m.service,
            builder: (context, _) {
              final installed = m.service.status == HandwritingStatus.installed;
              return CheckboxListTile.adaptive(
                key: ValueKey('intro-model-${m.id}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                secondary: Icon(m.icon),
                title: Text(tr(m.title)),
                subtitle: Text(installed ? tr('Already on this device') : tr('{description} About {size} MB.', {'description': tr(m.description), 'size': '${m.service.sizeMb}'})),
                value: installed || _downloads.contains(m.id),
                onChanged: installed
                    ? null
                    : (v) => setState(() {
                          final now = {..._downloads};
                          v == true ? now.add(m.id) : now.remove(m.id);
                          _download = now;
                        }),
              );
            },
          ),
        const SizedBox(height: 8),
        Text(
          mb == 0 ? 'Nothing will be downloaded.' : tr('Pressing Start downloads {size} MB in the background; the settings show how far it is.', {'size': '$mb'}),
          key: const ValueKey('intro-download-note'),
          style: hint,
        ),
        if (_mobile && mb > 0) ...[
          const SizedBox(height: 8),
          Row(key: const ValueKey('intro-mobile-hint'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.network_cell, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'You are on mobile data. These models are large: untick them to download later on Wi-Fi (the settings have the same list), or go ahead if your plan allows it.',
                style: TextStyle(fontSize: 13, color: scheme.error),
              ),
            ),
          ]),
        ],
      ],
    ]);
  }
}

/// While a model is being downloaded: how far it is, and that the person can go on.
class _DownloadBanner extends StatelessWidget {
  final IntroSmart smart;

  const _DownloadBanner({required this.smart});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([for (final m in smart.models) m.service]),
      builder: (context, _) {
        final busy = [for (final m in smart.models) if (m.service.status == HandwritingStatus.downloading) m];
        final failed = [for (final m in smart.models) if (m.service.status != HandwritingStatus.downloading && m.service.error != null) m];
        if (busy.isEmpty && failed.isEmpty) return const SizedBox.shrink();
        return Container(
          key: const ValueKey('intro-downloads'),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final m in busy) ...[
              Row(children: [
                Expanded(child: Text.verbatim(tr(m.title), style: const TextStyle(fontWeight: FontWeight.bold))),
                Text.verbatim('${(m.service.progress * 100).round()} %', key: ValueKey('intro-progress-${m.id}')),
              ]),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: m.service.progress > 0 ? m.service.progress : null),
              const SizedBox(height: 8),
            ],
            for (final m in failed) ...[
              Text(tr('The download of "{name}" did not work. You can try again in the settings.', {'name': tr(m.title)}), style: TextStyle(fontSize: 13, color: scheme.error)),
              const SizedBox(height: 4),
            ],
            if (busy.isNotEmpty) Text('You can carry on: the download continues in the background.', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ]),
        );
      },
    );
  }
}
