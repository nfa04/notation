import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/models/canvas_models.dart';

// ---- a network that misbehaves

/// A guest's way to the host: it can be down (no new connection), silent (messages are taken in both directions and nobody is told),
/// and cut (the links are closed, as when the phone changes from wifi to mobile data).
class Link implements JoinTransport {
  final LoopbackHub hub;
  final Random random;
  bool down = false;
  bool silent = false;

  /// Reported as going through a relay.
  bool relayed = false;

  /// The link watches itself, as a WebRTC connection does: it measures its own questions and answers, and closes itself after
  /// [watchDeadAfter] questions in a row went unanswered (both ends: they lose each other's answers when either way is broken).
  bool watched = false;
  int watchDeadAfter = 5;
  Duration watchEvery = const Duration(milliseconds: 50);

  /// Whether a question of either end gets its answer now.
  bool get answers => !silent && !deaf && !mute;

  /// Messages are taken away on the way to this guest only (it hears nothing) or on the way from it only (nobody hears it).
  bool deaf = false, mute = false;
  final List<PeerChannel> _open = [];
  int connects = 0;

  /// The guest whose link is being made right now.
  static Link? connecting;

  Link(this.hub, this.random);

  @override
  void Function(String stage)? onStage;

  @override
  Future<PeerChannel> connect() async {
    if (down) throw StateError('no network');
    // (the host's end of this link is made inside this call, and asks who is connecting: both ends of a real link see the same route)
    connecting = this;
    final PeerChannel inner;
    try {
      inner = await hub.guest.connect();
    } finally {
      connecting = null;
    }
    connects++;
    final c = SlowChannel(inner, this, 12);
    _open.add(c);
    return c;
  }

  /// Closes every link of this guest.
  Future<void> cut() async {
    for (final c in List.of(_open)) {
      await c.close();
    }
    _open.clear();
  }
}

/// A link that is slow by a few milliseconds, differently for each message (the order stays), and that can be made silent.
class SlowChannel implements PeerChannel, RoutedChannel, WatchedChannel {
  final PeerChannel inner;
  final Link? link;
  final int ms;
  SlowChannel(this.inner, this.link, this.ms) {
    unawaited(inner.closed.then((_) => _stopWatch()));
  }

  /// The guest's link this channel is an end of (for the host's end: the one it was made for).
  Link? get guest => link is _HostSide ? (link as _HostSide).of : link;

  @override
  bool get watching => guest?.watched ?? false;

  StreamController<Duration?>? _trips;
  Timer? _watchTimer;
  int _unanswered = 0;

  @override
  Stream<Duration?> get roundTrips {
    final c = _trips ??= StreamController<Duration?>.broadcast();
    _watchTimer ??= Timer.periodic(guest?.watchEvery ?? const Duration(milliseconds: 50), (_) {
      final g = guest;
      if (g == null || c.isClosed) return;
      if (g.answers) {
        _unanswered = 0;
        c.add(Duration(milliseconds: 5 + g.random.nextInt(15)));
      } else {
        c.add(null);
        if (++_unanswered >= g.watchDeadAfter) unawaited(close()); // (the connection gives the link up by itself)
      }
    });
    return c.stream;
  }

  void _stopWatch() {
    _watchTimer?.cancel();
    unawaited(_trips?.close());
  }

  @override
  Stream<Uint8List> get messages => inner.messages.where((_) => !((link?.silent ?? false) || (link?.deaf ?? false)));

  @override
  Future<void> send(Uint8List message) async {
    final r = (link?.random ?? Random(1)).nextInt(ms + 1);
    if (r > 0) await Future<void>.delayed(Duration(milliseconds: r));
    if ((link?.silent ?? false) || (link?.mute ?? false)) return;
    await inner.send(message);
  }

  @override
  Future<LinkRoute> route() async => (link?.relayed ?? false) ? LinkRoute.relayed : LinkRoute.direct;

  @override
  Future<String> binding() => inner.binding();

  @override
  Future<void> get closed => inner.closed;

  @override
  Future<void> close() {
    _stopWatch();
    return inner.close();
  }
}

class SlowHost implements HostTransport {
  final HostTransport inner;
  final Random random;
  SlowHost(this.inner, this.random);

  @override
  void Function(String event)? onEvent;

  @override
  Stream<PeerChannel> get incoming => inner.incoming.map((c) => SlowChannel(c, _HostSide(random, Link.connecting)..relayed = Link.connecting?.relayed ?? false, 8));

  @override
  void wake() {}

  @override
  Future<void> close() => inner.close();
}

/// (only to give the host's side of a link the random numbers: it is never silent by itself)
class _HostSide extends Link {
  final Link? of;
  _HostSide(Random random, this.of) : super(LoopbackHub(), random);
}


// ---- people

class Screen {
  final NoteData note = NoteData(id: 'n');
  final Directory dir;
  int redraws = 0;
  late final CollabBinding binding;
  Screen(this.dir) {
    binding = CollabBinding(
      note: () => note,
      change: (f) {
        f();
        redraws++;
      },
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: (id, bytes, ext) => (File('${dir.path}/$id.$ext')..writeAsBytesSync(bytes)).path,
      onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
    );
  }

  Set<String> get strokeIds => {for (final l in note.strokes.values) for (final s in l) s.id};

  int _drawn = 0;

  /// Draws one stroke on [page], the way an editor does (into the note, then tells the session).
  String draw(String who, int page, {double y = 10}) {
    final id = '$who-${_drawn++}';
    (note.strokes[page] ??= []).add(DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]));
    return id;
  }
}

class Member {
  final String name;
  final Link link;
  final Screen screen;
  late final CollabSession session;
  final List<String> drawn = [];
  Member(this.name, this.link, this.screen);

  String draw(int page, {double y = 10}) {
    final id = screen.draw(name, page, y: y);
    drawn.add(id);
    session.localChanged();
    return id;
  }
}

String uidOf(int i) => (i + 1).toString().padLeft(16, '0');

/// [what] is a text or a function that makes it (when it depends on how things stand when the wait is given up).
Future<void> waitUntil(bool Function() ok, Object what, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('gave up waiting for: ${what is String Function() ? what() : what}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

