import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'math_decoder.dart' show MathVocab;

/// What GLM-OCR (zai-org/GLM-OCR, MIT, 0.9 billion parameters) needs around its two networks, which `onnx_glm_ocr.dart` runs: the
/// picture of a line cut into patches, the positions of the patches and of the words of the prompt, the prompt itself, the words of the
/// model's own vocabulary and its table of word vectors. Everything here was checked against the Python of the model (the processor of
/// transformers and `get_rope_index`): see `test/glm_ocr_test.dart` and `tool/handwriting_bench/glm_onnx/`.
const glmPatch = 14;
const glmMerge = 2; // 2 x 2 patches become one token
const glmHidden = 1536;
const glmLayers = 16;
const glmKvHeads = 8;
const glmHeadDim = 128;

/// The word table has this many rows (the vocabulary of 59 246 words and the special tokens after them).
const glmTableRows = 59392;

/// How many words [GlmVocabulary] spells: the ordinary ones. What comes after (the end of the text, the picture, the roles) is special.
const glmOrdinaryTokens = 59246;
const glmImageToken = 59280;
const glmEndTokens = {59246, 59253}; // <|endoftext|>, <|user|>

/// `[gMASK]<sop><|user|>\n<|begin_of_image|>`, then the picture's places, then `<|end_of_image|>Text Recognition:<|assistant|>\n`
/// (the token ids of the chat template of the model, checked against its tokenizer).
const glmPromptBefore = [59248, 59250, 59253, 10, 59256];
const glmPromptAfter = [59257, 3649, 7404, 49600, 58, 59254, 10];

/// The pictures must have at least this many pixels (the processor of the model enlarges smaller ones) and no more patches on a side
/// than the position table of the exported vision network has.
const glmMinPixels = 12544;
const glmMaxPatchesPerSide = 512;

/// The picture of a line, as the vision network takes it: [patches] is [gridHeight] x [gridWidth] patches of 1176 numbers each.
class GlmPicture {
  final Float32List patches;
  final int gridHeight, gridWidth;
  const GlmPicture(this.patches, this.gridHeight, this.gridWidth);

  int get count => gridHeight * gridWidth;
}

const _mean = [0.48145466, 0.4578275, 0.40821073];
const _spread = [0.26862954, 0.26130258, 0.27577711];

/// The pixels [rgba] (4 bytes each, [width] x [height], both a multiple of 28) as patches of 14 x 14: every colour as
/// `(value / 255 - mean) / spread`, the patches in blocks of 2 x 2 (a block is one token), each patch as its three colours, each of
/// them twice (the model's two video frames; a picture is the same frame twice), each as 14 rows of 14.
Float32List glmPatches(Uint8List rgba, int width, int height) {
  assert(width % 28 == 0 && height % 28 == 0);
  final gh = height ~/ glmPatch, gw = width ~/ glmPatch;
  const frame = glmPatch * glmPatch;
  final out = Float32List(gh * gw * 3 * 2 * frame);
  var at = 0;
  for (var by = 0; by < gh ~/ 2; by++) {
    for (var bx = 0; bx < gw ~/ 2; bx++) {
      for (var my = 0; my < 2; my++) {
        for (var mx = 0; mx < 2; mx++) {
          final y0 = (by * 2 + my) * glmPatch, x0 = (bx * 2 + mx) * glmPatch;
          for (var c = 0; c < 3; c++) {
            for (var y = 0; y < glmPatch; y++) {
              var p = 4 * ((y0 + y) * width + x0) + c;
              for (var x = 0; x < glmPatch; x++) {
                final v = (rgba[p] / 255 - _mean[c]) / _spread[c];
                out[at + y * glmPatch + x] = v;
                out[at + frame + y * glmPatch + x] = v;
                p += 4;
              }
            }
            at += 2 * frame;
          }
        }
      }
    }
  }
  return out;
}

/// Row and column of every patch of a [gridHeight] x [gridWidth] picture, in the order of [glmPatches] (row, column, row, column ...).
List<int> glmPatchPositions(int gridHeight, int gridWidth) {
  final out = <int>[];
  for (var by = 0; by < gridHeight ~/ 2; by++) {
    for (var bx = 0; bx < gridWidth ~/ 2; bx++) {
      for (var my = 0; my < 2; my++) {
        for (var mx = 0; mx < 2; mx++) {
          out..add(by * 2 + my)..add(bx * 2 + mx);
        }
      }
    }
  }
  return out;
}

/// The token ids of the prompt for a picture of [gridHeight] x [gridWidth] patches (one token for every 2 x 2 patches).
List<int> glmPrompt(int gridHeight, int gridWidth) =>
    [...glmPromptBefore, ...List.filled(gridHeight ~/ glmMerge * (gridWidth ~/ glmMerge), glmImageToken), ...glmPromptAfter];

/// The position of every token of [glmPrompt], as the three rows the model's rotary embedding takes (time, height, width), one after
/// the other: the words before the picture count 0, 1, 2 ... in all three; the picture's tokens share one time (where it begins)
/// and take height and width from their place in the grid; the words after it go on from where the picture began plus its longer side.
List<int> glmPromptPositions(int gridHeight, int gridWidth) {
  final gh = gridHeight ~/ glmMerge, gw = gridWidth ~/ glmMerge;
  final length = glmPromptBefore.length + gh * gw + glmPromptAfter.length;
  final rows = [for (var r = 0; r < 3; r++) List<int>.filled(length, 0)];
  var at = 0;
  for (var i = 0; i < glmPromptBefore.length; i++, at++) {
    for (final r in rows) {
      r[at] = i;
    }
  }
  final start = glmPromptBefore.length;
  for (var y = 0; y < gh; y++) {
    for (var x = 0; x < gw; x++, at++) {
      rows[0][at] = start;
      rows[1][at] = start + y;
      rows[2][at] = start + x;
    }
  }
  var next = start + (gh > gw ? gh : gw);
  for (var i = 0; i < glmPromptAfter.length; i++, at++, next++) {
    for (final r in rows) {
      r[at] = next;
    }
  }
  return [for (final r in rows) ...r];
}

/// The words of the model, to turn the tokens it wrote back into text: `vocab.txt` has the spelling of every ordinary token, one per
/// line in id order, in the byte-level form of the BPE (a space is `Ġ`, a line break `Ċ`).
class GlmVocabulary {
  final List<String> pieces;
  const GlmVocabulary(this.pieces);

  factory GlmVocabulary.parse(String source) => GlmVocabulary(source.split('\n')..removeLast());

  /// The text of [ids]; the special tokens (the end, the picture, the roles) are left out.
  String decode(Iterable<int> ids) {
    final bytes = <int>[];
    for (final id in ids) {
      if (id < 0 || id >= pieces.length || id >= glmOrdinaryTokens) continue;
      for (final rune in pieces[id].runes) {
        final b = MathVocab.byteOfBpeChar[rune];
        if (b != null) bytes.add(b);
      }
    }
    return utf8.decode(bytes, allowMalformed: true).trim();
  }
}

/// The table of word vectors, read row by row from its file (it is 87 MB and a line needs a few dozen rows): the rows of
/// [glmTableRows] x [glmHidden] as whole numbers of 8 bits, then one float32 for each row that they are multiplied with.
class GlmEmbeddings {
  final RandomAccessFile _file;
  final Map<int, Float32List> _rows = {};
  GlmEmbeddings._(this._file);

  static Future<GlmEmbeddings> open(String path) async => GlmEmbeddings._(await File(path).open());

  Future<Float32List> row(int id) async {
    final known = _rows[id];
    if (known != null) return known;
    await _file.setPosition(id * glmHidden);
    final q = await _file.read(glmHidden);
    await _file.setPosition(glmTableRows * glmHidden + id * 4);
    final scale = ByteData.sublistView(Uint8List.fromList(await _file.read(4))).getFloat32(0, Endian.little);
    final out = Float32List(glmHidden);
    for (var i = 0; i < glmHidden; i++) {
      out[i] = (q[i] > 127 ? q[i] - 256 : q[i]) * scale;
    }
    return _rows[id] = out;
  }

  Future<void> close() => _file.close();
}
