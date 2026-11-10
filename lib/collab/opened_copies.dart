import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/note_repository.dart';
import '../sync/caldav_service.dart' show SecretStore;
import 'cloud_share.dart';
import 'inbox.dart';
import 'note_delta.dart';
import 'replica.dart';

/// A copy of someone else's note that was opened from a link: what it looked like when it was received (so that
/// what the person changed since can be found), and what has been sent back already.
class OpenedCopy {
  final String noteId;
  final CopyInvite invite;

  /// The digests of the elements of the note as received (and as of the last session on it).
  Map<String, String> baseline;

  /// This copy's name in the owner's inbox.
  final String site;

  /// The digests of the changes that were sent last, so that nothing is sent again.
  Map<String, String> lastSent;

  /// Whether the note was in a live session at the last look (when it ends, the baseline moves on).
  bool inSession;

  /// The time of the marker that a join was last tried for (not to try again for the same one).
  DateTime? triedAt;

  /// The version of the owner's copy that was taken in last ([LiveMarker.copy]); null: the one first shared.
  int? ownerVersion;

  OpenedCopy(this.noteId, this.invite, this.baseline, this.site, {Map<String, String>? lastSent, this.inSession = false, this.triedAt, this.ownerVersion})
      : lastSent = lastSent ?? {};

  Map<String, Object?> toJson() => {
        'note': noteId,
        'link': invite.toLink(),
        'baseline': baseline,
        'site': site,
        'sent': lastSent,
        'inSession': inSession,
        if (triedAt != null) 'tried': triedAt!.millisecondsSinceEpoch,
        if (ownerVersion != null) 'owner': ownerVersion,
      };

  static OpenedCopy? fromJson(Map<String, Object?> m) {
    final invite = CopyInvite.parse(m['link'] as String? ?? '');
    if (invite == null) return null;
    return OpenedCopy(
      m['note'] as String,
      invite,
      (m['baseline'] as Map).cast<String, String>(),
      m['site'] as String,
      lastSent: (m['sent'] as Map?)?.cast<String, String>(),
      inSession: m['inSession'] == true,
      triedAt: m['tried'] is num ? DateTime.fromMillisecondsSinceEpoch((m['tried'] as num).toInt()) : null,
      ownerVersion: m['owner'] is num ? (m['owner'] as num).toInt() : null,
    );
  }
}

/// The copies of other people's notes that this device has opened: it sends what the person changed on them back
/// to the owner (into the inbox of the copy), and says when the owner is online so that the person can join.
class OpenedCopies extends ChangeNotifier {
  final SecretStore _store;
  final CloudShare _share;
  final NoteRepository _notes;
  final DateTime Function() _now;

  OpenedCopies(this._store, this._share, this._notes, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final List<OpenedCopy> _copies = [];
  bool _loaded = false;

  List<OpenedCopy> get copies => List.unmodifiable(_copies);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final text = await _store.read();
    try {
      if (text != null) {
        _copies.addAll([
          for (final e in jsonDecode(text) as List)
            ?OpenedCopy.fromJson((e as Map).cast<String, Object?>()),
        ]);
      }
    } catch (_) {
      _copies.clear();
    }
  }

  Future<void> save() => _copies.isEmpty ? _store.delete() : _store.write(jsonEncode([for (final c in _copies) c.toJson()]));

  OpenedCopy? of(String noteId) => _copies.where((c) => c.noteId == noteId).firstOrNull;

  /// Notes that [noteId] was made from the copy [invite]; the note as it is now is what later changes count from.
  /// [ownerVersion] is the version of the copy that it was made from.
  Future<void> add(String noteId, CopyInvite invite, {int? ownerVersion}) async {
    await load();
    final note = await _notes.loadNote(noteId);
    if (note == null) return;
    final r = Random.secure();
    final site = List.generate(5, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _copies.removeWhere((c) => c.noteId == noteId);
    _copies.add(OpenedCopy(noteId, invite, NoteDelta.digests(note), site, ownerVersion: ownerVersion));
    await save();
    notifyListeners();
  }

  Future<void> forget(String noteId) async {
    await load();
    _copies.removeWhere((c) => c.noteId == noteId);
    await save();
    notifyListeners();
  }

  /// What the person changed on the copy since the baseline.
  Future<List<CollabOp>> changesOf(OpenedCopy copy) async {
    final note = await _notes.loadNote(copy.noteId);
    return note == null ? const [] : NoteDelta.changesSince(note, copy.baseline);
  }

  /// Sends what was changed on the copies since the last time to their owners, where they have an inbox. Returns
  /// how many were sent. Copies in a live session are left alone (the session carries their changes).
  Future<int> send({bool Function(String noteId)? inSession, String Function()? name}) async {
    await load();
    var sent = 0;
    for (final copy in _copies) {
      if (copy.invite.inbox == null || (inSession?.call(copy.noteId) ?? false)) continue;
      try {
        final ops = await changesOf(copy);
        if (ops.isEmpty) continue;
        final digests = NoteDelta.digestsOf(ops);
        if (mapEquals(digests, copy.lastSent)) continue;
        final message = InboxMessage(site: copy.site, name: name?.call() ?? '', at: _now(), ops: ops);
        await _share.dropChanges(copy.invite, message.fileName, await message.seal(copy.invite.key));
        copy.lastSent = digests;
        sent++;
      } catch (e) {
        debugPrint('[live] could not send the changes of a copy: $e');
      }
    }
    if (sent > 0) await save();
    return sent;
  }
}
