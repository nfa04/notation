import '../data/note_repository.dart';
import '../ink/ink_clusters.dart';
import '../models/canvas_models.dart';
import 'search_query.dart';

/// The setting that switches reading the writing for the search off (`0`); it is on otherwise.
const inkIndexSetting = 'index_handwriting';

/// Reads the handwriting of the notes with the handwriting reader and keeps the text, so that the search can look in it (see
/// `ink_text`). Goes through the notes one after the other, reads the blocks of strokes that have no text yet, and stops when
/// [stop] says so. A note that is open is read by its editor as it is written (see `InkPrefetcher`); this is for all the others.
class InkIndexer {
  final NoteRepository repository;

  /// Reads the strokes of a block as text.
  final Future<String> Function(List<DrawingStroke> strokes) read;

  InkIndexer(this.repository, this.read);

  bool _running = false;

  /// Reads what is not read yet; [progress] is told (done, all) after each note. Returns how many blocks were read.
  Future<int> run({bool Function()? stop, void Function(int done, int all)? progress}) async {
    if (_running) return 0;
    _running = true;
    var blocks = 0;
    try {
      final ids = await repository.text.noteIdsWithInk();
      var done = 0;
      progress?.call(0, ids.length);
      for (final id in ids) {
        if (stop?.call() ?? false) break;
        blocks += await _index(id, stop);
        progress?.call(++done, ids.length);
      }
    } finally {
      _running = false;
    }
    return blocks;
  }

  Future<int> _index(String id, bool Function()? stop) async {
    final note = await repository.loadNote(id);
    if (note == null) return 0;
    final clusters = [for (final e in note.strokes.entries) ...clusterStrokes(e.key, e.value)];
    final have = {for (final t in await repository.text.inkTexts(id)) t.key: t};
    final fresh = <InkText>[];
    for (final c in clusters) {
      if (have.containsKey(c.key)) continue;
      if (stop?.call() ?? false) break;
      try {
        fresh.add(InkText(key: c.key, page: c.page, text: (await read(c.strokes)).trim(), bounds: c.bounds));
      } catch (_) {
        // a block the reader cannot read is left; the next run tries again
      }
    }
    final alive = {for (final c in clusters) c.key};
    if (fresh.isNotEmpty || have.keys.any((k) => !alive.contains(k))) await repository.text.saveInkText(id, fresh, alive);
    return fresh.length;
  }
}
