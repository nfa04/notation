import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../data/note_file.dart';
import '../data/note_file_service.dart';
import '../l10n/language.dart';
import 'live_marker.dart';
import 'invite.dart';
import 'secure_box.dart';
import '../sync/caldav_service.dart' show SecretStore;
import 'share_storage.dart';

/// A link to a copy of a note that waits on cloud storage: where to fetch the sealed file, and the
/// key that opens it. As a link: `notation://copy?u=<address>&n=<who shares>#<key>`; the key is after
/// the `#`, which no server ever sees, so the storage holds only a file nobody can read.
class CopyInvite {
  final Uri url;
  final Uint8List key;
  final String? from;

  /// The marker file next to the copy, which says whether its owner is in a live session on the note right now.
  final Uri? marker;

  /// Where people who have this link can leave their changes to the note for its owner (sealed), if the service has such a place.
  final Uri? inbox;

  CopyInvite(this.url, this.key, {this.from, this.marker, this.inbox});

  static const keyBytes = 32;

  String toLink() {
    final query = {'u': url.toString(), if (marker != null) 'm': marker.toString(), if (inbox != null) 'i': inbox.toString(), if (from != null && from!.isNotEmpty) 'n': from!};
    return '${Uri(scheme: 'notation', host: 'copy', queryParameters: query)}#${base64Url.encode(key).replaceAll('=', '')}';
  }

  /// Reads a link (or text that has one in it); null if it is not a link to a copy.
  static CopyInvite? parse(String text) {
    final match = RegExp(r'notation://copy[^\s]*').firstMatch(text.trim());
    if (match == null) return null;
    final Uri uri;
    try {
      uri = Uri.parse(match.group(0)!);
    } on FormatException {
      return null;
    }
    if (uri.host != 'copy') return null;
    final u = Uri.tryParse(uri.queryParameters['u'] ?? '');
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return null;
    final fragment = uri.fragment;
    if (fragment.isEmpty) return null;
    try {
      final key = base64Url.decode(fragment + '=' * ((4 - fragment.length % 4) % 4));
      if (key.length != keyBytes) return null;
      final m = Uri.tryParse(uri.queryParameters['m'] ?? '');
      final marker = m != null && (m.scheme == 'https' || m.scheme == 'http') && m.host.isNotEmpty ? m : null;
      final i = Uri.tryParse(uri.queryParameters['i'] ?? '');
      final inbox = i != null && (i.scheme == 'https' || i.scheme == 'http') && i.host.isNotEmpty ? i : null;
      return CopyInvite(u, Uint8List.fromList(key), from: uri.queryParameters['n'], marker: marker, inbox: inbox);
    } on FormatException {
      return null;
    }
  }
}

/// Sharing a copy of a note through a storage service the person has connected, and opening such a copy.
/// The note is sealed here with a key of its own that goes only into the link; the service gets the sealed file.
class CloudShare {
  final NoteFileService _files;

  /// The services a copy can be put on, in the order they are offered.
  final List<ShareStorage> storages;

  /// Used to download plain links (and the one that [ShareStorage.handles] none).
  final Future<Uint8List> Function(Uri url) _download;

  /// Keeps the markers of the copies that were shared, so that opening a link while the owner is live offers to join.
  final LiveMarkers markers;

  /// [download] is for tests against a local server; [markers] to follow sessions with.
  CloudShare(this._files, this.storages, {Future<Uint8List> Function(Uri url)? download, LiveMarkers? markers})
      : _download = download ?? downloadShared,
        markers = markers ?? LiveMarkers(storages, _NoStore());

  /// The services that can be used now.
  List<ShareStorage> get available => [for (final s in storages) if (s.available) s];

  /// Whether there is any service to share through.
  bool get canShare => available.isNotEmpty;

  /// Passes a link that came back from a service's sign-in page (`notation://oauth/...`) to the service it is for.
  /// True if one of them took it.
  Future<bool> handleRedirect(Uri uri) async {
    for (final s in storages) {
      if (await s.handleRedirect(uri)) return true;
    }
    return false;
  }

  /// Seals a copy of the note and puts it on [storage] (the first available one when null). The link works
  /// whether or not this device is online.
  Future<CopyInvite> shareCopy(String noteId, {String? from, ShareStorage? storage}) async {
    final target = storage ?? available.firstOrNull;
    if (target == null) {
      throw StateError(storages.isEmpty ? tr('There is no service to share through.') : storages.first.unavailableReason ?? tr('There is no service to share through.'));
    }
    if (!target.available) throw StateError(target.unavailableReason ?? tr('There is no service to share through.'));
    final edited = await markers.editedOf(noteId);
    final bytes = await _files.exportBytes(noteId);
    if (bytes == null) throw StateError(await _files.isLocked(noteId) ? tr('Take the lock off this note before sharing it.') : tr('That note is gone'));
    final r = Random.secure();
    final key = Uint8List.fromList([for (var i = 0; i < CopyInvite.keyBytes; i++) r.nextInt(256)]);
    final sealed = await SecureBox(key).seal(bytes);
    final copy = await target.store(sealed);

    // the marker: lets whoever opens the link know when the owner is live on the note
    Uri? marker;
    if (target.canReplace) {
      try {
        final first = await LiveMarker(live: false, at: DateTime.now()).seal(key);
        final file = await target.store(first);
        marker = file.url;
        await markers.add(noteId, target, file.ref, key, copyRef: copy.ref, copyOf: edited);
      } catch (_) {
        marker = null; // the copy works without it
      }
    }
    // a place for people who have the link to leave their changes for the owner, if the service has one
    InboxInfo? inbox;
    if (target.hasInbox) {
      try {
        inbox = await target.createInbox();
      } catch (_) {
        inbox = null; // the copy works without it
      }
    }
    if (marker != null && inbox != null) await markers.setInbox(noteId, key, inbox.ref, target);
    return CopyInvite(copy.url, key, from: from, marker: marker, inbox: inbox?.dropUrl);
  }

  /// Leaves [sealed] in the inbox of the copy [invite] points at (the owner takes it in when the app next looks).
  Future<void> dropChanges(CopyInvite invite, String name, Uint8List sealed) async {
    final url = invite.inbox;
    final storage = url == null ? null : storages.where((s) => s.handlesDrop(url)).firstOrNull;
    if (url == null || storage == null) throw StateError(tr('This copy has no place to send changes to.'));
    await storage.drop(url, name, sealed);
  }

  /// The live session of the owner of a copy, when the link's marker says they are there right now (a session that
  /// runs, or the room where they wait: coming in starts one); null otherwise, also when the marker cannot be read.
  Future<SessionInvite?> liveSession(CopyInvite invite, {DateTime? now}) async => (await liveOffer(invite, now: now))?.invite;

  /// Like [liveSession], with the time the marker was written.
  Future<({SessionInvite invite, DateTime at})?> liveOffer(CopyInvite invite, {DateTime? now}) async {
    final url = invite.marker;
    if (url == null) return null;
    try {
      final marker = await LiveMarker.open(invite.key, await _fetch(url));
      if (marker == null || !marker.isFresh(now ?? DateTime.now())) return null;
      final session = SessionInvite.parse(marker.link!);
      return session == null ? null : (invite: session, at: marker.at);
    } catch (_) {
      return null;
    }
  }

  /// The version of the copy [invite] points at, as its marker says (whether or not the owner is there); null if
  /// the marker cannot be read or says nothing about it (the copy is as first shared).
  Future<int?> copyVersion(CopyInvite invite) async {
    final url = invite.marker;
    if (url == null) return null;
    try {
      return (await LiveMarker.open(invite.key, await _fetch(url)))?.copy;
    } catch (_) {
      return null;
    }
  }

  /// The note in the copy [invite] points at, as it is up there now (nothing is saved).
  Future<ParsedNoteFile> readCopy(CopyInvite invite) async {
    final sealed = await _fetch(invite.url);
    try {
      return decodeNoteFile(await SecureBox(invite.key).open(sealed));
    } catch (_) {
      throw StateError(tr('This copy cannot be opened: the link is incomplete, or the file was changed.'));
    }
  }

  Future<Uint8List> _fetch(Uri url) {
    final special = storages.where((s) => s.handles(url)).firstOrNull;
    return special?.fetch(url) ?? _download(url);
  }

  /// Makes a new note of the copy a link points at.
  Future<ImportResult> openCopy(CopyInvite invite, {String? folderId}) async {
    final sealed = await _fetch(invite.url);
    final Uint8List plain;
    try {
      plain = await SecureBox(invite.key).open(sealed);
    } catch (_) {
      throw StateError(tr('This copy cannot be opened: the link is incomplete, or the file was changed.'));
    }
    return _files.importBytes(plain, folderId: folderId);
  }
}

/// Where nothing is kept (a [CloudShare] made without markers to remember).
class _NoStore implements SecretStore {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async => _value = value;
  @override
  Future<void> delete() async => _value = null;
}
