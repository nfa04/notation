import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/note_data.dart';
import 'replica.dart';

/// What was changed on a copy of a note without a live session: new, changed and deleted elements, found by
/// comparing the note with how it was when the copy was received (the baseline). Nothing here needs the other
/// device to be online, or a [Replica]; the changes go to the owner as [CollabOp]s, which take them in.
class NoteDelta {
  /// The marker of a deleted element in a digest list.
  static const gone = 'gone';

  static String _digest(Map<String, Object?> data) {
    final clean = {...data}..remove('bytes')..remove('ext');
    return sha1.convert(utf8.encode(jsonEncode(clean))).toString();
  }

  /// A short fingerprint for every element of [note], by `kind:id`. Stable between runs and devices.
  static Map<String, String> digests(NoteData note) => {for (final e in Replica.elementsOf(note).entries) e.key: _digest(e.value.data)};

  /// What differs between [note] and the [baseline]: elements that are new or changed (with the bytes of new
  /// pictures), and the deletion of the ones that are gone.
  static List<CollabOp> changesSince(NoteData note, Map<String, String> baseline, {String site = 'offline', Uint8List? Function(String path)? readImage}) {
    final now = Replica.elementsOf(note);
    final ops = <CollabOp>[];
    const version = Version(1, 'offline');
    for (final e in now.entries) {
      final digest = _digest(e.value.data);
      if (baseline[e.key] == digest) continue;
      final data = {...e.value.data};
      if (e.value.kind == ElementKind.image && !baseline.containsKey(e.key)) {
        final path = _imagePath(note, e.value.id);
        final bytes = path == null ? null : (readImage ?? Replica.imageBytes)(path);
        if (bytes != null) {
          data['bytes'] = base64Encode(bytes);
          data['ext'] = Replica.imageExtension(path!);
        }
      }
      ops.add(CollabOp(e.value.kind, e.value.id, version, data: data));
    }
    for (final key in baseline.keys) {
      if (now.containsKey(key)) continue;
      final colon = key.indexOf(':');
      final kind = ElementKind.values.where((k) => k.name == key.substring(0, colon)).firstOrNull;
      if (kind == null || kind == ElementKind.note) continue;
      ops.add(CollabOp(kind, key.substring(colon + 1), version, deleted: true));
    }
    return ops;
  }

  static String? _imagePath(NoteData note, String id) {
    for (final list in note.images.values) {
      for (final m in list) {
        if (m.id == id) return m.path;
      }
    }
    return null;
  }

  /// The digests of [ops], to compare with the ones of an earlier set (what was taken in already).
  static Map<String, String> digestsOf(List<CollabOp> ops) => {
        for (final op in ops) Replica.keyOf(op.kind, op.id): op.deleted ? gone : _digest(op.data),
      };

  /// Of [ops], those that differ from what [applied] says was taken in before: a delta that is sent again and
  /// again (it always counts from the same baseline) is only applied for what changed since the last time.
  static List<CollabOp> notYetApplied(List<CollabOp> ops, Map<String, String> applied) {
    final digests = digestsOf(ops);
    return [
      for (final op in ops)
        if (applied[Replica.keyOf(op.kind, op.id)] != digests[Replica.keyOf(op.kind, op.id)]) op,
    ];
  }
}
