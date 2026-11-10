import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/file_digest.dart';
import '../data/note_data.dart';
import '../models/canvas_models.dart';
import '../models/authorship.dart' show Author;
import '../pdf/pdf_pages.dart' show PageArrangement;
import 'backoff.dart';
import 'invite.dart';
import 'keep_alive.dart';
import 'link_stats.dart';
import 'roster.dart';
import 'session_keys.dart';
import 'succession.dart';
import 'replica.dart';
import 'compression.dart';
import 'secure_box.dart';
import 'transport.dart';
import '../l10n/language.dart';

/// Whether this device started the session (the host decides who joins) or joined it (a guest).
enum SessionRole { host, guest }

enum SessionState {
  /// Connecting (a guest) or starting (the host).
  starting,

  /// A guest that has asked to join and waits for the host to say yes.
  waiting,
  live,

  /// A guest whose link to the host broke (the app was in the background, the network changed) and
  /// that is making it again; the host lets it back in without asking.
  reconnecting,
  ended,
}

/// A person in a session: [site] names the device within the session, [name] is shown to the others.
class Participant {
  final String site;
  final String name;

  /// The id of the person ([UserProfile.id]), when they have one: two people with one name differ by it.
  final String? uid;

  const Participant(this.site, this.name, {this.uid});

  Map<String, String> toJson() => {'site': site, 'name': name, 'uid': ?uid};

  /// What to show for [p] among [all]: the name, with the start of the id after it if another has the same name.
  static String labelOf(Participant p, Iterable<Participant> all) {
    final clash = all.any((o) => !identical(o, p) && o.name == p.name && o.site != p.site);
    return clash && p.uid != null ? '${p.name} (#${Author.shortId(p.uid!)})' : p.name;
  }
}

/// Someone who asked to join, and whom the host has not answered yet.
class PendingJoin {
  final String id;
  final String name;

  /// The id of the person who asks, if they have one.
  final String? uid;

  /// Both screens show this; if it is not the same on both, it is not who was expected.
  final String code;

  const PendingJoin(this.id, this.name, this.code, {this.uid});
}

/// The PDF of a note, as it goes to someone who joins.
class SharedPdf {
  final String name;
  final String sha256;
  final int pages;
  final Uint8List bytes;

  const SharedPdf(this.name, this.sha256, this.pages, this.bytes);
}

/// What the owner of the note gives a session to work with: the note as it is now, and ways to
/// change it that the screen knows about (they redraw and save).
class CollabBinding {
  /// The note as it is now: its pages, strokes, boxes. Changes made to it are what the person sees.
  final NoteData Function() note;

  /// Runs [change], which alters the note, and makes the screen take it in.
  final void Function(void Function() change) change;
  final BoxMaker makeBox;
  final ImageSaver saveImage;
  final NoteFieldSink onNoteField;

  /// The PDF of a note that was made from one (only the host is asked).
  final Future<SharedPdf?> Function()? pdf;

  /// Gives the PDF of the note the pages somebody else arranged (moved, added, deleted); what is on them follows with the other changes.
  final Future<void> Function(PageArrangement arrangement)? onPages;

  /// Gives the note the PDF somebody else put in its place (a change of its pages taken back).
  final Future<void> Function(SharedPdf pdf)? onPdf;

  const CollabBinding({
    required this.note,
    required this.change,
    required this.makeBox,
    required this.saveImage,
    required this.onNoteField,
    this.pdf,
    this.onPages,
    this.onPdf,
  });
}

/// What a guest receives when the host lets it in: the note as it is, to make a note from.
class Welcome {
  final NoteData note;
  final SharedPdf? pdf;

  /// File names of pictures were made by [CollabSession]'s image saver.
  const Welcome(this.note, this.pdf);
}

class _Peer {
  final PeerChannel channel;
  final SecureBox box;
  String? site;
  String? name;
  String? uid;

  /// The signing key this device proved it holds when it asked to join (null: none, or the proof did not check).
  String? key;

  /// The device said it is a web page (see [RosterMember.web]).
  bool web = false;

  /// The device said it should not take over now, and why ('battery', 'metered'; see `DeviceBudget`); null: it did not.
  String? veto;

  /// On a link to or from a successor (see [WarmNet]): the nonce of the device that connected, and the binding of the link.
  String? linkNonce, linkBinding;

  /// Told when what is measured on this link changes (by default [CollabSession._bandCheck]).
  void Function(LinkStats stats)? onBand;
  bool admitted = false;
  String? pendingId;

  /// Watches this link (a question every few seconds; see [CollabSession._startHeartbeat]) and what it measured.
  KeepAlive? alive;
  LinkStats? stats;

  /// What the link measures of itself, when it watches itself (see [WatchedChannel]).
  StreamSubscription<Duration?>? watch;

  /// Whether the link is watched, one way or the other.
  bool watched = false;

  /// No more watching of this link.
  void unwatch() {
    alive?.stop();
    unawaited(watch?.cancel());
    watch = null;
  }

  /// The guest said goodbye: its link going is no drop; and a drop that was counted is not counted twice.
  bool leaving = false, counted = false;
  Future<void> _chain = Future.value();
  Future<void> _inbox = Future.value();

  /// Messages are handled one after the other, in the order they came: opening a big one takes longer than a small one, and the small
  /// one must not be acted on first (an `ops` that overtook the `welcome` before it would be dropped).
  /// Runs [then] once the messages that came before have been handled (a link that is gone is told of after what it said last).
  void afterMessages(void Function() then) {
    _inbox = _inbox.then((_) => then()).catchError((Object e) {
      debugPrint('[live] $e');
    });
  }

  void receive(Uint8List data, Future<void> Function(_Peer peer, Uint8List data) handle) {
    _inbox = _inbox.then((_) => handle(this, data)).catchError((Object e) {
      debugPrint('[live] a message could not be handled: $e');
    });
  }

  _Peer(this.channel, this.box);

  /// Whether the other side reads compressed messages: it said so (`z`) in what it sent first. An older app does not.
  bool unpacks = false;

  /// Messages go out in the order they were given, though sealing takes a moment.
  Future<void> send(Map<String, Object?> message) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    final done = _chain.then((_) async => channel.send(await box.seal(unpacks ? await packMessage(bytes) : bytes)));
    _chain = done.then((_) {}, onError: (Object _) {});
    return done;
  }
}

/// One live session on one note, as the host or as a guest. All traffic is sealed with the key
/// of the invite: the host relays what a guest sends to the others (as sealed data it can
/// read, being a member, but the transport and the signalling server never can).
class CollabSession extends ChangeNotifier {
  final SessionRole role;
  final SessionInvite invite;
  final String name;
  final String site;
  late Replica replica = Replica(site);

  SessionState _state = SessionState.starting;
  String? _endReason;
  String? _code;
  final List<Participant> _participants = [];
  final List<PendingJoin> _pending = [];
  final Map<String, _Peer> _pendingPeers = {};
  final List<_Peer> _peers = [];
  CollabBinding? _binding;
  NoteData? _headless;
  Future<SharedPdf?> Function()? _pdfProvider;

  /// Called (a moment after) changes from others were applied while no screen shows the note: the note
  /// that holds them is to be kept.
  void Function(NoteData note)? onHeadlessChanged;

  /// Called while no screen shows the note, when somebody arranged the pages of its PDF: the file of [note] is to get them.
  Future<void> Function(NoteData note, PageArrangement arrangement)? onHeadlessPages;

  /// Called while no screen shows the note, when somebody put another PDF in its place: [note] is to get it.
  Future<void> Function(NoteData note, SharedPdf pdf)? onHeadlessPdf;
  Timer? _headlessTimer;
  Timer? _debounce;
  late final SecureBox _box = SecureBox(invite.messageKey);

  /// Called on a guest when the host has let it in.
  void Function(Welcome welcome)? onWelcome;

  /// Set on a guest of a session between the devices of one person: when the host leaves (or cannot be reached any more), the session
  /// ends quietly and this is called; the devices arrange a new one among themselves (see `DeviceSyncService`). The session is ended
  /// before it is called, with [handedOver] set.
  void Function(CollabSession session)? onHostLost;

  /// This session ended because the host was lost and [onHostLost] took the matter up: the person need not be told it ended.
  bool handedOver = false;

  /// On the host: whether a request to join may come in without the host being asked (the guest proves that it
  /// has the link of a copy of the note, which the host made). Given the request.
  bool Function(Map<String, Object?> request)? trust;

  /// On the host: called when someone has come in (also when they were let in without being asked).
  void Function(Participant who)? onJoined;

  /// On a guest that joins a note it has already: what it changed on it while it was away (taken over what the
  /// host has), and the key of the copy it has, which proves it may come in without the host being asked.
  List<CollabOp> _offline = const [];
  Uint8List? _proofKey;

  /// The proof that a guest has [key], the key of a shared copy, for the request with [guestNonce].
  static String copyProof(Uint8List key, String guestNonce) =>
      Hmac(sha256, key).convert(utf8.encode('notation-copy-join|$guestNonce')).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Where the pictures that others send are put when there is no screen yet to do it.
  ImageSaver? headlessImageSaver;

  /// How a link that does not watch itself is watched by the session (see [_startHeartbeat]; a WebRTC link watches itself): a sealed
  /// question every [heartbeatEvery], and a link that was silent for [heartbeatDeadAfter] is closed (a guest then makes a new one, the host
  /// forgets the guest until it is back).
  static Duration heartbeatEvery = const Duration(seconds: 10), heartbeatDeadAfter = const Duration(seconds: 35);

  /// The host's: what is measured on the link to each guest by site (kept while the guest is away, so that drops add up).
  final Map<String, LinkStats> _stats = {};

  /// A guest's: what is measured on the link to the host, and what the host says of the others'.
  final LinkStats _hostStats = LinkStats();
  final Map<String, ({LinkBand band, bool relayed})> _bands = {};

  // ---- successors (see [Succession] and [WarmNet])

  /// The host's choice of who takes over.
  final Succession _succession = Succession();

  /// The host's: what the guests measured on their links to the successors, by successor and then by who measured it.
  final Map<String, Map<String, Observation>> _observed = {};
  Timer? _successionTimer;

  /// A guest's: how the successors are reached, the links to them (by site), and while this device is one of them, the links of the others.
  WarmNet? _warmNet;
  HostTransport? _warmListener;
  StreamSubscription<PeerChannel>? _warmSub;
  bool _warmListening = false;
  final Map<String, _Peer> _warmOut = {};
  final Set<String> _warmConnecting = {};
  final Map<String, LinkStats> _warmStats = {};
  final Map<String, Timer> _warmRetry = {};
  final List<_Peer> _warmIn = [];
  String? _lastObs;

  /// Whether this device is a web page (said in the request to join; see [RosterMember.web]).
  bool _web = kIsWeb;

  /// A guest's: whether it should not take over now, and why (see `DeviceBudget`), and what the host was told last.
  ValueListenable<String?>? _budget;
  String? _vetoSent;

  /// How long a guest waits before it tries again to reach a successor that could not be reached.
  static Duration warmRetryAfter = const Duration(seconds: 20);

  /// How many of the successors the guests keep links to.
  static const warmSuccessors = 2;
  String? _hostSite;

  // ---- who is who

  /// The seed of this device's signing key in this session (the key is made from it when first needed; see [SessionKeys]).
  final Uint8List _keySeed = Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
  late final Future<SessionKeys> _keys = SessionKeys.fromSeed(_keySeed);

  /// Who is in the session as the host has signed it: the host's own, or on a guest the latest one that checked out. Null until the
  /// first device is let in (the host), or while the host has sent none (an older app).
  Roster? _roster;
  Roster? get roster => _roster;

  /// The host: the devices it let in (the oldest first), the number of its changes, and the line that keeps them in order.
  final List<RosterMember> _members = [];
  int _rev = 0;
  Future<void> _rosterLine = Future.value();

  /// A guest: the key of the host, as the first welcome said it (this is who signs rosters), and how many times a host came with another.
  String? _trustedHostKey;
  int hostKeyChanges = 0;

  /// The number of hosts the session has had (the first is 1).
  int get epoch => _roster?.epoch ?? 1;

  PeerChannel? _hostChannel; // a guest's link to the host
  _Peer? _host;
  StreamSubscription<PeerChannel>? _incomingSub;
  HostTransport? _hostTransport;
  String? _hostNonce, _guestNonce;

  /// The host's: who may come back without asking, by the token each was given when let in.
  final Map<String, String> _resumable = {}; // token -> site

  /// A guest's: the token it was given, and how it connects again.
  String? _token;
  JoinTransport? _joinTransport;
  bool _reconnecting = false;
  Completer<void>? _resumed;
  Completer<void>? _nudge;

  /// The id of the person here ([UserProfile.id]), sent to the others so that people of one name can be told apart.
  final String? userId;

  CollabSession._(this.role, this.invite, this.name, this.site, CollabBinding? binding, {this.userId}) : _binding = binding;

  static String _newSite() {
    final r = Random.secure();
    return List.generate(5, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _nonce() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  SessionState get state => _state;
  String? get endReason => _endReason;

  /// What a guest should show while it waits for the host to say yes.
  String? get verificationCode => _code;
  List<Participant> get participants => List.unmodifiable(_participants);

  final Map<String, int> _viewing = {};

  /// The page (zero-based) each participant ([Participant.site]) has in view, for those who have told.
  Map<String, int> get viewing => Map.unmodifiable(_viewing);

  final Map<String, int> _sheets = {};

  /// Which sheet of the page in [viewing] each participant has in view, for a page shown as several sheets (a written document longer
  /// than a page); 0 when not told (older versions do not say).
  Map<String, int> get viewingSheet => Map.unmodifiable(_sheets);

  /// The message that says [from] has [page] (and its [sheet]) in view; [seq] is the number its sender gave it (see [_atSeen]).
  static Map<String, Object?> _atMessage(String? from, Object? page, Object? sheet, {Object? seq}) => {
    't': 'at',
    'site': from,
    'page': page,
    if (sheet is int && sheet > 0) 'sheet': sheet,
    if (seq is int) 'q': seq,
  };

  /// The number of the last page this device told the others about (each one gets the next).
  int _atSeq = 0;

  /// The highest number of a page message taken from each site. A message with a lower one is older than what is known and is not taken:
  /// messages of one device can come by different ways (an old link whose backlog is still being worked through, and the new one), and
  /// the page is not a thing with versions that a later state would put right. Kept after somebody left, for what of theirs is still on
  /// the way. Messages of an older app have no number and are taken as they come.
  final Map<String, int> _atSeen = {};

  /// Tells the others which page this device has in view, and which [sheet] of it when the page is shown as several.
  void announcePage(int page, {int sheet = 0}) {
    if (_viewing[site] != page || (_sheets[site] ?? 0) != sheet) {
      _viewing[site] = page;
      _sheets[site] = sheet;
      notifyListeners();
    }
    if (_state != SessionState.live) return;
    final message = _atMessage(site, page, sheet, seq: ++_atSeq);
    if (role == SessionRole.host) {
      unawaited(_broadcast(message));
    } else {
      unawaited(_host?.send(message).then((_) {}, onError: (Object _) {}));
    }
  }

  /// Tells the others that the pages of the PDF were arranged here (see [PageArrangement]); the same is done to their copy of the file.
  void announcePages(PageArrangement arrangement) {
    if (_state != SessionState.live) return;
    final message = {'t': 'pages', 'a': arrangement.toJson()};
    if (role == SessionRole.host) {
      unawaited(_broadcast(message));
    } else {
      unawaited(_host?.send(message).then((_) {}, onError: (Object _) {}));
    }
  }

  /// Tells the others that the PDF is this one now (a change of its pages was taken back, which cannot be told as an arrangement:
  /// a page that was deleted is not in their file any more).
  void announcePdf(SharedPdf pdf) {
    if (_state != SessionState.live) return;
    final message = {'t': 'pdf', 'f': _pdfJson(pdf)};
    if (role == SessionRole.host) {
      unawaited(_broadcast(message));
    } else {
      unawaited(_host?.send(message).then((_) {}, onError: (Object _) {}));
    }
  }

  static Map<String, Object?> _pdfJson(SharedPdf pdf) => {'name': pdf.name, 'sha': pdf.sha256, 'pages': pdf.pages, 'bytes': base64Encode(pdf.bytes)};

  /// The PDF [p] holds, or null when it is not one (it comes from somebody else: nothing in it can be taken for granted).
  static SharedPdf? _pdfFrom(Object? p) {
    if (p is! Map) return null;
    final name = p['name'], bytes = p['bytes'], sha = p['sha'], pages = p['pages'];
    if (name is! String || bytes is! String) return null;
    try {
      return SharedPdf(name, sha is String ? sha : '', pages is num ? pages.toInt() : 0, base64Decode(bytes));
    } on FormatException {
      return null;
    }
  }

  static bool _looksLikePdf(Uint8List b) => b.length > 8 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46; // "%PDF"

  /// Puts the PDF in [json] in the place of this one. False when it is none, and so not to be passed on.
  Future<bool> _takePdf(Object? json) async {
    final sent = _pdfFrom(json);
    if (sent == null || !_looksLikePdf(sent.bytes)) return false;
    // (the hash is worked out here: a note file is checked against it when it is read again)
    final pdf = SharedPdf(sent.name, await sha256Of(sent.bytes), sent.pages, sent.bytes);
    final binding = _binding;
    final note = _headless;
    try {
      if (binding != null) {
        await binding.onPdf?.call(pdf);
      } else if (note != null) {
        await onHeadlessPdf?.call(note, pdf);
      }
    } catch (e) {
      debugPrint('[live] the PDF could not be taken: $e'); // (the others still get it)
    }
    return true;
  }

  /// Does what somebody else did to the pages of the PDF to this one. False when it is not an arrangement, and so not to be passed on.
  Future<bool> _takePages(Object? json) async {
    final arrangement = PageArrangement.fromJson(json);
    if (arrangement == null) return false;
    final binding = _binding;
    final note = _headless;
    try {
      if (binding != null) {
        await binding.onPages?.call(arrangement);
      } else if (note != null) {
        await onHeadlessPages?.call(note, arrangement);
      }
    } catch (e) {
      debugPrint('[live] the pages could not be arranged: $e'); // (the others still get them)
    }
    return true;
  }

  /// Takes in that [from] has [page] in view. False when it is not taken (not somebody here, about this device, or older than what is
  /// known): then it is not passed on either.
  bool _takePage(String? from, Object? page, Object? sheet, [Object? seq]) {
    if (from == null || page is! int || page < 0 || !_participants.any((p) => p.site == from)) return false;
    // what is in view here is known here: a host that tells it back (from before the link broke) is behind
    if (from == site) return false;
    if (seq is int) {
      final seen = _atSeen[from];
      if (seen != null && seq <= seen) return false;
      _atSeen[from] = seq;
    }
    final s = sheet is int && sheet > 0 ? sheet : 0;
    if (_viewing[from] == page && (_sheets[from] ?? 0) == s) return true;
    _viewing[from] = page;
    _sheets[from] = s;
    notifyListeners();
    return true;
  }

  /// Forgets the pages of those who are not in the session any more.
  void _pruneViewing() { _viewing.removeWhere((site, _) => !_participants.any((p) => p.site == site));
    _sheets.removeWhere((site, _) => !_viewing.containsKey(site));
  }
  List<PendingJoin> get pending => List.unmodifiable(_pending);
  bool get isLive => _state == SessionState.live;

  // ---- the host

  /// Starts a session on a note that [binding] gives access to. [transport] is how guests connect.
  static CollabSession host(SessionInvite invite, HostTransport transport, CollabBinding binding, {String name = 'Host', String? userId}) {
    final s = CollabSession._(SessionRole.host, invite, name, _newSite(), binding, userId: userId)
      .._hostTransport = transport
      .._pdfProvider = binding.pdf;
    s._participants.add(Participant(s.site, name, uid: userId));
    s._incomingSub = transport.incoming.listen(s._onIncoming);
    s._set(SessionState.live);
    // the note as it is, so that what is already on it counts as the host's own, first
    s.replica.localChanges(binding.note());
    return s;
  }

  void _onIncoming(PeerChannel channel) {
    final peer = _Peer(channel, _box);
    channel.messages.listen(
      (data) => peer.receive(data, _hostReceive),
      onDone: () => peer.afterMessages(() => _peerGone(peer)),
    );
    channel.closed.then((_) => peer.afterMessages(() => _peerGone(peer)));
  }

  Future<Map<String, Object?>?> _open(_Peer peer, Uint8List data) async {
    try {
      final plain = await unpackMessage(await peer.box.open(data));
      final m = (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
      if (m['z'] == 1) peer.unpacks = true;
      return m;
    } catch (_) {
      return null; // not sealed with this session's key, or garbled: not from a member
    }
  }

  /// The id of the person in a request to join, if it has a good one.
  static String? _uidOf(Map<String, Object?> m) {
    final uid = m['uid'];
    return uid is String && Author.isId(uid) ? uid : null;
  }

  Future<void> _hostReceive(_Peer peer, Uint8List data) async {
    final m = await _open(peer, data);
    if (m == null) {
      if (!peer.admitted) await peer.channel.close();
      return;
    }
    peer.alive?.heard();
    switch (m['t']) {
      case 'ping':
        if (peer.admitted) await _answerPing(peer, m);
      case 'pong':
        _gotPong(peer, m);
      case 'join':
        if (_state == SessionState.ended) {
          await peer.channel.close(); // not here any more: the guest tries again elsewhere instead of waiting
          return;
        }
        if (peer.admitted || peer.pendingId != null) return;
        peer.key = await _provenKey(m);
        peer.web = m['pf'] == 'web';
        peer.veto = _vetoFrom(m['nv']);
        final claimed = m['site'];
        final known = claimed is String ? _members.where((x) => x.site == claimed).firstOrNull : null;
        if (known != null && known.key != peer.key) {
          // somebody asks to be a device that is in already, and cannot show its key: not that device (it only knows its site)
          debugPrint('[live] a request in the name of a device that is in, with another key, was refused');
          await peer.channel.close();
          return;
        }
        final token = m['resume'];
        if (token is String && m['site'] is String && _resumable[token] == m['site']) {
          // a guest that was let in before and lost the link: back in without asking again
          peer.site = m['site'] as String;
          peer.name = (m['name'] as String?)?.trim().isEmpty ?? true ? 'Someone' : (m['name'] as String).trim();
          peer.uid = _uidOf(m);
          // awaited: a link that breaks while the guest is let back in is an error of this message (told and dropped by receive), not one
          // that nobody catches
          await _admit(peer, resumeToken: token);
          return;
        }
        peer.site = m['site'] as String?;
        peer.name = (m['name'] as String?)?.trim().isEmpty ?? true ? 'Someone' : (m['name'] as String).trim();
        peer.uid = _uidOf(m);
        if (peer.site != null && (trust?.call(m) ?? false)) {
          // it holds the link of a copy of this note: no need to ask
          await _admit(peer);
          return;
        }
        final guestNonce = m['nonce'] as String? ?? '';
        final hostNonce = _nonce();
        final id = '${peer.site}-$hostNonce';
        peer.pendingId = id;
        _pendingPeers[id] = peer;
        _pending.add(PendingJoin(id, peer.name!, invite.verificationCode(hostNonce, guestNonce), uid: peer.uid));
        notifyListeners();
        await peer.send({'t': 'pending', 'z': 1, 'nonce': hostNonce, 'host': name});
      case 'ops':
        if (!peer.admitted) return;
        _takeRemote(m);
        await _broadcast({'t': 'ops', 'ops': m['ops']}, except: peer);
      case 'pages':
        if (!peer.admitted) return;
        if (await _takePages(m['a'])) await _broadcast({'t': 'pages', 'a': m['a']}, except: peer);
      case 'pdf':
        if (!peer.admitted) return;
        if (await _takePdf(m['f'])) await _broadcast({'t': 'pdf', 'f': m['f']}, except: peer);
      case 'at':
        if (!peer.admitted) return;
        if (_takePage(peer.site, m['page'], m['sheet'], m['q'])) {
          await _broadcast(_atMessage(peer.site, m['page'], m['sheet'], seq: m['q']), except: peer);
        }
      case 'obs':
        if (peer.admitted) _takeObservations(peer.site, m['o']);
      case 'veto':
        final veto = _vetoFrom(m['why']);
        if (veto == peer.veto) return;
        peer.veto = veto;
        if (peer.admitted) _reconsiderSuccession();
      case 'bye':
        peer.leaving = true;
        await peer.channel.close();
    }
  }

  /// The host says yes to a request: the guest is given the note as it is now, and every change from then on.
  Future<void> approve(String pendingId) async {
    final peer = _pendingPeers.remove(pendingId);
    _pending.removeWhere((p) => p.id == pendingId);
    if (peer == null || _state == SessionState.ended) return;
    await _admit(peer);
  }

  /// The link that a guest (by site) was most recently let in on, or is being: when a guest comes back twice in a short time (the host is
  /// busy with others, the guest gives up on the first try and makes a second one), the first admission is still waiting for the note
  /// while the second starts, and must not add its dead link behind the second's.
  final Map<String, _Peer> _latestAdmit = {};

  /// Takes the links the same guest had before [peer] out of the session, and closes them.
  void _dropOldLinksOf(_Peer peer) {
    for (final old in _peers.where((p) => p.site == peer.site && !identical(p, peer)).toList()) {
      _peers.remove(old);
      _participants.removeWhere((p) => p.site == old.site);
      old.unwatch();
      unawaited(old.channel.close());
    }
  }

  Future<void> _admit(_Peer peer, {String? resumeToken}) async {
    // the same guest on an old link that is not known to be gone yet
    _latestAdmit[peer.site!] = peer;
    _dropOldLinksOf(peer);
    peer.admitted = true;
    peer.pendingId = null;
    final token = resumeToken ?? _nonce() + _nonce();
    _resumable[token] = peer.site!;
    final registered = await _registerMember(peer.site!, peer.key, web: peer.web);
    if (registered == null) {
      debugPrint('[live] the session is full: a device was not let in');
      unawaited(peer.channel.close());
      return;
    }
    _flushLocal(); // what was changed just now is in what the guest gets
    for (var i = 0; i < 100 && _binding == null && _headless == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20)); // the screen is just going away
    }
    final note = _binding?.note() ?? _headless!;
    final pdf = await _pdfProvider?.call();
    final ops = replica.state(note);
    if (!identical(_latestAdmit[peer.site], peer) || _state == SessionState.ended) {
      // the guest came again meanwhile (this link is the old one, and probably dead), or the session is over
      unawaited(peer.channel.close());
      return;
    }
    _dropOldLinksOf(peer);
    _peers.add(peer);
    _participants.add(Participant(peer.site!, peer.name!, uid: peer.uid));
    _startHeartbeat(peer, _stats.putIfAbsent(peer.site!, LinkStats.new));
    notifyListeners();
    await peer.send({
      't': 'welcome',
      'z': 1,
      'site': site,
      'token': token,
      if (resumeToken != null) 'resume': true,
      'roster': (_roster ?? registered.roster).toJson(), // (the latest: one made meanwhile went to the others, not to this link)
      'ops': [for (final o in ops) o.toJson()],
      'peers': [for (final p in _participants) p.toJson()],
      if (pdf != null) 'pdf': _pdfJson(pdf),
    });
    await _broadcast({'t': 'peers', 'peers': [for (final p in _participants) p.toJson()]}, except: peer);
    // (a copy of who, and what is current when each is sent: while this waits for the link, others come and go and announce pages -
    // the page read before the wait would arrive after the newer one that was broadcast meanwhile, and stay)
    for (final who in _viewing.keys.toList()) {
      final page = _viewing[who];
      if (page == null) continue;
      await peer.send(_atMessage(who, page, _sheets[who], seq: who == site ? _atSeq : _atSeen[who]));
    }
    await peer.send(_bandsMessage());
    if (registered.changed) await _broadcast({'t': 'roster', 'r': registered.roster.toJson()}, except: peer);
    _successionTimer ??= Timer.periodic(_successionTick, (_) => _reconsiderSuccession());
    _reconsiderSuccession();
    if (resumeToken == null) onJoined?.call(Participant(peer.site!, peer.name!, uid: peer.uid));
  }

  Future<void> deny(String pendingId, {String reason = 'The host did not accept the request'}) async {
    final peer = _pendingPeers.remove(pendingId);
    _pending.removeWhere((p) => p.id == pendingId);
    notifyListeners();
    if (peer == null) return;
    await peer.send({'t': 'deny', 'reason': reason});
    await peer.channel.close();
  }

  void _peerGone(_Peer peer) {
    _countDrop(peer);
    final id = peer.pendingId;
    if (id != null) {
      _pendingPeers.remove(id);
      _pending.removeWhere((p) => p.id == id);
      notifyListeners();
    }
    if (_peers.remove(peer)) {
      // (not when the same guest is in on another link: the entry is theirs, not this old link's)
      if (!_peers.any((p) => p.site == peer.site)) _participants.removeWhere((p) => p.site == peer.site);
      _pruneViewing();
      notifyListeners();
      unawaited(_broadcast({'t': 'peers', 'peers': [for (final p in _participants) p.toJson()]}));
      _reconsiderSuccession();
    }
  }

  /// Gives [message] to every guest (but [except]). It is handed to all of the links at once, not one after the other: a message
  /// that waits for the links before it in the list would come after a later one on the links behind them (a list of who is there,
  /// made when somebody went, arriving after the one made when they came back), and with ten guests the waiting adds up.
  Future<void> _broadcast(Map<String, Object?> message, {_Peer? except}) async {
    final sends = <Future<void>>[];
    for (final p in List.of(_peers)) {
      if (identical(p, except)) continue;
      // a link that is going down: its own close handler takes it off the list
      sends.add(p.send(message).then((_) {}, onError: (Object _) {}));
    }
    await Future.wait(sends);
  }

  // ---- who is who

  /// The key in a request to join, if the request shows that the device holds it (it signed this request with it); else null.
  Future<String?> _provenKey(Map<String, Object?> m) async {
    final key = m['key'], proof = m['kp'], site = m['site'], nonce = m['nonce'];
    if (key is! String || proof is! String || site is! String || nonce is! String) return null;
    return await SessionKeys.verifyText(key, SessionKeys.joinProof(site, nonce, key), proof) ? key : null;
  }

  /// The host lets a device in: it is put on the roster (with its key) unless it is on it, and the roster is signed again if that
  /// changed it. Done one after the other, so that every roster has the members it was made with and a later number than the one before.
  /// Null when the roster is full of devices that are all here.
  Future<({Roster roster, bool changed})?> _registerMember(String site, String? key, {bool web = false}) {
    final done = _rosterLine.then((_) async {
      var changed = false;
      final at = _members.indexWhere((x) => x.site == site);
      if (at >= 0 && web && !_members[at].web) {
        // (it can only say so: that makes it less likely to be chosen)
        _members[at] = RosterMember(site, _members[at].key, web: true);
        changed = true;
      }
      if (at < 0) {
        if (_members.length >= Roster.maxMembers) {
          final gone = _members.indexWhere((x) => !_peers.any((p) => p.site == x.site));
          if (gone < 0) return null;
          _members.removeAt(gone);
        }
        _members.add(RosterMember(site, key, web: web));
        changed = true;
      }
      if (changed || _roster == null) {
        _roster = await Roster.make(keys: await _keys, epoch: 1, rev: ++_rev, hostSite: this.site, members: _members, succession: _successionNow());
        changed = true;
      }
      return (roster: _roster!, changed: changed);
    });
    _rosterLine = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  /// [_acceptRoster], for the tests of what is believed and what is not.
  @visibleForTesting
  Future<void> acceptRosterForTest(Roster? r, {bool restarted = false}) => _acceptRoster(r, restarted: restarted);

  /// A guest takes in the roster the host sent. It counts when the host signed it with the key this guest holds for the host (the key of the
  /// first welcome), it names this device with the key it sent, and it is newer than the one held. A host that comes with another key
  /// after it was gone (the app was started again: it knows nothing of the session) is taken as the new host, and counted in
  /// [hostKeyChanges]; nothing yet says that it may be (that is what the host chain of a later step is for).
  Future<void> _acceptRoster(Roster? r, {required bool restarted}) async {
    if (r == null || !await r.verify()) return;
    final mine = (await _keys).publicKeyText;
    if (r.member(site)?.key != mine) return; // (it does not have me as I am)
    if (r.hostSite != _hostSite) return;
    final pinned = _trustedHostKey;
    if (pinned == null) {
      _trustedHostKey = r.hostKey;
    } else if (pinned != r.hostKey) {
      if (!restarted) return;
      _trustedHostKey = r.hostKey;
      hostKeyChanges++;
      _roster = r;
      notifyListeners();
      _warmCheck();
      return;
    }
    final held = _roster;
    if (held == null || r.newerThan(held)) {
      _roster = r;
      notifyListeners();
      _warmCheck();
    }
  }

  // ---- how good the links are

  /// Some bytes that do not shrink when packed, for the larger question now and then (a link may answer a tiny one at once and still
  /// carry little).
  static final String _probePad = base64.encode(List.generate(1500, (_) => Random.secure().nextInt(256)));

  /// Watches the link of [peer] and puts what is measured into [stats]. There is one watch for each link: a link that watches itself (a
  /// WebRTC connection asks its own questions and closes itself when the answers stop) hands on what it measured, and nothing more is sent;
  /// only a link that does not gets the session's own questions, and is closed by the session when it falls silent.
  void _startHeartbeat(_Peer peer, LinkStats stats) {
    peer.unwatch();
    peer.stats = stats;
    peer.watched = true;
    final channel = peer.channel;
    final check = peer.onBand ?? _bandCheck;
    void route() => unawaited(routeOf(channel).then((r) {
          stats.route = r;
          check(stats);
        }, onError: (Object _) {}));
    if (channel is WatchedChannel && (channel as WatchedChannel).watching) {
      var answers = 0;
      route();
      peer.watch = (channel as WatchedChannel).roundTrips.listen((rtt) {
        if (_state == SessionState.ended || _disposed) return;
        if (rtt == null) {
          stats.missed();
        } else {
          stats.record(rtt);
          if (++answers % 6 == 0) route(); // (the route can change while a link stays up)
        }
        check(stats);
      });
      return;
    }
    var asked = 0;
    void ask() {
      if (_state == SessionState.ended || _disposed) return;
      final now = DateTime.now();
      final wait = heartbeatEvery * 2;
      stats.expire(now, wait > LinkStats.timing.lostAfter ? wait : LinkStats.timing.lostAfter);
      final data = asked++ % 6 == 5;
      final n = stats.probe(now, data: data);
      unawaited(peer.send({'t': 'ping', 'n': n, if (data) 'pad': _probePad}).then((_) {}, onError: (Object _) {}));
      if (data || asked == 1) route(); // (the route can change while a link stays up: asked again now and then)
      check(stats);
    }

    peer.alive = KeepAlive(
      every: heartbeatEvery,
      deadAfter: heartbeatDeadAfter,
      grace: heartbeatEvery,
      ping: ask,
      dead: () {
        debugPrint('[live] a link was silent for ${heartbeatDeadAfter.inSeconds} s: it is given up');
        unawaited(peer.channel.close().then((_) {}, onError: (Object _) {}));
      },
    )..start();
    ask();
  }

  /// The question of the other side: answered at once, with what came along (a bounded amount: nobody can make this device send a lot).
  Future<void> _answerPing(_Peer peer, Map<String, Object?> m) async {
    final pad = m['pad'];
    await peer.send({'t': 'pong', 'n': m['n'], if (pad is String && pad.length <= 4096) 'pad': pad});
  }

  void _gotPong(_Peer peer, Map<String, Object?> m) {
    peer.alive?.heard(pong: true);
    final n = m['n'], stats = peer.stats;
    if (n is! int || stats == null) return;
    stats.answered(n, DateTime.now());
    (peer.onBand ?? _bandCheck)(stats);
  }

  /// A link broke: it counts once, and not when the guest said goodbye.
  void _countDrop(_Peer peer) {
    peer.unwatch();
    final stats = peer.stats;
    if (stats == null || peer.leaving || peer.counted || _state == SessionState.ended) return;
    peer.counted = true;
    stats.dropped(DateTime.now());
    (peer.onBand ?? _bandCheck)(stats);
  }

  /// The band of a link changed: whoever shows it is told, and the host tells the guests (only changes are sent).
  void _bandCheck(LinkStats stats) {
    if (!stats.bandChanged(DateTime.now())) return;
    notifyListeners();
    if (role == SessionRole.host && _state == SessionState.live) {
      unawaited(_broadcast(_bandsMessage()));
      _reconsiderSuccession();
    }
  }

  Map<String, Object?> _bandsMessage() {
    final now = DateTime.now();
    return {
      't': 'bands',
      'b': {
        for (final e in _stats.entries)
          if (_peers.any((p) => p.site == e.key)) e.key: {'b': e.value.band(now).name, if (e.value.relayed) 'r': 1},
      },
    };
  }

  void _takeBands(Object? b) {
    if (b is! Map) return;
    _bands.clear();
    for (final e in b.entries) {
      final v = e.value;
      if (e.key is! String || v is! Map) continue;
      final band = LinkBand.values.where((x) => x.name == v['b']).firstOrNull ?? LinkBand.unknown;
      _bands[e.key as String] = (band: band, relayed: v['r'] == 1);
    }
    notifyListeners();
  }

  /// How good the link of [site] to the host is. On the host: measured on the link to that guest. On a guest: its own link is measured
  /// here (so is the host's, being the same link), the others' are what the host measured. [LinkBand.unknown] when nothing is known.
  LinkBand bandOf(String site) {
    final now = DateTime.now();
    if (role == SessionRole.host) return _stats[site]?.band(now) ?? LinkBand.unknown;
    if (site == this.site || site == _hostSite) return _hostStats.band(now);
    return _bands[site]?.band ?? LinkBand.unknown;
  }

  /// Whether the link of [site] to the host goes through a relay (TURN), as far as is known: the relay's bandwidth is spent on it.
  bool relayedVia(String site) {
    if (role == SessionRole.host) return _stats[site]?.relayed ?? false;
    if (site == this.site || site == _hostSite) return _hostStats.relayed;
    return _bands[site]?.relayed ?? false;
  }

  /// The site of the host, once a guest has been let in (the host's own is [site]).
  String? get hostSite => role == SessionRole.host ? site : _hostSite;

  /// What this device should show of its own situation: a guest's link to the host; for the host the worst of its guests' links (one
  /// that is poor drags the session down for everybody). [LinkBand.unknown] while nothing is known.
  LinkBand get linkBand {
    if (_state != SessionState.live) return LinkBand.unknown;
    if (role == SessionRole.guest) return bandOf(site);
    var worst = LinkBand.unknown;
    for (final p in _peers) {
      final b = bandOf(p.site ?? '');
      if (b.index > worst.index) worst = b; // (the order of [LinkBand]: unknown, good, fair, poor)
    }
    return worst;
  }

  /// What is measured on the link to the host (a guest) - for the tests and for what is built on it.
  LinkStats get hostLink => _hostStats;

  /// What is measured on the links to the guests (the host).
  Map<String, LinkStats> get guestLinks => Map.unmodifiable(_stats);

  // ---- who takes over (see [Succession]; how the links to the successors are made: [WarmNet])

  /// The successors in the roster this device holds, in order (empty until there are any).
  List<String> get succession => List.unmodifiable(_roster?.succession ?? const <String>[]);

  /// The host's: how [site] is judged as a successor, from what the host and the guests measured on their links to it.
  Score scoreOf(String site) {
    final now = DateTime.now();
    final here = {for (final p in _peers) ?p.site};
    final own = _stats[site];
    return Succession.scoreOf([
      if (own != null && here.contains(site)) Observation(own.band(now), relayed: own.relayed),
      for (final e in (_observed[site] ?? const <String, Observation>{}).entries)
        if (here.contains(e.key)) e.value,
    ]);
  }

  /// How often the host looks at the list again (also without news: one on it that stays poor goes after a while).
  static Duration get _successionTick {
    final d = Succession.hold ~/ 10;
    return d < const Duration(milliseconds: 100) ? const Duration(milliseconds: 100) : d;
  }

  /// The list as chosen, of those that the roster has (with a key).
  List<String> _successionNow() => [
        for (final s in _succession.current)
          if (_members.any((m) => m.site == s && m.key != null)) s,
      ];

  /// What a guest measured on its links to the successors. What it says of itself is not taken; of devices that are not members, neither.
  void _takeObservations(String? from, Object? o) {
    if (from == null || o is! Map) return;
    for (final e in o.entries) {
      final c = e.key, v = e.value;
      if (c is! String || c == from || c == site || v is! Map || !_members.any((x) => x.site == c)) continue;
      final band = LinkBand.values.where((x) => x.name == v['b']).firstOrNull ?? LinkBand.unknown;
      (_observed[c] ??= {})[from] = Observation(band, relayed: v['r'] == 1);
    }
    for (final e in _observed.entries) {
      if (!o.containsKey(e.key)) e.value.remove(from); // (it has no link to that one any more)
    }
    _reconsiderSuccession();
  }

  /// The host chooses the successors again, and signs a new roster when they changed.
  void _reconsiderSuccession() {
    if (role != SessionRole.host || _state != SessionState.live || _roster == null || _disposed) return;
    final here = {for (final p in _peers) ?p.site};
    final before = _roster!.succession;
    _succession.choose(
        members: List.of(_members),
        present: here,
        scores: {for (final m in _members) m.site: scoreOf(m.site)},
        now: DateTime.now(),
        vetoed: {
          for (final p in _peers)
            if (p.admitted && p.veto != null) ?p.site,
        });
    if (listEquals(before, _successionNow())) return;
    _rosterLine = _rosterLine.then((_) async {
      final list = _successionNow();
      if (_state != SessionState.live || listEquals(_roster?.succession, list)) return;
      _roster = await Roster.make(keys: await _keys, epoch: 1, rev: ++_rev, hostSite: site, members: _members, succession: list);
      notifyListeners();
      await _broadcast({'t': 'roster', 'r': _roster!.toJson()});
    }).then((_) {}, onError: (Object e) => debugPrint('[live] the roster could not be made: $e'));
  }

  /// The host's: why the guest [site] said it should not take over ('battery', 'metered'), or null.
  String? vetoOf(String site) => _peers.where((p) => p.site == site && p.admitted).firstOrNull?.veto;

  /// What a device says of why it should not take over: any short word counts as "not now" (an unknown one is kept as 'other').
  static String? _vetoFrom(Object? why) => why is! String || why.isEmpty ? null : (why == 'battery' || why == 'metered' ? why : 'other');

  /// A guest tells the host when it should (not) take over changed.
  void _reportVeto() {
    final host = _host;
    if (role != SessionRole.guest || host == null || !_welcomed || _state == SessionState.ended || _disposed) return;
    final veto = _budget?.value;
    if (veto == _vetoSent) return;
    _vetoSent = veto;
    unawaited(host.send({'t': 'veto', 'why': ?veto}).then((_) {}, onError: (Object _) {}));
  }

  /// The successors a guest keeps links to (not itself).
  Set<String> get _warmTargets {
    if (_state == SessionState.ended || _disposed || _warmNet == null) return const {};
    return {for (final s in (_roster?.succession ?? const <String>[]).take(warmSuccessors)) if (s != site) s};
  }

  bool get _warmListenWanted =>
      _state != SessionState.ended && !_disposed && _warmNet != null && (_roster?.succession ?? const <String>[]).take(warmSuccessors).contains(site);

  /// The successors this guest has a checked link to (for the tests).
  Set<String> get warmLinks => {for (final e in _warmOut.entries) if (e.value.admitted) e.key};

  /// How many guests have a checked link to this one, a successor (for the tests).
  int get warmIncoming => _warmIn.where((p) => p.admitted).length;

  /// Whether this guest waits for links as a successor (for the tests).
  bool get listensAsSuccessor => _warmListener != null;

  /// What this guest measured on its link to [successor] (for the tests).
  LinkStats? warmStatsOf(String successor) => _warmStats[successor];

  /// Makes the links to and from successors match the roster: a guest keeps one to each of the first [warmSuccessors], and one of those
  /// waits for the others' links.
  void _warmCheck() {
    if (role != SessionRole.guest) return;
    final listen = _warmListenWanted;
    if (listen && _warmListener == null && !_warmListening) unawaited(_warmListen());
    if (!listen && (_warmListener != null || _warmIn.isNotEmpty)) unawaited(_warmUnlisten());
    final targets = _warmTargets;
    for (final s in _warmOut.keys.toList()) {
      if (targets.contains(s)) continue;
      final p = _warmOut.remove(s)!;
      p.leaving = true;
      p.unwatch();
      unawaited(p.channel.close().then((_) {}, onError: (Object _) {}));
    }
    for (final s in _warmRetry.keys.toList()) {
      if (!targets.contains(s)) _warmRetry.remove(s)!.cancel();
    }
    for (final s in targets) {
      if (!_warmOut.containsKey(s) && !_warmRetry.containsKey(s)) unawaited(_warmReach(s));
    }
    if (!_disposed && _state != SessionState.ended) _reportWarm();
  }

  void _warmLater(String s) {
    if (!_warmTargets.contains(s)) return;
    _warmRetry[s]?.cancel();
    _warmRetry[s] = Timer(warmRetryAfter, () {
      _warmRetry.remove(s);
      if (_warmTargets.contains(s) && !_warmOut.containsKey(s)) unawaited(_warmReach(s));
    });
  }

  /// Connects to the successor [s]: this device says who it is (signed over the link), and the successor must answer the same way with the
  /// key the roster has for it, or the link is not used: whoever else answers there (every member can listen in that room) measures
  /// nothing.
  Future<void> _warmReach(String s) async {
    if (!_warmConnecting.add(s)) return;
    final PeerChannel channel;
    final String binding;
    try {
      channel = await _warmNet!.reach(s).timeout(const Duration(seconds: 45));
    } catch (e) {
      _warmConnecting.remove(s);
      _warmLater(s);
      return;
    }
    try {
      binding = await channel.binding();
    } catch (_) {
      _warmConnecting.remove(s);
      await channel.close();
      _warmLater(s);
      return;
    }
    _warmConnecting.remove(s);
    if (!_warmTargets.contains(s) || _warmOut.containsKey(s)) {
      await channel.close();
      return;
    }
    final nonce = _nonce();
    final peer = _Peer(channel, _box)
      ..site = s
      ..linkNonce = nonce
      ..linkBinding = binding
      ..onBand = _warmBand;
    _warmOut[s] = peer;
    channel.messages.listen((d) => peer.receive(d, _warmOutReceive), onDone: () => peer.afterMessages(() => _warmOutGone(peer)));
    channel.closed.then((_) => peer.afterMessages(() => _warmOutGone(peer)));
    final keys = await _keys;
    try {
      await peer.send({'t': 'warm', 'site': site, 'n': nonce, 'kp': await keys.signText(SessionKeys.linkProof(site, s, nonce, binding))});
    } catch (_) {
      return; // (gone: its close handler takes it from here)
    }
    Timer(const Duration(seconds: 20), () {
      if (!peer.admitted) unawaited(channel.close().then((_) {}, onError: (Object _) {}));
    });
  }

  Future<void> _warmOutReceive(_Peer peer, Uint8List data) async {
    final m = await _open(peer, data);
    if (m == null || !identical(_warmOut[peer.site], peer)) return;
    peer.alive?.heard();
    switch (m['t']) {
      case 'warmok':
        if (peer.admitted) return;
        final key = _roster?.member(peer.site!)?.key, sig = m['sig'];
        final ok = key != null && sig is String && await SessionKeys.verifyText(key, SessionKeys.linkProof(peer.site!, site, peer.linkNonce!, peer.linkBinding!), sig);
        if (!ok) {
          debugPrint('[live] the device that answered for a successor could not show its key: the link is not used');
          await peer.channel.close();
          return;
        }
        peer.admitted = true;
        _startHeartbeat(peer, _warmStats.putIfAbsent(peer.site!, LinkStats.new));
        notifyListeners();
      case 'ping':
        if (peer.admitted) await _answerPing(peer, m);
      case 'pong':
        if (peer.admitted) _gotPong(peer, m);
    }
  }

  void _warmOutGone(_Peer peer) {
    _countDrop(peer);
    if (identical(_warmOut[peer.site], peer)) {
      _warmOut.remove(peer.site);
      notifyListeners();
      _warmLater(peer.site!);
    }
  }

  void _warmBand(LinkStats stats) {
    if (stats.bandChanged(DateTime.now())) notifyListeners();
    _reportWarm();
  }

  /// Tells the host what this guest measured on its links to the successors, when that changed.
  void _reportWarm() {
    final host = _host;
    if (role != SessionRole.guest || host == null || !_welcomed || _state == SessionState.ended) return;
    final now = DateTime.now();
    final o = <String, Object?>{
      for (final s in _warmTargets)
        if (_warmStats[s] case final st?) s: {'b': st.band(now).name, if (st.relayed) 'r': 1},
    };
    final text = jsonEncode(o);
    if (text == _lastObs) return;
    _lastObs = text;
    unawaited(host.send({'t': 'obs', 'o': o}).then((_) {}, onError: (Object _) {}));
  }

  Future<void> _warmListen() async {
    _warmListening = true;
    try {
      final listener = await _warmNet!.listen(site);
      if (!_warmListenWanted || _warmListener != null) {
        await listener.close();
        return;
      }
      _warmListener = listener;
      _warmSub = listener.incoming.listen(_onWarmIncoming);
      notifyListeners();
    } catch (e) {
      debugPrint('[live] could not wait for links as a successor: $e');
      Timer(warmRetryAfter, _warmCheck);
    } finally {
      _warmListening = false;
    }
  }

  Future<void> _warmUnlisten() async {
    final listener = _warmListener, sub = _warmSub;
    _warmListener = null;
    _warmSub = null;
    for (final p in List.of(_warmIn)) {
      p.unwatch();
      unawaited(p.channel.close().then((_) {}, onError: (Object _) {}));
    }
    _warmIn.clear();
    await sub?.cancel();
    await listener?.close();
    notifyListeners();
  }

  /// A guest connected to this device as a successor. It is answered once it has shown, with its key from the roster, who it is; a link that
  /// does not show it soon, or falls silent, is closed.
  void _onWarmIncoming(PeerChannel channel) {
    if (_warmIn.length >= Roster.maxMembers || !_warmListenWanted) {
      unawaited(channel.close().then((_) {}, onError: (Object _) {}));
      return;
    }
    final peer = _Peer(channel, _box);
    _warmIn.add(peer);
    void gone() {
      peer.unwatch();
      if (_warmIn.remove(peer)) notifyListeners();
    }

    channel.messages.listen((d) => peer.receive(d, _warmInReceive), onDone: () => peer.afterMessages(gone));
    channel.closed.then((_) => peer.afterMessages(gone));
    if (!(channel is WatchedChannel && (channel as WatchedChannel).watching)) {
      // (the guest asks; a link that watches itself closes itself)
      peer.alive = KeepAlive(
        every: heartbeatEvery,
        deadAfter: heartbeatDeadAfter * 2,
        grace: heartbeatEvery,
        ping: () {},
        dead: () => unawaited(channel.close().then((_) {}, onError: (Object _) {})),
      )..start();
    }
    Timer(const Duration(seconds: 20), () {
      if (!peer.admitted) unawaited(channel.close().then((_) {}, onError: (Object _) {}));
    });
  }

  Future<void> _warmInReceive(_Peer peer, Uint8List data) async {
    final m = await _open(peer, data);
    if (m == null) {
      await peer.channel.close();
      return;
    }
    peer.alive?.heard(pong: true);
    switch (m['t']) {
      case 'warm':
        if (peer.admitted) return;
        final from = m['site'], n = m['n'], kp = m['kp'];
        final key = from is String && from != site ? _roster?.member(from)?.key : null;
        if (key == null || n is! String || n.length > 64 || kp is! String) {
          await peer.channel.close();
          return;
        }
        final String binding;
        try {
          binding = await peer.channel.binding();
        } catch (_) {
          await peer.channel.close();
          return;
        }
        if (!await SessionKeys.verifyText(key, SessionKeys.linkProof(from as String, site, n, binding), kp)) {
          await peer.channel.close();
          return;
        }
        peer
          ..site = from
          ..admitted = true;
        notifyListeners();
        await peer.send({'t': 'warmok', 'sig': await (await _keys).signText(SessionKeys.linkProof(site, from, n, binding))});
      case 'ping':
        if (peer.admitted) await _answerPing(peer, m);
    }
  }

  // ---- a guest

  /// Joins a session. [onWelcome] is called with the note once the host has said yes; the host may not
  /// answer for a while ([state] is waiting, [verificationCode] is set).
  ///
  /// With [into], the note the person has already, the host's note is taken into it (what the person changed
  /// meanwhile, [offline], stays, and goes to the host) instead of making a new note. [proofKey] is the key of the
  /// copy the person has, which lets them in without the host being asked.
  static Future<CollabSession> join(SessionInvite invite, JoinTransport transport,
      {String name = 'Guest',
      void Function(Welcome)? onWelcome,
      ImageSaver? imageSaver,
      NoteData? into,
      List<CollabOp> offline = const [],
      Uint8List? proofKey,
      String? userId,
      WarmNet? warmNet,
      bool? web,
      ValueListenable<String?>? budget}) async {
    final s = CollabSession._(SessionRole.guest, invite, name, _newSite(), null, userId: userId)
      .._warmNet = warmNet
      .._budget = budget
      .._web = web ?? kIsWeb
      ..onWelcome = onWelcome
      ..headlessImageSaver = imageSaver
      .._offline = offline
      .._proofKey = proofKey
      .._headless = into ?? NoteData(id: '');
    s._joinTransport = transport;
    budget?.addListener(s._reportVeto);
    await s._connectGuest(await transport.connect());
    return s;
  }

  Future<void> _connectGuest(PeerChannel channel) async {
    _hostChannel = channel;
    _lostAgain = false; // (a new link: what was lost before is not this)
    _hostStats.route = LinkRoute.unknown;
    final peer = _host = _Peer(channel, _box);
    channel.messages.listen((data) => peer.receive(data, _guestReceive), onDone: () => peer.afterMessages(() => _hostGone(peer)));
    channel.closed.then((_) => peer.afterMessages(() => _hostGone(peer)));
    _guestNonce = _nonce();
    final keys = await _keys;
    final keyText = keys.publicKeyText;
    final keyProof = await keys.signText(SessionKeys.joinProof(site, _guestNonce!, keyText));
    _vetoSent = _budget?.value;
    await peer.send({
      't': 'join',
      'z': 1,
      'site': site,
      'name': name,
      if (userId != null) 'uid': userId,
      'nonce': _guestNonce,
      'key': keyText,
      'kp': keyProof,
      if (_web) 'pf': 'web',
      if (_vetoSent != null) 'nv': _vetoSent,
      if (_token != null) 'resume': _token,
      if (_proofKey != null) 'proof': copyProof(_proofKey!, _guestNonce!),
    });
  }

  Future<void> _guestReceive(_Peer peer, Uint8List data) async {
    final m = await _open(peer, data);
    if (m == null) return;
    // a link that was given up for a new one may still have messages to work through: they are older than what the new one brings
    // (which starts with the whole state again), and a list of who is there or a page from them would undo what is newer
    if (!identical(peer, _host)) return;
    peer.alive?.heard();
    switch (m['t']) {
      case 'ping':
        await _answerPing(peer, m);
      case 'pong':
        _gotPong(peer, m);
      case 'bands':
        _takeBands(m['b']);
      case 'roster':
        await _acceptRoster(Roster.fromJson(m['r']), restarted: false);
      case 'pending':
        _hostNonce = m['nonce'] as String?;
        _code = invite.verificationCode(_hostNonce!, _guestNonce!);
        _set(SessionState.waiting);
      case 'deny':
        _end(tr(m['reason'] as String? ?? 'The host did not accept the request'));
        await peer.channel.close();
      case 'welcome':
        _token = m['token'] as String? ?? _token;
        _hostSite = m['site'] as String? ?? _hostSite;
        await _acceptRoster(Roster.fromJson(m['roster']), restarted: m['resume'] != true && _welcomed);
        _lastObs = null; // (a host that was started again knows nothing of what was measured)
        _reportWarm();
        _reportVeto(); // (it changed while the host had not answered yet)
        if (m['resume'] == true) {
          // back after a break: what happened meanwhile is merged into the note as it is now
          _takeRemote({'ops': m['ops']});
          _setParticipants(m['peers']);
          _set(SessionState.live);
          if (!(_resumed?.isCompleted ?? true)) _resumed!.complete();
          // and everything here goes out: not only what was changed meanwhile, but also what was sent just before the link broke and
          // never arrived (a message handed to a link that died is not known to be lost - the host has no way to ask for it again).
          // Changes that are known on the other side are no change there (the later version wins, see Replica), so this is safe to repeat.
          _sendAll();
          _sendOwnPage();
          return;
        }
        if (_welcomed) {
          // a host that does not know this session any more (its app was started again): its note is merged into
          // the one here, everything here goes to it (it may have lost what it was sent before), and the session goes on
          _takeRemote({'ops': m['ops']});
          _setParticipants(m['peers']);
          _set(SessionState.live);
          if (!(_resumed?.isCompleted ?? true)) _resumed!.complete();
          _sendAll();
          _sendOwnPage();
          return;
        }
        _welcomed = true;
        final headless = _headless!;
        final saver = headlessImageSaver ?? (id, bytes, ext) => throw StateError('no place for pictures');
        for (final j in (m['ops'] as List).map(CollabOp.fromJson).whereType<CollabOp>()) {
          replica.apply(headless, j,
              makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
              saveImage: saver,
              onNoteField: (f, d) => Replica.applyNoteField(headless, f, d));
        }
        if (_offline.isNotEmpty) {
          // what the person changed while away stays (as if they had just done it)
          final raw = Replica('offline');
          for (final op in _offline) {
            raw.apply(headless, op,
                makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero), saveImage: saver, onNoteField: (f, d) => Replica.applyNoteField(headless, f, d));
          }
          _offline = const [];
        }
        // whatever the note has that the host does not (and what was just put back) goes to the host
        final mine = replica.localChanges(headless);
        if (mine.isNotEmpty) unawaited(peer.send({'t': 'ops', 'ops': [for (final o in mine) o.toJson()]}).then((_) {}, onError: (Object _) {}));
        _setParticipants(m['peers']);
        final pdf = _pdfFrom(m['pdf']);
        _set(SessionState.live);
        onWelcome?.call(Welcome(headless, pdf));
      case 'ops':
        if (_state == SessionState.live) _takeRemote(m);
      case 'peers':
        _setParticipants(m['peers']);
      case 'pages':
        if (_state == SessionState.live) await _takePages(m['a']);
      case 'pdf':
        if (_state == SessionState.live) await _takePdf(m['f']);
      case 'at':
        _takePage(m['site'] as String?, m['page'], m['sheet'], m['q']);
      case 'bye':
        _hostLeft(tr('The host ended the session'));
        await peer.channel.close();
    }
  }

  /// The host is gone for good: the session ends here, or - for a session between a person's own devices - the guests carry on without it.
  void _hostLeft(String reason) {
    if (_state == SessionState.ended) return;
    final carryOn = onHostLost;
    if (carryOn != null) handedOver = true;
    _end(reason);
    if (carryOn != null) carryOn(this);
  }

  /// Whether the first welcome has come (the note was made from it).
  bool _welcomed = false;

  /// Set while the screen is going away: the whole note goes to the host once the session holds it again.
  bool _sendAllLater = false;

  /// Sends the whole note to the host, deleted things included.
  void _sendAll() {
    final note = _binding?.note() ?? _headless;
    if (note == null) {
      _sendAllLater = true;
      return;
    }
    _sendAllLater = false;
    replica.localChanges(note); // (what is in the note counts as known from now on)
    final ops = replica.state(note, includeDeleted: true);
    if (ops.isEmpty || _host == null) return;
    unawaited(_host!.send({'t': 'ops', 'ops': [for (final o in ops) o.toJson()]}).then((_) {}, onError: (Object _) {}));
  }

  /// Tells the host again which page is in view here: a host that lost the link forgot it (and one started again never knew), and the
  /// screen only says so when the page or the number of people changes.
  void _sendOwnPage() {
    final page = _viewing[site];
    if (page == null) return;
    unawaited(_host?.send(_atMessage(site, page, _sheets[site], seq: ++_atSeq)).then((_) {}, onError: (Object _) {}));
  }

  void _setParticipants(Object? list) {
    _participants
      ..clear()
      ..addAll([
        for (final p in (list as List? ?? const []).whereType<Map>())
          Participant(p['site'] as String, p['name'] as String, uid: p['uid'] is String && Author.isId(p['uid'] as String) ? p['uid'] as String : null),
      ]);
    _pruneViewing();
    notifyListeners();
  }

  /// Set when the link that is current was lost while a way back was still being made: the loop in [_reconnect] has to go on.
  bool _lostAgain = false;

  void _hostGone(_Peer peer) {
    _countDrop(peer);
    if (!identical(peer, _host) || _state == SessionState.ended) return; // an old link
    if (_reconnecting && _state == SessionState.live) {
      // The welcome that made the session live and the loss of this link can come one right after the other, before the loop that made
      // the link has seen that it worked: starting another one is refused, and the loop then ends content with a link that is gone.
      _lostAgain = true;
      return;
    }
    if (_state == SessionState.live && _token != null && _joinTransport != null) {
      unawaited(_reconnect());
    } else if (_state != SessionState.reconnecting) {
      _hostLeft(tr('The connection to the host was lost'));
    }
  }

  /// How long a guest keeps trying to get back before it gives up.
  static const reconnectFor = Duration(minutes: 10);

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    _set(SessionState.reconnecting);
    // between a person's own devices a new session is arranged, so there is no use in waiting for ten minutes
    final deadline = DateTime.now().add(onHostLost != null ? giveUpOnHostAfter : reconnectFor);
    // (a quick second try for a hiccup, then slower; the random part keeps the guests of one host from all coming at the same moment)
    final backoff = Backoff(base: const Duration(seconds: 1), max: const Duration(seconds: 10));
    while (_state == SessionState.reconnecting && DateTime.now().isBefore(deadline)) {
      _resumed = Completer<void>();
      PeerChannel? channel;
      try {
        channel = await _joinTransport!.connect();
        if (_state != SessionState.reconnecting) {
          await channel.close();
          break;
        }
        await _connectGuest(channel);
        await Future.any([_resumed!.future, channel.closed,]).timeout(const Duration(seconds: 45));
        if (_state == SessionState.live) break;
      } catch (_) {
        // not there yet
      }
      if (_state != SessionState.reconnecting) break;
      // a link that came up but never got us back in is not left open behind the next try
      if (channel != null) unawaited(channel.close().then((_) {}, onError: (Object _) {}));
      _nudge = Completer<void>();
      final nudge = _nudge!;
      await Future.any([Future<void>.delayed(backoff.next()), nudge.future]);
      if (nudge.isCompleted) backoff.reset(); // (the app is back in front, or the network changed: the way may be there now)
    }
    _reconnecting = false;
    if (_state == SessionState.reconnecting) {
      _hostLeft(tr('The connection to the host was lost'));
    } else if (_state == SessionState.live && _lostAgain) {
      _lostAgain = false;
      unawaited(_reconnect()); // back in, and the link is gone again already
    }
  }

  /// How long a guest of a session between a person's own devices tries to reach the host before the oldest guest takes over.
  static const giveUpOnHostAfter = Duration(seconds: 20);

  /// The app is back in front: a host makes sure it can be reached again; a guest that lost the host tries now.
  void wake() {
    if (_state == SessionState.ended) return;
    if (role == SessionRole.host) {
      _hostTransport?.wake();
    } else if (_nudge != null && !_nudge!.isCompleted) {
      _nudge!.complete();
    }
  }

  // ---- both

  /// The note's owner (the editor) takes over a note that was made from the welcome: from now on changes
  /// go to and come from the screen.
  void attach(CollabBinding binding) {
    final headless = _headless;
    _binding = binding;
    _headless = null;
    _headlessTimer?.cancel();
    _pdfProvider = binding.pdf ?? _pdfProvider;
    if (headless != null) {
      // The note on the screen was made from the welcome; changes that came in since were applied to the
      // headless copy. Bring the screen up to date with all of it, then carry on with the screen as the note.
      final old = replica;
      final catchUp = old.state(headless, includeDeleted: true);
      replica = Replica(site, clock: old.clock);
      binding.change(() {
        final note = binding.note();
        for (final op in catchUp) {
          replica.apply(note, op, makeBox: binding.makeBox, saveImage: binding.saveImage, onNoteField: binding.onNoteField);
        }
      });
    }
    // anything else the screen has counts as known (and goes out at the next change)
    replica.localChanges(binding.note());
    if (_sendAllLater) _sendAll();
    notifyListeners();
  }

  /// The screen that showed the note is gone (the person went elsewhere in the app); the session goes
  /// on with [note], the note as it was saved, taking in changes from others until a screen takes over again.
  void detach(NoteData note) {
    _binding = null;
    _headless = note;
    if (_buffered.isNotEmpty) {
      final ops = List.of(_buffered);
      _buffered.clear();
      _applyToHeadless(ops);
    }
    if (_sendAllLater) _sendAll();
  }

  /// The screen is going away: until [detach] gives the session a note to hold, what comes in is kept aside.
  void suspend() {
    _flushLocal();
    _binding = null;
    _headless = null;
  }

  final List<CollabOp> _buffered = [];

  void _applyToHeadless(List<CollabOp> ops) {
    final headless = _headless!;
    for (final op in ops) {
      replica.apply(headless, op,
          makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
          saveImage: headlessImageSaver ?? (id, bytes, ext) => throw StateError('no place for pictures'),
          onNoteField: (f, d) => Replica.applyNoteField(headless, f, d));
    }
    _headlessTimer?.cancel();
    _headlessTimer = Timer(const Duration(seconds: 1), () => onHeadlessChanged?.call(headless));
  }

  /// Gives the note that was made from the welcome (with its id) to the session to keep up to date while there is no screen.
  void adoptNote(NoteData note) {
    if (_binding == null) _headless = note;
  }

  bool get hasScreen => _binding != null;

  void _takeRemote(Map<String, Object?> m) {
    final ops = [for (final j in (m['ops'] as List? ?? const [])) ?CollabOp.fromJson(j)];
    if (ops.isEmpty) return;
    final binding = _binding;
    if (binding != null) {
      binding.change(() {
        final note = binding.note();
        for (final op in ops) {
          replica.apply(note, op, makeBox: binding.makeBox, saveImage: binding.saveImage, onNoteField: binding.onNoteField);
        }
      });
    } else if (_headless != null) {
      _applyToHeadless(ops);
    } else {
      _buffered.addAll(ops);
    }
  }

  /// Takes in changes that did not come over the session (made on a copy while its owner was away) as if the
  /// person here had made them: put into the note, and sent to the others. They replace what is there.
  void applyExternal(List<CollabOp> ops) {
    if (ops.isEmpty || _state == SessionState.ended) return;
    final raw = Replica('external');
    final binding = _binding;
    if (binding != null) {
      binding.change(() {
        final note = binding.note();
        for (final op in ops) {
          raw.apply(note, op, makeBox: binding.makeBox, saveImage: binding.saveImage, onNoteField: binding.onNoteField);
        }
      });
      localChanged();
    } else if (_headless != null) {
      final note = _headless!;
      for (final op in ops) {
        raw.apply(note, op,
            makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
            saveImage: headlessImageSaver ?? (id, bytes, ext) => throw StateError('no place for pictures'),
            onNoteField: (f, d) => Replica.applyNoteField(note, f, d));
      }
      final out = replica.localChanges(note);
      if (out.isNotEmpty && _state == SessionState.live && role == SessionRole.host) {
        unawaited(_broadcast({'t': 'ops', 'ops': [for (final o in out) o.toJson()]}));
      }
      _headlessTimer?.cancel();
      _headlessTimer = Timer(const Duration(seconds: 1), () => onHeadlessChanged?.call(note));
    }
  }

  /// The person here changed the note: what changed goes to the others shortly. Called as often as
  /// you like; the work is done once things settle.
  void localChanged() {
    if (_state != SessionState.live) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _flushLocal);
  }

  /// Sends what changed here, now.
  void flush() {
    _debounce?.cancel();
    _flushLocal();
  }

  void _flushLocal() {
    if (_state != SessionState.live || _binding == null) return;
    final ops = replica.localChanges(_binding!.note());
    if (ops.isEmpty) return;
    final message = {'t': 'ops', 'ops': [for (final o in ops) o.toJson()]};
    if (role == SessionRole.host) {
      unawaited(_broadcast(message));
    } else {
      unawaited(_host!.send(message).then((_) {}, onError: (Object _) {}));
    }
  }

  void _set(SessionState s) {
    _state = s;
    if (s == SessionState.live && role == SessionRole.guest) {
      final h = _host;
      if (h != null && !h.watched) _startHeartbeat(h, _hostStats);
    }
    notifyListeners();
  }

  void _end(String reason) {
    if (_state == SessionState.ended) return;
    _endReason = reason;
    _debounce?.cancel();
    _stopHeartbeats();
    _successionTimer?.cancel();
    _set(SessionState.ended);
    _warmCheck(); // (closes them all)
  }

  void _stopHeartbeats() {
    _host?.unwatch();
    for (final p in _peers) {
      p.unwatch();
    }
  }

  /// Leaves the session (a guest) or ends it for everyone (the host). The note stays as it is.
  Future<void> end() async {
    if (_state == SessionState.ended) return;
    _flushLocal();
    final wasHost = role == SessionRole.host;
    _end(wasHost ? tr('You ended the session') : tr('You left the session'));
    if (wasHost) {
      for (final id in _pendingPeers.keys.toList()) {
        await deny(id, reason: 'The host ended the session');
      }
      await _broadcast({'t': 'bye'});
      for (final p in List.of(_peers)) {
        await p.channel.close();
      }
      await _incomingSub?.cancel();
      await _hostTransport?.close();
    } else {
      try {
        await _host?.send({'t': 'bye'});
      } catch (_) {
        // already gone
      }
      await _hostChannel?.close();
    }
  }

  bool _disposed = false;

  /// A session that was disposed still gets what a link that is not closed yet delivers; nobody listens any more, so nobody is told.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _successionTimer?.cancel();
    _disposed = true;
    _budget?.removeListener(_reportVeto);
    _warmCheck(); // (nothing is wanted of a disposed session: closes the links to and from successors)
    _debounce?.cancel();
    _stopHeartbeats();
    _headlessTimer?.cancel();
    super.dispose();
  }
}
