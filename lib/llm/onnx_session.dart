
import 'package:flutter/foundation.dart' show TargetPlatform, ValueNotifier, debugPrint, defaultTargetPlatform, kIsWeb;
import 'dart:async';
import 'dart:io' show Directory, File, FileSystemEntityType;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
// ignore: implementation_imports
import 'package:flutter_onnxruntime/src/flutter_onnxruntime_platform_interface.dart' show FlutterOnnxruntimePlatform;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n/language.dart' show tr;
import '../web/blob_url_io.dart' if (dart.library.js_interop) '../web/blob_url_web.dart';
import '../web/web_files.dart';

/// Opens the model at [path]. In a browser the runtime takes an address, not a path: the file (kept in IndexedDB, see
/// lib/web/web_files_web.dart) is read and handed to the runtime under a name (web/index.html), with as few copies as possible: the
/// runtime has its own once it has the session, and nothing else is left.
///
/// With [accelerate] the session asks for the chip's own accelerator first (see [onnxPlatformAccelerators]) and, if the runtime refuses
/// (the provider is missing from the build, or cannot take the model), is made again on the CPU, so asking never costs a model.
/// Models that decode token by token (their shapes change with every step) pass false: accelerators compile for fixed shapes.
///
/// [force] asks for the accelerator whatever the setting says (timing it, making its plans): for this session only.
Future<OrtSession> openOnnxSession(String path, {OrtSessionOptions? options, bool accelerate = true, bool force = false}) async {
  var providers = accelerate ? await _usableAccelerators(force: force) : const <OrtProvider>[];
  final model = path.split('/').last;
  if (_tooSlow.contains(path)) providers = const <OrtProvider>[]; // (it did not get ready in time before: not tried again until the app is started again)
  if (!kIsWeb) {
    if (providers.isNotEmpty) {
      // (Android: one accelerator after the other, each with the processor behind it; elsewhere all at once)
      for (final attempt in await _attempts(providers, path)) {
        final list = attempt.providers;
        final tried = '$path|${attempt.label ?? list.first.name}';
        if (_refused.contains(tried)) continue;
        try {
          final extra = list.contains(OrtProvider.CORE_ML) && onnxCheckedForFp16(path) ? {OrtProvider.CORE_ML: await coreMlOptions(path, fixed: options?.freeDimensions)} : attempt.options;
          // (an accelerator takes what it supports and leaves the rest to the processor without a word: the profiler says how much)
          final profile = list.first == OrtProvider.NNAPI || list.first == OrtProvider.QNN;
          final preparing = onnxModelName(path);
          onnxNoteRun(preparing, '$onnxPreparing${list.first.name}', running: true);
          final OrtSession session;
          try {
            // (QNN: the compiled model is kept in a file of its own: the first session writes it, later ones read it instead of compiling)
            final cache = attempt.label == 'QNN (NPU)' ? _qnnCache(path, attempt.label!) : null; // (the NPU's compile is the long one; the GPU's is not kept)
            final cached = cache != null && File(cache).existsSync();
            if (cached) debugPrint('onnx: $model: the compiled model of ${attempt.label} is read from $cache');
            final making = OnnxRuntime().createSession(cached ? cache : path,
                options: _withProviders(options, list, extra, profile, cache == null || cached ? null : {'ep.context_enable': '1', 'ep.context_embed_mode': '1', 'ep.context_file_path': cache}));
            // (a phone's NNAPI compiles the whole model while the session is made: a quarter of an hour was seen for a 344 MB one, and the
            // compile cannot be stopped; so the processor takes over after [onnxCompileLimit], and the session that comes out later is closed)
            session = list.first == OrtProvider.NNAPI || list.first == OrtProvider.QNN
                ? await making.timeout(onnxCompileLimit, onTimeout: () {
                    _tooSlow.add(path);
                    unawaited(making.then((late) => late.close(), onError: (_) {}));
                    throw TimeoutException('${list.first.name} did not get the model ready in ${onnxCompileLimit.inSeconds} s');
                  })
                : await making;
          } finally {
            onnxNoteRun(preparing, '$onnxPreparing${list.first.name}', running: false);
          }
          final label = attempt.label ?? list.first.name;
          _report(model, label);
          // (the session is made, so CoreML's compiled copy is on disk: the converted copy's weights are not needed again)
          if (extra?[OrtProvider.CORE_ML]?['ModelCacheDirectory'] case final String cache?) unawaited(coreMlDropConvertedWeights(cache));
          final placed = _place(session, path, list.first.name);
          if (profile) {
            _toProfile.add(placed);
            onnxCompiledForChip.add(path);
          }
          return placed;
        } catch (e) {
          _report(model, 'CPU (${attempt.label ?? list.first.name} refused: $e)');
          _refused.add(tried);
          // (a compiled file that did not load, from another build of the runtime perhaps: thrown away, made again at the next start)
          if (attempt.label == 'QNN (NPU)') {
            final stale = _qnnCache(path, attempt.label ?? 'QNN');
            try {
              if (File(stale).existsSync()) File(stale).deleteSync();
            } catch (_) {}
          }
          if (_tooSlow.contains(path)) break;
        }
      }
    } else {
      _report(model, 'CPU (${accelerate ? (onnxAccelerationEnabled ? 'no accelerator here' : 'switched off') : 'decoder'})');
    }
    try {
      return _place(await OnnxRuntime().createSession(path, options: options), path, OrtProvider.CPU.name);
    } catch (e) {
      // A runtime pack (AMD's, say) has a processor build with fewer operators than the app's own: a model that only the accelerator
      // could run (an 8-bit one with ConvInteger) then has nowhere to go. Say so, in the settings and in the error.
      final reason = 'not opened: $e';
      _report(model, providers.isEmpty ? reason : 'CPU ($reason)');
      throw StateError(
          'The model $model could not be opened ($e). If a graphics card runtime is selected in Settings > AI, its processor part may lack operators this file needs: choose "The one in the app" there and start the app again.');
    }
  }
  final name = handOverBytes(await webFileBytes(path));
  try {
    if (providers.isNotEmpty) {
      try {
        final session = await OnnxRuntime().createSession(name, options: _withProviders(options, providers));
        _report(model, providers.first.name);
        return _place(session, path, providers.first.name);
      } catch (e) {
        _report(model, 'wasm (${providers.first.name} refused: $e)');
      }
    } else {
      _report(model, 'wasm (${accelerate ? (onnxAccelerationEnabled ? 'no accelerator here' : 'switched off') : 'decoder'})');
    }
    return _place(await OnnxRuntime().createSession(name, options: options), path, OrtProvider.WEB_ASSEMBLY.name);
  } finally {
    forgetBytes(name);
    await releaseWebFile(path);
  }
}

/// A model's run, for showing where the work goes on: [model] is the model's folder and file ("glm_ocr/vision-gpu.onnx"), [on] the
/// provider's name ([OrtProvider.name], 'CPU' for the processor) or [onnxMakingPlan]. [at] is the last time it started or ended.
class OnnxRun {
  final String model;
  final String on;
  DateTime at;
  int running = 0;
  bool _told = false; // (whether the listeners were told that it runs)
  Timer? _settle;
  OnnxRun(this.model, this.on, this.at);
}

/// How long a session with NNAPI first may take to be made (it compiles the model for the chip then) before the processor is used.
const onnxCompileLimit = Duration(seconds: 90);

/// Models (by path) whose session was made with NNAPI first. NNAPI compiles the model again for every session and ONNX Runtime has no
/// cache for that, so a reader keeps such a session open longer than the others.
final onnxCompiledForChip = <String>{};

/// The ways of asking for a session ('path|name') that the runtime refused: not asked again until the app is started again (a phone
/// without Qualcomm's chip would otherwise fail QNN again for every model it opens).
final _refused = <String>{};

/// Models whose session with an accelerator did not get ready in time (see [onnxCompileLimit]).
final _tooSlow = <String>{};

/// What the runtime does while it makes a session with an accelerator first: the model is compiled for the chip then (on a phone's NNAPI
/// that can take minutes), as [OnnxRun.on] '$onnxPreparing' and the provider's name.
const onnxPreparing = 'prepare:';

/// What the accelerator does while it works out a plan for a new input size (see [WarmSession]): in [OnnxRun.on].
const onnxMakingPlan = 'plan';

/// The models that ran, by model and place, with the time; the listeners are told when one starts running somewhere, and when it has
/// stopped for [onnxRunSettle] (a decoder runs once for each token: that is one start and one stop for the whole reading).
final onnxRuns = ValueNotifier<Map<String, OnnxRun>>(const {});

const onnxRunSettle = Duration(milliseconds: 300);

/// Notes that [model] starts ([running]) or stops running [on].
void onnxNoteRun(String model, String on, {required bool running}) {
  void tell() => onnxRuns.value = {...onnxRuns.value}; // (a new map: the listeners are told)
  final key = '$model|$on';
  var run = onnxRuns.value[key];
  if (run == null) {
    if (!running) return;
    onnxRuns.value = {...onnxRuns.value, key: OnnxRun(model, on, DateTime.now())..running = 1.._told = true};
    return;
  }
  run.at = DateTime.now();
  run.running = math.max(0, run.running + (running ? 1 : -1));
  if (run.running > 0) {
    run._settle?.cancel();
    if (!run._told) {
      run._told = true;
      tell();
    }
  } else if (run._told) {
    final stopped = run;
    stopped._settle?.cancel();
    stopped._settle = Timer(onnxRunSettle, () {
      if (stopped.running == 0 && stopped._told) {
        stopped._told = false;
        tell();
      }
    });
  }
}

/// The model's folder and file, as [OnnxRun.model] has it.
String onnxModelName(String path) => path.split('/').reversed.take(2).toList().reversed.join('/');

final _places = Expando<String>('where the session runs');

/// Sessions made with the profiler on, that have not finished a run yet (see [onnxSplits]).
final _toProfile = <OrtSession>{};

/// What really ran where, by model ("texteller/encoder-gpu.onnx"), for the sessions an accelerator took: "NNAPI 12 % of the time (7
/// parts), processor 88 % (1900 kernels)". Written after the first run of the session, as the profiler of ONNX Runtime saw it (Android).
/// An accelerator's session says only that it was accepted: the part of the model it took may be small or nothing.
final onnxSplits = ValueNotifier<Map<String, String>>(const {});

Future<void> _writeSplit(OrtSession session, String model) async {
  try {
    final seen = await session.endProfiling();
    if (seen == null || seen.isEmpty) {
      onnxSplits.value = {...onnxSplits.value, model: tr('the runtime could not say what ran on it')};
      return;
    }
    final total = seen.values.fold<double>(0, (a, v) => a + v.ms);
    final parts = <String>[];
    for (final e in seen.entries.toList()..sort((a, b) => b.value.ms.compareTo(a.value.ms))) {
      final name = e.key.replaceAll('ExecutionProvider', '');
      final share = total <= 0 ? 0 : (100 * e.value.ms / total).round();
      parts.add(name == 'CPU'
          ? tr('processor {share} % ({kernels} kernels)', {'share': '$share', 'kernels': '${e.value.kernels}'})
          : tr('{name} {share} % of the time ({kernels} parts)', {'name': name.toUpperCase(), 'share': '$share', 'kernels': '${e.value.kernels}'}));
    }
    if (!seen.keys.any((k) => !k.startsWith('CPU'))) parts.insert(0, tr('nothing ran on the accelerator'));
    final text = parts.join(', ');
    debugPrint('onnx: $model ran as: $text');
    onnxSplits.value = {...onnxSplits.value, model: text};
  } catch (e) {
    debugPrint('onnx: could not read the profile of $model ($e)');
    onnxSplits.value = {...onnxSplits.value, model: tr('the runtime could not say what ran on it')};
  }
}

OrtSession _place(OrtSession session, String path, String on) {
  _places[session] = '${onnxModelName(path)}|$on';
  OrtSession.onRun ??= (s, running) {
    final place = _places[s];
    if (place == null) return;
    final at = place.lastIndexOf('|');
    onnxNoteRun(place.substring(0, at), place.substring(at + 1), running: running);
    if (!running && _toProfile.remove(s)) unawaited(_writeSplit(s, place.substring(0, at)));
  };
  return session;
}

/// What each model was opened on, newest last (shown in the settings, and printed: in a browser it is in the console).
final onnxSessionReport = <String, String>{};

void _report(String model, String on) {
  onnxSessionReport.remove(model);
  onnxSessionReport[model] = on;
  debugPrint('onnx: $model on $on');
}

/// Switch for all hardware acceleration (the setting 'Run models on', and tests). Sessions already open keep what they were made with;
/// the readers that keep theirs open look at [onnxAccelerationChanges] and open them again.
bool get onnxAccelerationEnabled => _accelerationEnabled;
set onnxAccelerationEnabled(bool on) {
  if (on == _accelerationEnabled) return;
  _accelerationEnabled = on;
  onnxAccelerationVersion.value++;
}

bool _accelerationEnabled = true;

/// How often [onnxAccelerationEnabled] changed: a session opened at another count was opened for the other setting. The services that
/// choose their files by it listen to [onnxAccelerationVersion].
int get onnxAccelerationChanges => onnxAccelerationVersion.value;
final onnxAccelerationVersion = ValueNotifier<int>(0);

/// Whether pictures for the networks that cannot take any size are padded to a few fixed sizes (the setting 'Pad to fixed sizes', on by
/// default). It is on whatever the setting says while the provider in use compiles for exact sizes ([onnxNeedsFixedShapes]).
bool padToFixedSizes = true;

/// True when the accelerator that would run a model compiles it for the exact size of its input (MIGraphX: minutes for each size, kept
/// for the next time). CUDA, OpenVINO and the processor take any size.
Future<bool> onnxNeedsFixedShapes() async => onnxAccelerationEnabled && (await onnxAvailableAccelerators()).firstOrNull == OrtProvider.MIGRAPHX;

/// The model files whose 16-bit form was checked against the processor (the statistics of their norms are kept in 32 bits, see
/// tool/texteller_fix_ln_fp16.py): only these may run where an accelerator computes in 16 bits throughout. Measured on a Mac's CoreML
/// (MLProgram, .github/workflows/coreml-check.yml): the fixed formula encoder 0.8 % from the processor; the 8-bit one 15 % (the same
/// overflow as on AMD's card) and the 8-bit vision network could not be built at all.
const onnxFp16Files = {'encoder-gpu.onnx', 'vision-gpu.onnx'};

bool onnxCheckedForFp16(String path) => onnxFp16Files.contains(path.split('/').last);

/// True when the accelerator in use should only get the files of [onnxFp16Files], the others staying on the processor: MIGraphX (cannot
/// run quantised operators, compiles for exact sizes) and CoreML (computes in 16 bits: a quantised or 32-bit file gives wrong answers, or
/// is slower than the processor).
Future<bool> onnxTakesOnlyFp16Files() async {
  if (!onnxAccelerationEnabled) return false;
  final first = (await onnxAvailableAccelerators()).firstOrNull;
  return first == OrtProvider.MIGRAPHX || first == OrtProvider.CORE_ML;
}

/// True when CoreML is the accelerator in use (iOS, macOS): models whose input size is free run there one size at a time (see
/// [openWarmSession]), so pictures of handwriting are padded to a few widths.
Future<bool> onnxUsesCoreMl() async => onnxAccelerationEnabled && (await onnxAvailableAccelerators()).firstOrNull == OrtProvider.CORE_ML;

/// Whether the picture of a line of writing is padded now: the setting, or the provider needs it.
Future<bool> padPicturesNow() async => padToFixedSizes || await onnxNeedsFixedShapes();

/// What the runtime says it can use on this device, once asked; null until then or when it could not be asked.
Future<Set<OrtProvider>?>? _detecting;

/// The accelerators of [onnxPlatformAccelerators] that this device's runtime really has (not the CPU). Empty where there is none.
Future<List<OrtProvider>> onnxAvailableAccelerators() async {
  final wanted = onnxPlatformAccelerators();
  if (wanted.isEmpty) return const [];
  _detecting ??= () async {
    try {
      return (await OnnxRuntime().getAvailableProviders()).toSet();
    } catch (e) {
      debugPrint('onnx: could not ask for the available providers ($e)');
      return null;
    }
  }();
  final have = await _detecting;
  // (could not ask: try anyway, session creation falls back by itself)
  return [for (final p in wanted) if (p != OrtProvider.CPU && (have == null || have.contains(p))) p];
}

Future<List<OrtProvider>> _usableAccelerators({bool force = false}) async {
  if (!onnxAccelerationEnabled && !force) return const [];
  final have = await onnxAvailableAccelerators();
  return have.isEmpty ? const [] : [...have, OrtProvider.CPU];
}

/// The accelerators the runtime we ship can use on this platform (in the browser: WebGPU, vendored with the jsep files of web/ort), best first, the CPU last. On Linux the runtime bundled
/// is the CPU build, so nothing is found until the user picks a runtime pack (lib/llm/onnx_runtime_packs.dart) with CUDA, MIGraphX or OpenVINO: what is asked here is then
/// checked against what the pack says it has. Windows is empty: its bundled build is the CPU one too (WebGPU on the desktop was timed and is slower than the processor).
List<OrtProvider> onnxPlatformAccelerators() {
  if (kIsWeb) return const [OrtProvider.WEB_GPU, OrtProvider.CPU]; // the graphics card, through the browser (WebGPU)
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return const [OrtProvider.CORE_ML, OrtProvider.CPU]; // Neural Engine / GPU
    case TargetPlatform.android:
      return const [OrtProvider.QNN, OrtProvider.NNAPI, OrtProvider.CPU]; // Snapdragon NPU and GPU (QNN) / whatever the phone's driver offers (NNAPI)
    case TargetPlatform.linux:
      return const [OrtProvider.CUDA, OrtProvider.MIGRAPHX, OrtProvider.OPEN_VINO, OrtProvider.CPU]; // only those the runtime pack in use has
    default:
      return const [];
  }
}

/// One way of asking for a session: the providers in order, their options, and a name for the report.
typedef _Attempt = ({List<OrtProvider> providers, Map<OrtProvider, Map<String, String>>? options, String? label});

/// The ways to ask for a session on this device, best first. On Android each accelerator is tried alone with the processor behind it
/// (a phone has the one chip, and a refusal of QNN on a phone without Qualcomm's must not cost NNAPI): QNN on the NPU, QNN on the Adreno
/// graphics chip, then NNAPI. Elsewhere all the accelerators are given at once.
Future<List<_Attempt>> _attempts(List<OrtProvider> providers, String path) async {
  if (defaultTargetPlatform != TargetPlatform.android) return [(providers: providers, options: null, label: null)];
  final cpu = [OrtProvider.CPU];
  return [
    for (final p in providers)
      if (p == OrtProvider.QNN) ...[
        // (the NPU; fp16 is what the models in 16 bits need there)
        (providers: [p, ...cpu], options: {p: {'backend_type': 'htp', 'enable_htp_fp16_precision': '1'}}, label: 'QNN (NPU)'),
        (providers: [p, ...cpu], options: {p: {'backend_type': 'gpu'}}, label: 'QNN (GPU)'),
      ] else if (p != OrtProvider.CPU)
        (providers: [p, ...cpu], options: null, label: null),
  ];
}

/// Where the compiled form of the model at [path] is kept for QNN's [label] (NPU or GPU): next to the model, named by the model's size so
/// that a changed file is not read from an old one's compile.
String _qnnCache(String path, String label) {
  final dir = Directory(p.join(p.dirname(path), 'qnn_cache'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final size = File(path).existsSync() ? File(path).lengthSync() : 0;
  return p.join(dir.path, '${p.basename(path)}.$size.${label.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}.onnx');
}

OrtSessionOptions _withProviders(OrtSessionOptions? o, List<OrtProvider> providers, [Map<OrtProvider, Map<String, String>>? extra, bool profile = false, Map<String, String>? configs]) => OrtSessionOptions(
  profile: profile,
  // (only QNN takes what has known shapes: NNAPI, given them, compiled for longer than anyone waits)
  freeDimensions: providers.isNotEmpty && providers.first == OrtProvider.QNN ? o?.freeDimensions : null,
  intraOpNumThreads: o?.intraOpNumThreads,
  interOpNumThreads: o?.interOpNumThreads,
  providers: providers,
  useArena: o?.useArena,
  deviceId: o?.deviceId,
  sessionConfigs: {...?o?.sessionConfigs, ...?configs},
  lowPriority: o?.lowPriority,
  ownThread: o?.ownThread,
  providerOptions: {...?o?.providerOptions, ...?extra},
  logSeverityLevel: o?.logSeverityLevel,
);

/// CoreML's options for the model at [path] (iOS, macOS), given to the files of [onnxFp16Files] only. Without options ONNX Runtime uses the older NeuralNetwork format, which takes
/// fewer operators, and converts the model again at every session (seconds to minutes for the vision network). So: the MLProgram
/// format, every compute unit, and a folder that keeps the converted model. CoreML does not notice when the file behind a cached model
/// changes (its key is the path), so the folder is named by the file's size and time, and the folders of older versions are removed.
/// [fixed]: the free input sizes the session fixes (see [OrtSessionOptions.freeDimensions]): each gets a folder of its own, since CoreML
/// would otherwise load the model converted for another size. [root] is for tests (else the app's cache folder).
Future<Map<String, String>> coreMlOptions(String path, {String computeUnits = 'ALL', Map<String, int>? fixed, Directory? root}) async {
  final cache = await coreMlCacheFolder(path, fixed: fixed, root: root);
  return {'ModelFormat': 'MLProgram', 'MLComputeUnits': computeUnits, 'ModelCacheDirectory': ?cache};
}

/// The folder for CoreML's converted copy of the model at [path] (see [coreMlOptions]), made if needed; null if it cannot be.
Future<String?> coreMlCacheFolder(String path, {Map<String, int>? fixed, Directory? root}) async {
  try {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    // (an external-data file holds the weights: a new one is a new model too)
    final data = File('$path.data');
    final dataStat = await data.exists() ? await data.stat() : null;
    final name = onnxModelName(path).replaceAll('/', '_');
    final key = '$name-${stat.size}-${stat.modified.millisecondsSinceEpoch}${dataStat == null ? '' : '-${dataStat.size}-${dataStat.modified.millisecondsSinceEpoch}'}';
    final base = root ?? Directory(p.join((await getApplicationCacheDirectory()).path, 'coreml'));
    if (await base.exists()) {
      await for (final e in base.list()) {
        final old = p.basename(e.path);
        if (old != key && old.startsWith('$name-') && RegExp(r'^-\d').hasMatch(old.substring(name.length))) {
          await e.delete(recursive: true);
        }
      }
    }
    // (one folder per fixed size, inside the file's: an old version of the file goes with all its sizes)
    final sizes = [for (final e in (fixed ?? const <String, int>{}).entries) '${e.key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}-${e.value}']..sort();
    final dir = Directory(sizes.isEmpty ? p.join(base.path, key) : p.join(base.path, key, sizes.join('_')));
    await dir.create(recursive: true);
    return dir.path;
  } catch (e) {
    debugPrint('onnx: no CoreML cache folder for $path ($e)');
    return null;
  }
}

/// Deletes the weights of CoreML's converted models under [cache] where the compiled model is next to them (ModelCacheDirectory holds
/// both, each with all the weights: 1.6 GB for the handwriting vision network, 0.8 GB without the converted ones). ONNX Runtime only
/// checks that the converted model's folder is there and then loads the compiled one (model.mm CompileOrReadCachedModel), so nothing is
/// built again: checked on a Mac (.github/workflows/coreml-probe.yml), the next session opened in half a second with the same answer.
/// Returns how many folders were deleted.
Future<int> coreMlDropConvertedWeights(String cache) async {
  var dropped = 0;
  try {
    final root = Directory(cache);
    if (!await root.exists()) return 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! Directory || p.basename(e.path) != 'Data' || p.basename(e.parent.path) != 'model') continue;
      if (!await Directory(p.join(e.parent.path, 'compiled_model.mlmodelc')).exists()) continue; // (not built yet: leave it)
      await e.delete(recursive: true);
      dropped++;
    }
  } catch (e) {
    debugPrint('onnx: could not tidy the CoreML cache $cache ($e)');
  }
  return dropped;
}

/// A tensor of 64-bit whole numbers (the ids of tokens, the masks, the positions). A browser has no `Int64List` (it throws), so
/// there the numbers are handed over as a list and the runtime makes its BigInt array of them (see web/index.html).
Future<OrtValue> int64Value(List<int> values, List<int> shape) async {
  if (kIsWeb) return OrtValue.fromMap(await FlutterOnnxruntimePlatform.instance.createOrtValue('int64', values, shape));
  return OrtValue.fromList(Int64List.fromList(values), shape);
}
