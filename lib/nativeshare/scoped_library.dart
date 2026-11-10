import 'dart:typed_data';

import '../devicesync/sync_library.dart';
import 'share_model.dart';
import 'share_scope.dart';

/// The library as one share sees it: the shared note, or the shared folder with what is below it, and nothing else. It is what the
/// sync of a shared folder (`FolderSync`) is given in place of the whole library, so that the same engine - newer replaces older, a
/// change on both sides keeps both, deletions travel - works for a share, and cannot reach anything outside it.
///
/// What the other participants publish is untrusted: anyone who can write in the shared folder can put anything in a manifest. So a
/// note or folder is taken only if it belongs to the share, or is new here and lies in the share's folder; one that is here already and
/// does not belong to the share is left alone whatever the manifest says (an id that was made up cannot overwrite a note), a deletion
/// reaches only what belongs to the share, and settings are never taken.
class ScopedSyncLibrary extends SyncLibrary {
  final ShareScope scope;

  /// Where a received share is put: the folder the person chose (null: at the top). Used for the root folder of a shared folder and
  /// for a shared note, the first time they arrive.
  final String? targetFolderId;

  /// The participants of the share: the manifest tells only these what this device agreed with whom.
  Set<String> participants = {};

  /// Set when the participants deleted the shared note, or the root folder of the share. It is not deleted here: the share is over, and
  /// what the person has stays.
  bool rootDeleted = false;

  // ignore: use_super_parameters
  ScopedSyncLibrary(SyncLibrary base, this.scope, {this.targetFolderId}) : super.sharing(base);

  /// What the last [plan] allowed: notes and folders that are not part of the share yet but may be taken in now.
  final Set<String> _mayNotes = {}, _mayFolders = {};

  @override
  Future<SyncManifest> manifest() async {
    await scope.refresh();
    final all = await super.manifest();
    return SyncManifest(
      [for (final f in all.folders) if (scope.currentFolders.contains(f.id)) f],
      [
        for (final n in all.notes)
          if (scope.currentNotes.contains(n.id))
            SyncNote(n.id, n.version, n.created, n.folderId, n.favorite, n.deletedAt,
                marks: {for (final e in n.marks.entries) if (participants.contains(e.key)) e.key: e.value}, ancestors: n.ancestors),
      ],
      const [],
      [
        for (final t in all.tombs)
          if ((t.kind == 'note' && scope.hasNote(t.id)) || (t.kind == 'folder' && scope.hasFolder(t.id))) t,
      ],
    );
  }

  @override
  Future<SyncNote?> noteInfo(String id) async => scope.currentNotes.contains(id) ? super.noteInfo(id) : null;

  @override
  Future<SyncPlan> plan(String peer, String me, SyncManifest theirs, {bool lazy = false}) async {
    await scope.refresh();
    final present = await database.query('notes', columns: ['id']);
    final localNotes = {for (final r in present) r['id'] as String};
    final localFolders = {for (final r in await database.query('folders', columns: ['id'])) r['id'] as String};

    // folders: the root, and any folder below one that is in the share (parents first, whatever order the manifest has them in)
    final folders = <String>{};
    if (scope.isFolder) {
      var grew = true;
      while (grew) {
        grew = false;
        for (final f in theirs.folders) {
          if (folders.contains(f.id)) continue;
          final known = scope.hasFolder(f.id);
          if (!known && localFolders.contains(f.id)) continue; // an id that is here and not part of the share
          final under = f.parentId != null && (scope.currentFolders.contains(f.parentId) || folders.contains(f.parentId));
          if (known || f.id == scope.rootId || under) {
            folders.add(f.id);
            grew = true;
          }
        }
      }
    }
    final notes = <String>{};
    for (final n in theirs.notes) {
      final known = scope.hasNote(n.id);
      if (!known && localNotes.contains(n.id)) continue;
      final inside = scope.isFolder && n.folderId != null && (scope.currentFolders.contains(n.folderId) || folders.contains(n.folderId));
      if (scope.isFolder ? (known || inside) : n.id == scope.rootId) notes.add(n.id);
    }
    _mayFolders
      ..clear()
      ..addAll(folders);
    _mayNotes
      ..clear()
      ..addAll(notes);

    final told = SyncManifest(
      [for (final f in theirs.folders) if (folders.contains(f.id)) f],
      [for (final n in theirs.notes) if (notes.contains(n.id)) n],
      const [],
      [
        for (final t in theirs.tombs)
          if ((t.kind == 'note' && scope.hasNote(t.id)) || (t.kind == 'folder' && scope.hasFolder(t.id))) t,
      ],
    );
    final plan = await super.plan(peer, me, told);
    // the root going is the end of the share, not something to do here
    if (plan.deleteNotes.remove(scope.rootId) && !scope.isFolder) rootDeleted = true;
    if (plan.deleteFolders.remove(scope.rootId) && scope.isFolder) rootDeleted = true;
    return plan;
  }

  bool _mayTakeNote(String id) => scope.hasNote(id) || _mayNotes.contains(id);

  @override
  Future<void> applyNote(String peer, SyncNote info, Uint8List? bytes, {required bool data, required bool meta, String? title, bool lazy = false}) async {
    if (!_mayTakeNote(info.id)) return;
    final first = !scope.hasNote(info.id) && (await database.query('notes', columns: ['id'], where: 'id = ?', whereArgs: [info.id])).isEmpty;
    await scope.addNote(info.id);
    // a shared note goes where the person chose, and stays there: where the owner keeps it, and whether they starred it, is theirs
    final keepPlace = !scope.isFolder && !first;
    await super.applyNote(peer, info, bytes, data: data, meta: meta && !keepPlace);
    if (first && !scope.isFolder) {
      final target = targetFolderId;
      final ok = target != null && (await database.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [target])).isNotEmpty;
      await database.update('notes', {'folder_id': ok ? target : null}, where: 'id = ?', whereArgs: [info.id]);
    }
  }

  @override
  Future<void> applyFolder(SyncFolder f, {({String ext, Uint8List bytes})? image}) async {
    if (!scope.isFolder || !(scope.hasFolder(f.id) || _mayFolders.contains(f.id))) return;
    var folder = f;
    if (f.id == scope.rootId) {
      // the root of a shared folder is put where the person chose, the first time; after that it stays where they moved it
      final here = await database.query('folders', columns: ['parent_id'], where: 'id = ?', whereArgs: [f.id]);
      final target = targetFolderId;
      final targetOk = target != null && (await database.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [target])).isNotEmpty;
      folder = SyncFolder(f.id, here.isNotEmpty ? here.single['parent_id'] as String? : (targetOk ? target : null), f.name, f.color, f.sortOrder, f.updatedAt);
    }
    await scope.addFolder(f.id);
    await super.applyFolder(folder, image: image);
  }

  @override
  Future<void> deleteNote(String id, {int? at}) async {
    if (!scope.hasNote(id)) return;
    await super.deleteNote(id, at: at);
  }

  @override
  Future<void> deleteFolder(String id, {int? at}) async {
    if (!scope.hasFolder(id)) return;
    await super.deleteFolder(id, at: at);
  }

  /// A shared place never has settings.
  @override
  Future<void> applySetting(SyncSettingValue s) async {}

  /// Whether the share is of a note ([ShareKind.note]) or a folder.
  ShareKind get kind => scope.kind;
}
