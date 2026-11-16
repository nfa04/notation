import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../llm/onnx_acceleration_setting.dart';
import '../llm/onnx_runtime_packs.dart';
import '../llm/onnx_session.dart';

/// Where the models (handwriting, maths, scans, search) run: on the processor, or on the device's own accelerator when it has one.
class AccelerationSettings extends StatefulWidget {
  final NoteRepository repository;

  /// Times a model on the accelerator and on the processor (null: no model to time); gives a line of text for each.
  final Future<List<String>> Function()? benchmark;
  /// Makes the accelerator's plan for every picture size of the handwriting reader (null: not possible here); says how far it is, and asks whether to stop.
  final Future<void> Function(void Function(int done, int total) progress, bool Function() cancelled)? precompile;
  /// Which plans are made and which are missing, a line of text for each model (asked when the page opens and after [precompile]).
  final Future<List<String>> Function()? planStatus;
  /// The runtime packs (Linux): which one runs now, those found, where they go, and how to save the choice. Null: the real ones.
  final Future<({String version, String path, String error, String chosen})?> Function()? runtimeInfo;
  final Future<List<OnnxRuntimePack>> Function()? findPacks;
  final Future<String> Function()? packFolder;
  final Future<void> Function(OnnxRuntimePack? pack)? choosePack;
  /// Fetches a runtime pack and gives it back, saying how far it is (null: the real download); and which ones suit this machine.
  final Future<OnnxRuntimePack> Function(OnnxRuntimeDownload d, void Function(double) progress)? downloadPack;
  final Future<List<String>> Function()? suggested;
  const AccelerationSettings({super.key, required this.repository, this.benchmark, this.precompile, this.planStatus, this.runtimeInfo, this.findPacks, this.packFolder, this.choosePack, this.downloadPack, this.suggested});

  @override
  State<AccelerationSettings> createState() => _AccelerationSettingsState();
}

class _AccelerationSettingsState extends State<AccelerationSettings> {
  bool _cpuOnly = false;
  bool _pad = true;
  bool _needsFixed = false; // the accelerator compiles for exact sizes: padding cannot be turned off
  bool _coreMl = false; // CoreML: the handwriting reader's 16-bit file runs one picture width at a time, so it pads anyway
  List<String>? _found; // null: still asking
  bool _preparing = false;
  bool _stopPreparing = false;
  int _prepared = 0, _prepareTotal = 0;
  String? _prepareError;
  List<String> _plans = const [];
  bool _timing = false;
  List<String>? _timed;
  String? _timeError;
  ({String version, String path, String error, String chosen})? _runtime; // the runtime in use (null: not asked, or no packs here)
  List<OnnxRuntimePack> _packs = const [];
  String _packFolder = '';
  String? _chosen; // library path saved for the next start, '' for the app's own
  List<String> _suggested = const [];
  String? _downloading; // id of the pack being fetched
  double _downloadProgress = 0;
  String? _downloadError;
  bool get _packsHere => widget.runtimeInfo != null || onnxRuntimePacksSupported;

  Future<void> _loadPacks() async {
    final info = await (widget.runtimeInfo ?? onnxRuntimeInfo)();
    final folder = widget.packFolder != null ? await widget.packFolder!() : (await onnxRuntimePackFolder()).path;
    final suggested = await (widget.suggested ?? suggestedRuntimeDownloads)();
    final packs = await (widget.findPacks ?? () async => findOnnxRuntimePacks(await onnxRuntimePackFolder()))();
    if (mounted) {
      setState(() {
        _runtime = info;
        _packs = packs;
        _suggested = suggested;
        _packFolder = folder;
        _chosen = info?.chosen ?? '';
      });
    }
  }

  Future<void> _pickPack(OnnxRuntimePack? pack) async {
    setState(() => _chosen = pack?.library ?? '');
    await (widget.choosePack ?? chooseOnnxRuntimePack)(pack);
  }

  Future<void> _download(OnnxRuntimeDownload d) async {
    setState(() {
      _downloading = d.id;
      _downloadProgress = 0;
      _downloadError = null;
    });
    try {
      void progress(double x) {
        if (mounted) setState(() => _downloadProgress = x);
      }

      final pack = await (widget.downloadPack ?? (d, pr) async => downloadOnnxRuntimePack(d, folder: await onnxRuntimePackFolder(), progress: pr))(d, progress);
      final packs = await (widget.findPacks ?? () async => findOnnxRuntimePacks(await onnxRuntimePackFolder()))();
      if (mounted) setState(() => _packs = packs);
      await _pickPack(packs.where((x) => x.library == pack.library).firstOrNull ?? pack); // (it is what they came for)
    } catch (e) {
      if (mounted) setState(() => _downloadError = '$e');
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  Future<void> _prepare() async {
    setState(() {
      _preparing = true;
      _stopPreparing = false;
      _prepareError = null;
      _prepared = 0;
      _prepareTotal = 0;
    });
    try {
      await widget.precompile!((done, total) {
        if (mounted) {
          setState(() {
            _prepared = done;
            _prepareTotal = total;
          });
        }
      }, () => _stopPreparing);
    } catch (e) {
      if (mounted) setState(() => _prepareError = '$e');
    } finally {
      if (mounted) setState(() => _preparing = false);
      await _loadPlans();
    }
  }

  Future<void> _loadPlans() async {
    if (widget.planStatus == null) return;
    try {
      final lines = await widget.planStatus!();
      if (mounted) setState(() => _plans = lines);
    } catch (_) {
      // (nothing to show)
    }
  }

  Future<void> _time() async {
    setState(() {
      _timing = true;
      _timed = null;
      _timeError = null;
    });
    try {
      final lines = await widget.benchmark!();
      if (mounted) setState(() => _timed = lines);
    } catch (e) {
      if (mounted) setState(() => _timeError = '$e');
    } finally {
      if (mounted) setState(() => _timing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (_packsHere) _loadPacks();
    _loadPlans();
    () async {
      final cpu = await widget.repository.settings.get(onnxAccelerationSetting) == 'cpu';
      final pad = await widget.repository.settings.get(onnxPadSetting) != 'off';
      final fixed = await onnxNeedsFixedShapes();
      final coreMl = await onnxUsesCoreMl();
      final found = [for (final p in await onnxAvailableAccelerators()) _label(p.name)];
      if (mounted) {
        setState(() {
          _cpuOnly = cpu;
          _pad = pad;
          _needsFixed = fixed;
          _coreMl = coreMl;
          _found = found;
        });
      }
    }();
  }

  static String _label(String provider) => switch (provider) {
        'CORE_ML' => 'Apple Neural Engine / GPU (CoreML)',
        'CUDA' => 'NVIDIA graphics card (CUDA)',
        'MIGRAPHX' => 'AMD graphics card (MIGraphX)',
        'OPEN_VINO' => 'Intel graphics card / NPU (OpenVINO)',
        'WEB_GPU' => 'Graphics card (WebGPU)',
        'NNAPI' => 'Android NPU / GPU (NNAPI)',
        _ => provider,
      };

  Future<void> _choose(bool cpuOnly) async {
    setState(() => _cpuOnly = cpuOnly);
    await widget.repository.settings.set(onnxAccelerationSetting, cpuOnly ? 'cpu' : 'auto');
    await applyOnnxAcceleration(widget.repository.settings.get);
    final fixed = await onnxNeedsFixedShapes();
    final coreMl = await onnxUsesCoreMl();
    if (mounted) {
      setState(() {
        _needsFixed = fixed;
        _coreMl = coreMl;
      });
    }
  }

  Future<void> _choosePad(bool on) async {
    setState(() => _pad = on);
    await widget.repository.settings.set(onnxPadSetting, on ? 'on' : 'off');
    await applyOnnxPadding(widget.repository.settings.get);
  }

  List<Widget> _packSection(TextStyle muted) {
    final r = _runtime!;
    final inUse = r.path.isEmpty ? tr('the one in the app (processor only)') : _packs.where((x) => x.library == r.path).map((x) => x.name).firstOrNull ?? r.path;
    return [
      const SizedBox(height: 16),
      Text(tr('Graphics card runtime'), style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Text(tr('Running now: {name} (ONNX Runtime {version})', {'name': inUse, 'version': r.version}), key: const ValueKey('runtime-in-use'), style: muted),
      if (r.error.isNotEmpty) Text(tr('The chosen runtime could not be opened: {why}', {'why': r.error}), key: const ValueKey('runtime-error'), style: muted.copyWith(color: Theme.of(context).colorScheme.error)),
      const SizedBox(height: 4),
      RadioGroup<String>(
        groupValue: _chosen ?? '',
        onChanged: (v) => _pickPack(v == null || v.isEmpty ? null : _packs.firstWhere((x) => x.library == v)),
        child: Column(children: [
          RadioListTile<String>(key: const ValueKey('runtime-app'), dense: true, value: '', title: Text(tr('The one in the app (processor only)'))),
          for (final pk in _packs) RadioListTile<String>(key: ValueKey('runtime-${pk.name}'), dense: true, value: pk.library, title: Text.verbatim(pk.name)),
        ]),
      ),
      const SizedBox(height: 8),
      for (final d in onnxRuntimeDownloads.where((d) => !_packs.any((x) => x.name.startsWith(d.id)) && (_suggested.isEmpty || _suggested.contains(d.id) || _downloading == d.id)))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(d.label), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(_suggested.contains(d.id) ? tr('Found on this computer. Needs {needs}.', {'needs': d.needs}) : tr('Needs {needs}.', {'needs': d.needs}), style: muted),
              ]),
            ),
            if (_downloading == d.id)
              SizedBox(width: 90, child: LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null))
            else
              OutlinedButton(key: ValueKey('runtime-download-${d.id}'), onPressed: _downloading == null ? () => _download(d) : null, child: Text(tr('Download'))),
          ]),
        ),
      if (_downloadError != null) Text(tr('The download failed: {why}', {'why': _downloadError!}), key: const ValueKey('runtime-download-error'), style: muted.copyWith(color: Theme.of(context).colorScheme.error)),
      Text(
        _packs.isEmpty
            ? tr('No graphics card runtime downloaded yet. Pick one above; it is used from the next start of the app.')
            : tr('Takes effect when the app is started again. Folder of the runtimes: {folder}', {'folder': _packFolder}),
        key: const ValueKey('runtime-hint'),
        style: muted,
      ),
    ];
  }

  /// Why there is nothing to run on. On Linux the runtime in the app is the one for the processor: a graphics card the computer has is
  /// only used once its runtime is downloaded (below) and the app is started again.
  String _noAccelerator() {
    final wanted = [for (final d in onnxRuntimeDownloads) if (_suggested.contains(d.id)) tr(d.label)];
    if (_packsHere && wanted.isNotEmpty) {
      return tr('This computer has a graphics card ({names}), but the app is running on the runtime for the processor. Download the runtime for it below, then start the app again.', {'names': wanted.join(', ')});
    }
    return tr('This device has no accelerator the app can use: models always run on the processor.');
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    final found = _found;
    final has = found != null && found.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Run models on'), style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Text(
        found == null
            ? tr('Looking for an accelerator…')
            : has
                ? tr('Available on this device: {names}', {'names': found.join(', ')})
                : kIsWeb
                    ? tr('This browser gives the page no graphics card (WebGPU): models run on the processor. WebGPU needs https or localhost, and a browser that has it switched on (chrome://gpu shows why not).')
                    : _noAccelerator(),
        key: const ValueKey('acceleration-found'),
        style: muted,
      ),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        key: const ValueKey('acceleration-choice'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: false, enabled: has, label: Text(tr('Accelerator when available'))),
          ButtonSegment(value: true, label: Text(tr('Processor only'))),
        ],
        selected: {has ? _cpuOnly : true},
        onSelectionChanged: (v) => _choose(v.first),
      ),
      SwitchListTile(
        key: const ValueKey('pad-fixed-sizes'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('Pad to fixed sizes')),
        subtitle: Text(
          _needsFixed
              ? tr('Needed with this accelerator: it works out a plan for every picture size it sees, which takes minutes. Pictures of handwriting are made one of a few widths (about a fifth more work) so each plan is made once.')
              : _coreMl
                  ? tr('Always on with CoreML for the "Graphics card" size of the handwriting model: CoreML prepares it once for each picture width (seconds, kept for the next start), so pictures are made one of a few widths.')
                  : tr('Makes pictures of handwriting one of a few widths, so an accelerator that works out a plan for each size (AMD) does it a few times, not for every line. Costs about a fifth more work; switch it off where the accelerator takes any size.'),
          style: muted,
        ),
        value: _pad || _needsFixed || _coreMl,
        onChanged: _needsFixed || _coreMl ? null : _choosePad,
      ),
      if (has && _needsFixed && widget.precompile != null) ...[
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton(key: const ValueKey('precompile-sizes'), onPressed: _preparing ? null : _prepare, child: Text(_preparing ? tr('Preparing…') : tr('Precompile picture sizes'))),
          if (_preparing) TextButton(key: const ValueKey('precompile-stop'), onPressed: _stopPreparing ? null : () => setState(() => _stopPreparing = true), child: Text(tr('Stop'))),
        ]),
        if (_preparing) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: LinearProgressIndicator(value: _prepareTotal > 0 ? _prepared / _prepareTotal : null)),
        Text(
          _preparing
              ? tr('Size {done} of {total} done. Each takes 4 to 5 minutes; the app can be used meanwhile, and what is done is kept.', {'done': '$_prepared', 'total': '$_prepareTotal'})
              : tr('Makes the graphics card\'s plan for every picture size of the handwriting reader now, for the quality chosen (about an hour the first time, once; another quality needs its own), so that no reading has to wait for one. Needs the "Graphics card" size of the handwriting model.'),
          style: muted,
        ),
        if (_prepareError != null) Text.verbatim(_prepareError!, key: const ValueKey('precompile-error'), style: muted.copyWith(color: Theme.of(context).colorScheme.error)),
        for (final l in _plans) Text.verbatim(l, key: ValueKey('plan-status-$l'), style: muted),
      ],
      if (has && widget.benchmark != null) ...[
        const SizedBox(height: 8),
        OutlinedButton(key: const ValueKey('acceleration-time'), onPressed: _timing ? null : _time, child: Text(_timing ? tr('Timing…') : tr('Time the handwriting reader'))),
        for (final l in _timed ?? const <String>[]) Text.verbatim(l, style: muted),
        if (_timeError != null) Text.verbatim(_timeError!, style: muted),
      ],
      if (onnxSessionReport.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(tr('Models opened so far'), style: Theme.of(context).textTheme.labelMedium),
        for (final e in onnxSessionReport.entries) Text.verbatim('${e.key}: ${e.value}', style: muted),
      ],
      if (_packsHere && _runtime != null) ..._packSection(muted),
      const SizedBox(height: 6),
      Text(tr('Applies to models opened from now on; restart the app to switch all of them. Models that write text word by word always use the processor.'), style: muted),
    ]);
  }
}
