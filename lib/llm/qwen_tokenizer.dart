import 'dart:convert';
import 'dart:typed_data';

/// The tokenizer of Qwen models (byte-level BPE) from the model's
/// `tokenizer.json`. Text goes in as ids and ids come back as text; the
/// special tokens (`<|im_start|>`, `<think>`, ...) are found in the text as
/// they are written.
class QwenTokenizer {
  final Map<String, int> _vocab;
  final List<String> _tokens; // id -> token text (in the byte-to-letter alphabet)
  final Map<String, int> _ranks;
  final Map<String, int> _added; // special and added tokens: text -> id
  final Set<int> _special;
  final RegExp _addedPattern;

  QwenTokenizer._(this._vocab, this._tokens, this._ranks, this._added, this._special, this._addedPattern);

  /// Reads the contents of `tokenizer.json`.
  factory QwenTokenizer.parse(String json) {
    final data = jsonDecode(json) as Map<String, Object?>;
    final model = data['model'] as Map<String, Object?>;
    final vocab = (model['vocab'] as Map).map((k, v) => MapEntry(k as String, v as int));
    final ranks = <String, int>{};
    final merges = model['merges'] as List;
    for (var i = 0; i < merges.length; i++) {
      final m = merges[i];
      final pair = m is List ? '${m[0]} ${m[1]}' : m as String;
      ranks[pair] = i;
    }
    final added = <String, int>{};
    final special = <int>{};
    for (final t in (data['added_tokens'] as List).cast<Map<String, Object?>>()) {
      added[t['content'] as String] = t['id'] as int;
      if (t['special'] == true) special.add(t['id'] as int);
    }
    final size = [...vocab.values, ...added.values].fold<int>(0, (m, v) => v > m ? v : m) + 1;
    final tokens = List<String>.filled(size, '');
    vocab.forEach((k, v) => tokens[v] = k);
    added.forEach((k, v) => tokens[v] = k);
    final longestFirst = added.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    final pattern = RegExp(longestFirst.map(RegExp.escape).join('|'));
    return QwenTokenizer._(vocab, tokens, ranks, added, special, pattern);
  }

  int? idOf(String special) => _added[special];

  // Qwen's split into words; (?i:...) is written out because Dart has no inline flags
  static final _words = RegExp(
    r"(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
    unicode: true,
  );

  static final _byteToChar = _alphabet();
  static final Map<String, int> _charToByte = {for (var i = 0; i < 256; i++) _byteToChar[i]: i};

  /// GPT-2's table: every byte gets a visible character.
  static List<String> _alphabet() {
    final keep = <int>[
      for (var i = 33; i <= 126; i++) i,
      for (var i = 161; i <= 172; i++) i,
      for (var i = 174; i <= 255; i++) i,
    ];
    final table = List<String>.filled(256, '');
    var extra = 0;
    for (var b = 0; b < 256; b++) {
      table[b] = String.fromCharCode(keep.contains(b) ? b : 256 + extra++);
    }
    return table;
  }

  final Map<String, List<int>> _cache = {};

  List<int> _bpe(String word) {
    return _cache.putIfAbsent(word, () {
      var parts = word.runes.map(String.fromCharCode).toList();
      while (parts.length > 1) {
        var best = -1;
        var bestRank = 1 << 30;
        for (var i = 0; i < parts.length - 1; i++) {
          final r = _ranks['${parts[i]} ${parts[i + 1]}'];
          if (r != null && r < bestRank) {
            bestRank = r;
            best = i;
          }
        }
        if (best < 0) break;
        parts = [...parts.sublist(0, best), parts[best] + parts[best + 1], ...parts.sublist(best + 2)];
      }
      return [for (final p in parts) _vocab[p] ?? 0];
    });
  }

  /// The ids for [text]; special tokens written in it count as one token.
  List<int> encode(String text) {
    final ids = <int>[];
    var at = 0;
    void plain(String chunk) {
      for (final m in _words.allMatches(chunk)) {
        final bytes = utf8.encode(m.group(0)!);
        ids.addAll(_bpe(bytes.map((b) => _byteToChar[b]).join()));
      }
    }

    for (final m in _addedPattern.allMatches(text)) {
      if (m.start > at) plain(text.substring(at, m.start));
      ids.add(_added[m.group(0)!]!);
      at = m.end;
    }
    if (at < text.length) plain(text.substring(at));
    return ids;
  }

  /// The text for [ids]; special tokens are left out.
  String decode(Iterable<int> ids) {
    final bytes = BytesBuilder();
    for (final id in ids) {
      if (id < 0 || id >= _tokens.length || _special.contains(id)) continue;
      final token = _tokens[id];
      if (_added.containsKey(token)) {
        bytes.add(utf8.encode(token));
        continue;
      }
      for (final c in token.runes) {
        final b = _charToByte[String.fromCharCode(c)];
        if (b != null) bytes.addByte(b);
      }
    }
    return utf8.decode(bytes.toBytes(), allowMalformed: true);
  }
}
