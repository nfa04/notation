import 'package:flutter/foundation.dart';

import '../collab/collab_service.dart';
import '../collab/invite.dart';
import '../collab/transport.dart';

/// What the sync services need of the live sessions of the app, to work on one note live on two devices of the same person.
abstract class LiveNotes {
  /// Whether a live session of any kind is going on for the note.
  bool hasSession(String noteId);

  /// The notes with a session between the person's own devices.
  Set<String> get ownNotes;

  /// Hosts a session on the open note for the person's other devices, which come in over [transport]. False if it cannot be done.
  Future<bool> host(String noteId, SessionInvite invite, HostTransport transport);

  /// Joins the session another device of the person hosts on the open note, over [transport]. False if it did not work.
  Future<bool> join(String noteId, SessionInvite invite, JoinTransport transport);

  /// Ends the session between the person's own devices on the note.
  Future<void> end(String noteId);

  /// The invite of the session this device hosts on the note, if it hosts one.
  SessionInvite? hostedInvite(String noteId);

  /// How the session stands: whether this device hosts it, how many are in it, whether it is over; null if there was none.
  ({bool host, int people, bool ended})? status(String noteId);

  /// Saves the note as it is on screen.
  Future<void> saveNote(String noteId);

  /// Told when a session changes (someone comes or goes, it ends).
  Listenable get changes;

  /// The way to the other devices is back (the connection to the server was made again): a session that is trying to get back to its
  /// host tries now, not at its next turn.
  void wake() {}

  /// The notes whose editor is ready to take part in a session, as each becomes so: a note is reported open before its editor has
  /// loaded it, and a session cannot start before.
  Stream<String> get editorsReady => const Stream.empty();
}

/// [LiveNotes] on the live sessions of the app and the editors that are open.
class CollabLiveNotes implements LiveNotes {
  final CollabService collab;

  CollabLiveNotes(this.collab);

  @override
  bool hasSession(String noteId) => collab.hasSession(noteId);

  @override
  Set<String> get ownNotes => collab.ownLiveNotes;

  @override
  Future<bool> host(String noteId, SessionInvite invite, HostTransport transport) => collab.startOwnHosting(noteId, invite, transport);

  @override
  Future<bool> join(String noteId, SessionInvite invite, JoinTransport transport) => collab.joinOwn(noteId, invite, transport);

  @override
  Future<void> end(String noteId) => collab.endOwn(noteId);

  @override
  SessionInvite? hostedInvite(String noteId) => collab.hostedInviteOf(noteId);

  @override
  ({bool host, int people, bool ended})? status(String noteId) => collab.ownStatus(noteId);

  @override
  Future<void> saveNote(String noteId) => collab.saveOpen(noteId);

  @override
  Listenable get changes => collab;

  @override
  void wake() => collab.wake();

  @override
  Stream<String> get editorsReady => collab.editorsReady;
}
