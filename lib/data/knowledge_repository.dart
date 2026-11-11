import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../citations/citation_document.dart' show findCitations;
import 'note_data.dart';
import '../util/whole_number.dart';

/// What is worked out from the text of notes and kept: the vector of a note, its passages (see `NoteKnowledge`), its facts and the
/// graph built from them (see `GraphService`), and the links and citations written in notes. Locked and deleted notes are left out.
class KnowledgeRepository {
  final Database _db;

  KnowledgeRepository(this._db);

  /// Told (`graph:<uid>`) when a graph is made, renamed or removed here - not when the sync takes one in - so that the sync of the
  /// devices (which listens for what changed) carries it soon, as it does a note that was saved.
  void Function(String id)? onChange;

  /// What was kept of the reading of note [id] by [model]; null if nothing, or if it was by another model.
  Future<({int textHash, Float32List vector})?> noteEmbedding(String id, String model) async {
    final rows = await _db.query('note_embeddings', where: 'note_id = ? AND model = ?', whereArgs: [id, model]);
    if (rows.isEmpty) return null;
    final bytes = rows.single['vector'] as Uint8List;
    return (
      textHash: wholeNumber( rows.single['text_hash']),
      vector: Float32List.fromList(Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4)),
    );
  }

  Future<void> saveNoteEmbedding(String id, String model, int textHash, Float32List vector) => _db.insert(
        'note_embeddings',
        {
          'note_id': id,
          'model': model,
          'text_hash': textHash,
          'vector': Uint8List.view(vector.buffer, vector.offsetInBytes, vector.lengthInBytes),
        },
        conflictAlgorithm: ConflictAlgorithm.replace
      );

  // ---- passages (see NoteKnowledge)

  /// The model and the hash of the text the passages of note [id] were made from; null if there are none.
  Future<({String model, int textHash})?> chunkState(String id) async {
    final rows = await _db.query('note_chunk_state', where: 'note_id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : (model: rows.single['model'] as String, textHash: wholeNumber( rows.single['text_hash']),);
  }

  /// Keeps [chunks] as the passages of note [id].
  Future<void> saveChunks(String id, String model, int textHash, List<StoredChunk> chunks) => _db.transaction((txn) async {
        await txn.delete('note_chunks', where: 'note_id = ?', whereArgs: [id]);
        final batch = txn.batch();
        for (var i = 0; i < chunks.length; i++) {
          final c = chunks[i];
          batch.insert('note_chunks', {
            'note_id': id,
            'idx': i,
            'page': c.page,
            'label': c.label,
            'text': c.text,
            'vector': c.vector == null ? null : Uint8List.view(c.vector!.buffer, c.vector!.offsetInBytes, c.vector!.lengthInBytes),
          });
        }
        await batch.commit(noResult: true);
        await txn.insert('note_chunk_state', {'note_id': id, 'model': model, 'text_hash': textHash}, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<List<StoredChunk>> chunksOf(String id) async {
    final rows = await _db.query('note_chunks', where: 'note_id = ?', whereArgs: [id], orderBy: 'idx');
    return [
      for (final r in rows)
        StoredChunk(
          r['page'] as int?,
          r['label'] as String,
          r['text'] as String,
          r['vector'] == null ? null : Float32List.fromList(Float32List.view((r['vector'] as Uint8List).buffer, (r['vector'] as Uint8List).offsetInBytes, (r['vector'] as Uint8List).lengthInBytes ~/ 4)),
        ),
    ];
  }

  // ---- facts and the graph (see GraphService)

  Future<({int textHash, String model, String extractor})?> factState(String id) async {
    final rows = await _db.query('fact_state', where: 'note_id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return (textHash: wholeNumber( rows.single['text_hash']), model: rows.single['model'] as String, extractor: rows.single['extractor'] as String);
  }

  Future<void> replaceFacts(String id, int textHash, String model, String extractor, List<StoredFact> facts) => _db.transaction((txn) async {
        await txn.delete('facts', where: 'note_id = ?', whereArgs: [id]);
        final batch = txn.batch();
        for (final f in facts) {
          batch.insert('facts', {
            'note_id': id,
            'page': f.page,
            'title': f.title,
            'tag': f.tag,
            'sentence': f.sentence,
            'keywords': f.keywords.join(','),
            'vector': f.vector == null ? null : Uint8List.view(f.vector!.buffer, f.vector!.offsetInBytes, f.vector!.lengthInBytes),
          });
        }
        await batch.commit(noResult: true);
        await txn.insert('fact_state', {'note_id': id, 'text_hash': textHash, 'model': model, 'extractor': extractor}, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  /// The facts of the notes that are not in the trash and not locked.
  Future<List<StoredFact>> allFacts() async {
    final rows = await _db.rawQuery('''
      SELECT f.* FROM facts f JOIN notes n ON n.id = f.note_id
       WHERE n.deleted_at IS NULL AND n.lock_mode = 0 ORDER BY f.note_id, f.id
    ''');
    return [
      for (final r in rows)
        StoredFact(
          id: r['id'] as int,
          noteId: r['note_id'] as String,
          page: r['page'] as int?,
          title: r['title'] as String,
          tag: r['tag'] as String,
          sentence: r['sentence'] as String,
          keywords: (r['keywords'] as String).isEmpty ? const [] : (r['keywords'] as String).split(','),
          vector: r['vector'] == null ? null : Float32List.fromList(Float32List.view((r['vector'] as Uint8List).buffer, (r['vector'] as Uint8List).offsetInBytes, (r['vector'] as Uint8List).lengthInBytes ~/ 4)),
        ),
    ];
  }

  /// Keeps a graph as a new one ([replace] null; returns its id) or in the place of the graph [replace] (name kept).

  Future<int> saveGraph({
    required String name,
    required String mode,
    required String? folderId,
    required String payload,
    int? replace,
  }) async {
    final at = DateTime.now().millisecondsSinceEpoch;
    if (replace != null) {
      await _archive(where: 'id = ?', args: [replace]);
      final changed = await _db.update(
        'saved_graphs',
        {
          'mode': mode,
          'folder_id': folderId,
          'built_at': at,
          'updated_at': at, 'payload': payload},
        where: 'id = ?',
        whereArgs: [replace],
      );
      if (changed > 0) {
        await _told(replace);
        return replace;
      }
    }
    final id = await _db.insert('saved_graphs', {
      'uid': newGraphUid(),
      'name': name,
      'mode': mode,
      'folder_id': folderId,
      'built_at': at,
      'updated_at': at,
      'payload': payload,
    });
    await _told(id);
    return id;
  }

  /// How many earlier pictures are kept for each graph.
  static const keptVersions = 5;

  /// Puts the picture of the graph that [where] finds into `graph_versions` (before it is replaced), and drops the oldest ones past
  /// [keptVersions]. Nothing when there is no such graph.
  Future<void> _archive({required String where, required List<Object?> args}) async {
    final rows = await _db.query('saved_graphs', columns: ['uid', 'mode', 'built_at', 'payload'], where: where, whereArgs: args);
    if (rows.isEmpty) return;
    final r = rows.single;
    final uid = r['uid'] as String;
    var nodes = 0;
    try {
      nodes = ((jsonDecode(r['payload'] as String) as Map)['nodes'] as List).length;
    } catch (_) {}
    await _db.insert('graph_versions', {'graph_uid': uid, 'mode': r['mode'], 'built_at': r['built_at'], 'nodes': nodes, 'payload': r['payload']});
    await _db.delete(
      'graph_versions',
      where: 'graph_uid = ? AND id NOT IN (SELECT id FROM graph_versions WHERE graph_uid = ? ORDER BY id DESC LIMIT $keptVersions)',
      whereArgs: [uid, uid],
    );
  }

  /// The earlier pictures that are kept (without the pictures), newest first; of the graph [uid], or of all.
  Future<List<GraphVersion>> listGraphVersions({String? uid}) async {
    final rows = await _db.query(
      'graph_versions',
      columns: ['id', 'graph_uid', 'mode', 'built_at', 'nodes'],
      where: uid == null ? null : 'graph_uid = ?',
      whereArgs: uid == null ? null : [uid],
      orderBy: 'id DESC',
    );
    return [
      for (final r in rows)
        GraphVersion(
          id: r['id'] as int,
          graphUid: r['graph_uid'] as String,
          mode: r['mode'] as String,
          builtAt: DateTime.fromMillisecondsSinceEpoch(r['built_at'] as int),
          nodes: r['nodes'] as int,
        ),
    ];
  }

  Future<String?> loadGraphVersion(int id) async {
    final rows = await _db.query('graph_versions', columns: ['payload'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.single['payload'] as String;
  }

  Future<void> deleteGraphVersion(int id) => _db.delete('graph_versions', where: 'id = ?', whereArgs: [id]);

  /// Brings an earlier picture back as the graph's picture; the one that was there takes its place in the list. Returns the id of the
  /// graph, or null when the picture or its graph is gone. The graph counts as changed now (the other devices take it over).
  Future<int?> restoreGraphVersion(int id) async {
    final found = await _db.query('graph_versions', where: 'id = ?', whereArgs: [id]);
    if (found.isEmpty) return null;
    final v = found.single;
    final graph = await _db.query('saved_graphs', columns: ['id'], where: 'uid = ?', whereArgs: [v['graph_uid']]);
    if (graph.isEmpty) return null;
    final graphId = graph.single['id'] as int;
    await _archive(where: 'id = ?', args: [graphId]);
    await _db.delete('graph_versions', where: 'id = ?', whereArgs: [id]);
    await _db.update(
      'saved_graphs',
      {'mode': v['mode'], 'built_at': v['built_at'], 'updated_at': DateTime.now().millisecondsSinceEpoch, 'payload': v['payload']},
      where: 'id = ?',
      whereArgs: [graphId],
    );
    await _told(graphId);
    return graphId;
  }

  /// Tells the listeners that the graph with the number [id] changed.

  Future<void> _told(int id) async {
    final rows = await _db.query(
      'saved_graphs',
      columns: ['uid'], where: 'id = ?', whereArgs: [id],
    );
    if (rows.isNotEmpty) onChange?.call('graph:${rows.single['uid']}');
  }

  /// A name for a graph that is the same on every device (made at random: two devices never make the same).
  static String newGraphUid() {
    final random = Random.secure();
    return List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// The kept graphs, oldest first, without their payload (which is big): see [loadGraph].
  Future<List<SavedGraph>> listGraphs() async {
    final rows = await _db.query(
      'saved_graphs',
      columns: [
        'id',
        'uid',
        'name',
        'mode',
        'folder_id',
        'built_at',
        'updated_at',
      ],
      orderBy: 'id',
    );
    return [
      for (final r in rows)
        SavedGraph(
          id: r['id'] as int,
          uid: r['uid'] as String,
          name: r['name'] as String,mode: r['mode'] as String,
          folderId: r['folder_id'] as String?,
          builtAt: DateTime.fromMillisecondsSinceEpoch(r['built_at'] as int),
          updatedAt: r['updated_at'] as int,
        ),
    ];
  }

  Future<String?> loadGraph(int id) async {
    final rows = await _db.query(
      'saved_graphs',
      columns: ['payload'],
      where: 'id = ?',
      whereArgs: [id]);
    return rows.isEmpty ? null : rows.single['payload'] as String;
  }

  /// The picture of the graph that goes by [uid] on every device (for the sync).
  Future<String?> loadGraphByUid(String uid) async {
    final rows = await _db.query(
      'saved_graphs',
      columns: ['payload'],
      where: 'uid = ?',
      whereArgs: [uid],
    );
    return rows.isEmpty ? null : rows.single['payload'] as String;
  }

  Future<void> renameGraph(int id, String name) async {
    await _db.update(
      'saved_graphs',
      {'name': name, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _told(id);
  }

  /// Removes a graph and remembers that it was (as a note or folder that was deleted is), so that the other devices remove it too.
  Future<void> deleteGraph(int id) async {
    final rows = await _db.query(
      'saved_graphs',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return;
    final uid = rows.single['uid'] as String;
    await _removeGraph(uid, DateTime.now().millisecondsSinceEpoch);
    onChange?.call('graph:$uid');
  }

  /// Removes the graph [uid] because another device did, at the time it did (not now: a change made elsewhere since must not look as if
  /// it came before the deletion).
  Future<void> deleteGraphByUid(String uid, {required int at}) =>
      _removeGraph(uid, at);

  Future<void> _removeGraph(String uid, int at) async {
    await _db.delete('saved_graphs', where: 'uid = ?', whereArgs: [uid]);
    await _db.delete('graph_versions', where: 'graph_uid = ?', whereArgs: [uid]);
    final rows = await _db.query(
      'sync_tombstones',
      columns: ['deleted_at'],
      where: 'kind = ? AND id = ?',
      whereArgs: ['graph', uid],
    );
    if (rows.isNotEmpty && (rows.single['deleted_at'] as int) >= at) return;
    await _db.insert('sync_tombstones', {
      'kind': 'graph',
      'id': uid,
      'deleted_at': at,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Takes over a graph that another device made, renamed or made again (the sync): put in the place of the one that goes by the same
  /// [SavedGraph.uid], or added.
  Future<void> applySyncedGraph(SavedGraph g, String payload) async {
    final values = {
      'name': g.name,
      'mode': g.mode,
      'folder_id': g.folderId,
      'built_at': g.builtAt.millisecondsSinceEpoch,
      'updated_at': g.updatedAt,
      'payload': payload,
    };
    // (the picture that is replaced is kept, unless it is the same one)
    final there = await _db.query('saved_graphs', columns: ['payload'], where: 'uid = ?', whereArgs: [g.uid]);
    if (there.isNotEmpty && there.single['payload'] != payload) await _archive(where: 'uid = ?', args: [g.uid]);
    final changed = await _db.update(
      'saved_graphs',
      values,
      where: 'uid = ?',
      whereArgs: [g.uid],
    );
    if (changed == 0) await _db.insert('saved_graphs', {'uid': g.uid, ...values});
    await _db.delete(
      'sync_tombstones',
      where: 'kind = ? AND id = ?',
      whereArgs: ['graph', g.uid],
    );
  }

  /// The links from one note to another that are written in the notes (`note:<id>`): (from, to).
  Future<List<(String, String)>> noteLinks() async {
    final live = {for (final r in await _db.query('notes', columns: ['id'], where: 'deleted_at IS NULL AND lock_mode = 0')) r['id'] as String};
    final found = <(String, String)>{};
    final pattern = RegExp(r'note:([A-Za-z0-9]+-[A-Za-z0-9]+)');
    void scan(String from, String text) {
      for (final m in pattern.allMatches(text)) {
        final to = m.group(1)!;
        if (to != from && live.contains(to) && live.contains(from)) found.add((from, to));
      }
    }

    for (final r in await _db.query('text_boxes', columns: ['note_id', 'text'], where: "text LIKE '%note:%'")) {
      scan(r['note_id'] as String, r['text'] as String);
    }
    for (final r in await _db.query('notes', columns: ['id', 'document_text'], where: "document_text LIKE '%note:%'")) {
      scan(r['id'] as String, r['document_text'] as String);
    }
    return found.toList();
  }

  /// The sources each note cites (`[@key]` or `@key` in its text boxes and written document), by the id of the note: the keys of the library.
  /// Notes without citations, deleted and locked notes are not in it. An `@name` in a sentence is a citation only if [isSource] says
  /// the library has it (without [isSource] those are left out).
  Future<Map<String, Set<String>>> noteCitations({bool Function(String key)? isSource}) async {
    final live = {for (final r in await _db.query('notes', columns: ['id'], where: 'deleted_at IS NULL AND lock_mode = 0')) r['id'] as String};
    final found = <String, Set<String>>{};
    void scan(String note, String text) {
      if (!live.contains(note)) return;
      for (final mark in findCitations(text)) {
        for (final ref in mark.items) {
          if (ref.narrative && !(isSource?.call(ref.key) ?? false)) continue;
          (found[note] ??= {}).add(ref.key);
        }
      }
    }

    for (final r in await _db.query('text_boxes', columns: ['note_id', 'text'], where: "text LIKE '%@%'")) {
      scan(r['note_id'] as String, r['text'] as String);
    }
    for (final r in await _db.query('notes', columns: ['id', 'document_text'], where: "document_text LIKE '%@%'")) {
      scan(r['id'] as String, r['document_text'] as String);
    }
    return found;
  }
}

/// An earlier picture of a kept graph (see [KnowledgeRepository.listGraphVersions]).
class GraphVersion {
  final int id;

  /// The [SavedGraph.uid] of the graph it belonged to.
  final String graphUid;
  final String mode;

  /// When that picture was made, and how many nodes it has.
  final DateTime builtAt;
  final int nodes;
  const GraphVersion({required this.id, required this.graphUid, required this.mode, required this.builtAt, required this.nodes});
}

/// A graph that was kept: what it is called, what it was made of and when (its picture is loaded by [KnowledgeRepository.loadGraph]).
class SavedGraph {
  /// This device's number for it (the tab), and the name it goes by on every device of the profile ([uid]).
  final int id;
  final String uid;
  final String name;

  /// 'notes' or 'facts'.
  final String mode;

  /// The folder (with its subfolders) it was made of; null: all notes.
  final String? folderId;
  final DateTime builtAt;

  /// When it was last made, made again or renamed (milliseconds): the newer of two copies wins in the sync.
  final int updatedAt;
  const SavedGraph({
    required this.id,
    required this.uid,
    required this.name,
    required this.mode,
    required this.folderId,
    required this.builtAt,
    required this.updatedAt,
  });

  SavedGraph named(String newName) => SavedGraph(
    id: id,
    uid: uid,
    name: newName,
    mode: mode,
    folderId: folderId,
    builtAt: builtAt,
    updatedAt: updatedAt,
  );
}
