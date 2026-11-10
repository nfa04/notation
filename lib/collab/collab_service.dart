import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/note_data.dart';
import '../data/safe_names.dart';
import '../models/canvas_models.dart';
import '../pdf/pdf_pages.dart';
import '../data/brush_library.dart';
import '../data/note_repository.dart';
import 'cloud_share.dart';
import '../nativeshare/native_share_service.dart';
import '../sync/caldav_service.dart' show SecretStore, KeystoreSecretStore;
import 'defaults.dart';
import 'device_budget.dart';
import 'invite.dart';
import 'inbox.dart';
import 'live_marker.dart';
import 'note_delta.dart';
import 'opened_copies.dart';
import '../history/note_history.dart';
import '../models/authorship.dart';
import '../profile/user_profile.dart';
import 'replica.dart';
import 'shared_notes.dart';
import 'standby.dart';
import 'session.dart';
import 'signaling.dart';
import 'transport.dart';
import 'ice_settings.dart';
import 'webrtc_transport.dart';
import '../l10n/language.dart';
import '../data/app_secure_storage.dart';

typedef HostTransportFactory = Future<HostTransport> Function(SessionInvite invite);
typedef JoinTransportFactory = JoinTransport Function(SessionInvite invite);

/// How the guests of a session reach the devices named to take over from the host (see [WarmNet]); null: they do not.
typedef WarmNetFactory = WarmNet? Function(SessionInvite invite);

/// Whether this device should not take over a session now, and why (see [DeviceBudget]); null: never says so.
typedef BudgetFactory = ValueListenable<String?>? Function();

/// What a note's editor offers the service, so that sessions on a note that is open use the editor's own data.
class EditorHooks {
  /// Starts the session of the note with [invite] (null: a new one).
  final Future<void> Function(SessionInvite? invite) start;

  /// Takes in changes that were made on a copy of the note while the owner was away.
  final Future<void> Function(List<CollabOp> ops) merge;

  /// Saves the note as it is on screen now.
  final Future<void> Function()? save;

  /// Starts a session of the note's own devices: it is hosted with [invite] on [transport], whose devices have proved who they are
  /// already, so they come in without being asked.
  final Future<void> Function(SessionInvite invite, HostTransport transport)? startOwn;

  /// Takes part in the session the service has for this note now (one that was joined, not started here).
  final void Function()? bind;

  const EditorHooks({required this.start, required this.merge, this.save, this.startOwn, this.bind});
}

/// What happened to a shared note, as told to the person (see [ShareNotice]).
enum ShareNoticeKind {
  /// Someone opened a copy of the note and a session was started for them.
  opened,

  /// Someone is in the session of the note.
  joined,

  /// Changes made on a copy while the owner was away were taken into the note.
  merged,

  /// The owner of a copy the person has opened is online: the person's copy joined their session.
  joinedOwner,

  /// The owner of a copy is online, but the note is open here: joining is up to the person.
  ownerOnline,
}

/// Something that happened with a note that was shared, for the person to be told.
class ShareNotice {
  final ShareNoticeKind kind;
  final String noteId;
  final String title;

  /// Who it was, if known.
  final String? who;

  const ShareNotice(this.kind, this.noteId, this.title, {this.who});
}

/// Someone's request to join one of our sessions, with the note it is about.
class JoinRequest {
  final String noteId;
  final String noteTitle;
  final CollabSession session;
  final PendingJoin request;

  const JoinRequest(this.noteId, this.noteTitle, this.session, this.request);
}

/// A try at joining a session, as it goes: connecting, waiting for the host to say yes (with the
/// code to read out), and then the note that was made from it.
class JoinAttempt extends ChangeNotifier {
  final SessionInvite invite;
  CollabSession? session;
  String? error;
  String? noteId;
  bool cancelled = false;

  /// How far the connection has got, in words.
  String status = tr('Connecting...');

  JoinAttempt(this.invite);

  bool get done => noteId != null || error != null || cancelled;

  /// Completes when the attempt has ended (joined, failed or cancelled).
  Future<void> get finished {
    if (done) return Future.value();
    final c = Completer<void>();
    void check() {
      if (done && !c.isCompleted) {
        removeListener(check);
        c.complete();
      }
    }

    addListener(check);
    return c.future;
  }

  void _update() => notifyListeners();
}

/// Live sessions of the app: hosting a note, joining one, and which note has which session. The
/// settings it needs are where the signalling server is, and the name others see.
class CollabService extends ChangeNotifier implements LiveSource {
  static const _serverKey = 'collab_server';
  static const _nameKey = 'collab_name';

  final NoteRepository _notes;
  final HostTransportFactory _hostTransport;
  final JoinTransportFactory _joinTransport;
  final WarmNetFactory _warmNet;
  final BudgetFactory _budgetFactory;
  ValueListenable<String?>? _budget;
  bool _budgetMade = false;

  /// One for all the sessions this device joins, made (and started) when the first one needs it.
  ValueListenable<String?>? get _deviceBudget {
    if (!_budgetMade) {
      _budgetMade = true;
      _budget = _budgetFactory();
    }
    return _budget;
  }

  /// The relay the direct connections fall back on (null: only STUN).
  final IceSettings? ice;
  final Future<Directory> Function() _support;
  final String _builtIn;

  /// Which notes are shared with others or were shared with the person.
  late final SharedNotes shared = SharedNotes(
    (key) => _notes.settings.get(key),
    (key, value) => _notes.settings.set(key, value),
    byMe: () => {
      ...?cloudShare?.markers.noteIds,
      for (final e in _sessions.entries)
        if (e.value.role == SessionRole.host && e.value.state != SessionState.ended) e.key,
    },
  );

  CollabService(
    this._notes, {
    HostTransportFactory? hostTransport,
    JoinTransportFactory? joinTransport,
    WarmNetFactory? warmNet,
    BudgetFactory? budget,
    Future<Directory> Function()? supportDirectory,
    String builtInServer = builtInSignalingServer,
    this.ice,
  })  : _builtIn = builtInServer,
        _hostTransport = hostTransport ??
            ((invite) async {
              final host = WebRtcHost(invite, iceServers: ice?.servers ?? defaultIceServers);
              await host.start();
              return host;
            }),
        _joinTransport = joinTransport ?? ((invite) => WebRtcJoin(invite, iceServers: ice?.servers ?? defaultIceServers)),
        // (on the same network as the sessions themselves: with transports of their own (tests), none unless given)
        _warmNet = warmNet ??
            (hostTransport == null && joinTransport == null ? (invite) => WebRtcWarmNet(invite, iceServers: ice?.servers ?? defaultIceServers) : (_) => null),
        // (the battery and the network of the device itself: not in tests with transports of their own, unless given)
        _budgetFactory = budget ?? (hostTransport == null && joinTransport == null ? () => DeviceBudget.platform()..start() : () => null),
        _support = supportDirectory ?? getApplicationSupportDirectory;

  /// Shares copies of notes through a storage service the person has connected (set when there is one to use).
  CloudShare? cloudShare;

  /// Sharing with the other people of a cloud service (see `NativeShareService`); null: not offered.
  NativeShareService? get nativeShares => _nativeShares;
  NativeShareService? _nativeShares;
  set nativeShares(NativeShareService? s) {
    _nativeShares = s;
    shared.native = s; // (the group symbol on a note takes it into account)
  }
  Standby? _standby;
  HostInbox? _inbox;
  OpenedCopies? _copies;
  bool _background = false;
  Timer? _copyTimer;

  /// The copies of other people's notes that were opened here (null until sharing is set up).
  OpenedCopies? get openedCopies => _copies;

  /// Starts sharing copies through [share]: the markers next to them follow the sessions of this service, and the
  /// app waits for people who open a copy (a session is started for them).
  ///
  /// [standbyClient] makes the connection to a room (for tests).
  void attachShare(CloudShare share, {SignalingClient Function(SessionInvite invite)? standbyClient, bool startInbox = true, SecretStore? copiesStore}) {
    cloudShare = share;
    share.markers.addListener(notifyListeners); // (the group symbol on notes follows the copies)
    share.markers.serverOf = () => server;
    share.markers.nameOf = () => _name;
    share.markers.watch(this);
    _standby = Standby(share.markers, this, (noteId) => unawaited(_onKnock(noteId)), clientFor: standbyClient);
    _standby!.refresh();
    _inbox = HostInbox(
      share.markers,
      (key) => _notes.settings.get(key),
      (key, value) => _notes.settings.set(key, value),
      (noteId, who, ops) => applyOffline(noteId, who, ops),
    );
    _copies = OpenedCopies(copiesStore ?? const KeystoreSecretStore(appSecureStorage, 'opened_copies'), share, _notes);
    _background = startInbox;
    if (startInbox) {
      _inbox!.start();
      _copyTimer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(checkCopies()));
      unawaited(checkCopies());
    }
  }

  /// Notes that [noteId] was made from the copy [invite] (opened from its link): what the person changes on it is
  /// sent back to the owner, and when the owner is online the copy joins their session.
  Future<void> rememberCopy(String noteId, CopyInvite invite) async {
    await shared.markWithMe(noteId, from: invite.from);
    await _copies?.add(noteId, invite, ownerVersion: await cloudShare?.copyVersion(invite));
    if (_background) unawaited(checkCopies());
  }

  bool _checkingCopies = false;

  /// For the copies that were opened here: sends what was changed on them, and joins the session of an owner who is online.
  Future<void> checkCopies() async {
    final copies = _copies, share = cloudShare;
    if (copies == null || share == null || _checkingCopies) return;
    _checkingCopies = true;
    try {
      await copies.load();
      // sessions that ended: what the note is now is what later changes count from
      for (final c in copies.copies) {
        final live = _sessions[c.noteId];
        final running = live != null && live.state != SessionState.ended;
        if (c.inSession && !running) {
          final note = await _notes.loadNote(c.noteId);
          if (note != null) c.baseline = NoteDelta.digests(note);
          c.lastSent = {};
          c.inSession = false;
          // the copy up there may be from before the session: what the owner puts up after it counts
          c.ownerVersion = await share.copyVersion(c.invite) ?? c.ownerVersion;
          await copies.save();
        }
      }
      // owners who are online and not tried yet: the copy joins their session (which carries its changes)
      final toJoin = <OpenedCopy>[];
      for (final c in copies.copies) {
        final live = _sessions[c.noteId];
        if (live != null && live.state != SessionState.ended) continue;
        final offer = await share.liveOffer(c.invite);
        if (offer == null || (c.triedAt != null && !offer.at.isAfter(c.triedAt!))) continue;
        c.triedAt = offer.at;
        toJoin.add(c);
      }
      if (toJoin.isNotEmpty) await copies.save();
      // the others take in what the owner changed while the two were not in a session, then send what was changed here
      final joining = {for (final c in toJoin) c.noteId};
      for (final c in copies.copies) {
        final live = _sessions[c.noteId];
        if (joining.contains(c.noteId) || (live != null && live.state != SessionState.ended)) continue;
        try {
          await _takeOwnerCopy(c);
        } catch (e) {
          debugPrint('[live] could not take in the copy of the owner: $e');
        }
      }
      await copies.send(
        inSession: (id) => joining.contains(id) || (_sessions[id] != null && _sessions[id]!.state != SessionState.ended),
        name: () => _name,
      );
      for (final c in toJoin) {
        if (_editors.containsKey(c.noteId)) {
          // the note is on screen: joining replaces what is on screen, so the person decides
          _notice(ShareNotice(ShareNoticeKind.ownerOnline, c.noteId, (await _notes.noteInfo(c.noteId))?.title ?? '', who: c.invite.from));
          continue;
        }
        final attempt = await joinOpenedCopy(c.noteId);
        if (attempt != null) {
          unawaited(attempt.finished.then((_) {
            if (attempt.noteId != null) {
              _notice(ShareNotice(ShareNoticeKind.joinedOwner, c.noteId, _titles[c.noteId] ?? '', who: c.invite.from));
            }
          }));
        }
      }
    } catch (e) {
      debugPrint('[live] could not check the copies: $e');
    } finally {
      _checkingCopies = false;
    }
  }

  /// When the owner put a newer state of the note up (the marker says so), takes in what they changed since the copy
  /// was last taken in. What the person here changed on the same things meanwhile stays, and still goes to the owner.
  Future<void> _takeOwnerCopy(OpenedCopy c) async {
    final share = cloudShare, copies = _copies;
    if (share == null || copies == null) return;
    final version = await share.copyVersion(c.invite);
    if (version == null || (c.ownerVersion != null && version <= c.ownerVersion!)) return;
    final local = await _notes.loadNote(c.noteId);
    if (local == null) return;
    final theirs = await share.readCopy(c.invite);
    // (the brushes the owner drew with: kept before the changes are worked out, which send a line together with its brush)
    await BrushLibrary(_notes.settings).adopt(theirs.brushes);
    final mine = {for (final op in NoteDelta.changesSince(local, c.baseline)) Replica.keyOf(op.kind, op.id)};
    final pictures = {
      for (final list in theirs.note.images.values)
        for (final m in list)
          if (theirs.images[m.id] case final picture?) m.path: picture.bytes,
    };
    final changes = [
      for (final op in NoteDelta.changesSince(theirs.note, c.baseline, readImage: (path) => pictures[path]))
        if (!mine.contains(Replica.keyOf(op.kind, op.id))) op,
    ];
    if (changes.isNotEmpty) await applyOffline(c.noteId, c.invite.from ?? '', changes);
    // from now on, changes here count from the owner's note (so what was changed here and not by them still counts)
    c.baseline = NoteDelta.digests(theirs.note);
    c.ownerVersion = version;
    await copies.save();
  }

  /// Joins the session of the owner of the copy that [noteId] was made from, if they are online; the note is
  /// taken in with what the owner has, and what the person changed on it meanwhile stays.
  Future<JoinAttempt?> joinOpenedCopy(String noteId) async {
    final copies = _copies, share = cloudShare;
    final copy = copies?.of(noteId);
    if (copies == null || share == null || copy == null) return null;
    final offer = await share.liveOffer(copy.invite);
    if (offer == null) return null;
    final offline = await copies.changesOf(copy);
    final attempt = join(offer.invite, intoNoteId: noteId, offline: offline, proofKey: copy.invite.key);
    // once in, the baseline moves on when the session ends (not before: a join that failed loses nothing)
    unawaited(attempt.finished.then((_) async {
      if (attempt.noteId != null) {
        copy.inSession = true;
        await copies.save();
      }
    }));
    return attempt;
  }

  /// Looks in the inboxes of the shared copies now (changes guests made on their copies are taken into the notes).
  Future<void> checkInboxes() => _inbox?.poll() ?? Future.value();

  /// Takes in changes that [who] made on a copy of [noteId] while its owner was away: into the session of the note
  /// if there is one, else into the editor that has it open, else into the saved note.
  Future<void> applyOffline(String noteId, String who, List<CollabOp> ops) async {
    await _keepVersion(noteId, VersionReason.merge, who: who);
    final session = _sessions[noteId];
    final editor = _editors[noteId];
    if (session != null && session.state != SessionState.ended) {
      session.applyExternal(ops);
    } else if (editor != null) {
      await editor.merge(ops);
    } else {
      final note = await _notes.loadNote(noteId);
      if (note == null) return;
      final raw = Replica('external');
      for (final op in ops) {
        raw.apply(note, op,
            makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero), saveImage: saveImage, onNoteField: (f, d) => Replica.applyNoteField(note, f, d));
      }
      await _notes.saveNote(note);
    }
    final title = _titles[noteId] ?? (await _notes.noteInfo(noteId))?.title ?? '';
    _notice(ShareNotice(ShareNoticeKind.merged, noteId, title, who: who.isEmpty ? null : who));
  }

  /// The notes whose rooms the app waits in for someone to open a copy.
  Set<String> get standbyNotes => _standby?.waitingFor ?? const {};

  final Map<String, EditorHooks> _editors = {};

  /// Earlier versions of notes: one is kept before changes from someone else come into a note. Null: none are.
  NoteHistory? history;

  /// Keeps the note as it is now (on screen, if it is open) as a version, before something else changes it.
  Future<void> _keepVersion(String noteId, VersionReason reason, {String? who}) async {
    final h = history;
    if (h == null) return;
    try {
      await _editors[noteId]?.save?.call();
      await h.snapshot(noteId, reason: reason, who: who == null || who.isEmpty ? null : who);
    } catch (e) {
      debugPrint('[history] could not keep a version: $e');
    }
  }

  /// The editor of [noteId] says it is open (and what it can do).
  void registerEditor(String noteId, EditorHooks hooks) {
    _editors[noteId] = hooks;
    if (!_ready.isClosed) _ready.add(noteId);
  }

  final _ready = StreamController<String>.broadcast();

  /// The notes whose editor registered, as each does (the live sessions between a person's own devices wait for it).
  Stream<String> get editorsReady => _ready.stream;

  void unregisterEditor(String noteId, EditorHooks hooks) {
    if (identical(_editors[noteId], hooks)) _editors.remove(noteId);
  }

  final _notices = StreamController<ShareNotice>.broadcast();

  /// Things that happened with notes that were shared (someone opened a copy, someone joined, changes were merged).
  Stream<ShareNotice> get notices => _notices.stream;

  void _notice(ShareNotice n) {
    if (!_notices.isClosed) _notices.add(n);
  }

  final Set<String> _knocking = {};

  /// Someone with the link of a copy of [noteId] knocked: a session is started in the room of the invite, in the
  /// editor if the note is open, else without one. The person who knocked keeps knocking, and gets in.
  Future<void> _onKnock(String noteId) async {
    if (!_knocking.add(noteId)) return;
    try {
      final existing = _sessions[noteId];
      if (existing != null && existing.state != SessionState.ended) return;
      final invite = cloudShare?.markers.standbyFor(noteId);
      final editor = _editors[noteId];
      if (editor != null) {
        await editor.start(invite);
      } else {
        await hostWithoutScreen(noteId, invite: invite);
      }
      final title = _titles[noteId] ?? (await _notes.noteInfo(noteId))?.title ?? '';
      _notice(ShareNotice(ShareNoticeKind.opened, noteId, title));
    } catch (e) {
      debugPrint('[live] could not start the session for a copy of $noteId: $e');
    } finally {
      _knocking.remove(noteId);
    }
  }

  /// Starts a session on [noteId] without a screen showing the note: it works on the note as saved, and a screen
  /// that opens the note later takes over.
  Future<CollabSession?> hostWithoutScreen(String noteId, {SessionInvite? invite}) async {
    final existing = _sessions[noteId];
    if (existing != null && existing.state != SessionState.ended) return existing;
    if (await _notes.locks.lockModeOf(noteId) != 0) return null;
    final note = await _notes.loadNote(noteId);
    if (note == null) return null;
    final binding = CollabBinding(
      note: () => note,
      change: (f) => f(),
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: saveImage,
      onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
      pdf: () async {
        final path = note.pdfPath;
        if (path == null || !File(path).existsSync()) return null;
        return SharedPdf(note.pdfName ?? 'document.pdf', note.pdfSha256 ?? '', note.pdfPageCount ?? 0, await File(path).readAsBytes());
      },
      onPages: (arrangement) => _arrangePdfOf(note, arrangement),
      onPdf: (pdf) => _replacePdfOf(note, pdf),
    );
    final session = await startHosting(noteId, binding, title: note.title, invite: invite);
    session.detach(note);
    return session;
  }

  /// Whether a request to join the session of [noteId] proves that it has the link of a copy that was shared.
  bool _trusted(String noteId, Map<String, Object?> request) {
    final proof = request['proof'], nonce = request['nonce'];
    if (proof is! String || nonce is! String) return false;
    final keys = cloudShare?.markers.keysFor(noteId) ?? const [];
    return keys.any((k) => CollabSession.copyProof(k, nonce) == proof);
  }

  String? _custom;
  String _name = '';
  String? _imageDir;

  /// The server the person entered, if they chose to use their own.
  String? get customServer => _custom;

  /// Whether the app comes with a server of its own to use.
  bool get hasBuiltInServer => _builtIn.isNotEmpty;

  /// The signalling server in use: the person's own if they set one, else the built-in one; null if neither.
  String? get server => _custom ?? (hasBuiltInServer ? _builtIn : null);

  /// What the others see.
  String get name => _name.isEmpty ? tr('Someone') : _name;
  String get nameSetting => _name;

  final Map<String, CollabSession> _sessions = {};
  final Map<String, SessionInvite> _invites = {};

  /// Who the person is (their name and id); the name here is theirs. Without one the name is kept here on its own.
  UserProfile? _profile;

  /// Takes the name from [profile], and sends its id to the others in sessions.
  void useProfile(UserProfile profile) {
    _profile?.removeListener(_profileChanged);
    _profile = profile..addListener(_profileChanged);
    _name = profile.name;
  }

  void _profileChanged() {
    _name = _profile!.name;
    notifyListeners();
  }

  /// The id of the person here, as the others see it in a session.
  String? get userId => _profile?.id;

  Future<void> load() async {
    final s = await _notes.settings.get(_serverKey);
    _custom = s == null || s.trim().isEmpty ? null : s.trim();
    if (_profile != null) {
      _name = _profile!.name;
    } else {
      _name = (await _notes.settings.get(_nameKey)) ?? '';
      Authorship.set(_name);
    }
    await shared.load();
    _imageDir = p.join((await _support()).path, 'images');
    Directory(_imageDir!).createSync(recursive: true);
    notifyListeners();
  }

  /// Uses the server at [url] (null or empty: back to the built-in one). An address without a scheme
  /// is taken as `wss://`, and `https://` as `wss://`.
  Future<void> setServer(String? url) async {
    var u = url?.trim();
    if (u != null && u.isNotEmpty) {
      u = u.replaceFirst(RegExp(r'^https://'), 'wss://').replaceFirst(RegExp(r'^http://'), 'ws://');
      if (!u.startsWith('ws://') && !u.startsWith('wss://')) u = 'wss://$u';
    }
    _custom = u == null || u.isEmpty ? null : u;
    await _notes.settings.set(_serverKey, _custom ?? '');
    notifyListeners();
  }

  /// Asks the server at [url] whether it works as a signalling server: null if it does, else why not.
  Future<String?> testServer(String url) {
    var u = url.trim();
    u = u.replaceFirst(RegExp(r'^https://'), 'wss://').replaceFirst(RegExp(r'^http://'), 'ws://');
    if (u.isNotEmpty && !u.startsWith('ws://') && !u.startsWith('wss://')) u = 'wss://$u';
    return SignalingClient.check(u);
  }

  Future<void> setName(String name) async {
    if (_profile != null) {
      await _profile!.setName(name);
      return;
    }
    _name = name.trim();
    Authorship.set(_name);
    await _notes.settings.set(_nameKey, _name);
    notifyListeners();
  }

  /// Puts the bytes of a picture that came from another device into a file of the app.
  String saveImage(String id, Uint8List bytes, String extension) {
    final dir = _imageDir ?? Directory.systemTemp.path;
    final path = p.join(dir, 'live_${safeFileId(id)}.${safeExtension(extension)}');
    File(path).writeAsBytesSync(bytes, flush: true);
    return path;
  }

  /// What last happened with a device that tried to connect to a session of ours (for the panel).
  String? hostLog;

  CollabSession? sessionFor(String noteId) => _sessions[noteId];

  @override
  String? hostedLink(String noteId) {
    final s = _sessions[noteId];
    return s != null && s.role == SessionRole.host && s.state == SessionState.live ? _invites[noteId]?.toLink() : null;
  }
  SessionInvite? inviteFor(String noteId) => _invites[noteId];

  /// Requests to join, in all the sessions that are being hosted, that wait for an answer.
  List<JoinRequest> get requests => [
        for (final e in _sessions.entries)
          if (e.value.role == SessionRole.host)
            for (final r in e.value.pending) JoinRequest(e.key, _titles[e.key] ?? '', e.value, r),
      ];
  final Map<String, String> _titles = {};

  /// Starts a live session on note [noteId]. Throws if no signalling server is set.
  ///
  /// With [transport] the devices come that way instead of through the signalling server; with [trustAll] each of them is let
  /// in without asking (the transport lets only devices through that proved who they are).
  Future<CollabSession> startHosting(String noteId, CollabBinding binding,
      {String title = '', SessionInvite? invite, HostTransport? transport, bool trustAll = false}) async {
    final existing = _sessions[noteId];
    if (existing != null && existing.state != SessionState.ended) return existing;
    if (await _notes.locks.lockModeOf(noteId) != 0) throw StateError(tr('Take the lock off this note before sharing it.'));
    final server = this.server;
    if (server == null && transport == null) throw StateError(tr('Set the signalling server first (Settings, Live collaboration).'));
    invite ??= SessionInvite.create(server!, from: name);
    final hostTransport = transport ?? await _hostTransport(invite);
    hostTransport.onEvent = (event) {
      hostLog = event;
      notifyListeners();
    };
    final session = CollabSession.host(invite, hostTransport, binding, name: name, userId: userId)
      ..trust = ((request) => trustAll || _trusted(noteId, request))
      ..onJoined = ((who) => _notice(ShareNotice(ShareNoticeKind.joined, noteId, _titles[noteId] ?? title, who: who.name)));
    _track(noteId, session, invite, title);
    return session;
  }

  /// Gives the PDF of [note] (a note nobody has open) the pages somebody else arranged, and keeps the note.
  Future<void> _arrangePdfOf(NoteData note, PageArrangement arrangement) async {
    final path = note.pdfPath;
    if (path == null || (note.pdfPageCount ?? 0) != arrangement.from) return;
    final moved = await arrangePdfFile(path, arrangement.order,
        fileName: '${note.id}-${DateTime.now().millisecondsSinceEpoch}.pdf', blank: arrangement.blank);
    note
      ..pdfPath = moved.path
      ..pdfSha256 = moved.sha256
      ..pdfPageCount = moved.pages;
    await _notes.saveNote(note);
    File(path).delete().catchError((Object _) => File(path));
  }

  /// Puts the PDF somebody else sent in the place of the PDF of [note] (a note nobody has open), and keeps the note.
  Future<void> _replacePdfOf(NoteData note, SharedPdf pdf) async {
    final path = note.pdfPath;
    if (path == null) return;
    final fresh = p.join(p.dirname(path), '${note.id}-${DateTime.now().millisecondsSinceEpoch}.pdf');
    await File(fresh).writeAsBytes(pdf.bytes, flush: true);
    note
      ..pdfPath = fresh
      ..pdfSha256 = pdf.sha256
      ..pdfPageCount = pdf.pages;
    await _notes.saveNote(note);
    File(path).delete().catchError((Object _) => File(path));
  }

  void _track(String noteId, CollabSession session, SessionInvite invite, String title) {
    _sessions[noteId] = session;
    _invites[noteId] = invite;
    _titles[noteId] = title;
    // changes that come in while no screen shows the note are written to the note
    session.onHeadlessChanged = (note) => unawaited(_notes.saveNote(note));
    session.onHeadlessPages = _arrangePdfOf;
    session.onHeadlessPdf = _replacePdfOf;
    session.addListener(() {
      notifyListeners();
    });
    notifyListeners();
  }

  /// Joins the session of [invite]. The attempt tells how it goes; when the host has let it in, a note
  /// exists ([JoinAttempt.noteId]) that can be opened.
  ///
  /// With [intoNoteId] the session is joined with a note the person has already (a copy they were given): the host's
  /// note is taken into it and what they changed meanwhile ([offline]) stays. [proofKey] (the key of that copy) lets
  /// them in without the host being asked.
  ///
  /// With [transport] the host is reached that way instead of through the signalling server.
  JoinAttempt join(SessionInvite invite, {String? intoNoteId, List<CollabOp> offline = const [], Uint8List? proofKey, JoinTransport? transport}) {
    final attempt = JoinAttempt(invite);
    final sessionMade = Completer<CollabSession>(); // (the host may answer before the session object is handed back)
    () async {
      try {
        final joinTransport = (transport ?? _joinTransport(invite))
          ..onStage = (stage) {
            attempt.status = stage;
            attempt._update();
          };
        if (intoNoteId != null) await _keepVersion(intoNoteId, VersionReason.joined, who: invite.from);
        final into = intoNoteId == null ? null : await _notes.loadNote(intoNoteId);
        final session = await CollabSession.join(
          invite,
          joinTransport,
          name: name,
          imageSaver: saveImage,
          into: into,
          offline: offline,
          proofKey: proofKey,
          userId: userId,
          // (sessions between one person's own devices carry on in their own way when the host is lost: see joinOwn)
          warmNet: transport == null ? _warmNet(invite) : null,
          budget: transport == null ? _deviceBudget : null,
          onWelcome: (w) async {
            try {
              if (attempt.cancelled) return;
              // into a note that was there: the session has merged the host's note into it; it is kept
              final id = into != null ? await _keepJoinedNote(into) : await _noteFromWelcome(w, attemptSession: attempt.session ?? await sessionMade.future);
              _track(id, attempt.session ?? await sessionMade.future, invite, w.note.title);
              attempt.noteId = id;
            } catch (e) {
              attempt.error = tr('Could not make a note of it: {error}', {'error': e});
            }
            attempt._update();
          },
        );
        attempt.session = session;
        if (!sessionMade.isCompleted) sessionMade.complete(session);
        session.addListener(() {
          if (session.state == SessionState.ended && attempt.noteId == null && attempt.error == null) {
            attempt.error = session.endReason ?? tr('The session ended');
          }
          attempt._update();
        });
        attempt._update();
      } catch (e) {
        attempt.error = '$e'.replaceFirst('Bad state: ', '');
        attempt._update();
      }
    }();
    return attempt;
  }

  Future<String> _keepJoinedNote(NoteData note) async {
    await _notes.saveNote(note);
    return note.id;
  }

  Future<String> _noteFromWelcome(Welcome w, {CollabSession? attemptSession}) async {
    final id = await _notes.createNote(title: w.note.title);
    final note = w.note;
    // the note of the welcome has no id of its own yet: the same note, under the new id
    final copy = NoteData(
      id: id,
      title: note.title,
      background: note.background,
      pageFormat: note.pageFormat,
      landscape: note.landscape,
      nativePages: Set.of(note.nativePages),
      layers: note.layers,
      marginLeft: note.marginLeft,
      marginRight: note.marginRight,
      marginTop: note.marginTop,
      marginBottom: note.marginBottom,
      documentText: note.documentText,
      documentSpans: note.documentSpans,
      strokes: note.strokes,
      textBoxes: note.textBoxes,
      highlights: note.highlights,
      images: note.images,
    );
    final pdf = w.pdf;
    if (pdf != null) {
      final dir = await Directory(p.join((await _support()).path, 'pdfs')).create(recursive: true);
      final path = p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_${pdf.name}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'));
      await File(path).writeAsBytes(pdf.bytes, flush: true);
      copy
        ..pdfName = pdf.name
        ..pdfPath = path
        ..pdfSha256 = pdf.sha256
        ..pdfPageCount = pdf.pages;
    }
    await _notes.saveNote(copy);
    await shared.markWithMe(id, from: attemptSession?.invite.from);
    attemptSession?.adoptNote(copy); // until a screen shows it, the session keeps this note up to date
    return id;
  }

  // ---- live sessions between the devices of one person (see `DeviceSyncService`)

  /// The sessions between the person's own devices, by note (an ended one stays until the note has another).
  final Map<String, CollabSession> _own = {};

  /// The notes with a session of the person's own devices that is going on.
  Set<String> get ownLiveNotes => {
        for (final e in _own.entries)
          if (e.value.state != SessionState.ended && identical(_sessions[e.key], e.value)) e.key,
      };

  /// Whether a session of any kind is going on for the note.
  bool hasSession(String noteId) => _sessions[noteId] != null && _sessions[noteId]!.state != SessionState.ended;

  /// Starts a session on the open note [noteId] for the person's other devices: they come in over [transport] (default: the
  /// signalling server, with [invite]) and need no asking - the invite is only known to the person's devices. False if the note is
  /// not open.
  Future<bool> startOwnHosting(String noteId, SessionInvite invite, [HostTransport? transport]) async {
    final start = _editors[noteId]?.startOwn;
    if (start == null) {
      debugPrint('[live] no editor of $noteId has registered for sessions (is "Working together" switched off in the tools, or is the note not on screen?)');
      return false;
    }
    if (hasSession(noteId) || await _notes.locks.lockModeOf(noteId) != 0) {
      debugPrint('[live] $noteId: a session exists already or the note is locked');
      return false;
    }
    await start(invite, transport ?? await _hostTransport(invite));
    if (!hasSession(noteId)) {
      debugPrint('[live] the editor of $noteId did not start the session (it was closed meanwhile?)');
      return false;
    }
    _own[noteId] = _sessions[noteId]!;
    return true;
  }

  /// Joins the session another device of the person hosts on the open note [noteId] (by default through the signalling server); the
  /// editor takes part once the host has let this device in. False if the note is not open or joining failed.
  Future<bool> joinOwn(String noteId, SessionInvite invite, [JoinTransport? transport]) async {
    final editor = _editors[noteId];
    if (editor == null || hasSession(noteId) || await _notes.locks.lockModeOf(noteId) != 0) return false;
    await editor.save?.call();
    final attempt = join(invite, intoNoteId: noteId, transport: transport ?? _joinTransport(invite));
    await attempt.finished;
    if (attempt.noteId == null) return false;
    final session = _sessions[noteId]!;
    _own[noteId] = session;
    // if the host leaves, the session ends quietly: the room of the devices says who hosts next (see `DeviceSyncService`)
    session.onHostLost = (_) {};
    editor.bind?.call();
    return true;
  }

  /// How the session of an open note stands: whether this device hosts it, and how many are in it; null if there is none.
  ({bool host, int people, bool ended})? ownStatus(String noteId) {
    final s = _own[noteId];
    if (s == null) return null;
    return (host: s.role == SessionRole.host, people: s.participants.length, ended: s.state == SessionState.ended);
  }

  /// The invite of the session this device hosts on [noteId], if it hosts one.
  SessionInvite? hostedInviteOf(String noteId) {
    final s = _sessions[noteId];
    if (s != null && s.role == SessionRole.host && s.state != SessionState.ended) return _invites[noteId];
    return null;
  }

  /// Saves the note as it is on screen (when it is open).
  Future<void> saveOpen(String noteId) async => _editors[noteId]?.save?.call();

  /// Ends the session of the person's own devices on a note (it is not needed any more: the note was closed here).
  Future<void> endOwn(String noteId) async {
    final s = _own[noteId];
    if (s != null && s.state != SessionState.ended) await end(noteId);
  }

  /// The app came back to the front: live sessions get their connections back.
  void wake() {
    for (final s in _sessions.values) {
      s.wake();
    }
    _standby?.wake();
    if (_background) {
      unawaited(checkInboxes());
      unawaited(checkCopies());
    }
  }

  @override
  void dispose() {
    _standby?.dispose();
    _inbox?.dispose();
    if (_budget case final DeviceBudget b) b.dispose();
    _copyTimer?.cancel();
    _notices.close();
    _ready.close();
    super.dispose();
  }

  /// Leaves or ends the session of a note.
  Future<void> end(String noteId) async {
    final s = _sessions[noteId];
    if (s == null) return;
    await s.end();
    notifyListeners();
  }
}
