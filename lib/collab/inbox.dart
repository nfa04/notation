import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'live_marker.dart';
import 'note_delta.dart';
import 'replica.dart';
import 'secure_box.dart';

/// What a guest leaves in the inbox of a copy: the changes they made to their copy since they received it, sealed
/// with a key derived from the secret of the copy's link (so the storage and anyone without the link see nothing).
class InboxMessage {
  /// The guest's copy, so that the owner can tell what is new in a message that is sent again.
  final String site;
  final String name;
  final DateTime at;
  final List<CollabOp> ops;

  const InboxMessage({required this.site, required this.name, required this.at, required this.ops});

  static final _aad = utf8.encode('notation-inbox');

  /// The file name for a message, so that later ones sort after earlier ones.
  String get fileName => 'changes-$site-${at.millisecondsSinceEpoch.toString().padLeft(14, '0')}.s';

  static String? siteOf(String fileName) => RegExp(r'^changes-([A-Za-z0-9]+)-\d+\.s$').firstMatch(fileName)?.group(1);

  Future<Uint8List> seal(Uint8List linkKey) => SecureBox(deriveKey(linkKey, 'inbox')).seal(
        Uint8List.fromList(utf8.encode(jsonEncode({'site': site, 'name': name, 'at': at.millisecondsSinceEpoch, 'ops': [for (final o in ops) o.toJson()]}))),
        aad: _aad,
      );

  static Future<InboxMessage?> open(Uint8List linkKey, Uint8List sealed) async {
    try {
      final m = jsonDecode(utf8.decode(await SecureBox(deriveKey(linkKey, 'inbox')).open(sealed, aad: _aad))) as Map;
      return InboxMessage(
        site: m['site'] as String,
        name: m['name'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
        ops: [for (final j in (m['ops'] as List)) ?CollabOp.fromJson(j)],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Looks in the inboxes of the copies this device shared, and hands what guests changed on their copies to
/// [onChanges] (a guest's message always counts from what they received, so only what differs from what was taken in
/// before is handed on, and a later change to the same thing replaces an earlier one).
class HostInbox {
  final LiveMarkers _markers;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  /// Takes in changes of the guest [who] to the note [noteId]; completes when they are in.
  final Future<void> Function(String noteId, String who, List<CollabOp> ops) onChanges;

  final Duration every;
  Timer? _timer;
  Future<void>? _running;

  HostInbox(this._markers, this._read, this._write, this.onChanges, {this.every = const Duration(minutes: 3)});

  /// Starts looking now and then.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => poll());
    unawaited(poll());
  }

  void dispose() => _timer?.cancel();

  /// Looks in every inbox once. Calls that overlap share one look.
  Future<void> poll() => _running ??= _poll().whenComplete(() => _running = null);

  Future<void> _poll() async {
    for (final box in _markers.inboxes) {
      if (!box.storage.available) continue;
      try {
        final files = [for (final f in await box.storage.readInbox(box.ref)) f.name]..sort();
        // per guest: the newest message counts; the older files are removed with it
        final bySite = <String, List<String>>{};
        final junk = <String>[];
        for (final name in files) {
          final site = InboxMessage.siteOf(name);
          (site == null ? junk : bySite.putIfAbsent(site, () => [])).add(name);
        }
        for (final name in junk) {
          await box.storage.removeInboxFile(box.ref, name);
        }
        for (final e in bySite.entries) {
          final newest = e.value.last;
          final message = await InboxMessage.open(box.key, await box.storage.readInboxFile(box.ref, newest));
          if (message != null && message.site == e.key) {
            final applied = await _applied(box.noteId, message.site);
            final fresh = NoteDelta.notYetApplied(message.ops, applied);
            if (fresh.isNotEmpty) {
              await onChanges(box.noteId, message.name, fresh);
              await _remember(box.noteId, message.site, {...applied, ...NoteDelta.digestsOf(message.ops)});
            }
          }
          for (final name in e.value) {
            await box.storage.removeInboxFile(box.ref, name);
          }
        }
      } catch (err) {
        debugPrint('[live] could not read the inbox ${box.ref}: $err');
      }
    }
  }

  String _key(String noteId, String site) => 'inbox_applied:$noteId:$site';

  Future<Map<String, String>> _applied(String noteId, String site) async {
    final text = await _read(_key(noteId, site));
    if (text == null) return {};
    try {
      return (jsonDecode(text) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _remember(String noteId, String site, Map<String, String> digests) => _write(_key(noteId, site), jsonEncode(digests));
}
