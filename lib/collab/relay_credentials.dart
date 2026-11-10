import 'dart:async';

/// What a signalling server answers to the request `{"s":"ice"}`: the servers of a relay (TURN) for connections that cannot be made
/// directly, with the time they work for - or why there are none (`unconfigured`: this server has no relay; `limit`: its budget is
/// used up; `unavailable`; `busy`: too many asked for).
class IceReply {
  final List<Map<String, Object>> servers;
  final Duration ttl;
  final String? none;

  const IceReply({this.servers = const [], this.ttl = Duration.zero, this.none});

  static IceReply? parse(Map<Object?, Object?> m) {
    if (m['s'] != 'ice') return null;
    final out = <Map<String, Object>>[];
    for (final s in (m['servers'] is List ? m['servers'] as List : const [])) {
      if (s is! Map) continue;
      final urls = s['urls'];
      final list = urls is List ? [for (final u in urls) if (u is String) u] : (urls is String ? [urls] : <String>[]);
      if (list.isEmpty) continue;
      out.add({
        'urls': list,
        if (s['username'] is String) 'username': s['username'] as String,
        if (s['credential'] is String) 'credential': s['credential'] as String,
      });
    }
    final ttl = m['ttl'];
    return IceReply(servers: out, ttl: Duration(seconds: ttl is num ? ttl.toInt() : 0), none: m['none'] is String ? m['none'] as String : (out.isEmpty ? 'unavailable' : null));
  }
}

/// The relay servers that a signalling server hands out, asked for once and kept for as long as they work. What a server says it has
/// none of is not asked again for a while (an old server that does not know the question does not answer: that is asked about once in
/// half an hour, so that it does not slow every connection down).
class RelayCredentials {
  static final Map<String, _Entry> _cache = {};
  static final Map<String, Future<List<Map<String, Object>>>> _asking = {};

  /// How long before a credential ends a new one is asked for.
  static const renewBefore = Duration(minutes: 15);

  /// How long "no relay here" is believed, by the reason.
  static Duration _believedFor(String? none) => switch (none) {
        'unconfigured' => const Duration(hours: 6),
        null => const Duration(minutes: 30), // (no answer at all)
        _ => const Duration(minutes: 10),
      };

  /// The relay servers to add to the others for connections through [server]: none, when there is no relay. [ask] makes the request
  /// on a connection to the server and gives its answer (null: none came).
  static Future<List<Map<String, Object>>> forServer(String server, Future<IceReply?> Function() ask, {DateTime Function()? now}) {
    final clock = now ?? DateTime.now;
    final known = _cache[server];
    if (known != null && clock().isBefore(known.until)) return Future.value(known.servers);
    return _asking[server] ??= () async {
      try {
        final reply = await ask();
        final at = clock();
        if (reply != null && reply.servers.isNotEmpty) {
          // asked for again a little before the end, but not at once when it works for a short time only
          final keep = reply.ttl > renewBefore * 2 ? reply.ttl - renewBefore : reply.ttl ~/ 2;
          _cache[server] = _Entry(reply.servers, at.add(keep));
          return reply.servers;
        }
        _cache[server] = _Entry(const [], at.add(_believedFor(reply?.none)));
        return const <Map<String, Object>>[];
      } catch (_) {
        return const <Map<String, Object>>[]; // (not asked again at once is not worth a rule: the next connection asks)
      } finally {
        _asking.remove(server);
      }
    }();
  }

  /// For tests: forget everything.
  static void forgetAll() {
    _cache.clear();
    _asking.clear();
  }
}

class _Entry {
  final List<Map<String, Object>> servers;
  final DateTime until;
  const _Entry(this.servers, this.until);
}

/// The requests for relay servers that are waiting for the answer of a signalling server (it answers `{"s":"ice"}` to the device that
/// asked, and the answer carries nothing to tell which request it is for, so it goes to all that wait).
class IceRequests {
  final List<Completer<IceReply?>> _waiting = [];

  /// Asks with [send] (which says whether the request could be sent); null: no answer, or no connection to ask on.
  Future<IceReply?> ask(bool Function(String frame) send, {Duration timeout = const Duration(seconds: 3)}) {
    final answer = Completer<IceReply?>();
    _waiting.add(answer);
    if (!send('{"s":"ice"}')) {
      _waiting.remove(answer);
      return Future.value(null);
    }
    return answer.future.timeout(timeout, onTimeout: () {
      _waiting.remove(answer);
      return null;
    });
  }

  /// The server answered.
  void answered(IceReply? reply) {
    for (final c in _waiting.toList()) {
      if (!c.isCompleted) c.complete(reply);
    }
    _waiting.clear();
  }
}
