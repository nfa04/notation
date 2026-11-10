import 'sync_keys.dart';

/// What the link that adds a device to a profile holds: where the signalling server is, the secret of the profile
/// ([SyncSecret], after the `#`, so it stays on the devices), and - to be shown to the person who opens it - the name of the
/// profile.
///
/// `notation://sync?s=<server>&n=<name>#<secret>`
class SyncLink {
  final String server;
  final SyncSecret secret;

  /// The name of the person whose profile it is, for the one who is asked to join.
  final String? from;

  const SyncLink(this.server, this.secret, {this.from});

  String toLink() {
    final query = {'s': server, if (from != null && from!.isNotEmpty) 'n': from!};
    return '${Uri(scheme: 'notation', host: 'sync', queryParameters: query)}#${secret.toText()}';
  }

  /// Reads a link (or text that has one in it); null if it is not one.
  static SyncLink? parse(String text) {
    final match = RegExp(r'notation://sync[^\s]*').firstMatch(text.trim());
    if (match == null) return null;
    final Uri uri;
    try {
      uri = Uri.parse(match.group(0)!);
    } on FormatException {
      return null;
    }
    if (uri.host != 'sync') return null;
    final server = uri.queryParameters['s'];
    if (server == null || !(server.startsWith('ws://') || server.startsWith('wss://'))) return null;
    final secret = SyncSecret.fromText(uri.fragment);
    if (secret == null) return null;
    return SyncLink(server, secret, from: uri.queryParameters['n']);
  }
}

/// What the web version shows as a QR code when it is used for a while only ("Connect temporarily"): where the signalling server
/// is and a secret made for this one visit (after the `#`, as in [SyncLink]). A device that already has a profile reads it, goes into
/// the room of that secret and hands the browser a [SyncLink] there, sealed with it - the browser never sees the profile's secret
/// unless the person scanned its code and then says yes to the code the two show.
///
/// `notation://connect?s=<server>#<secret>`
class ConnectLink {
  final String server;
  final SyncSecret secret;

  const ConnectLink(this.server, this.secret);

  String toLink() => '${Uri(scheme: 'notation', host: 'connect', queryParameters: {'s': server})}#${secret.toText()}';

  static ConnectLink? parse(String text) {
    final match = RegExp(r'notation://connect[^\s]*').firstMatch(text.trim());
    if (match == null) return null;
    final Uri uri;
    try {
      uri = Uri.parse(match.group(0)!);
    } on FormatException {
      return null;
    }
    if (uri.host != 'connect') return null;
    final server = uri.queryParameters['s'];
    if (server == null || !(server.startsWith('ws://') || server.startsWith('wss://'))) return null;
    final secret = SyncSecret.fromText(uri.fragment);
    if (secret == null) return null;
    return ConnectLink(server, secret);
  }
}
