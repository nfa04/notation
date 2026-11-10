import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/knowledge_repository.dart' show SavedGraph;
import '../data/brush_library.dart';
import '../data/note_file.dart';
import '../data/note_file_service.dart';
import '../data/note_repository.dart';
import '../data/safe_names.dart';
import '../data/settings_repository.dart';
import '../graph/graph_model.dart' show KnowledgeGraph;
import '../l10n/language.dart';

/// The settings that travel between the devices of a profile: how the app looks and behaves, not where it connects to or
/// what it is allowed to (servers, accounts, the choice of model are per device, and secrets are never in the settings).
bool syncedSetting(String key) =>
    const {
      'collab_name',
      'app_accent',
      'app_language',
      'calendar_theme',
      'features_areas',
      'features_enabled',
      'ai_enabled',
      'ai_summary_config',
      'automations',
      'ocr_language',
      'spell_languages',
      'spell_personal',
      'whisper_language',
      'translate_to',
      'straighten_lines',
      'toolbar_layout',
      'toolbar_profiles',
      'sync_cloud_on',
      'sync_cloud_provider',
      'sync_cloud_mode',
      'native_shares',
      'sync_cloud_folder',
      'sync_signin_verifier',
    }.contains(key) ||
    key.startsWith('a11y_') ||
    // designed brushes (see BrushLibrary)
    key.startsWith('brush:') ||
    key.startsWith('stylus_') ||
    // the library of sources and the citation styles (see CitationRepository)
    key.startsWith('cite:') ||
    key.startsWith('citation_style');

class SyncFolder {
  final String id;
  final String? parentId;
  final String name;
  final int? color;
  final int sortOrder;
  final int updatedAt;

  const SyncFolder(this.id, this.parentId, this.name, this.color, this.sortOrder, this.updatedAt);

  Map<String, Object?> toJson() => {'id': id, 'parent': parentId, 'name': name, 'color': color, 'sort': sortOrder, 'at': updatedAt};

  static SyncFolder fromJson(Map j) => SyncFolder(j['id'] as String, j['parent'] as String?, j['name'] as String, j['color'] as int?, (j['sort'] as int?) ?? 0, j['at'] as int);

  bool sameAs(SyncFolder o) => parentId == o.parentId && name == o.name && color == o.color && sortOrder == o.sortOrder;
}

/// A note as the manifest tells of it: when its content was last edited ([version]) and where it is ([meta]: folder, star, trash).
class SyncNote {
  final String id;
  final int version;
  final int created;
  final String? folderId;
  final bool favorite;
  final int? deletedAt;

  /// What the device that tells of the note last agreed about it with each other device (by device id): the version and the place
  /// both had then. A device that reads this learns what the other's note grew from - also when the two never agreed directly, as
  /// in a cloud folder, where each only reads what the other published, and not always before the other changes the note again.
  final Map<String, ({int version, String meta})> marks;

  /// The versions this one grew from, newest first (as far as the device that tells of it knows; see `sync_lineage`).
  final List<int> ancestors;

  const SyncNote(this.id, this.version, this.created, this.folderId, this.favorite, this.deletedAt, {this.marks = const {}, this.ancestors = const []});

  /// A text that is the same when the note is in the same place (the trash time is left out: it is when, not whether).
  String get meta => '${folderId ?? ''}|${favorite ? 1 : 0}|${deletedAt == null ? 0 : 1}';

  /// Whether this version of the note grew from [version] (it is one of its ancestors, or the device that tells of it agreed it with
  /// some device at some point).
  bool knows(int version) => ancestors.contains(version) || marks.values.any((m) => m.version == version);

  Map<String, Object?> toJson() => {
        'id': id,
        'v': version,
        'c': created,
        'f': folderId,
        'star': favorite,
        'del': deletedAt,
        if (marks.isNotEmpty) 'b': {for (final e in marks.entries) e.key: [e.value.version, e.value.meta]},
        if (ancestors.isNotEmpty) 'a': ancestors,
      };

  static SyncNote fromJson(Map j) => SyncNote(j['id'] as String, j['v'] as int, (j['c'] as int?) ?? 0, j['f'] as String?, j['star'] == true, j['del'] as int?,
      marks: {
        for (final e in (j['b'] is Map ? j['b'] as Map : const {}).entries)
          if (e.key is String && e.value is List && (e.value as List).length == 2 && (e.value as List)[0] is int && (e.value as List)[1] is String)
            e.key as String: (version: (e.value as List)[0] as int, meta: (e.value as List)[1] as String),
      },
      ancestors: [for (final v in (j['a'] is List ? j['a'] as List : const [])) if (v is int) v]);
}

/// A graph that was made on a device as the manifest tells of it (the picture is asked for when it is wanted). [uid] names it on every
/// device; [at] is when it was last made, made again or renamed.
class SyncGraph {
  final String uid, name, mode;
  final String? folderId;
  final int builtAt, at;

  const SyncGraph(
    this.uid,
    this.name,
    this.mode,
    this.folderId,
    this.builtAt,
    this.at,
  );

  factory SyncGraph.of(SavedGraph g) => SyncGraph(
    g.uid,
    g.name,
    g.mode,
    g.folderId,
    g.builtAt.millisecondsSinceEpoch,
    g.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'uid': uid,
    'name': name,
    'mode': mode,
    'f': folderId,
    'built': builtAt,
    'at': at,
  };

  static SyncGraph fromJson(Map j) => SyncGraph(
    j['uid'] as String,
    j['name'] as String,
    j['mode'] as String,
    j['f'] as String?,
    (j['built'] as int?) ?? (j['at'] as int),
    j['at'] as int,
  );

  bool sameAs(SyncGraph o) =>
      name == o.name &&
      mode == o.mode &&
      folderId == o.folderId &&
      builtAt == o.builtAt;

  SavedGraph toSaved() => SavedGraph(
    id: 0,
    uid: uid,
    name: name,
    mode: mode,
    folderId: folderId,
    builtAt: DateTime.fromMillisecondsSinceEpoch(builtAt),
    updatedAt: at,
  );
}

class SyncSettingValue {
  final String key, value;
  final int at;
  const SyncSettingValue(this.key, this.value, this.at);

  Map<String, Object?> toJson() => {'k': key, 'v': value, 'at': at};

  static SyncSettingValue fromJson(Map j) => SyncSettingValue(j['k'] as String, j['v'] as String, (j['at'] as int?) ?? 0);
}

class SyncTomb {
  final String kind, id;
  final int at;
  const SyncTomb(this.kind, this.id, this.at);

  Map<String, Object?> toJson() => {'kind': kind, 'id': id, 'at': at};

  static SyncTomb fromJson(Map j) => SyncTomb(j['kind'] as String, j['id'] as String, j['at'] as int);
}

/// What one device has to offer: a line for every folder, note, graph, synced setting and thing that was deleted. No content.
class SyncManifest {
  final List<SyncFolder> folders;
  final List<SyncNote> notes;
  final List<SyncSettingValue> settings;
  final List<SyncTomb> tombs;

  /// The graphs that were kept (never part of a share: the library of a share leaves them out).
  final List<SyncGraph> graphs;

  const SyncManifest(this.folders, this.notes, this.settings, this.tombs, {
    this.graphs = const [],
  });

  Map<String, Object?> toJson() => {
        'folders': [for (final f in folders) f.toJson()],
        'notes': [for (final n in notes) n.toJson()],
        'settings': [for (final s in settings) s.toJson()],
        'tombs': [for (final t in tombs) t.toJson()],
    if (graphs.isNotEmpty) 'graphs': [for (final g in graphs) g.toJson()],
      };

  static SyncManifest fromJson(Map j) => SyncManifest(
        [for (final f in (j['folders'] as List? ?? const [])) SyncFolder.fromJson(f as Map)],
        [for (final n in (j['notes'] as List? ?? const [])) SyncNote.fromJson(n as Map)],
        [for (final s in (j['settings'] as List? ?? const [])) SyncSettingValue.fromJson(s as Map)],
        [for (final t in (j['tombs'] as List? ?? const [])) SyncTomb.fromJson(t as Map)],
    graphs: [
      for (final g in (j['graphs'] as List? ?? const []))
        SyncGraph.fromJson(g as Map),
    ],
      );
}

/// What this device takes from the other, worked out from both manifests.
class SyncPlan {
  /// Notes to ask for: with their content ([data]) and/or where they are ([meta]).
  final Map<String, ({bool data, bool meta})> notes = {};
  final List<String> folders = [];
  final List<String> settings = [];

  /// Graphs to ask for (by uid), and graphs the other device removed that are removed here too (the time is in [deletedAt] as `graph:<uid>`).
  final List<String> graphs = [];
  final List<String> deleteGraphs = [];

  /// Things the other device deleted that are deleted here too, and when it deleted them (by `note:<id>` and `folder:<id>`): what
  /// is deleted here is deleted at that time, not now.
  final List<String> deleteNotes = [];
  final List<String> deleteFolders = [];
  final Map<String, int> deletedAt = {};

  bool get isEmpty => notes.isEmpty && folders.isEmpty && settings.isEmpty && deleteNotes.isEmpty && deleteFolders.isEmpty &&
      graphs.isEmpty &&
      deleteGraphs.isEmpty;
}

class _SyncState {
  final Set<String> applying = {};
  final Map<String, Future<void>> writing = {};
  String? forced;
}

/// The notes, folders and settings of this device, for syncing: what there is ([manifest]), what to take from another device
/// ([plan]), and taking it in. Notes travel as note files (`.uninote`), so everything in a note goes with it.
///
/// Notes that are locked are never part of it. A note, folder or setting is replaced by the newer one; when a note was changed on
/// both devices since they last synced, the newer one wins and the older is kept as a copy next to it, so nothing is lost.
class SyncLibrary {
  final Database _db;
  final NoteRepository notes;
  final NoteFileService files;
  final SettingsRepository settings;

  /// Notes that are open in an editor: they are not replaced under it (they are taken at the next sync).
  Set<String> Function() busy;

  /// What the syncs are doing to notes right now. A library that sees only part of this one ([SyncLibrary.sharing]) shares it, so that
  /// the two never write the same note at once.
  final _SyncState _st;

  /// What is being written to each note now: a sync through the folder and a direct one may want to change the same note at once, and
  /// each must see what the other left (or one would keep a copy of the wrong version, or none).
  Future<T> _oneAtATime<T>(String id, Future<T> Function() job) {
    final before = _st.writing[id] ?? Future<void>.value();
    final run = before.then((_) => job());
    final done = run.then<void>((_) {}, onError: (Object _) {});
    _st.writing[id] = done;
    done.then((_) {
      if (identical(_st.writing[id], done)) _st.writing.remove(id);
    });
    return run;
  }

  /// Whether a note is being written by a sync now (its save is not news to the service that syncs).
  bool isApplying(String id) => _st.applying.contains(id);

  bool _isBusy(String id) => id != _st.forced && busy().contains(id);

  /// Runs [job] with the note [id] counted as free to be replaced although an editor has it open (the editor asked for it itself).
  Future<T> forcing<T>(String id, Future<T> Function() job) async {
    final before = _st.forced;
    _st.forced = id;
    try {
      return await job();
    } finally {
      _st.forced = before;
    }
  }

  SyncLibrary(this._db, this.notes, this.files, this.settings, {Set<String> Function()? busy})
      : busy = busy ?? (() => const {}),
        _st = _SyncState();

  /// A library over the same database, notes and files as [base] that does what it is told to by the subclass (see
  /// `ScopedSyncLibrary`); it counts the notes it is writing in the same books as [base], and is as busy as [base].
  SyncLibrary.sharing(SyncLibrary base)
      : _db = base._db,
        notes = base.notes,
        files = base.files,
        settings = base.settings,
        busy = (() => base.busy()),
        _st = base._st;

  /// The database, for a library that sees only part of this one.
  Database get database => _db;

  Future<SyncManifest> manifest() async {
    final folders = [
      for (final r in await _db.query('folders'))
        SyncFolder(r['id'] as String, r['parent_id'] as String?, r['name'] as String, r['color'] as int?, r['sort_order'] as int, r['updated_at'] as int),
    ];
    final noteRows = await _db.query('notes',
        columns: ['id', 'updated_at', 'created_at', 'folder_id', 'favorite', 'deleted_at'], where: 'lock_mode = 0');
    final marks = <String, Map<String, ({int version, String meta})>>{};
    for (final r in await _db.query('sync_marks', where: 'kind = ?', whereArgs: ['note'])) {
      (marks[r['id'] as String] ??= {})[r['peer'] as String] = (version: r['version'] as int, meta: r['meta'] as String);
    }
    final lineage = await _lineage();
    final noteList = [for (final r in noteRows) await _syncNote(r, marks[r['id']] ?? const {}, lineage[r['id']])];
    final values = await settings.allWhere(syncedSetting);
    final tombs = [
      for (final r in await _db.query('sync_tombstones')) SyncTomb(r['kind'] as String, r['id'] as String, r['deleted_at'] as int),
    ];
    final graphs = [
      for (final g in await notes.knowledge.listGraphs()) SyncGraph.of(g),
    ];
    return SyncManifest(folders, noteList, [for (final e in values.entries) SyncSettingValue(e.key, e.value.value, e.value.changedAt)], tombs,
      graphs: graphs,);
  }

  /// The line of the manifest for the note of row [r] (with its marks and what the sync knew of its versions, [line]).
  Future<SyncNote> _syncNote(Map<String, Object?> r, Map<String, ({int version, String meta})> marks, ({int cur, List<int> anc})? line) async {
    final id = r['id'] as String, version = r['updated_at'] as int;
    if (line == null || line.cur != version) {
      // changed here since the sync last looked (or never looked): the version it saw is what this one grew from
      line = (cur: version, anc: line == null ? const <int>[] : _bounded([line.cur, ...line.anc]));
      await _setLineage(id, line);
    }
    return SyncNote(id, version, r['created_at'] as int, r['folder_id'] as String?, r['favorite'] == 1, r['deleted_at'] as int?,
        marks: marks, ancestors: line.anc);
  }

  // ---- what each note grew from

  /// How many ancestors of a note are kept (the newest): a device that comes back with a version older than all of them is taken for
  /// one that changed the note on its own, and its version is kept as a copy - nothing is lost, there is a copy too many.
  static const maxAncestors = 64;

  static List<int> _bounded(Iterable<int> versions) => (versions.toSet().toList()..sort((a, b) => b.compareTo(a))).take(maxAncestors).toList();

  Future<Map<String, ({int cur, List<int> anc})>> _lineage() async => {
        for (final r in await _db.query('sync_lineage')) r['id'] as String: (cur: r['cur'] as int, anc: _decodeAnc(r['anc'])),
      };

  static List<int> _decodeAnc(Object? text) {
    try {
      return [for (final v in jsonDecode(text as String) as List) if (v is int) v];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _setLineage(String id, ({int cur, List<int> anc}) line) =>
      _db.insert('sync_lineage', {'id': id, 'cur': line.cur, 'anc': jsonEncode(line.anc)}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<({int cur, List<int> anc})?> _lineageOf(String id) async {
    final rows = await _db.query('sync_lineage', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : (cur: rows.single['cur'] as int, anc: _decodeAnc(rows.single['anc']));
  }

  // ---- what was agreed at the last sync with a device

  Future<({int version, String meta})?> mark(String peer, String id) async {
    final rows = await _db.query('sync_marks', where: 'peer = ? AND kind = ? AND id = ?', whereArgs: [peer, 'note', id]);
    return rows.isEmpty ? null : (version: rows.single['version'] as int, meta: rows.single['meta'] as String);
  }

  Future<void> _setMark(String peer, SyncNote n) => _db.insert(
        'sync_marks',
        {'peer': peer, 'kind': 'note', 'id': n.id, 'version': n.version, 'meta': n.meta},
        conflictAlgorithm: ConflictAlgorithm.replace
      );

  /// After taking in what a device published (or meeting it): the notes that are now as that device has them count as agreed with
  /// it. The others - say, one changed here and not published yet - do not, so that a change by the other device on top
  /// of them is told from a change made here.
  Future<void> markAgreed(String peer, SyncManifest theirs) async {
    final mine = {for (final n in (await manifest()).notes) n.id: n};
    final marked = await _marksOf(peer);
    // (only what differs from the mark that is there is written: a run that finds nothing new - most of them - writes nothing, instead of
    // one row for every note of the library)
    final batch = _db.batch();
    var any = false;
    for (final r in theirs.notes) {
      final l = mine[r.id];
      if (l == null || l.version != r.version || l.meta != r.meta) continue;
      final was = marked[l.id];
      if (was != null && was.version == l.version && was.meta == l.meta) continue;
      batch.insert('sync_marks', {'peer': peer, 'kind': 'note', 'id': l.id, 'version': l.version, 'meta': l.meta}, conflictAlgorithm: ConflictAlgorithm.replace);
      any = true;
    }
    if (any) await batch.commit(noResult: true);
  }

  /// What was agreed with [peer] about each note, in one read (a plan asks for every note of the library, one by one it was a query each).
  Future<Map<String, ({int version, String meta})>> _marksOf(String peer) async => {
        for (final r in await _db.query('sync_marks', where: 'peer = ? AND kind = ?', whereArgs: [peer, 'note']))
          r['id'] as String: (version: r['version'] as int, meta: r['meta'] as String),
      };

  /// A note was worked on together with other devices (a live session) and they all have it as it is now: it counts as agreed with
  /// [peers], so that the copies in a cloud folder that follow are taken for what they are and not for a change made on both sides.
  Future<void> markNoteAgreed(String noteId, Iterable<String> peers) async {
    final now = await noteInfo(noteId);
    if (now == null) return;
    for (final peer in peers) {
      await _setMark(peer, now);
    }
  }

  Future<void> forgetMarks(String peer) => _db.delete('sync_marks', where: 'peer = ?', whereArgs: [peer]);

  // ---- notes that are only listed (a browser that is here for a while)

  /// Notes whose content the person asked for (they are taken at the next sync, see [plan]).
  final Set<String> requested = {};

  /// Asks for the content of [id] at the next sync (nothing if it is here in full).
  void request(String id) => requested.add(id);

  /// Takes back [request] (the content did not come).
  void withdraw(String id) => requested.remove(id);

  /// The notes that are only listed here: they have a title, a place and times, and no content.
  Future<Set<String>> stubIds() async => {for (final r in await _db.query('sync_stubs')) r['id'] as String};

  Future<bool> isStub(String id) async => (await _db.query('sync_stubs', where: 'id = ?', whereArgs: [id])).isNotEmpty;

  Future<String?> noteTitle(String id) async {
    final rows = await _db.query('notes', columns: ['title'], where: 'id = ? AND lock_mode = 0', whereArgs: [id]);
    return rows.isEmpty ? null : rows.single['title'] as String?;
  }

  // ---- working out what to take

  /// What this device (id [me]) takes from a device (id [peer]) that offers [theirs]. When both changed the same thing the
  /// device with the lower id is the one that wins, so that both come to the same result.
  ///
  /// With [lazy] (a browser that is here for a while only, see `DeviceSyncService.temporary`) a note that is not here yet is only listed
  /// (title, place and times, no content - see [applyNote]), and its content is asked for when the person opens it ([request]).
  Future<SyncPlan> plan(String peer, String me, SyncManifest theirs, {bool lazy = false}) async {
    final mine = await manifest();
    final stubs = lazy ? await stubIds() : const <String>{};
    final marked = await _marksOf(peer);
    final plan = SyncPlan();
    final theirWin = peer.compareTo(me) < 0;

    final myTombs = {for (final t in mine.tombs) '${t.kind}:${t.id}': t};
    final myNotes = {for (final n in mine.notes) n.id: n};
    final myFolders = {for (final f in mine.folders) f.id: f};
    final mySettings = {for (final s in mine.settings) s.key: s};
    final myGraphs = {for (final g in mine.graphs) g.uid: g};

    // deletions that are told
    for (final t in theirs.tombs) {
      if (t.kind == 'note') {
        final n = myNotes[t.id];
        if (n != null && n.version <= t.at && !_isBusy(t.id)) {
          plan.deleteNotes.add(t.id);
          plan.deletedAt['note:${t.id}'] = t.at;
        }
      } else if (t.kind == 'graph') {
        // a graph made again or renamed after it was removed elsewhere is kept (and comes back there)
        final g = myGraphs[t.id];
        if (g != null && g.at <= t.at) {
          plan.deleteGraphs.add(t.id);
          plan.deletedAt['graph:${t.id}'] = t.at;
        }
      } else if (t.kind == 'folder') {
        final f = myFolders[t.id];
        if (f != null && f.updatedAt <= t.at) {
          plan.deleteFolders.add(t.id);
          plan.deletedAt['folder:${t.id}'] = t.at;
        }
      }
    }

    for (final r in theirs.folders) {
      final tomb = myTombs['folder:${r.id}'];
      if (tomb != null && tomb.at >= r.updatedAt) continue;
      final l = myFolders[r.id];
      if (l == null || r.updatedAt > l.updatedAt || (r.updatedAt == l.updatedAt && !r.sameAs(l) && theirWin)) plan.folders.add(r.id);
    }

    for (final r in theirs.notes) {
      final tomb = myTombs['note:${r.id}'];
      if (tomb != null && tomb.at >= r.version) continue;
      final l = myNotes[r.id];
      if (l == null) {
        plan.notes[r.id] = (data: !lazy, meta: true);
        continue;
      }
      if (_isBusy(r.id)) continue;
      if (stubs.contains(r.id)) {
        // only listed here: its content comes when it was asked for; until then the list follows the other device (title, times, place)
        if (requested.contains(r.id)) {
          plan.notes[r.id] = (data: true, meta: true);
        } else if (r.version != l.version || r.meta != l.meta) {
          plan.notes[r.id] = (data: false, meta: true);
        }
        continue;
      }
      final b = _newer(marked[r.id], r.marks[me]);
      // newer content is taken - unless what is here grew from it (a clock that is behind); and what grew from what is here is
      // taken even when its time says otherwise
      final wantData = r.version != l.version && !l.knows(r.version) && (r.version > l.version || r.knows(l.version));
      var wantMeta = false;
      if (r.meta != l.meta) {
        final iChanged = b == null || b.meta != l.meta;
        final theyChanged = b == null || b.meta != r.meta;
        wantMeta = !iChanged || (theyChanged && theirWin);
      }
      if (wantData || wantMeta) plan.notes[r.id] = (data: wantData, meta: wantMeta);
    }

    for (final r in theirs.graphs) {
      final tomb = myTombs['graph:${r.uid}'];
      if (tomb != null && tomb.at >= r.at) continue;
      final l = myGraphs[r.uid];
      // the newer is taken as a whole (a graph can be made again, so no copy of the older is kept)
      if (l == null ||
          r.at > l.at ||
          (r.at == l.at && !r.sameAs(l) && theirWin)) {
        plan.graphs.add(r.uid);
      }
    }

    for (final r in theirs.settings) {
      final l = mySettings[r.key];
      if (l == null || r.at > l.at || (r.at == l.at && r.value != l.value && theirWin)) plan.settings.add(r.key);
    }
    return plan;
  }

  /// Of what this device agreed with another about a note, and what that one says it agreed with this one: the later.
  static ({int version, String meta})? _newer(({int version, String meta})? mine, ({int version, String meta})? theirs) {
    if (mine == null) return theirs;
    if (theirs == null) return mine;
    return theirs.version > mine.version ? theirs : mine;
  }

  // ---- giving

  /// The folders in the order they can be made in (parents first).
  Future<List<SyncFolder>> foldersFor(List<String> ids) async {
    final all = {for (final f in (await manifest()).folders) f.id: f};
    final out = [for (final id in ids) if (all[id] != null) all[id]!];
    int depth(SyncFolder f) {
      var d = 0;
      for (var p = f.parentId; p != null && all[p] != null && d < all.length; p = all[p]!.parentId) {
        d++;
      }
      return d;
    }

    out.sort((a, b) => depth(a).compareTo(depth(b)));
    return out;
  }

  /// The line of the manifest for one note (null: there is none, or it is locked). Read on its own: a sync that sends many notes asks
  /// for each, and making the whole manifest each time took as long as the library is big, for every note.
  Future<SyncNote?> noteInfo(String id) async {
    final rows = await _db.query('notes',
        columns: ['id', 'updated_at', 'created_at', 'folder_id', 'favorite', 'deleted_at'], where: 'id = ? AND lock_mode = 0', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final marks = {
      for (final r in await _db.query('sync_marks', where: 'kind = ? AND id = ?', whereArgs: ['note', id]))
        r['peer'] as String: (version: r['version'] as int, meta: r['meta'] as String),
    };
    return _syncNote(rows.single, marks, await _lineageOf(id));
  }

  Future<Uint8List?> noteBytes(String id) async {
    if (await isStub(id)) return null; // (a note that is only listed here has no content to give)
    final bytes = await files.exportBytes(id);
    if (bytes != null) {
      final rows = await _db.query('notes', columns: ['updated_at'], where: 'id = ?', whereArgs: [id]);
      if (rows.isNotEmpty) await _rememberContent(id, rows.single['updated_at'] as int, bytes);
    }
    return bytes;
  }

  /// How many versions of a note have their content remembered.
  static const _digestsKept = 8;

  /// Keeps what the note [id] held at [version] as it passes through a sync, to tell later whether a newer time on it means a change.
  Future<void> _rememberContent(String id, int version, Uint8List bytes) async {
    final digest = noteContentDigest(bytes);
    if (digest == null) return;
    await _db.insert('sync_digest', {'id': id, 'version': version, 'digest': digest}, conflictAlgorithm: ConflictAlgorithm.replace);
    await _db.delete('sync_digest',
        where: 'id = ? AND version NOT IN (SELECT version FROM sync_digest WHERE id = ? ORDER BY version DESC LIMIT $_digestsKept)', whereArgs: [id, id]);
  }

  /// Whether the note [id] holds here what it held at [agreed] (the version both devices had at the last sync): it was saved again
  /// (opened, a page count or a text layer found) but not changed, so it is no change to tell from the other device's.
  Future<bool> _unchangedSince(String id, int? agreed) async {
    if (agreed == null) return false;
    final rows = await _db.query('sync_digest', where: 'id = ? AND version = ?', whereArgs: [id, agreed]);
    if (rows.isEmpty) return false;
    final here = await files.exportBytes(id);
    return here != null && noteContentDigest(here) == rows.single['digest'];
  }

  /// The line of the manifest for the graph [uid], and its picture as text (null: it is gone).
  Future<({SyncGraph info, String payload})?> graphFor(String uid) async {
    final info = (await notes.knowledge.listGraphs())
        .where((g) => g.uid == uid)
        .firstOrNull;
    final payload = info == null
        ? null
        : await notes.knowledge.loadGraphByUid(uid);
    return info == null || payload == null
        ? null
        : (info: SyncGraph.of(info), payload: payload);
  }

  Future<SyncSettingValue?> settingValue(String key) async {
    if (!syncedSetting(key)) return null;
    final v = (await settings.allWhere((k) => k == key))[key];
    return v == null ? null : SyncSettingValue(key, v.value, v.changedAt);
  }

  // ---- taking

  /// The banner picture of a folder, for sending it along (nothing when it has none or it is very large).
  Future<({String ext, Uint8List bytes})?> folderImage(String id) async {
    final rows = await _db.query('folders', columns: ['theme_image'], where: 'id = ?', whereArgs: [id]);
    final path = rows.isEmpty ? null : rows.single['theme_image'] as String?;
    if (path == null) return null;
    final file = File(path);
    try {
      if (!await file.exists() || await file.length() > maxFolderImageBytes) return null;
      return (ext: p.extension(path).replaceFirst('.', ''), bytes: await file.readAsBytes());
    } on FileSystemException {
      return null;
    }
  }

  /// Pictures larger than this are left on the device that has them.
  static const maxFolderImageBytes = 8 * 1024 * 1024;

  /// Takes a folder over; [image] is its banner picture (none: it has none, and a banner here is taken away).
  Future<void> applyFolder(SyncFolder f, {({String ext, Uint8List bytes})? image}) async {
    final exists = (await _db.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [f.id])).isNotEmpty;
    // a parent that is not here (yet) leaves the folder at the top level
    final parentOk = f.parentId != null && (await _db.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [f.parentId])).isNotEmpty;
    final values = {'parent_id': parentOk ? f.parentId : null, 'name': f.name, 'color': f.color, 'sort_order': f.sortOrder, 'updated_at': f.updatedAt};
    if (exists) {
      await _db.update('folders', values, where: 'id = ?', whereArgs: [f.id]);
    } else {
      await _db.insert('folders', {'id': f.id, 'created_at': f.updatedAt, ...values});
    }
    await _db.delete('sync_tombstones', where: 'kind = ? AND id = ?', whereArgs: ['folder', f.id]);
    await _applyFolderImage(f, image);
  }

  Future<void> _applyFolderImage(SyncFolder f, ({String ext, Uint8List bytes})? image) async {
    final old = (await _db.query('folders', columns: ['theme_image'], where: 'id = ?', whereArgs: [f.id])).single['theme_image'] as String?;
    String? path;
    if (image != null) {
      final ext = safeExtension(image.ext);
      final dir = await Directory(p.join((await files.supportDirectory()).path, 'folder_images')).create(recursive: true);
      path = p.join(dir.path, '${safeFileId(f.id)}-${DateTime.now().millisecondsSinceEpoch}.$ext'); // (a new name, so that no old picture is shown from the cache)
      await File(path).writeAsBytes(image.bytes, flush: true);
    }
    if (path == old) return;
    // (the time of the folder stays the one that came with it)
    await _db.update('folders', {'theme_image': path}, where: 'id = ?', whereArgs: [f.id]);
    if (old != null) {
      try {
        await File(old).delete();
      } on FileSystemException {
        // gone already
      }
    }
  }

  /// Takes a graph over (the newer replaces the older). What another device sends is not trusted: a picture that cannot be read is left out.
  Future<void> applyGraph(SyncGraph g, String payload) async {
    final graph = KnowledgeGraph.decode(payload);
    if (graph == null ||
        graph.mode != g.mode ||
        (g.mode != 'notes' && g.mode != 'facts')) {
      return;
    }
    await notes.knowledge.applySyncedGraph(g.toSaved(), payload);
  }

  Future<void> deleteGraph(String uid, {required int at}) =>
      notes.knowledge.deleteGraphByUid(uid, at: at);

  Future<void> applySetting(SyncSettingValue s) async {
    if (!syncedSetting(s.key)) return;
    await settings.setFromSync(s.key, s.value, s.at);
    // (a brush that came from another device is drawn with from now on)
    if (s.key.startsWith(BrushLibrary.keyPrefix)) await BrushLibrary(settings).load();
  }

  /// Takes a note over: [bytes] is its note file (when [data]), [info] where it is and when it was last edited. If it was changed
  /// here since the last sync with [peer] too, the version here is kept as a copy.
  ///
  /// With [lazy], a note without content ([data] false) that is not here, or is only listed here, is kept as a stub with [title]: see [plan].
  Future<void> applyNote(String peer, SyncNote info, Uint8List? bytes, {required bool data, required bool meta, String? title, bool lazy = false}) => _oneAtATime(info.id, () async {
        if (_isBusy(info.id)) return;
        _st.applying.add(info.id);
        try {
          await _applyNote(peer, info, bytes, data: data, meta: meta, title: title, lazy: lazy);
          // taken: from now on this note counts as agreed with [peer] - also when the connection breaks before the end of the meeting,
          // so that the next one does not take what was just received for a change made here
          if (await noteInfo(info.id) case final now? when now.version == info.version) await _setMark(peer, now);
        } finally {
          _st.applying.remove(info.id);
        }
      });

  Future<void> _applyNote(String peer, SyncNote info, Uint8List? bytes, {required bool data, required bool meta, String? title, required bool lazy}) async {
    final existing = await _db.query('notes', columns: ['id', 'title', 'updated_at', 'folder_id', 'lock_mode'], where: 'id = ?', whereArgs: [info.id]);
    if (existing.isNotEmpty && existing.single['lock_mode'] != 0) return;
    final stub = existing.isNotEmpty && await isStub(info.id);
    if (lazy && !data && bytes == null && (existing.isEmpty || stub)) {
      await _applyStub(info, title, meta: meta, isNew: existing.isEmpty);
      return;
    }
    if (data && bytes != null) {
      // what the note grows from now: what the other's grew from - and, unless it is a conflict, what this one grew from too
      var ancestors = info.ancestors;
      if (existing.isEmpty) {
        await _db.insert('notes', {'id': info.id, 'title': '', 'created_at': info.created, 'updated_at': info.version});
      } else {
        final here = existing.single['updated_at'] as int;
        final b = await mark(peer, info.id);
        // changed here since the two last agreed - unless the other's note grew from this one (it says it had it), or the two are the
        // same anyway (worked on together, and saved at different times)
        final changedHere = !stub && (b == null || here > b.version) && !info.knows(here) && !await _same(info.id, bytes) && !await _unchangedSince(info.id, b?.version);
        final line = await _lineageOf(info.id);
        if (changedHere) {
          await _keepCopy(info.id, here, existing.single['title'] as String, existing.single['folder_id'] as String?, line?.anc ?? const []);
        } else {
          ancestors = _bounded([...info.ancestors, here, ...?line?.anc]);
        }
      }
      await files.restoreInto(info.id, bytes);
      await _rememberContent(info.id, info.version, bytes);
      await notes.setTimes(info.id,
          created: DateTime.fromMillisecondsSinceEpoch(info.created == 0 ? info.version : info.created), edited: DateTime.fromMillisecondsSinceEpoch(info.version));
      await _setLineage(info.id, (cur: info.version, anc: ancestors));
      await _db.delete('sync_tombstones', where: 'kind = ? AND id = ?', whereArgs: ['note', info.id]);
      await _db.delete('sync_stubs', where: 'id = ?', whereArgs: [info.id]);
      requested.remove(info.id);
    }
    if (meta || existing.isEmpty) await _applyPlace(info);
  }

  Future<void> _applyPlace(SyncNote info) async {
    final folderOk = info.folderId != null && (await _db.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [info.folderId])).isNotEmpty;
    await _db.update(
      'notes',
      {'folder_id': folderOk ? info.folderId : null, 'favorite': info.favorite ? 1 : 0, 'deleted_at': info.deletedAt},
      where: 'id = ?',
      whereArgs: [info.id],
    );
  }

  /// Keeps a note as it is told of in the manifest, without its content: a row with the title, the times and the place, marked in
  /// `sync_stubs`. Its content never leaves this device ([noteBytes]), and comes when it is asked for ([request]).
  Future<void> _applyStub(SyncNote info, String? title, {required bool meta, required bool isNew}) async {
    if (isNew) {
      await _db.insert('notes', {'id': info.id, 'title': title ?? '', 'created_at': info.created, 'updated_at': info.version});
      await _db.delete('sync_tombstones', where: 'kind = ? AND id = ?', whereArgs: ['note', info.id]);
    } else if (title != null) {
      await _db.update('notes', {'title': title}, where: 'id = ?', whereArgs: [info.id]);
    }
    await _db.insert('sync_stubs', {'id': info.id}, conflictAlgorithm: ConflictAlgorithm.ignore);
    await notes.setTimes(info.id,
        created: DateTime.fromMillisecondsSinceEpoch(info.created == 0 ? info.version : info.created), edited: DateTime.fromMillisecondsSinceEpoch(info.version));
    await _setLineage(info.id, (cur: info.version, anc: info.ancestors));
    if (meta || isNew) await _applyPlace(info);
  }

  /// Whether the note [id] here is the same as the note file [bytes].
  Future<bool> _same(String id, Uint8List bytes) async {
    final here = await files.exportBytes(id);
    return here != null && sameNoteContent(here, bytes);
  }

  /// The id of the copy of the note [id] as it was at [version]: the same on every device, so that two devices that both keep it
  /// (three changed the note at once) keep one note between them, not two.
  static String copyId(String id, int version) =>
      'k${sha256.convert(utf8.encode('$id@$version')).bytes.take(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  /// Keeps what is here of a note that is about to be replaced (its [version]) as a note of its own - once: a copy that is there, or
  /// was there and was deleted, is not made again.
  Future<void> _keepCopy(String id, int version, String title, String? folderId, List<int> ancestors) async {
    final copyId = SyncLibrary.copyId(id, version);
    if ((await _db.query('notes', columns: ['id'], where: 'id = ?', whereArgs: [copyId])).isNotEmpty) return;
    if ((await _db.query('sync_tombstones', where: 'kind = ? AND id = ?', whereArgs: ['note', copyId])).isNotEmpty) return;
    final bytes = await files.exportBytes(id);
    if (bytes == null) return;
    final copy = await files.importBytes(bytes, folderId: folderId, id: copyId);
    final name = title.isEmpty ? tr('Untitled') : title;
    await _db.update('notes', {'title': '$name (${tr('from before the sync')})'}, where: 'id = ?', whereArgs: [copy.noteId]);
    // its times are those of what it keeps: on every device that keeps it, it is the same note in the same version
    final times = await notes.noteTimes(id);
    await notes.setTimes(copy.noteId, created: times?.created ?? DateTime.fromMillisecondsSinceEpoch(version), edited: DateTime.fromMillisecondsSinceEpoch(version));
    await _setLineage(copy.noteId, (cur: version, anc: ancestors));
  }

  Future<void> deleteNote(String id, {int? at}) => _oneAtATime(id, () async {
        _st.applying.add(id);
        try {
          await notes.deleteNote(id, deletedAt: at);
          await Future<void>.delayed(Duration.zero,); // (the news of it reaches those who listen while it still counts as the sync's own)
        } finally {
          _st.applying.remove(id);
        }
      });

  Future<void> deleteFolder(String id, {int? at}) async {
    _st.applying.add(id);
    try {
      await notes.deleteFolder(id, deletedAt: at);
      await Future<void>.delayed(Duration.zero);
    } finally {
      _st.applying.remove(id);
    }
  }

  /// Hashes the text of the manifest, for telling a device that nothing changed (kept for the log).
  static int fingerprint(SyncManifest m) => jsonEncode(m.toJson()).hashCode;
}
