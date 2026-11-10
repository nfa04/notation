import 'dart:convert';
import 'dart:math' as math;

/// The tokenizer of XLM-R style models (SentencePiece "unigram") from the model's
/// `tokenizer.json`: the text is cut at spaces, each word gets a `▁` in front, and
/// each is split into the pieces of the vocabulary whose scores add up best.
/// Text goes in as ids between `<s>` and `</s>`.
///
/// The model's own normaliser (Unicode compatibility forms) is not repeated: ordinary
/// text, already in composed form, comes out the same.
class UnigramTokenizer {
  final Map<String, ({int id, double score})> _pieces;
  final int unk, bos, eos;
  final int _longest;

  UnigramTokenizer._(this._pieces, this.unk, this.bos, this.eos, this._longest);

  /// Reads the contents of `tokenizer.json`.
  factory UnigramTokenizer.parse(String json) {
    final data = jsonDecode(json) as Map<String, Object?>;
    final model = data['model'] as Map<String, Object?>;
    if (model['type'] != 'Unigram') throw FormatException('not a Unigram tokenizer: ${model['type']}');
    final vocab = model['vocab'] as List;
    final pieces = <String, ({int id, double score})>{};
    var longest = 1;
    for (var i = 0; i < vocab.length; i++) {
      final entry = vocab[i] as List;
      final text = entry[0] as String;
      pieces[text] = (id: i, score: (entry[1] as num).toDouble());
      longest = math.max(longest, text.runes.length);
    }
    int special(String token, int fallback) => pieces[token]?.id ?? fallback;
    return UnigramTokenizer._(pieces, (model['unk_id'] as int?) ?? 3, special('<s>', 0), special('</s>', 2), longest);
  }

  static final _space = RegExp(r'\s+', unicode: true);

  /// The best split of one word (already with its `▁`): the pieces whose scores add up highest.
  List<int> _split(List<String> chars) {
    final n = chars.length;
    final best = List<double>.filled(n + 1, double.negativeInfinity)..[0] = 0;
    final from = List<int>.filled(n + 1, 0);
    final id = List<int>.filled(n + 1, unk);
    for (var end = 1; end <= n; end++) {
      for (var start = math.max(0, end - _longest); start < end; start++) {
        if (best[start] == double.negativeInfinity) continue;
        final piece = _pieces[chars.sublist(start, end).join()];
        // a character the vocabulary lacks is the unknown token, at a poor score
        final score = piece?.score ?? (end - start == 1 ? -100.0 : null);
        if (score == null) continue;
        if (best[start] + score > best[end]) {
          best[end] = best[start] + score;
          from[end] = start;
          id[end] = piece?.id ?? unk;
        }
      }
    }
    final out = <int>[];
    for (var at = n; at > 0; at = from[at]) {
      out.add(id[at]);
    }
    return out.reversed.toList();
  }

  /// The token ids of [text] without the markers around them.
  List<int> tokens(String text) {
    final out = <int>[];
    for (final word in text.split(_space)) {
      if (word.isEmpty) continue;
      final cleaned = String.fromCharCodes(word.runes.where((r) => r >= 32 && r != 0x7f && r != 0xFFFD));
      if (cleaned.isEmpty) continue;
      out.addAll(_split(('▁$cleaned').runes.map(String.fromCharCode).toList()));
    }
    // (a bare unknown after a bare "▁" would double up; the reference merges those, which rarely matters)
    return out;
  }

  /// [text] as `<s> ... </s>`, cut to at most [maxLength] ids.
  List<int> encode(String text, {int maxLength = 256}) {
    final t = tokens(text);
    return [bos, ...t.take(maxLength - 2), eos];
  }

  /// Several windows of [text] of at most [window] tokens each.
  List<List<int>> windows(String text, {int window = 256, int most = 4}) {
    final t = tokens(text);
    if (t.isEmpty) return [];
    final room = window - 2;
    return [
      for (var i = 0; i < t.length && i ~/ room < most; i += room) [bos, ...t.skip(i).take(room), eos],
    ];
  }
}
