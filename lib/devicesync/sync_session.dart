import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../collab/compression.dart';
import '../collab/secure_box.dart';
import '../collab/transport.dart';
import '../l10n/language.dart';
import 'sync_accounts.dart';
import 'sync_devices.dart';
import 'sync_diag.dart';
import 'sync_keys.dart';
import 'sync_library.dart';

/// How a meeting of two devices ended.
enum SyncEnd {
  /// The libraries were brought together.
  done,

  /// The other device is not one this profile accepts (or this one was told it is not wanted any more).
  refused,

  /// The connection broke, or the other side did not follow the protocol.
  failed,
}

class SyncOutcome {
  final SyncEnd end;
  final String? problem;

  /// The device on the other side, once it said who it is.
  final String? peerId;
  final String? peerName;

  /// A new device was added to the profile in this meeting.
  final bool paired;

  /// This device was taken out of the profile by the other devices.
  final bool removedSelf;

  /// How many notes, folders and settings were taken in or deleted here.
  final int changes;

  /// For a meeting that was about a live session on one note: the link to go on with.
  final LiveLink? live;

  /// This device turned a sync of the libraries away, as it does not sync its notes now (nothing went wrong here).
  final bool declined;

  const SyncOutcome(this.end, {this.problem, this.peerId, this.peerName, this.paired = false, this.removedSelf = false, this.changes = 0, this.live, this.declined = false});

  bool get ok => end == SyncEnd.done;
}

/// The result of a meeting that was about working live on one note: the device on the other side has proved who it is, and
/// [channel] is the line to it, free for the live session to use (it has its own sealing, with [secret]).
class LiveLink {
  final String noteId;
  final String peerId;
  final PeerChannel channel;

  /// The secret of the session (see `SessionInvite`), which the device that hosts the session made and sent over the proven line.
  final Uint8List secret;

  const LiveLink(this.noteId, this.peerId, this.channel, this.secret);
}

/// This device offered a link: a device that comes with its secret is a new one, and the person here decides whether it is let in.
class PairingOffer {
  /// Asks the person; [code] is what both screens must show.
  final Future<bool> Function(String deviceName, String code) approve;
  const PairingOffer(this.approve);
}

/// This device came with a link: it shows the code and asks the person whether the device that offered the link shows the same
/// one. Only a yes lets the session go on - a device that is not the one the person holds gets nothing from this one and
/// does not become its profile.
class PairingJoin {
  final Future<bool> Function(String code) confirm;

  /// Takes the profile (id and name) of the device that let this one in.
  final Future<void> Function(String profileId, String profileName) adopt;
  const PairingJoin(this.confirm, this.adopt);
}

/// The person this device belongs to.
abstract class ProfileAccess {
  String get id;
  String get name;
}

/// One meeting of two devices over a direct connection: they prove who they are to each other, and bring their libraries
/// together. Everything is sealed with a key from the secret of the profile on top of what the connection does.
///
/// 1. **Who is there.** Each device says its id, public key and a random number. Each then signs both numbers and both ids with
///    its device secret and the other checks the signature against the public key it has on its list. A device that is not on
///    the list can only get in through *pairing*: one device offered a link, the other came with it; both show six digits that
///    come from the secret, both public keys and both random numbers; the person on the offering device says yes.
/// 2. **The lists of devices** are merged, so that a new device is known everywhere and a removed one is not let in again.
/// 3. **Manifests** (a line for each note, folder, setting and deletion) are exchanged, each side works out what it wants, asks
///    for it, and is sent it. Newer replaces older; a note changed on both sides is kept twice.
class SyncSession {
  static const protocol = 2;

  final PeerChannel channel;
  final SyncSecret secret;
  final String roomName;
  final DeviceIdentity identity;
  final String deviceName;
  final DeviceBook book;
  final ProfileAccess profile;
  final SyncLibrary library;
  final PairingOffer? offer;
  final PairingJoin? join;
  final void Function(String what, double? fraction)? onProgress;
  final Duration step;

  /// This device wants to work on note [liveNote] live with the other one, instead of syncing the libraries (the other device
  /// hosts the session).
  final String? liveNote;

  /// The cloud accounts of this device, exchanged at the end of a meeting (null: this device has none to give or take).
  final SyncedAccounts? accounts;

  /// Whether this device syncs its notes now. Off (it is only in the room for a note it works on live, and the person did not ask for
  /// the automatic sync), a meeting about the libraries is turned away; one about a live session is not.
  final bool syncsLibrary;

  /// Notes that are not here yet are only listed, and their content is asked for when the person opens them (a browser that is here
  /// for a while only; see `SyncLibrary.plan`).
  final bool lazyNotes;

  /// This device answers a request for a live session: given the note and the device that asks, it gives the secret of the
  /// session it hosts on that note, or null if it hosts none.
  final Future<Uint8List?> Function(String noteId, String peerId)? liveSecretFor;

  late final SecureBox _box = SecureBox(secret.messageKey);
  final List<Map<String, Object?>> _queue = [];
  Completer<void>? _waiting;
  bool _gone = false;
  StreamSubscription<Uint8List>? _sub;

  SyncSession({
    required this.channel,
    required this.secret,
    required this.roomName,
    required this.identity,
    required this.deviceName,
    required this.book,
    required this.profile,
    required this.library,
    this.offer,
    this.join,
    this.onProgress,
    this.step = const Duration(seconds: 30),
    this.liveNote,
    this.liveSecretFor,
    this.accounts,
    this.syncsLibrary = true,
    this.lazyNotes = false,
  });

  // ---- the line

  /// Whether the other device reads compressed messages (it said so in its `hi`; an older one does not).
  bool _peerUnpacks = false;

  Future<void> _send(Map<String, Object?> message) async {
    final json = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    await channel.send(await _box.seal(_peerUnpacks ? await packMessage(json) : json));
  }

  // For a live meeting: what arrives that is not sealed for this meeting is the live session's own traffic, which starts as soon as
  // the other side is through. It is kept until the line is handed over.
  final List<Uint8List> _raw = [];
  StreamController<Uint8List>? _handoff;

  bool get _liveMode => liveNote != null || liveSecretFor != null;

  /// Messages are taken one after the other, in the order they came: telling a message that is not for this meeting from one that is
  /// takes longer the bigger it is, and a small message that overtook a big one would reach the live session first.
  Future<void> _inbox = Future.value();

  void _listen() {
    _sub = channel.messages.listen((data) {
      _inbox = _inbox.then((_) async {
        final handed = _handoff;
        if (handed != null) {
          handed.add(data); // the line belongs to the live session now
          return;
        }
        try {
          final plain = await unpackMessage(await _box.open(data));
          _queue.add((jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>());
        } catch (_) {
          // not sealed with the secret of this profile: dropped, unless it is what the live session sends
          if (_liveMode) {
            final out = _handoff;
            if (out != null) {
              out.add(data);
            } else if (_raw.length < 64) {
              _raw.add(data);
            }
          }
          return;
        }
        final w = _waiting;
        if (w != null && !w.isCompleted) w.complete();
      });
    });
    // (after the messages that came before it: what the other device said last, a refusal say, is read before the line counts as gone)
    channel.closed.then((_) {
      _inbox = _inbox.then((_) {
        _gone = true;
        final w = _waiting;
        if (w != null && !w.isCompleted) w.complete();
      });
    });
  }

  /// The next message, which must be of type [type] - or [refusal], with which the other device turns the meeting away ([why]).
  Future<Map<String, Object?>> _nextOr(String type, String refusal, String why, String? peerId, String? peerName) async {
    await _wait(step);
    if (_queue.first['t'] == refusal) throw _Stop(SyncEnd.refused, why, peerId, peerName);
    return _next(type);
  }

  /// Waits up to [timeout] for a message to read; throws when none comes, or the line is gone.
  Future<void> _wait(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_queue.isEmpty) {
      if (_gone) throw _Stop(SyncEnd.failed, tr('The connection to the other device was lost'));
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw _Stop(SyncEnd.failed, tr('The other device did not answer'));
      _waiting = Completer<void>();
      await _waiting!.future.timeout(left, onTimeout: () {});
    }
  }

  /// The next message, which must be of type [type].
  Future<Map<String, Object?>> _next(String type, {Duration? timeout}) async {
    await _wait(timeout ?? step);
    final m = _queue.removeAt(0);
    if (m['t'] != type) throw _Stop(SyncEnd.failed, tr('The other device did not follow the protocol'));
    return m;
  }

  // ---- the meeting

  Future<SyncOutcome> run() async {
    String? peerId, peerName;
    var paired = false;
    var changes = 0;
    _listen();
    try {
      // 1. who is there
      // Each side first commits to its random number and key, and only reveals them when it has the other's commitment: a device
      // in the middle cannot pick its numbers and key after seeing the honest ones, so it cannot make the six digits of a
      // pairing come out the same on both screens.
      final myNonce = newNonce();
      final myKey = base64.encode(identity.publicKey);
      await _send({'t': 'hi', 'v': protocol, 'id': identity.id, 'name': deviceName, 'commit': _commit(identity.id, myNonce, myKey), 'live': ?liveNote, 'offering': offer != null, 'z': 1});
      final hi = await _next('hi');
      _peerUnpacks = hi['z'] == 1;
      if (hi['v'] != protocol) throw _Stop(SyncEnd.failed, tr('The other device runs a different version of the sync'));
      peerId = hi['id'] as String?;
      peerName = hi['name'] as String?;
      final theirCommit = hi['commit'] as String?;
      if (peerId == null || theirCommit == null || peerId == identity.id) throw _Stop(SyncEnd.failed, tr('The other device did not say who it is'));
      await _send({'t': 'reveal', 'nonce': myNonce, 'key': myKey});
      final reveal = await _next('reveal');
      final peerNonce = reveal['nonce'] as String?;
      final peerKeyText = reveal['key'] as String?;
      if (peerNonce == null || peerKeyText == null || _commit(peerId, peerNonce, peerKeyText) != theirCommit) {
        throw _Stop(SyncEnd.refused, tr('The other device did not keep to what it first said'), peerId, peerName);
      }
      final peerKey = Uint8List.fromList(base64.decode(peerKeyText));
      if (peerKey.length != 32) throw _Stop(SyncEnd.failed, tr('The other device did not say who it is'));

      // what ties the proof to this very connection (see PeerChannel.binding)
      final binding = await channel.binding();
      final known = book.find(peerId);
      syncDiag(
        'session: ${identity.id} (${keyTag(identity.publicKey)}) meets $peerId ($peerName), which presents key ${keyTag(peerKey)}; ${known == null ? 'not on the list' : 'the list has key ${keyTag(known.publicKey)} for it'}',
      );
      if (known != null && !_same(known.publicKey, peerKey)) {
        syncDiag(
          'session: KEY MISMATCH for $peerId ($peerName): the list has ${keyTag(known.publicKey)}, it presented ${keyTag(peerKey)}. This device ${identity.id} signs with ${keyTag(identity.publicKey)}. The list: ${book.describe()}',
        );
        throw _Stop(SyncEnd.refused, tr('The key of the other device is not the one that was accepted'), peerId, peerName);
      }
      await _send({
        't': 'auth',
        'sig': base64.encode(await identity.sign(DeviceIdentity.meeting(
            room: roomName, signerId: identity.id, idA: identity.id, nonceA: myNonce, idB: peerId, nonceB: peerNonce, binding: binding))),
      });
      final auth = await _next('auth');
      final proven = await DeviceIdentity.verify(
          peerKey,
          DeviceIdentity.meeting(room: roomName, signerId: peerId, idA: identity.id, nonceA: myNonce, idB: peerId, nonceB: peerNonce, binding: binding),
          Uint8List.fromList(base64.decode(auth['sig'] as String)));
      if (!proven) {
        syncDiag(
          'session: $peerId (${keyTag(peerKey)}) did NOT prove it holds that key',
        ); throw _Stop(SyncEnd.refused, tr('The other device could not prove who it is'), peerId, peerName
        );
      }
      syncDiag('session: $peerId proved its key ${keyTag(peerKey)}');

      final peerLive = hi['live'] as String?;
      if (liveNote != null || peerLive != null) {
        return await _liveMeeting(known != null, peerId, peerName, peerLive);
      }

      if (!syncsLibrary && known != null) {
        await _send({'t': 'declined'});
        return SyncOutcome(SyncEnd.refused, peerId: peerId, peerName: peerName, declined: true);
      }
      if (known == null) {
        // a device that joins meets every device it finds; it compares a code only with one that made the link (an older device
        // does not say, and is asked as before)
        if (join != null && offer == null && hi['offering'] == false) {
          throw _Stop(SyncEnd.refused, tr('This device is not one of this profile (add it with the link from a device of the profile)'), peerId, peerName);
        }
        paired = await _pairing(peerId, peerName ?? '', myNonce, peerNonce, peerKey, binding);
      }

      // 2. the devices
      onProgress?.call(tr('Comparing the devices...'), null);
      await _send({'t': 'devices', 'list': [for (final d in book.all) d.toJson()]});
      final devices = await _nextOr('devices', 'declined', tr('The other device does not sync its notes now'), peerId, peerName);
      await book.merge([for (final j in (devices['list'] as List? ?? const [])) ?PairedDevice.fromJson(j)]);
      if (book.find(identity.id) == null) {
        return SyncOutcome(SyncEnd.refused, problem: tr('This device was removed from the profile'), peerId: peerId, peerName: peerName, removedSelf: true);
      }
      if (book.find(peerId) == null) throw _Stop(SyncEnd.refused, tr('The other device was removed from the profile'), peerId, peerName);

      // 3. the libraries
      onProgress?.call(tr('Looking at what changed...'), null);
      final mine = await library.manifest();
      await _send({'t': 'manifest', 'm': mine.toJson()});
      final theirs = SyncManifest.fromJson((await _next('manifest'))['m'] as Map);

      final plan = await library.plan(peerId, identity.id, theirs, lazy: lazyNotes);
      for (final id in plan.deleteNotes) {
        await library.deleteNote(id, at: plan.deletedAt['note:$id']);
        changes++;
      }
      for (final id in plan.deleteFolders) {
        await library.deleteFolder(id, at: plan.deletedAt['folder:$id']);
        changes++;
      }
      for (final id in plan.deleteGraphs) {
        await library.deleteGraph(id, at: plan.deletedAt['graph:$id']!);
        changes++;
      }
      await _send({
        't': 'want',
        'folders': plan.folders,
        'graphs': plan.graphs,
        'notes': {for (final e in plan.notes.entries) e.key: {'data': e.value.data, 'meta': e.value.meta}},
        'settings': plan.settings,
      });
      final want = await _next('want');

      // giving
      final wantFolders = [for (final id in (want['folders'] as List? ?? const [])) id as String];
      final wantNotes = (want['notes'] as Map? ?? const {}).cast<String, dynamic>();
      final wantSettings = [for (final k in (want['settings'] as List? ?? const [])) k as String];
      for (final f in await library.foldersFor(wantFolders)) {
        final image = await library.folderImage(f.id);
        await _send({'t': 'folder', 'f': f.toJson(), if (image != null) 'img': {'ext': image.ext, 'bytes': base64.encode(image.bytes)}});
      }
      var given = 0;
      for (final e in wantNotes.entries) {
        final info = await library.noteInfo(e.key);
        if (info == null) continue;
        final wantsData = (e.value as Map)['data'] == true;
        final bytes = wantsData ? await library.noteBytes(e.key) : null;
        if (wantsData && bytes == null) continue; // locked or gone meanwhile
        await _send({'t': 'note', 'n': info.toJson(), 'data': wantsData, 'meta': (e.value as Map)['meta'] == true, if (!wantsData) 'title': await library.noteTitle(e.key), if (bytes != null) 'bytes': base64.encode(bytes)});
        onProgress?.call(tr('Sending notes...'), wantNotes.isEmpty ? null : ++given / wantNotes.length);
      }
      for (final id in [
        for (final u in (want['graphs'] as List? ?? const [])) u as String,
      ]) {
        final got = await library.graphFor(id);
        if (got != null) {
          await _send({
            't': 'graph',
            'g': got.info.toJson(),
            'payload': got.payload,
          });
        }
      }
      for (final k in wantSettings) {
        final v = await library.settingValue(k);
        if (v != null) await _send({'t': 'setting', 's': v.toJson()});
      }
      await _send({'t': 'end'});

      // taking
      var taken = 0;
      final expected = plan.folders.length + plan.notes.length + plan.settings.length +
          plan.graphs.length;
      while (true) {
        final m = await _nextAny();
        final t = m['t'];
        if (t == 'end') break;
        if (t == 'folder') {
          final img = m['img'];
          await library.applyFolder(
            SyncFolder.fromJson(m['f'] as Map),
            image: img is Map ? (ext: '${img['ext']}', bytes: base64.decode(img['bytes'] as String)) : null,
          );
        } else if (t == 'note') {
          final bytes = m['bytes'] is String ? Uint8List.fromList(base64.decode(m['bytes'] as String)) : null;
          await library.applyNote(peerId, SyncNote.fromJson(m['n'] as Map), bytes, data: m['data'] == true, meta: m['meta'] == true, title: m['title'] is String ? m['title'] as String : null, lazy: lazyNotes);
        } else if (t == 'graph') {
          if (m['payload'] is String) {
            await library.applyGraph(
              SyncGraph.fromJson(m['g'] as Map),
              m['payload'] as String,);
          }
        } else if (t == 'setting') {
          await library.applySetting(SyncSettingValue.fromJson(m['s'] as Map));
        } else {
          throw _Stop(SyncEnd.failed, tr('The other device did not follow the protocol'));
        }
        changes++;
        onProgress?.call(tr('Receiving...'), expected == 0 ? null : (++taken / expected).clamp(0.0, 1.0));
      }
      // what is the same on both now counts as agreed (what was taken in counts already, see `applyNote`); a note that was not exchanged
      // - it was open in an editor on one side - does not, or a later change on top of it would be taken for no change at all
      await library.markAgreed(peerId, theirs);

      // 4. the cloud accounts: the newer of each is taken (they only go over this proven, sealed line)
      await _send({'t': 'accounts', 'list': [if (accounts != null) for (final b in await accounts!.export()) b.toJson()]});
      final theirAccounts = await _next('accounts');
      if (accounts != null) {
        changes += await accounts!.apply([for (final j in (theirAccounts['list'] as List? ?? const [])) ?AccountBundle.fromJson(j)]);
      }
      return SyncOutcome(SyncEnd.done, peerId: peerId, peerName: peerName, paired: paired, changes: changes);
    } on _Stop catch (s) {
      debugPrint(
        'A sync meeting ended: ${s.end} ${s.problem}${s.peerId == null ? '' : ' (peer ${s.peerId}, ${s.peerName})'}',);
      return SyncOutcome(s.end, problem: s.problem, peerId: s.peerId ?? peerId, peerName: s.peerName ?? peerName, paired: paired, changes: changes);
    } catch (e, stack) {
      debugPrint('A sync meeting failed: $e\n$stack');
      return SyncOutcome(SyncEnd.failed, problem: '$e', peerId: peerId, peerName: peerName, paired: paired, changes: changes);
    } finally {
      if (!_handedOver) {
        await _sub?.cancel();
        await channel.close();
      }
    }
  }

  bool _handedOver = false;

  /// A meeting about one note: only a device that is on the list is served, and the host sends the secret of its session; the
  /// line then goes to the live session.
  Future<SyncOutcome> _liveMeeting(bool known, String peerId, String? peerName, String? peerLive) async {
    if (!known) throw _Stop(SyncEnd.refused, tr('A live session is only for devices that are in the profile'), peerId, peerName);
    Uint8List secret;
    String note;
    if (liveNote != null && peerLive == null) {
      note = liveNote!;
      final m = await _next('live');
      final text = m['secret'];
      if (text is! String) throw _Stop(SyncEnd.refused, tr('The other device has no live session on this note'), peerId, peerName);
      secret = Uint8List.fromList(base64.decode(text));
    } else if (liveNote == null && peerLive != null) {
      note = peerLive;
      final mine = await liveSecretFor?.call(note, peerId);
      if (mine == null) {
        await _send({'t': 'live', 'no': true});
        throw _Stop(SyncEnd.refused, tr('No live session on this note is hosted here'), peerId, peerName);
      }
      secret = mine;
      await _send({'t': 'live', 'secret': base64.encode(secret)});
    } else {
      throw _Stop(SyncEnd.refused, tr('Both devices asked for a live session'), peerId, peerName);
    }
    if (secret.length != 32) throw _Stop(SyncEnd.failed, tr('The other device did not follow the protocol'), peerId, peerName);
    final out = StreamController<Uint8List>();
    _handoff = out;
    for (final data in _raw) {
      out.add(data);
    }
    _raw.clear();
    _handedOver = true;
    unawaited(channel.closed.then((_) {
      if (!out.isClosed) out.close();
    }));
    return SyncOutcome(SyncEnd.done, peerId: peerId, peerName: peerName, live: LiveLink(note, peerId, _HandoffChannel(channel, out, _sub), secret));
  }

  /// How long the other device may be silent in the middle of the exchange (a connection that is cut without a word shows only so).
  static const silence = Duration(seconds: 90);

  Future<Map<String, Object?>> _nextAny() async {
    await _wait(silence);
    return _queue.removeAt(0);
  }

  /// A device that is not on the list: it can only come in if one side offered a link and the other came with it, and the person
  /// who offered it says yes after comparing the code. Returns whether a device was added.
  Future<bool> _pairing(String peerId, String peerName, String myNonce, String peerNonce, Uint8List peerKey, String binding) async {
    final code = secret.pairingCode(nonceA: myNonce, nonceB: peerNonce, publicKeyA: identity.publicKey, publicKeyB: peerKey, binding: binding);
    if (offer != null && join == null) {
      onProgress?.call(tr('A new device asks to join'), null);
      final yes = await offer!.approve(peerName, code);
      await book.add(PairedDevice(id: identity.id, name: deviceName, publicKey: identity.publicKey, addedAt: _nowIfNew(identity.id))); // (this device is on its own list)
      if (yes) {
        await book.add(PairedDevice(id: peerId, name: peerName, publicKey: peerKey, addedAt: DateTime.now().millisecondsSinceEpoch));
      }
      await _send({
        't': 'pair',
        'ok': yes,
        'profile': {'id': profile.id, 'name': profile.name},
        if (yes) 'devices': [for (final d in book.all) d.toJson()],
      });
      if (!yes) throw _Stop(SyncEnd.refused, tr('You did not let the new device in'), peerId, peerName);
      return true;
    }
    if (join != null && offer == null) {
      // the person here says whether the other device shows the same code; if not, nothing of that device is taken over
      final same = await join!.confirm(code);
      if (!same) throw _Stop(SyncEnd.refused, tr('The codes were not the same, so this device was not added'), peerId, peerName);
      final reply = await _next('pair', timeout: const Duration(minutes: 5));
      if (reply['ok'] != true) throw _Stop(SyncEnd.refused, tr('The other device did not let this one in'), peerId, peerName);
      final p = reply['profile'] as Map;
      await book.clear(); // the devices of an earlier profile are not part of this one
      await book.merge([for (final j in (reply['devices'] as List? ?? const [])) ?PairedDevice.fromJson(j)]);
      await join!.adopt(p['id'] as String, (p['name'] as String?) ?? '');
      return true;
    }
    throw _Stop(SyncEnd.refused, tr('This device is not one of this profile (add it with the link from a device of the profile)'), peerId, peerName);
  }

  static String _commit(String id, String nonce, String key) =>
      base64.encode(sha256.convert(utf8.encode('notation-commit-v1|$id|$nonce|$key')).bytes);

  int _nowIfNew(String id) => book.all.where((d) => d.id == id).firstOrNull?.addedAt ?? DateTime.now().millisecondsSinceEpoch;

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Stop implements Exception {
  final SyncEnd end;
  final String problem;
  final String? peerId, peerName;
  _Stop(this.end, this.problem, [this.peerId, this.peerName]);
}

/// The line of a meeting after it was handed to a live session: what arrives goes on to whoever listens, and closing it closes the line.
class _HandoffChannel implements PeerChannel {
  final PeerChannel _inner;
  final StreamController<Uint8List> _out;
  final StreamSubscription<Uint8List>? _sub;

  _HandoffChannel(this._inner, this._out, this._sub);

  @override
  Stream<Uint8List> get messages => _out.stream;

  @override
  Future<void> send(Uint8List message) => _inner.send(message);

  @override
  Future<String> binding() => _inner.binding();

  @override
  Future<void> get closed => _inner.closed;

  @override
  Future<void> close() async {
    await _sub?.cancel();
    if (!_out.isClosed) await _out.close();
    await _inner.close();
  }
}
