import 'package:flutter/material.dart' hide Text;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' show OrtProvider;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../llm/onnx_session.dart';

/// Where the models of a reading run: a line for each model that ran since [since] (or runs now), such as "Handwriting, picture part:
/// graphics card (MIGraphX)". With [compact], one short line of the places of what runs now ("graphics card + processor").
class OnnxPlaces extends StatelessWidget {
  final DateTime since;
  final TextStyle? style;
  final bool compact;

  /// Only the models in these folders (those of the reader that was asked; null: every model): another reader can run meanwhile, the
  /// one that reads the note in the background.
  final Set<String>? folders;

  const OnnxPlaces({super.key, required this.since, this.style, this.compact = false, this.folders});

  /// The model folders of the formula readers and of the handwriting readers, for [folders].
  static const formulaFolders = {'texteller', 'math'};
  static const handwritingFolders = {'glm_ocr', 'paddleocr_vl'};

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<String, OnnxRun>>(
        valueListenable: onnxRuns,
        builder: (context, runs, _) {
          // (compact: what ran in the last half minute, so that the line does not blink between one run and the next)
          final from = compact ? DateTime.now().subtract(const Duration(seconds: 30)) : since;
          final byModel = <String, List<OnnxRun>>{};
          for (final r in runs.values) {
            if (folders != null && !folders!.contains(r.model.split('/').first)) continue;
            if (r.running > 0 || !r.at.isBefore(from)) (byModel[r.model] ??= []).add(r);
          }
          if (compact) {
            final now = <String>{
              for (final list in byModel.values)
                for (final r in _current(list)) _short(r.on),
            };
            if (now.isEmpty) return const SizedBox.shrink();
            return Text.verbatim(now.join(' + '), key: const ValueKey('onnx-places-compact'), style: style);
          }
          if (byModel.isEmpty) return const SizedBox.shrink();
          return Column(
            key: const ValueKey('onnx-places'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in byModel.entries)
                Text.verbatim('${_model(e.key)}: ${_where(e.value)}', style: style),
            ],
          );
        },
      );

  /// The places of one model: those where it runs now, or else the last one.
  static String _where(List<OnnxRun> runs) => _current(runs).map((r) => _long(r.on)).join(', ');

  static List<OnnxRun> _current(List<OnnxRun> runs) {
    final now = [for (final r in runs) if (r.running > 0) r];
    return now.isNotEmpty ? now : [(runs.toList()..sort((a, b) => a.at.compareTo(b.at))).last];
  }
}

/// Which model, what it is for, which of its parts, and the file (which tells the weights: "vision-gpu.onnx" is the one for graphics
/// cards): "GLM-OCR (handwriting), picture part: vision-gpu.onnx".
String _model(String model) {
  final parts = model.split('/');
  final folder = parts.first, file = parts.last;
  final picture = file.startsWith('vision') || file.startsWith('encoder');
  final ({String name, String purpose})? known = switch (folder) {
    'glm_ocr' => (name: 'GLM-OCR', purpose: tr('handwriting')),
    'paddleocr_vl' => (name: 'PaddleOCR-VL', purpose: tr('handwriting')),
    'texteller' => (name: 'TexTeller', purpose: tr('formulas')),
    'math' => (name: 'Pix2Text', purpose: tr('formulas')),
    _ when folder.startsWith('whisper_') => (name: 'Whisper ${folder.substring('whisper_'.length)}', purpose: tr('speech')),
    _ when folder.startsWith('embed_') => (name: tr('embedding model'), purpose: tr('search')),
    _ when folder.startsWith('llm') => (name: 'Qwen', purpose: tr('language model')),
    _ => null,
  };
  if (known == null) return model;
  final part = folder.startsWith('whisper_')
      ? (picture ? tr('sound part') : tr('text part'))
      : folder == 'glm_ocr' || folder == 'paddleocr_vl' || folder == 'texteller' || folder == 'math'
          ? (picture ? tr('picture part') : tr('text part'))
          : null;
  return part == null
      ? tr('{model} ({purpose}): {file}', {'model': known.name, 'purpose': known.purpose, 'file': file})
      : tr('{model} ({purpose}), {part}: {file}', {'model': known.name, 'purpose': known.purpose, 'part': part, 'file': file});
}

const _names = {
  'MIGRAPHX': 'AMD MIGraphX',
  'ROCM': 'AMD ROCm',
  'CUDA': 'NVIDIA CUDA',
  'TENSOR_RT': 'NVIDIA TensorRT',
  'DIRECT_ML': 'DirectML',
  'WEB_GPU': 'WebGPU',
  'WEB_GL': 'WebGL',
  'CORE_ML': 'Core ML',
  'NNAPI': 'NNAPI',
  'QNN': 'Qualcomm QNN',
  'OPEN_VINO': 'OpenVINO',
  'WEB_NN': 'WebNN',
  'XNNPACK': 'XNNPACK',
  'DNNL': 'oneDNN',
  'ACL': 'Arm Compute Library',
};

final _graphics = {OrtProvider.MIGRAPHX, OrtProvider.ROCM, OrtProvider.CUDA, OrtProvider.TENSOR_RT, OrtProvider.DIRECT_ML, OrtProvider.WEB_GPU, OrtProvider.WEB_GL}.map((p) => p.name).toSet();
final _accelerators = {OrtProvider.CORE_ML, OrtProvider.NNAPI, OrtProvider.QNN, OrtProvider.OPEN_VINO, OrtProvider.WEB_NN}.map((p) => p.name).toSet();

String _long(String on) {
  if (on == onnxMakingPlan) return tr('the graphics card is making its plan for this picture size (minutes, once); the processor reads meanwhile');
  if (on == OrtProvider.CPU.name) return tr('processor (CPU)');
  if (on == OrtProvider.WEB_ASSEMBLY.name) return tr('processor (in the browser)');
  final name = _names[on] ?? on;
  if (_graphics.contains(on)) return tr('graphics card ({name})', {'name': name});
  if (_accelerators.contains(on)) return tr('accelerator ({name})', {'name': name});
  return tr('processor ({name})', {'name': name});
}

String _short(String on) {
  if (on == onnxMakingPlan) return tr('graphics card making a plan');
  if (_graphics.contains(on)) return tr('graphics card');
  if (_accelerators.contains(on)) return tr('accelerator');
  return tr('processor');
}
