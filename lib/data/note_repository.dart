import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/canvas_models.dart';
import '../models/connector.dart';
import '../models/image_item.dart';
import '../models/bezier.dart';
import '../models/gradient.dart';
import '../models/stroke_label.dart';
import '../models/layers.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';
import '../models/pdf_models.dart';
import '../models/rich_text.dart';
import 'knowledge_repository.dart';
import 'lock_repository.dart';
import 'note_ai_repository.dart';
import 'note_activity.dart';
import 'note_data.dart';
import 'note_text_repository.dart';
import 'settings_repository.dart';
import 'template_repository.dart';
import 'point_codec.dart';

/// Reads and writes notes. Saving replaces a note's annotations wholesale in
/// one transaction: simple, and fast enough for a few thousand strokes.
class NoteRepository {
  final Database _db;

  /// App settings kept with the notes, and the pen palette.
  final SettingsRepository settings;

  /// Locks of notes, and which locked notes are open now.
  final LockRepository locks;

  /// Saved templates.
  final TemplateRepository templates;

  /// The words of notes, for the search and the AI.
  final NoteTextRepository text;

  /// Vectors, passages, facts and the graph made from the notes.
  final KnowledgeRepository knowledge;

  /// What the AI made of a note.
  final NoteAiRepository ai;

  NoteRepository(Database db)
      : _db = db,
        settings = SettingsRepository(db),
        locks = LockRepository(db),
        templates = TemplateRepository(db),
        text = NoteTextRepository(db),
        knowledge = KnowledgeRepository(db),
        ai = NoteAiRepository(db) {
    knowledge.onChange = _changed;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static String newId() {
    final r = Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return '${_now().toRadixString(36)}-$hex';
  }

  /// The banner image of a note (null removes it). Kept apart from [saveNote]:
  /// it is not part of what the editor autosaves.
  Future<void> setNoteThemeImage(String id, String? path) =>
      _db.update('notes', {'theme_image': path, 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  /// Sets the dates of a note (a note put back from a lock keeps the dates it had).
  Future<void> setTimes(String id, {required DateTime created, required DateTime edited}) =>
      _db.update('notes', {'created_at': created.millisecondsSinceEpoch, 'updated_at': edited.millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);

  /// When a note was made and last edited, or null if there is no such note.
  Future<({DateTime created, DateTime edited})?> noteTimes(String id) async {
    final rows = await _db.query('notes', columns: ['created_at', 'updated_at'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return (
      created: DateTime.fromMillisecondsSinceEpoch(rows.single['created_at'] as int),
      edited: DateTime.fromMillisecondsSinceEpoch(rows.single['updated_at'] as int),
    );
  }

  /// Whether note [id] exists and is not in the trash.
  static Object? _decodeJson(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      return null;
    }
  }

  Future<bool> noteExists(String id) async =>
      (await _db.query('notes', columns: ['id'], where: 'id = ? AND deleted_at IS NULL', whereArgs: [id])).isNotEmpty;

  Future<List<NoteSummary>> listNotes() async {
    // a note without a banner of its own shows the one of its folder
    final rows = await _db.rawQuery('''
      SELECT n.id, n.title, n.updated_at, n.pdf_path, n.folder_id, n.favorite, n.lock_mode,
             CASE WHEN n.lock_mode = 0 THEN COALESCE(n.theme_image, f.theme_image) ELSE NULL END AS theme_image
        FROM notes n LEFT JOIN folders f ON f.id = n.folder_id
       WHERE n.deleted_at IS NULL
       ORDER BY n.updated_at DESC
    ''');
    return [
      for (final r in rows)
        NoteSummary(
          id: r['id'] as String,
          title: r['title'] as String,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
          isPdf: r['pdf_path'] != null,
          folderId: r['folder_id'] as String?,
          themeImage: r['theme_image'] as String?,
          favorite: (r['favorite'] as int) == 1,
          lockMode: r['lock_mode'] as int,
        ),
    ];
  }

  /// Stars a note, or takes the star away. (Not an edit: the note keeps its place in the list of recent ones.)
  Future<void> setFavorite(String id, bool favorite) async {
    await _db.update('notes', {'favorite': favorite ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    _changed(id);
  }

  Future<bool> isFavorite(String id) async {
    final rows = await _db.query('notes', columns: ['favorite'], where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty && rows.single['favorite'] == 1;
  }

  final StreamController<String> _createdNotes = StreamController<String>.broadcast();

  /// The ids of notes as they are created.
  Stream<String> get created => _createdNotes.stream;

  /// A note's title and folder, or null if there is no such note.
  Future<({String title, String? folderId, String? pdfName})?> noteInfo(String id) async {
    final rows = await _db.query('notes', columns: ['title', 'folder_id', 'pdf_name'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return (
      title: rows.single['title'] as String,
      folderId: rows.single['folder_id'] as String?,
      pdfName: rows.single['pdf_name'] as String?,
    );
  }

  /// Notes the user has not opened since [before] (an edit made some other way
  /// counts as an opening, and so does the note's making). Not those in the trash.
  Future<List<({String id, String title, String? folderId, String? pdfName, DateTime lastOpened})>> staleNotes(
      DateTime before) async {
    final rows = await _db.rawQuery('''
      SELECT id, title, folder_id, pdf_name,
             COALESCE(last_opened_at, updated_at, created_at) AS last_opened
        FROM notes
       WHERE deleted_at IS NULL AND COALESCE(last_opened_at, updated_at, created_at) < ?
    ''', [before.millisecondsSinceEpoch]);
    return [
      for (final r in rows)
        (
          id: r['id'] as String,
          title: r['title'] as String,
          folderId: r['folder_id'] as String?,
          pdfName: r['pdf_name'] as String?,
          lastOpened: DateTime.fromMillisecondsSinceEpoch(r['last_opened'] as int),
        ),
    ];
  }

  /// Notes that the user opened now. Not an edit: `updated_at` stays.
  Future<void> markOpened(String id, {DateTime? at}) => _db.update(
        'notes',
        {'last_opened_at': (at ?? DateTime.now()).millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Adds (or replaces) one text box of a note without touching the rest of it,
  /// and removes the ones of the same page whose id starts with [replacePrefix].
  /// For text made by an automation while the note may be open elsewhere.
  Future<void> putTextBox(
    String noteId,
    int page,
    TextBoxWidgetModel box, {
    String? replacePrefix,
  }) async {
    await _db.transaction((txn) async {
      if (replacePrefix != null) {
        final rows = await txn.query('text_boxes',
            columns: ['id'], where: 'note_id = ? AND page_index = ?', whereArgs: [noteId, page]);
        for (final r in rows) {
          final id = r['id'] as String;
          if (id.startsWith(replacePrefix)) {
            await txn.delete('text_boxes', where: 'note_id = ? AND id = ?', whereArgs: [noteId, id]);
          }
        }
      }
      final top = await txn.rawQuery('SELECT COALESCE(MAX(seq), -1) + 1 AS next FROM text_boxes WHERE note_id = ?', [noteId]);
      final seq = (top.single['next'] as int?) ?? 0;
      await txn.insert(
          'text_boxes',
          {
            'id': box.id,
            'note_id': noteId,
            'page_index': page,
            'x': box.position.dx,
            'y': box.position.dy,
            'width': box.size.width,
            'height': box.size.height,
            'font_size': box.fontSize,
            'text': box.controller.text,
            'spans': _encodeSpans(box.controller.attributes),
            'style': box.style.isDefault ? null : jsonEncode(box.style.toJson()),
            'seq': seq,
            'author': box.author,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<String> createNote({String title = 'Untitled Note', String? folderId, String? id}) async {
    id ??= newId();
    final now = _now();
    await _db.insert('notes', {
      'id': id,
      'title': title,
      'folder_id': folderId,
      'created_at': now,
      'updated_at': now,
    });
    _createdNotes.add(id);
    return id;
  }

  /// When the note was last edited (not opened, not moved), or null if there is no such note.
  /// Automations use it to run only on notes that changed since they last ran.
  Future<DateTime?> noteEditedAt(String id) async {
    final rows = await _db.query('notes', columns: ['updated_at'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(rows.single['updated_at'] as int);
  }

  /// The notes that lie in a folder (the trash excluded), with that folder.
  Future<List<({String id, String folderId})>> filedNotes() async {
    final rows = await _db.query('notes', columns: ['id', 'folder_id'], where: 'deleted_at IS NULL AND folder_id IS NOT NULL');
    return [for (final r in rows) (id: r['id'] as String, folderId: r['folder_id'] as String)];
  }

  /// Moves a note into [folderId], or out of all folders when null. Moving is
  /// not an edit, so `updated_at` stays as it was.
  Future<void> moveNote(String noteId, String? folderId) async {
    await _db.update(
      'notes',
      {'folder_id': folderId},
      where: 'id = ?',
      whereArgs: [noteId],
    );
    _changed(noteId);
  }

  // ---- folders -------------------------------------------------------------

  /// All folders, siblings in name order.
  Future<List<FolderEntry>> listFolders() async {
    final rows = await _db.rawQuery('''
      SELECT f.id, f.parent_id, f.name, f.theme_image,
             (SELECT COUNT(*) FROM notes n
               WHERE n.folder_id = f.id AND n.deleted_at IS NULL) AS note_count
        FROM folders f
       ORDER BY f.sort_order, f.name COLLATE NOCASE
    ''');
    return [
      for (final r in rows)
        FolderEntry(
          id: r['id'] as String,
          parentId: r['parent_id'] as String?,
          name: r['name'] as String,
          noteCount: r['note_count'] as int,
          themeImage: r['theme_image'] as String?,
        ),
    ];
  }

  Future<String> createFolder(String name, {String? parentId}) async {
    final id = newId();
    final now = _now();
    await _db.insert('folders', {
      'id': id,
      'parent_id': parentId,
      'name': name,
      'created_at': now,
      'updated_at': now,
    });
    _changed(id);
    return id;
  }

  /// Sets (or with null clears) the folder's banner image path.
  Future<void> setFolderThemeImage(String id, String? path) async {
    await _db.update(
      'folders',
      {'theme_image': path, 'updated_at': _now()},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed(id);
  }

  /// Takes the text box [id] of page [page] out of note [noteId] without touching the rest of it (what an automation put there). For a
  /// note that is not open.
  Future<void> removeTextBox(String noteId, int page, String id) async {
    await _db.delete('text_boxes', where: 'note_id = ? AND page_index = ? AND id = ?', whereArgs: [noteId, page, id]);
    _changed(noteId);
  }

  /// Gives note [id] the title [title] without touching the rest of it. For a note that is not open: an open one is named through its editor.
  Future<void> renameNote(String id, String title) async {
    await _db.update('notes', {'title': title, 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);
    _changed(id);
  }

  Future<void> renameFolder(String id, String name) async {
    await _db.update(
      'folders',
      {'name': name, 'updated_at': _now()},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed(id);
  }

  /// Moves [id] under [parentId] (null = top level). Throws [ArgumentError]
  /// if that would put a folder inside itself or one of its own subfolders.
  Future<void> moveFolder(String id, String? parentId) async {
    for (String? p = parentId; p != null;) {
      if (p == id) throw ArgumentError('a folder cannot be moved into itself');
      final rows = await _db.query('folders', columns: ['parent_id'], where: 'id = ?', whereArgs: [p]);
      p = rows.isEmpty ? null : rows.single['parent_id'] as String?;
    }
    await _db.update(
      'folders',
      {'parent_id': parentId, 'updated_at': _now()},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed(id);
  }

  /// Deletes the folder and its subfolders; the notes inside are kept and end
  /// up in no folder. [deletedAt]: when it was deleted, if that was somewhere else and this is the news of it (see [_tombstone]).
  Future<void> deleteFolder(String id, {int? deletedAt}) async {
    final all = await listFolders();
    // the subfolders go with it (and are told to the other devices)
    final gone = <String>{id};
    for (var grew = true; grew;) {
      grew = false;
      for (final f in all) {
        if (f.parentId != null && gone.contains(f.parentId) && gone.add(f.id)) grew = true;
      }
    }
    await _db.delete('folders', where: 'id = ?', whereArgs: [id]);
    for (final g in gone) {
      await _tombstone('folder', g, deletedAt);
    }
    _changed(id);
  }

  /// Remembers that a note or folder was deleted for good, so that the other devices of the profile delete it too. It says when: a
  /// note or folder changed later than that is not deleted by it. Told by another device that deleted it, it is the time that device
  /// put there ([at]), not now: a change made elsewhere between the two must not look as if it came before the deletion. A time that is
  /// there already is only moved on, never back.
  Future<void> _tombstone(String kind, String id, [int? at]) async {
    final when = at ?? _now();
    final rows = await _db.query('sync_tombstones', columns: ['deleted_at'], where: 'kind = ? AND id = ?', whereArgs: [kind, id]);
    if (rows.isNotEmpty && (rows.single['deleted_at'] as int) >= when) return;
    await _db.insert('sync_tombstones', {'kind': kind, 'id': id, 'deleted_at': when}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Puts the note in the trash (it can be brought back until the trash is emptied, see [purgeTrash]).
  Future<void> trashNote(String id) async {
    await _db.update('notes', {'deleted_at': _now()}, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    _changed(id);
  }

  Future<void> restoreNote(String id) async {
    await _db.update('notes', {'deleted_at': null}, where: 'id = ?', whereArgs: [id]);
    _changed(id);
  }

  /// The notes in the trash, the last thrown away first.
  Future<List<TrashedNote>> listTrash() async {
    final rows = await _db.query('notes',
        columns: ['id', 'title', 'deleted_at', 'pdf_path', 'lock_mode'], where: 'deleted_at IS NOT NULL', orderBy: 'deleted_at DESC');
    return [
      for (final r in rows)
        TrashedNote(
          id: r['id'] as String,
          title: r['title'] as String,
          deletedAt: DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
          isPdf: r['pdf_path'] != null,
          lockMode: r['lock_mode'] as int,
        ),
    ];
  }

  /// Deletes for good what has lain in the trash for longer than [keep] (everything when [keep] is null).
  Future<int> purgeTrash({Duration? keep = const Duration(days: 30)}) async {
    final rows = keep == null
        ? await _db.query('notes', columns: ['id'], where: 'deleted_at IS NOT NULL')
        : await _db.query('notes',
            columns: ['id'], where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [DateTime.now().subtract(keep).millisecondsSinceEpoch]);
    for (final r in rows) {
      await deleteNote(r['id'] as String);
    }
    return rows.length;
  }

  /// Deletes the note for good, with all it holds. [deletedAt]: when it was deleted, if that was on another device and this is the
  /// news of it (see [_tombstone]).
  Future<void> deleteNote(String id, {int? deletedAt}) async {
    final rows = await _db.query('notes', columns: ['theme_image'], where: 'id = ?', whereArgs: [id]);
    await _db.delete('notes', where: 'id = ?', whereArgs: [id]);
    await _tombstone('note', id, deletedAt);
    _changed(id);
    final image = rows.isEmpty ? null : rows.single['theme_image'] as String?;
    if (image != null) {
      File(image,).delete().catchError((Object _) => File(image)); // already gone is fine
    }
  }

  /// The note with all its annotations, or null if it does not exist.
  Future<NoteData?> loadNote(String id) async {
    final rows = await _db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    final folderId = r['folder_id'] as String?;
    final folderImage = folderId == null
        ? null
        : (await _db.query('folders', columns: ['theme_image'], where: 'id = ?', whereArgs: [folderId]))
            .map((f) => f['theme_image'] as String?)
            .firstOrNull;

    final note = NoteData(
      id: id,
      title: r['title'] as String,
      background: PageBackground.stored(r['paper'], r['background']),
      pageFormat: PageFormat.values.firstWhere(
        (f) => f.name == r['page_format'],
        orElse: () => PageFormat.a4,
      ),
      landscape: (r['landscape'] as int? ?? 0) != 0,
      themeImage: r['theme_image'] as String?,
      folderThemeImage: folderImage,
      marginLeft: (r['margin_left'] as num?)?.toDouble() ?? 56,
      marginRight: (r['margin_right'] as num?)?.toDouble() ?? 56,
      marginTop: (r['margin_top'] as num?)?.toDouble() ?? 56,
      marginBottom: (r['margin_bottom'] as num?)?.toDouble() ?? 56,
      documentText: r['document_text'] as String,
      documentSpans: _decodeSpans(r['document_spans'] as String),
      pdfName: r['pdf_name'] as String?,
      pdfPath: r['pdf_path'] as String?,
      pdfSha256: r['pdf_sha256'] as String?,
      pdfPageCount: r['pdf_page_count'] as int?,
      nativePages: _decodePages(r['native_pages'] as String?),
      layers: LayerStack.fromJsonText(r['layers'] as String?),
    );

    for (final s in await _db.query('strokes', where: 'note_id = ?', whereArgs: [id], orderBy: 'id')) {
      final stroke = DrawingStroke(
        id: s['uid'] as String?,
        color: Color(s['color'] as int),
        width: s['width'] as double,
        points: decodePoints(s['points'] as Uint8List),
        author: s['author'] as String?,
        dash: StrokeDash.byIndex(s['dash'] as int?),
        fill: s['fill'] == null ? null : Color(s['fill'] as int),
        brush: (s['brush'] as String?) ?? penBrushId,
        layer: (s['layer'] as String?) ?? baseLayerId,
        link: StrokeLink.decode(s['link'] as String?),
        group: (s['grp'] as String?) ?? noGroup,
        curve: CurvedPath.decode(s['curve'] as String?),
        gradient: FillGradient.decode(s['gradient'] as String?),
        label: StrokeLabel.decode(s['label'] as String?),
      );
      final pressure = s['pressure'] as Uint8List?;
      if (pressure != null && pressure.length == stroke.points.length) stroke.pressures = List.of(pressure);
      // a stroke from before strokes had ids got one just now: a stamp that never matches has it written at the next save
      _stored[stroke] = _StoredStroke(id, s['id'] as int, s['page_index'] as int, s['uid'] == null ? -1 : stroke.stamp);
      note.strokes.putIfAbsent(s['page_index'] as int, () => []).add(stroke);
    }

    for (final b in await _db.query('text_boxes', where: 'note_id = ?', whereArgs: [id], orderBy: 'seq')) {
      final box = TextBoxWidgetModel(
        id: b['id'] as String,
        position: Offset(b['x'] as double, b['y'] as double),
        // notes from before boxes could be resized all say 140, which was never a choice
        size: Size(b['width'] as double, (b['height'] as double) == 140 ? 0 : b['height'] as double),
        initialText: b['text'] as String,
        fontSize: b['font_size'] as double,
        style: b['style'] == null ? TextBoxStyle.defaults : TextBoxStyle.fromJson(_decodeJson(b['style'] as String)),
        author: b['author'] as String?,
        layer: (b['layer'] as String?) ?? baseLayerId,
        group: (b['grp'] as String?) ?? noGroup,
      );
      box.controller.attributes.addAll(_decodeSpans(b['spans'] as String));
      note.textBoxes.putIfAbsent(b['page_index'] as int, () => []).add(box);
    }

    for (final m in await _db.query('images', where: 'note_id = ?', whereArgs: [id], orderBy: 'seq')) {
      note.images.putIfAbsent(m['page_index'] as int, () => []).add(ImageItem(
            id: m['id'] as String,
            path: m['path'] as String,
            position: Offset(m['x'] as double, m['y'] as double),
            size: Size(m['width'] as double, m['height'] as double),
            author: m['author'] as String?,
            layer: (m['layer'] as String?) ?? baseLayerId,
            group: (m['grp'] as String?) ?? noGroup,
          ));
    }

    for (final h in await _db.query('highlights', where: 'note_id = ?', whereArgs: [id], orderBy: 'id')) {
      note.highlights.putIfAbsent(h['page_index'] as int, () => []).add(PdfHighlight(
            id: h['uid'] as String?,
            rect: Rect.fromLTRB(h['left'] as double, h['top'] as double,
                h['right'] as double, h['bottom'] as double),
            color: Color(h['color'] as int),
            commentBox: h['comment_box'] as String?,
            author: h['author'] as String?,
          ));
    }
    _hold(note);
    return note;
  }

  /// What each note held when it was last loaded or saved here, to tell at the next save what the save added. A note that was not
  /// loaded since the app started has no entry: its first save adds nothing (there is nothing to compare with).
  final _held = <String, NoteHeld>{};

  void _hold(NoteData note) {
    _held.remove(note.id);
    _held[note.id] = NoteHeld.of(note);
    if (_held.length > 100) _held.remove(_held.keys.first);
  }

  final StreamController<NoteActivity> _activity = StreamController<NoteActivity>.broadcast();

  /// What saves added to notes: pages that got something on them, highlights, links to other notes (see [NoteActivity]).
  Stream<NoteActivity> get activity => _activity.stream;

  /// Which row each stroke object was last written to (or read from), so that a save writes
  /// only the strokes that are new or changed instead of all of them.
  final Expando<_StoredStroke> _stored = Expando('stored strokes');

  /// Writes the note. The note row, its text boxes, pictures and highlights (a few small
  /// rows) are written afresh each time; the strokes, which are by far the most, only where
  /// they differ from what is stored: new ones are added, changed ones updated, removed
  /// ones deleted.
  Future<void> saveNote(NoteData n) async {
    final written = <(DrawingStroke, _StoredStroke)>[];
    await _db.transaction((txn) async {
      final updated = await txn.update(
        'notes',
        {
          'title': n.title,
          'background': n.background.legacyName,
          'paper': n.background.paperName,
          'layers': n.layers.toJsonText(),
          'page_format': n.pageFormat.name,
          'landscape': n.landscape ? 1 : 0,
          'margin_left': n.marginLeft,
          'margin_right': n.marginRight,
          'margin_top': n.marginTop,
          'margin_bottom': n.marginBottom,
          'document_text': n.documentText,
          'document_spans': _encodeSpans(n.documentSpans),
          'pdf_name': n.pdfName,
          'pdf_path': n.pdfPath,
          'pdf_sha256': n.pdfSha256,
          'pdf_page_count': n.pdfPageCount,
          'native_pages': jsonEncode((n.nativePages.toList()..sort())),
          'updated_at': _now(),
        },
        where: 'id = ?',
        whereArgs: [n.id],
      );
      if (updated == 0) return; // deleted meanwhile: do not resurrect its rows

      for (final table in const ['text_boxes', 'highlights', 'images']) {
        await txn.delete(table, where: 'note_id = ?', whereArgs: [n.id]);
      }

      // ---- strokes: what is there, then what differs. Everything about a stroke that gets
      // written (its bytes and its stamp) is taken in one go, after the reading and before the
      // writing: a stroke that changes while the writing waits is written as it was, and
      // is seen as changed by the next save.
      final existing = {
        for (final r in await txn.query('strokes', columns: ['id'], where: 'note_id = ?', whereArgs: [n.id])) r['id'] as int,
      };
      final keep = <int>{};
      final changed = <_StrokeWrite>[];
      final added = <_StrokeWrite>[];
      var inOrder = true;
      n.strokes.forEach((page, list) {
        var lastRow = -1;
        var sawNew = false;
        for (final s in list) {
          if (s.points.length < 2) continue; // a tap that never became a line
          final was = _stored[s];
          final stamp = s.stamp;
          if (was != null && was.noteId == n.id && was.page == page && existing.contains(was.rowId) && keep.add(was.rowId)) {
            // rows are read back in the order they were made: a stroke that went back in the
            // middle of a list (an undone erase) does not keep its place, so the note is rewritten
            if (sawNew || was.rowId < lastRow) inOrder = false;
            lastRow = was.rowId;
            if (was.stamp != stamp) changed.add(_StrokeWrite(s, page, stamp, was.rowId));
          } else {
            sawNew = true;
            added.add(_StrokeWrite(s, page, stamp));
          }
        }
      });
      if (!inOrder) {
        // all of them again, in order
        keep.clear();
        changed.clear();
        added.clear();
        n.strokes.forEach((page, list) {
          for (final s in list) {
            if (s.points.length >= 2) added.add(_StrokeWrite(s, page, s.stamp));
          }
        });
      }

      final gone = existing.difference(keep);
      if (gone.isNotEmpty) {
        final batch = txn.batch();
        for (final id in gone) {
          batch.delete('strokes', where: 'id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      }
      if (changed.isNotEmpty) {
        final batch = txn.batch();
        for (final w in changed) {
          batch.update('strokes', w.columns(n.id)..remove('note_id'), where: 'id = ?', whereArgs: [w.row]);
        }
        await batch.commit(noResult: true);
        for (final w in changed) {
          written.add((w.stroke, _StoredStroke(n.id, w.row!, w.page, w.stamp)));
        }
      }
      if (added.isNotEmpty) {
        final batch = txn.batch();
        for (final w in added) {
          batch.insert('strokes', w.columns(n.id));
        }
        final ids = await batch.commit();
        for (var i = 0; i < added.length; i++) {
          written.add((added[i].stroke, _StoredStroke(n.id, ids[i] as int, added[i].page, added[i].stamp)));
        }
      }

      final batch = txn.batch();
      n.textBoxes.forEach((page, list) {
        for (var i = 0; i < list.length; i++) {
          final b = list[i];
          batch.insert('text_boxes', {
            'id': b.id,
            'note_id': n.id,
            'page_index': page,
            'x': b.position.dx,
            'y': b.position.dy,
            'width': b.size.width,
            'height': b.size.height,
            'font_size': b.fontSize,
            'text': b.controller.text,
            'spans': _encodeSpans(b.controller.attributes),
            'style': b.style.isDefault ? null : jsonEncode(b.style.toJson()),
            'seq': i,
            'author': b.author,
            'layer': b.layer == baseLayerId ? null : b.layer,
            'grp': b.group == noGroup ? null : b.group,
          });
        }
      });
      n.images.forEach((page, list) {
        for (var i = 0; i < list.length; i++) {
          final m = list[i];
          batch.insert('images', {
            'id': m.id,
            'note_id': n.id,
            'page_index': page,
            'path': m.path,
            'x': m.position.dx,
            'y': m.position.dy,
            'width': m.size.width,
            'height': m.size.height,
            'seq': i,
            'author': m.author,
            'layer': m.layer == baseLayerId ? null : m.layer,
            'grp': m.group == noGroup ? null : m.group,
          });
        }
      });
      n.highlights.forEach((page, list) {
        for (final h in list) {
          batch.insert('highlights', {
            'uid': h.id,
            'note_id': n.id,
            'page_index': page,
            'left': h.rect.left,
            'top': h.rect.top,
            'right': h.rect.right,
            'bottom': h.rect.bottom,
            'color': h.color.toARGB32(),
            'comment_box': h.commentBox,
            'author': h.author,
          });
        }
      });
      await batch.commit(noResult: true);
    });
    // only now, with the changes safely written, are the rows remembered
    for (final (stroke, row) in written) {
      _stored[stroke] = row;
    }
    final before = _held[n.id];
    _hold(n);
    if (before != null && !_activity.isClosed) {
      final added = NoteActivity.between(n.id, before, _held[n.id]!);
      if (added.any) _activity.add(added);
    }
    if (!_savedNotes.isClosed) _savedNotes.add(n.id);
    _changed(n.id);
  }

  final StreamController<String> _savedNotes = StreamController<String>.broadcast();
  final StreamController<String> _changes = StreamController<String>.broadcast();

  void _changed(String id) {
    if (!_changes.isClosed) _changes.add(id);
  }

  /// The ids of notes and folders as something about them changes that the sync between the devices carries: a note saved (as in
  /// [saved]), moved, starred, put in the trash, brought back or deleted, and a folder made, renamed, moved or deleted.
  Stream<String> get changes => _changes.stream;

  /// The ids of notes as they are saved (whoever saved them: the editor, a merge, a session).
  Stream<String> get saved => _savedNotes.stream;

  static String _encodeSpans(List<TextSpanAttribute> spans) => jsonEncode([
        for (final s in spans) {'s': s.start, 'e': s.end, 't': s.type.name, if (s.value != null) 'v': s.value},
      ]);

  /// The pages in [json]; a column that is not a list of numbers (hand-edited, damaged) has none rather than keeping the note from opening.
  static Set<int> _decodePages(String? json) {
    if (json == null) return {};
    try {
      final list = jsonDecode(json);
      return list is List ? {for (final i in list) if (i is int && i >= 0) i} : {};
    } on FormatException {
      return {};
    }
  }

  static List<TextSpanAttribute> _decodeSpans(String json) => [
        for (final m in (jsonDecode(json) as List).cast<Map<String, dynamic>>())
          if (AttributeType.values.where((t) => t.name == m['t']).firstOrNull case final type?)
            TextSpanAttribute(
              start: m['s'] as int,
              end: m['e'] as int,
              type: type,
              value: m['v'] as String?,
            ),
      ];
}

/// A stroke to write, as it was when the save looked at it.
class _StrokeWrite {
  final DrawingStroke stroke;
  final int page, stamp;

  /// The row it replaces; null for a new one.
  final int? row;
  final Uint8List _points;

  _StrokeWrite(this.stroke, this.page, this.stamp, [this.row]) : _points = encodePoints(stroke.points);

  Map<String, Object?> columns(String noteId) => {
        'note_id': noteId,
        'uid': stroke.id,
        'page_index': page,
        'color': stroke.color.toARGB32(),
        'width': stroke.width,
        'points': _points,
        'author': stroke.author,
        'fill': stroke.fill?.toARGB32(),
        'dash': stroke.dash.index,
        'pressure': stroke.pressures == null ? null : Uint8List.fromList(stroke.pressures!),
        'brush': stroke.brush == penBrushId ? null : stroke.brush,
        'layer': stroke.layer == baseLayerId ? null : stroke.layer,
        'link': stroke.link?.encode(),
        'grp': stroke.group == noGroup ? null : stroke.group,
        'curve': stroke.curve?.encode(),
        'gradient': stroke.gradient?.encode(),
        'label': stroke.label?.encode(),
      };
}

/// Where a stroke is stored: the note, the row and page, and its [DrawingStroke.stamp] when it was written.
class _StoredStroke {
  final String noteId;
  final int rowId, page, stamp;

  const _StoredStroke(this.noteId, this.rowId, this.page, this.stamp);
}
