
import 'package:flutter/foundation.dart' show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
// ignore: implementation_imports
import 'package:flutter_onnxruntime/src/flutter_onnxruntime_platform_interface.dart' show FlutterOnnxruntimePlatform;

import '../web/blob_url_io.dart' if (dart.library.js_interop) '../web/blob_url_web.dart';
import '../web/web_files.dart';

/// Opens the model at [path]. In a browser the runtime takes an address, not a path: the file (kept in IndexedDB, see
/// lib/web/web_files_web.dart) is read and handed to the runtime under a name (web/index.html), with as few copies as possible: the
/// runtime has its own once it has the session, and nothing else is left.
///
/// With [accelerate] the session asks for the chip's own accelerator first (see [onnxPlatformAccelerators]) and, if the runtime refuses
/// (the provider is missing from the build, or cannot take the model), is made again on the CPU, so asking never costs a model.
/// Models that decode token by token (their shapes change with every step) pass false: accelerators compile for fixed shapes.
Future<OrtSession> openOnnxSession(String path, {OrtSessionOptions? options, bool accelerate = true}) async {
  final providers = accelerate ? await _usableAccelerators() : const <OrtProvider>[];
  final model = path.split('/').last;
  if (!kIsWeb) {
    if (providers.isNotEmpty) {
      try {
        final session = await OnnxRuntime().createSession(path, options: _withProviders(options, providers));
        _report(model, providers.first.name);
        return session;
      } catch (e) {
        _report(model, 'CPU (${providers.first.name} refused: $e)');
      }
    } else {
      _report(model, 'CPU (${accelerate ? (onnxAccelerationEnabled ? 'no accelerator here' : 'switched off') : 'decoder'})');
    }
    return OnnxRuntime().createSession(path, options: options);
  }
  final name = handOverBytes(await webFileBytes(path));
  try {
    if (providers.isNotEmpty) {
      try {
        final session = await OnnxRuntime().createSession(name, options: _withProviders(options, providers));
        _report(model, providers.first.name);
        return session;
      } catch (e) {
        _report(model, 'wasm (${providers.first.name} refused: $e)');
      }
    } else {
      _report(model, 'wasm (${accelerate ? (onnxAccelerationEnabled ? 'no accelerator here' : 'switched off') : 'decoder'})');
    }
    return await OnnxRuntime().createSession(name, options: options);
  } finally {
    forgetBytes(name);
    await releaseWebFile(path);
  }
}

/// What each model was opened on, newest last (shown in the settings, and printed: in a browser it is in the console).
final onnxSessionReport = <String, String>{};

void _report(String model, String on) {
  onnxSessionReport.remove(model);
  onnxSessionReport[model] = on;
  debugPrint('onnx: $model on $on');
}

/// Switch for all hardware acceleration (the setting 'Run models on', and tests). Sessions already open keep what they were made with.
bool onnxAccelerationEnabled = true;

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

Future<List<OrtProvider>> _usableAccelerators() async {
  if (!onnxAccelerationEnabled) return const [];
  final have = await onnxAvailableAccelerators();
  return have.isEmpty ? const [] : [...have, OrtProvider.CPU];
}

/// The accelerators the runtime we ship can use on this platform (in the browser: WebGPU, vendored with the jsep files of web/ort), best first, the CPU last. Linux and Windows are empty on
/// purpose: the runtime builds bundled there are the CPU ones (the GPU builds are separate downloads), so asking would only fail.
List<OrtProvider> onnxPlatformAccelerators() {
  if (kIsWeb) return const [OrtProvider.WEB_GPU, OrtProvider.CPU]; // the graphics card, through the browser (WebGPU)
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return const [OrtProvider.CORE_ML, OrtProvider.CPU]; // Neural Engine / GPU
    case TargetPlatform.android:
      return const [OrtProvider.NNAPI, OrtProvider.CPU]; // NPU / DSP / GPU where the phone has a driver
    default:
      return const [];
  }
}

OrtSessionOptions _withProviders(OrtSessionOptions? o, List<OrtProvider> providers) => OrtSessionOptions(
  intraOpNumThreads: o?.intraOpNumThreads,
  interOpNumThreads: o?.interOpNumThreads,
  providers: providers,
  useArena: o?.useArena,
  deviceId: o?.deviceId,
  sessionConfigs: o?.sessionConfigs,
  lowPriority: o?.lowPriority,
);

/// A tensor of 64-bit whole numbers (the ids of tokens, the masks, the positions). A browser has no `Int64List` (it throws), so
/// there the numbers are handed over as a list and the runtime makes its BigInt array of them (see web/index.html).
Future<OrtValue> int64Value(List<int> values, List<int> shape) async {
  if (kIsWeb) return OrtValue.fromMap(await FlutterOnnxruntimePlatform.instance.createOrtValue('int64', values, shape));
  return OrtValue.fromList(Int64List.fromList(values), shape);
}
