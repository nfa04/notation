import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'accelerator_plans.dart';
import 'onnx_session.dart';

/// What [WarmSession] runs a model with: a session, or a stand-in in tests.
class WarmEngine {
  final Future<Map<String, OrtValue>> Function(Map<String, OrtValue> inputs) run;
  final Future<void> Function() close;
  const WarmEngine(this.run, this.close);

  static WarmEngine of(OrtSession s) => WarmEngine((inputs) => s.run(inputs), s.close);

  /// A model cut into parts that run one after the other (see tool/split_glm_vision.py), ONE PART OPEN AT A TIME: each is opened ([open]),
  /// run and closed before the next. On a phone the parts are there for memory: QNN's GPU backend holds about three times a part's weights
  /// (0.6 GB for 210 MB of 16-bit weights), and with the parts of the handwriting reader's vision network held together the app went
  /// past 3.3 GB and Android killed it. After the first time a part opens from its compiled file (see [openOnnxSession]), not compiled.
  ///
  /// Each part takes what it needs of the inputs and of the outputs of the parts before it; the last part's outputs are the answer. The
  /// values between parts are let go of here (the caller's inputs are not).
  ///
  /// A part the accelerator cannot run (it opens, and fails when run: QNN's GPU backend on a Snapdragon 865 with the rotary tables of the
  /// handwriting reader) is run on the processor, then and from then on ([open] with accelerate false); the others stay on the accelerator.
  static WarmEngine parts(List<String> paths, Future<OrtSession> Function(String path, bool accelerate) open) {
    final onProcessor = <int>{};
    return WarmEngine((inputs) async {
        final known = <String, OrtValue>{...inputs};
        final between = <OrtValue>[];
        Future<Map<String, OrtValue>> runPart(int i, bool accelerate) async {
          final part = await open(paths[i], accelerate);
          try {
            return await part.run({
              for (final name in part.inputNames) name: known[name] ?? (throw StateError('part ${i + 1} needs $name, which no part before it made')),
            });
          } finally {
            await part.close();
          }
        }

        try {
          for (var i = 0; i < paths.length; i++) {
            Map<String, OrtValue> out;
            if (onProcessor.contains(i)) {
              out = await runPart(i, false);
            } else {
              try {
                out = await runPart(i, true);
              } catch (e) {
                debugPrint('onnx: part ${i + 1} of ${paths.first.split('/').last}: the accelerator could not run it, the processor does from now on ($e)');
                onProcessor.add(i);
                out = await runPart(i, false);
              }
            }
            if (i == paths.length - 1) return out;
            known.addAll(out);
            between.addAll(out.values);
          }
          throw StateError('a model of no parts');
        } finally {
          for (final v in between) {
            await v.dispose();
          }
        }
      }, () async {});
  }
}


/// A model on an accelerator that works out a plan for each input size it meets (MIGraphX: minutes the first time, kept on disk for
/// the next), which must not make a reading wait. A size whose plan is not known to be ready is run on the processor at once, with a
/// session of its own, while the accelerator works on the plan in the background; once it is done (and for every later run of that
/// size) the accelerator is used. A plan that is already on disk is loaded within [grace], so that reading is not sent to the processor
/// for nothing. One plan is made at a time: another size that arrives meanwhile is read on the processor.
///
/// A model that is not on such an accelerator ([openWarmSession] decides) runs on its one session, as before.
class WarmSession {
  final Future<WarmEngine> Function() _openAccelerated;
  final Future<WarmEngine> Function() _openProcessor;
  final Duration grace;

  WarmSession.test(
      {required Future<WarmEngine> Function() accelerated, required Future<WarmEngine> Function() processor, this.grace = const Duration(seconds: 4), this.onPlanned, this.oneSize = false, this.waitForPlan = false})
      : _openAccelerated = accelerated,
        _openProcessor = processor;

  WarmSession._plain(Future<WarmEngine> Function() open)
      : _openAccelerated = open,
        _openProcessor = open,
        grace = Duration.zero,
        onPlanned = null,
        oneSize = false,
        waitForPlan = false,
        _plain = true;

  // (8 s: loading a plan of the handwriting reader from disk took 2.4 to 5 s on a Radeon 780M, and the first run of a session up to 7 s, a
  // run on the stale plan and the load of the right one; making a plan takes 6 to 8 minutes)
  WarmSession._compiling(this._openAccelerated, this._openProcessor, this.onPlanned, this.oneSize, this._model, {this.waitForPlan = false})
      : grace = const Duration(seconds: 8);

  /// While a plan is made, wait for it instead of reading on the processor meanwhile (QNN on a phone: the processor's copy of the model
  /// beside the one being compiled took the app past what Android allows it, and it was killed). The processor is used only if the
  /// accelerator fails.
  final bool waitForPlan;

  /// The model's name as [onnxRuns] has it (null in tests).
  String? _model;

  /// Told of each size whose own plan is now on disk: a run of it after a run of another size (which loads that size's plan or makes
  /// it). The first run of a session is not enough: it can be answered by the first plan ever made for the model, of whatever size,
  /// unless the model has [oneSize] (then that first plan is its own).
  final void Function(String key)? onPlanned;
  final bool oneSize;

  int _acceleratedRuns = 0;

  bool _plain = false;
  Future<WarmEngine>? _accelerated, _processor;
  final Set<String> _ready = {};
  String? _compiling; // the size whose plan is being made
  bool _acceleratorFailed = false;
  bool _closed = false;

  /// Sizes the accelerator has a plan for (for the settings, and tests).
  Set<String> get ready => {..._ready};

  /// The size being planned for now, or null.
  String? get compiling => _compiling;

  /// The size of the accelerator's last run: its plan is the one in memory (MIGraphX holds one; another size loads its plan from disk,
  /// about 3 s for the handwriting reader), so a caller with several inputs runs this size first and the others grouped by size.
  String? get loaded => _loaded;
  String? _loaded;

  /// Runs the model. [inputs] makes the tensors (called once for each attempt, since a run that goes on in the background keeps its
  /// own); they are let go of here. [key] names the input size: runs with the same key share a plan. [accept] says whether an answer has
  /// the shape it must have: the first run of a new session on MIGraphX can be answered with the plan on disk for ANOTHER size (ONNX
  /// Runtime 1.23 loads the first plan it made for the model without comparing sizes); such an answer is run again, which loads (or
  /// makes) the right plan. The caller lets go of the outputs.
  Future<Map<String, OrtValue>> run(Future<Map<String, OrtValue>> Function() inputs, {String key = '', bool Function(Map<String, OrtValue> out)? accept}) async {
    if (_plain) return _runOn(await (_accelerated ??= _openAccelerated()), inputs, accept);
    Future<Map<String, OrtValue>?>? pending; // the accelerator's run that goes on in the background
    // (while a plan is being made the accelerator is busy for minutes, and a run of a size it has a plan for would wait behind it)
    if (!_acceleratorFailed && _ready.contains(key) && _compiling == null) {
      final out = await _tryAccelerated(inputs, key, accept);
      if (out != null) return _checked(out, inputs, key);
    } else if (!_acceleratorFailed && _compiling == null) {
      _compiling = key;
      final attempt = _tryAccelerated(inputs, key, accept);
      final model = _model;
      if (waitForPlan && model != null) onnxNoteRun(model, onnxMakingPlan, running: true);
      final first = waitForPlan
          ? await attempt.whenComplete(() => model == null ? null : onnxNoteRun(model, onnxMakingPlan, running: false))
          : await Future.any<Map<String, OrtValue>?>([attempt, Future<Map<String, OrtValue>?>.delayed(grace)]);
      if (first != null) return _checked(first, inputs, key);
      if (!_acceleratorFailed && !waitForPlan) {
        debugPrint('onnx: no plan for size "$key" yet: reading on the processor while the accelerator makes one');
        pending = attempt;
        if (model != null) {
          onnxNoteRun(model, onnxMakingPlan, running: true);
          unawaited(attempt.whenComplete(() => onnxNoteRun(model, onnxMakingPlan, running: false)));
        }
      }
    }
    final Map<String, OrtValue> out;
    try {
      out = await _runOn(await (_processor ??= _openProcessor()), inputs, null);
    } catch (e) {
      // (a runtime pack's processor part may lack operators of this model: then the plan is waited for)
      final late = pending == null ? null : await pending;
      if (late != null) return late;
      rethrow;
    }
    // (the background run goes on; when it ends its answer is of no use to this reading)
    if (pending != null) {
      unawaited(pending.then((o) async {
        for (final v in o?.values ?? const <OrtValue>[]) {
          await v.dispose();
        }
      }));
    }
    return out;
  }

  /// For finding out whether the accelerator answers what the processor does, on the app's own inputs: started with the environment
  /// variable NOTATION_CHECK_ACCELERATOR=1, every answer of the accelerator is worked out on the processor too, and how far apart they
  /// are is printed (a relative error of a few hundredths is what the graphics card files give; near 1 is a wrong answer).
  static final bool checkAgainstProcessor = !kIsWeb && Platform.environment['NOTATION_CHECK_ACCELERATOR'] == '1';

  Future<Map<String, OrtValue>> _checked(Map<String, OrtValue> out, Future<Map<String, OrtValue>> Function() inputs, String key) async {
    if (!checkAgainstProcessor) return out;
    try {
      final reference = await _runOn(await (_processor ??= _openProcessor()), inputs, null);
      for (final name in out.keys) {
        final a = await out[name]!.asFlattenedList(), b = await reference[name]?.asFlattenedList();
        if (b == null || a.length != b.length) {
          debugPrint('onnx check: size "$key", output $name: ${a.length} numbers on the accelerator, ${b?.length} on the processor');
          continue;
        }
        var diff = 0.0, norm = 0.0;
        for (var i = 0; i < a.length; i++) {
          final x = (a[i] as num).toDouble(), y = (b[i] as num).toDouble();
          diff += (x - y) * (x - y);
          norm += y * y;
        }
        debugPrint('onnx check: size "$key", output $name: relative error ${norm == 0 ? diff : math.sqrt(diff / norm)}');
      }
      for (final v in reference.values) {
        await v.dispose();
      }
    } catch (e) {
      debugPrint('onnx check: size "$key": the processor could not run it ($e)');
    }
    return out;
  }

  /// The run on the accelerator; null (and no accelerator from now on) if it fails.
  Future<Map<String, OrtValue>?> _tryAccelerated(Future<Map<String, OrtValue>> Function() inputs, String key, bool Function(Map<String, OrtValue>)? accept) async {
    try {
      final engine = await (_accelerated ??= _openAccelerated());
      final out = await _runOn(engine, inputs, accept, key: key);
      _ready.add(key);
      return out;
    } catch (e) {
      _acceleratorFailed = true;
      debugPrint('onnx: the accelerator could not run the model, using the processor from now on ($e)');
      return null;
    } finally {
      if (_compiling == key) _compiling = null;
    }
  }

  /// A run, and (when [accept] refuses the answer) a second one; an answer refused twice throws. With a [key] it is the accelerator's
  /// run: which plan is in memory is followed ([loaded], [onPlanned]).
  Future<Map<String, OrtValue>> _runOn(WarmEngine engine, Future<Map<String, OrtValue>> Function() inputs, bool Function(Map<String, OrtValue>)? accept, {String? key}) async {
    for (var attempt = 0;; attempt++) {
      final given = await inputs();
      // (a size other than the one in memory: its own plan is loaded, or made)
      final switching = _acceleratedRuns > 0 && _loaded != key;
      final Map<String, OrtValue> out;
      try {
        if (key != null) {
          _loaded = null; // (unknown until the run is done)
          _acceleratedRuns++;
        }
        out = await engine.run(given);
      } finally {
        for (final v in given.values) {
          await v.dispose();
        }
      }
      if (accept == null || accept(out)) {
        if (key != null) {
          _loaded = key;
          if (switching || oneSize) onPlanned?.call(key);
        }
        return out;
      }
      final shapes = [for (final v in out.values) v.shape];
      for (final v in out.values) {
        await v.dispose();
      }
      if (attempt >= 1) throw StateError('the answer has the wrong shape $shapes, twice');
      debugPrint('onnx: an answer of the wrong shape $shapes (a plan made for another size): running again');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final accelerated = _accelerated, processor = _processor;
    _accelerated = _processor = null;
    // (a plan that is still being made holds the accelerator's thread: not waited for)
    if (_compiling != null) {
      unawaited(accelerated?.then((e) => e.close()));
    } else {
      await (await accelerated)?.close();
    }
    await (await processor)?.close();
  }
}

/// A model's free input size, which CoreML needs fixed: the dimension's [name] in the model, and where an input carries it ([input],
/// [axis]). The handwriting reader's vision network: ('4*m', pixel_values, 0), the number of patches.
typedef PinnedSize = ({String name, String input, int axis});

/// CoreML with a model whose input size is free (see [PinnedSize]): one session for the size of the inputs, opened with that size fixed
/// (CoreML builds it once per size and keeps it in a folder of its own, see [coreMlOptions]); another size closes it and opens that
/// size's. One at a time: each holds the whole model.
@visibleForTesting
class OneSizeAtATime {
  final PinnedSize pin;
  final Future<WarmEngine> Function(int size) open;
  WarmEngine? _engine;
  int? _size;
  OneSizeAtATime(this.pin, this.open);

  /// The size of the session that is open, or null.
  int? get size => _size;

  Future<Map<String, OrtValue>> run(Map<String, OrtValue> inputs) async {
    final given = inputs[pin.input];
    if (given == null) throw StateError('the model has no input ${pin.input}');
    final size = given.shape[pin.axis];
    if (_size != size) {
      final old = _engine;
      _engine = null;
      _size = null;
      await old?.close();
      _engine = await open(size);
      _size = size;
    }
    return _engine!.run(inputs);
  }

  Future<void> close() async {
    final e = _engine;
    _engine = null;
    _size = null;
    await e?.close();
  }

  WarmEngine get engine => WarmEngine(run, close);
}

/// Opens [path] for [WarmSession]: with an accelerator that compiles for exact sizes (see [onnxNeedsFixedShapes]) as two sessions (the
/// accelerated one on a thread of its own, and a processor one made when first needed); otherwise as the one [openOnnxSession] gives.
/// With CoreML and a model whose input size is free ([pin]) the accelerated one is a session per size (see [OneSizeAtATime]): a size it
/// has not built yet is read on the processor meanwhile.
///
/// The sizes whose plan is made are noted in [AcceleratorPlans] (for the settings); [oneSize]: the model takes one input size only.
/// [processorPath]: another file of the same model for the processor (the handwriting reader's 8-bit vision file is quicker there than
/// the 16-bit one CoreML takes).
///
/// [parts]: the same model cut into parts (QNN on a phone: compiling the whole 868 MB vision network at once took the app past what
/// Android allows); used for the accelerated sessions of a pinned model, each part with the size fixed.
Future<WarmSession> openWarmSession(String path,
    {OrtSessionOptions? options, bool accelerate = true, bool oneSize = false, PinnedSize? pin, String? processorPath, List<String>? parts}) async {
  // (parts without the whole file, as Android downloads the handwriting reader's 16-bit network: the processor runs the parts too)
  final onlyParts = parts != null && parts.isNotEmpty && !File(path).existsSync();
  Future<WarmEngine> processor() async => onlyParts
      ? WarmEngine.parts(parts, (p, _) => openOnnxSession(p, options: options, accelerate: false))
      : WarmEngine.of(await openOnnxSession(processorPath ?? path, options: options, accelerate: false));
  if (accelerate && pin != null && await onnxPinsSizes(path)) {
    OrtSessionOptions fixed(int size) => OrtSessionOptions(
          intraOpNumThreads: options?.intraOpNumThreads,
          interOpNumThreads: options?.interOpNumThreads,
          useArena: options?.useArena,
          sessionConfigs: options?.sessionConfigs,
          lowPriority: options?.lowPriority,
          ownThread: options?.ownThread,
          freeDimensions: {...?options?.freeDimensions, pin.name: size},
        );
    final sized = OneSizeAtATime(
        pin,
        (size) async => parts != null && parts.isNotEmpty
            ? WarmEngine.parts(parts, (p, accelerate) => accelerate ? openOnnxSession(p, options: fixed(size)) : openOnnxSession(p, options: options, accelerate: false))
            : WarmEngine.of(await openOnnxSession(path, options: fixed(size))));
    return WarmSession._compiling(
      () async => sized.engine,
      processor,
      null,
      false,
      onnxModelName(path),
      // (QNN: a phone has no room for the processor's copy beside the one being compiled; CoreML reads on the processor meanwhile)
      waitForPlan: !await onnxUsesCoreMl(),
    );
  }
  if (accelerate && await onnxNeedsFixedShapes()) {
    OrtSessionOptions own() => OrtSessionOptions(
          intraOpNumThreads: options?.intraOpNumThreads,
          interOpNumThreads: options?.interOpNumThreads,
          useArena: options?.useArena,
          deviceId: options?.deviceId,
          sessionConfigs: options?.sessionConfigs,
          lowPriority: true,
          ownThread: true,
        );
    return WarmSession._compiling(
      () async => WarmEngine.of(await openOnnxSession(path, options: own())),
      () async => WarmEngine.of(await openOnnxSession(path, options: options, accelerate: false)),
      (key) => unawaited(AcceleratorPlans.add(path, key)),
      oneSize,
      onnxModelName(path),
    );
  }
  if (onlyParts) return WarmSession._plain(processor);
  return WarmSession._plain(() async => WarmEngine.of(await openOnnxSession(path, options: options, accelerate: accelerate)));
}
