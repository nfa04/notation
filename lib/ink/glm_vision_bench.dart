import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../llm/accelerator_plans.dart';
import '../llm/onnx_qwen.dart' show onnxThreads;
import '../llm/onnx_session.dart';
import 'glm_ocr.dart';
import 'ink_image.dart' show glmPaddedWidths;
import 'glm_ocr_service.dart';

/// How long the handwriting reader's vision network takes for a line of writing (the part that can run on an accelerator), on the
/// accelerator and on the processor, so that the person can see whether the accelerator is worth it on this device. Returns one text
/// per way: what it ran on, the median of [runs] runs, and the time to open the model.
Future<List<String>> benchmarkGlmVision(GlmOcrService glm, {int runs = 5, int rows = 10, int columns = 100}) async {
  final path = (await glm.file(glm.visionFile)).path;
  final count = rows * columns;
  final patches = Float32List(count * 3 * 2 * glmPatch * glmPatch);
  for (var i = 0; i < patches.length; i++) {
    patches[i] = ((i * 2654435761) % 2000) / 1000 - 1; // (the same numbers every time)
  }
  final positions = glmPatchPositions(rows, columns);
  final lines = <String>[];
  for (final accelerate in [true, false]) {
    final opening = Stopwatch()..start();
    final session = await openOnnxSession(
      path,
      options: OrtSessionOptions(intraOpNumThreads: onnxThreads, interOpNumThreads: 1, useArena: false),
      accelerate: accelerate,
      force: accelerate, // (asked for here, whatever the setting says)
    );
    opening.stop();
    final on = onnxSessionReport[glm.visionFile] ?? '?';
    try {
      final times = <int>[];
      for (var i = 0; i < runs + 1; i++) {
        final watch = Stopwatch()..start();
        final pixels = await OrtValue.fromList(patches, [count, 3 * 2 * glmPatch * glmPatch]);
        final ids = await int64Value(positions, [count, 2]);
        final out = await session.run({'pixel_values': pixels, 'pos_ids': ids});
        await (out[session.outputNames.first] ?? out.values.first).asFlattenedList();
        watch.stop();
        for (final v in [pixels, ids, ...out.values]) {
          await v.dispose();
        }
        if (i > 0) times.add(watch.elapsedMilliseconds); // (the first run warms up: compiling, uploading)
      }
      times.sort();
      lines.add('$on: ${times[times.length ~/ 2]} ms per line (best ${times.first}, worst ${times.last}), opened in ${opening.elapsedMilliseconds} ms');
    } finally {
      await session.close();
    }
  }
  return lines;
}

/// The picture widths (in columns of 28 pixels) a line of handwriting can have when pictures are padded (see [glmPaddedWidths]): a piece is
/// never wider than [GlmOcrService.widestPiece] times its height, so the wider sizes are never met.
List<int> glmSizesToPrepare({int rows = 10}) {
  final widest = (GlmOcrService.widestPiece * rows / 2).ceil();
  final out = <int>[];
  for (final w in glmPaddedWidths) {
    out.add(w);
    if (w >= widest) break;
  }
  return out;
}

/// The size of a picture of [rows] rows and [columns] columns of 28 pixels as the reader names it for its plans ([GlmPicture.gridHeight] x
/// [GlmPicture.gridWidth], in patches of 14).
String glmPlanKey(int rows, int columns) => '${rows}x${columns * 2}';

/// The picture sizes of [rows] whose plan is not on disk yet, as far as the app knows ([AcceleratorPlans]), in columns of 28 pixels; null
/// when the graphics card file of the reader is not installed.
Future<List<int>?> glmSizesMissing(GlmOcrService glm, {int rows = 10}) async {
  if (glm.inUse != GlmWeights.gpu || !glm.installed) return null;
  final have = await AcceleratorPlans.sizes((await glm.file(glm.visionFile)).path);
  return [for (final w in glmSizesToPrepare(rows: rows)) if (!have.contains(glmPlanKey(rows, w))) w];
}

/// Makes the accelerator's plan for every picture size of the handwriting reader now (AMD: 4 to 5 minutes each the first time, kept on disk),
/// so that no reading has to wait for one or read on the processor. Needs the vision file for graphics cards. [progress] gets the number
/// done and the total; [cancelled] is asked between sizes (a plan being made is finished first).
Future<void> precompileGlmSizes(GlmOcrService glm, {int rows = 10, void Function(int done, int total)? progress, bool Function()? cancelled}) async {
  if (glm.inUse != GlmWeights.gpu) {
    throw StateError('Plans can only be made for the graphics card file of the handwriting model (Settings > Handwriting > Size of the model).');
  }
  final path = (await glm.file(glm.visionFile)).path;
  final widths = glmSizesToPrepare(rows: rows);
  progress?.call(0, widths.length); // (opening the file takes a while: the number is known before)
  final session = await openOnnxSession(path, options: OrtSessionOptions(intraOpNumThreads: onnxThreads, interOpNumThreads: 1, useArena: false, ownThread: true), force: true);
  // (true when the answer has the size of this picture: the first run of a session can be answered by a plan of another size)
  Future<bool> runAt(int columns) async {
    final grid = columns * 2;
    final count = rows * grid;
    final pixels = await OrtValue.fromList(Float32List(count * 3 * 2 * glmPatch * glmPatch), [count, 3 * 2 * glmPatch * glmPatch]);
    final ids = await int64Value(glmPatchPositions(rows, grid), [count, 2]);
    final out = await session.run({'pixel_values': pixels, 'pos_ids': ids});
    final right = out.values.first.shape.fold<int>(1, (a, b) => a * b) == count ~/ 4 * glmHidden;
    for (final v in [pixels, ids, ...out.values]) {
      await v.dispose();
    }
    return right;
  }

  // (a run of another size than the one before loads its own plan, or makes it: then it is on disk)
  Future<void> planned(int columns) => AcceleratorPlans.add(path, glmPlanKey(rows, columns));

  try {
    // How ONNX Runtime 1.23 keeps MIGraphX plans (seen in its log): the first run of a session loads the first plan ever made for the model
    // (file "...-0.mxr", whatever its size) without comparing sizes, or makes it when there is none; a later run of another size than the
    // plan in memory loads that size's own file, or makes it. So the first size is run twice (the second run gets its own plan unless the
    // "-0" one was of that size), and once more at the end: if "-0" was made now, that last run makes the first size's own file, which a
    // later session needs (it never uses "-0" for it after another size).
    for (var i = 0; i < widths.length; i++) {
      if (cancelled?.call() ?? false) return;
      final right = await runAt(widths[i]);
      if (i == 0) {
        // (a wrong first answer was another size's plan: the second run then loads or makes this size's own)
        if (await runAt(widths[i]) && !right) await planned(widths[i]);
      } else {
        await planned(widths[i]);
      }
      progress?.call(i + 1, widths.length);
    }
    if (widths.length > 1 && !(cancelled?.call() ?? false)) {
      await runAt(widths.first);
      await planned(widths.first);
    }
  } finally {
    await session.close();
  }
}
