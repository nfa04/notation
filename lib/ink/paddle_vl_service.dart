import 'dart:io';

import '../llm/model_files.dart';
import '../models/canvas_models.dart';
import 'ink_image.dart';
import 'onnx_paddle_vl.dart';
import 'paddle_vl.dart';

/// Reads handwriting with PaddleOCR-VL 1.5 (Apache 2.0, 0.9 billion parameters; the 4-bit ONNX files of `onnx-community`), run by
/// ONNX Runtime like the other readers, so it works wherever the app does. It is a model that looks at the picture of a line and
/// writes what it says, with the knowledge of a language model about which words are likely, which the small readers do not have.
/// It is big (about 900 MB to download, a gigabyte or two of memory while it reads) and slow (seconds for a line on a computer, more
/// on a tablet). The files are not part of the app: they are downloaded on request.
class PaddleVlService extends ModelFilesService {
  static const _repo = 'https://huggingface.co/onnx-community/PaddleOCR-VL-1.5-ONNX/resolve/main';
  static const modelFiles = {
    'vision.onnx': (url: '$_repo/onnx/vision_encoder_q4.onnx', megabytes: 231),
    'decoder.onnx': (url: '$_repo/onnx/decoder_q4.onnx', megabytes: 234),
    'embeddings.bin': (url: '$_repo/onnx/embedding.onnx.data', megabytes: 424),
    'tokenizer.json': (url: '$_repo/tokenizer.json', megabytes: 11),
  };

  /// Turns the pictures of lines into token ids. Tests pass a fake.
  final Future<List<List<int>>> Function(String visionPath, String decoderPath, String embeddingsPath, List<PaddleVlPicture> pictures) _read;

  PaddleVlService({
    Future<List<List<int>>> Function(String, String, String, List<PaddleVlPicture>)? read,
    super.modelDirectory,
    super.download,
  })  : _read = read ?? _readWithOnnx,
        super(files: modelFiles, folderName: 'paddleocr_vl');

  static Future<List<List<int>>> _readWithOnnx(String vision, String decoder, String embeddings, List<PaddleVlPicture> pictures) =>
      readPicturesOnnx(visionPath: vision, decoderPath: decoder, embeddingsPath: embeddings, pictures: pictures);

  PaddleVlVocabulary? _vocabulary;

  @override
  Future<void> unload() async => _vocabulary = null;

  /// The text of each of [lines] (the strokes of one line of writing each). Throws if the model is not installed or cannot run.
  Future<List<String>> readLines(List<List<DrawingStroke>> lines) async {
    if (!installed) throw StateError('The handwriting model is not installed.');
    final pictures = [for (final line in lines) await renderInkForPaddleVl(line)];
    final tokens = await _read(
      (await file('vision.onnx')).path,
      (await file('decoder.onnx')).path,
      (await file('embeddings.bin')).path,
      pictures,
    );
    final vocabulary = _vocabulary ??= PaddleVlVocabulary.parse(await File((await file('tokenizer.json')).path).readAsString());
    return [for (final t in tokens) vocabulary.decode(t)];
  }
}
