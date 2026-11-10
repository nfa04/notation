import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// What a person needs to join a live session: where the signalling server is, and the secret
/// of the session. The secret is the only thing that opens what is sent; the server never sees it.
///
/// As a link: `notation://join?s=<server>&n=<who invites>#<secret>`. The secret is after the `#`, so
/// that it stays on the device (a web address never sends that part anywhere). A web address with
/// the same query and fragment (`https://example.org/join?...#...`) is read the same way.
class SessionInvite {
  /// The signalling server, `wss://host/path` or `ws://host:port`.
  final String server;
  final Uint8List secret;

  /// The name of whoever made the invite, for the person who is asked to join.
  final String? from;

  SessionInvite(this.server, this.secret, {this.from});

  static const secretBytes = 32;

  /// A new session on [server].
  factory SessionInvite.create(String server, {String? from, Random? random}) {
    final r = random ?? Random.secure();
    return SessionInvite(server, Uint8List.fromList([for (var i = 0; i < secretBytes; i++) r.nextInt(256)]), from: from);
  }

  // ---- keys: one secret, several uses that do not give each other away (HKDF, RFC 5869)

  static Uint8List _hkdf(Uint8List secret, String info, int length) {
    final prk = Hmac(sha256, utf8.encode('uninotes-session-v1')).convert(secret).bytes;
    final out = <int>[];
    var block = <int>[];
    for (var i = 1; out.length < length; i++) {
      block = Hmac(sha256, prk).convert([...block, ...utf8.encode(info), i]).bytes;
      out.addAll(block);
    }
    return Uint8List.fromList(out.sublist(0, length));
  }


  /// Another invite made from this one for [purpose]: on the same server, with a room and keys of its own. Every member can make it,
  /// nobody else (for the direct links between members, see [WarmNet]).
  SessionInvite derive(String purpose) => SessionInvite(server, _hkdf(secret, 'derive:$purpose', secretBytes));

  /// Names the session on the signalling server. It reveals nothing of the secret.
  String get room => _hkdf(secret, 'room', 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// The key that seals every message.
  Uint8List get messageKey => _hkdf(secret, 'messages', 32);

  Uint8List get _authKey => _hkdf(secret, 'verify', 32);

  /// Six digits that both sides of a join request can read out to each other. They come from the
  /// secret and from one random number from each side, so they are different every time.
  String verificationCode(String hostNonce, String joinerNonce) {
    final mac = Hmac(sha256, _authKey).convert(utf8.encode('$hostNonce|$joinerNonce')).bytes;
    final n = (mac[0] << 24 | mac[1] << 16 | mac[2] << 8 | mac[3]) & 0x7fffffff;
    final digits = (n % 1000000).toString().padLeft(6, '0');
    return '${digits.substring(0, 3)} ${digits.substring(3)}';
  }

  // ---- as a link

  String toLink() {
    final query = {'s': server, if (from != null && from!.isNotEmpty) 'n': from!};
    final secretText = base64Url.encode(secret).replaceAll('=', '');
    return '${Uri(scheme: 'notation', host: 'join', queryParameters: query)}#$secretText';
  }

  /// Reads a link (or text that has one in it); null if it is not an invite.
  static SessionInvite? parse(String text) {
    final match = RegExp(r'(notation://join[^\s]*|https?://[^\s]*/join[^\s]*#[^\s]+)').firstMatch(text.trim());
    if (match == null) return null;
    final Uri uri;
    try {
      uri = Uri.parse(match.group(0)!);
    } on FormatException {
      return null;
    }
    if (uri.scheme == 'notation' && uri.host != 'join') return null;
    final server = uri.queryParameters['s'];
    if (server == null || !(server.startsWith('ws://') || server.startsWith('wss://'))) return null;
    final fragment = uri.fragment;
    if (fragment.isEmpty) return null;
    try {
      final padded = fragment + '=' * ((4 - fragment.length % 4) % 4);
      final secret = base64Url.decode(padded);
      if (secret.length != secretBytes) return null;
      return SessionInvite(server, Uint8List.fromList(secret), from: uri.queryParameters['n']);
    } on FormatException {
      return null;
    }
  }
}
