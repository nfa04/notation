import 'dart:async';
import '../llm/onnx_session.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../llm/model_files.dart';
import '../web/web_files.dart';
import 'picture_edit.dart';

/// What runs the network that finds the subject of a picture: the real one is ONNX Runtime ([OnnxSubjectModel]); tests pass a
/// stand-in.
abstract class SubjectModel {
  /// What the network says of [input] (see [subjectModelInput]): [subjectModelSide] squared numbers, how sure it is of each pixel.
  Future<Float32List> run(Float32List input);

  Future<void> close();
}

/// [SubjectModel] run by ONNX Runtime.
class OnnxSubjectModel implements SubjectModel {
  final String path;
  OrtSession? _session;

  OnnxSubjectModel(this.path);

  static final _options = OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, useArena: false);

  @override
  Future<Float32List> run(Float32List input) async {
    final session = _session ??= await openOnnxSession(path, options: _options);
    final tensor = await OrtValue.fromList(input, [1, 3, subjectModelSide, subjectModelSide]);
    final out = await session.run({session.inputNames.first: tensor});
    await tensor.dispose();
    // (the network has several outputs, one for each of its stages: the first is the final one)
    final flat = await out[session.outputNames.first]!.asFlattenedList();
    for (final v in out.values) {
      await v.dispose();
    }
    final result = Float32List(flat.length);
    for (var i = 0; i < flat.length; i++) {
      result[i] = (flat[i] as num).toDouble();
    }
    return result;
  }

  @override
  Future<void> close() async {
    await _session?.close();
    _session = null;
  }
}

/// Finds the subject of a photograph, to take its background out. U²-Net-small (Apache 2.0, 4.6 MB, as published by the rembg
/// project) runs in ONNX Runtime, so it works on every platform the app does; it is not part of the app: it is downloaded on
/// request. Nothing leaves the device. It is good at one clear subject (a person, an animal, an object) and not at a crowd, or at
/// a picture that has none.
class SubjectService extends ModelFilesService {
  static const fileName = 'u2netp.onnx';

  /// The file as the rembg project publishes it (a release on GitHub), and an unchanged copy of it in a repository of ours on
  /// Hugging Face (https://huggingface.co/nfa04/u2netp-onnx, with the Apache-2.0 license text and the credit). The web build takes
  /// the copy, because a browser may only read a file from another site when that site allows it, and GitHub's release downloads
  /// do not (Hugging Face's do); every other build takes the release.
  static const githubUrl = 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/$fileName';
  static const hubUrl = 'https://huggingface.co/nfa04/u2netp-onnx/resolve/main/$fileName';
  static const url = kIsWeb ? hubUrl : githubUrl;

  /// SHA-256 of the file (the same at both places): a download that does not match is thrown away instead of being run.
  static const checksum = '309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8';

  final SubjectModel Function(String path) _open;
  SubjectModel? _model;

  final String? _checksum;

  /// [checksum]: what the downloaded file has to hash to (tests pass null to skip the check).
  SubjectService({SubjectModel Function(String path)? model, String? checksum = SubjectService.checksum, super.modelDirectory, super.download})
      : _open = model ?? OnnxSubjectModel.new,
        _checksum = checksum,
        super(files: const {fileName: (url: url, megabytes: 5)}, folderName: 'subject');

  @override
  Future<void> install() async {
    await super.install();
    final want = _checksum;
    if (want == null || !installed) return;
    final f = await file(fileName);
    await ensureWebFile(f.path); // (in a browser a model's file may be left empty until it is needed)
    final got = await f.exists() ? (await sha256.bind(f.openRead()).first).toString() : '';
    if (got == want) return;
    await remove();
    error = 'The downloaded file $fileName is not the one that was published (its checksum differs). Try again.';
    notifyListeners();
  }

  /// What the model says of [picture]: null if the model is not installed.
  Future<SubjectMatte?> find(RgbaPicture picture) async {
    if (!installed) return null;
    final model = _model ??= _open((await file(fileName)).path);
    final answer = await model.run(subjectModelInput(picture));
    return subjectMatteFrom(answer);
  }

  @override
  Future<void> unload() async {
    final model = _model;
    _model = null;
    await model?.close();
  }
}
