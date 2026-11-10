import 'dart:convert';

import 'session_keys.dart';

/// A device that the host let in: its [site] and the [key] it registered ([SessionKeys.publicKeyText]; null for a device of an older
/// app, which has none: it is in the session but cannot be chosen for anything that needs a signature).
///
/// [web]: the device said it is a web page. That is taken as said (a device can only make itself less likely to be chosen by it): a tab
/// in a browser is slowed down or stopped when it is not in front, so it takes over only when nothing else can.
class RosterMember {
  final String site;
  final String? key;
  final bool web;
  const RosterMember(this.site, this.key, {this.web = false});

  List<Object?> toJson() => [site, key, if (web) 1];

  static RosterMember? fromJson(Object? j) {
    if (j is! List || j.length < 2 || j.length > 3 || j[0] is! String || (j[1] != null && j[1] is! String)) return null;
    if (j.length == 3 && j[2] != 1) return null;
    return RosterMember(j[0] as String, j[1] as String?, web: j.length == 3);
  }
}

/// Who is in a live session, as the host that let them in has signed it: the devices that were approved, with the key of each, and
/// which of them come next if the host is lost. Everything that has to be believed about who somebody is comes from here.
///
/// [epoch] counts the hosts the session has had (a new host takes the next number; the first is 1) and [rev] the changes the host made
/// within its time. The later (epoch, rev) is the newer roster.
class Roster {
  static const int maxMembers = 64;

  /// How many devices are named to take over, in this order.
  static const int successors = 3;

  final int epoch, rev;
  final String hostSite, hostKey;

  /// In the order they were let in (the oldest first). The host is not in it.
  final List<RosterMember> members;

  /// The sites that take over, in order: only devices with a key, never the host.
  final List<String> succession;
  final String signature;

  const Roster({required this.epoch, required this.rev, required this.hostSite, required this.hostKey, required this.members, required this.succession, required this.signature});

  /// What is signed. A list of lists (no maps), so that the same roster is always the same text, here and on every device.
  static List<int> bytesOf(int epoch, int rev, String hostSite, String hostKey, List<RosterMember> members, List<String> succession) =>
      utf8.encode(jsonEncode(['notation-roster-v1', epoch, rev, hostSite, hostKey, [for (final m in members) m.toJson()], succession]));

  /// The first of [members] with a key (the oldest first), at most [successors], to take over in this order. (What a host uses before it
  /// has measured anybody; see [Succession] for the real choice.)
  static List<String> successionOf(List<RosterMember> members, {String? except}) => [
        for (final m in members)
          if (m.key != null && m.site != except) m.site,
      ].take(successors).toList();

  /// A roster made and signed by the host with [keys].
  static Future<Roster> make({
    required SessionKeys keys,
    required int epoch,
    required int rev,
    required String hostSite,
    required List<RosterMember> members,
    List<String>? succession,
  }) async {
    final order = succession ?? successionOf(members, except: hostSite);
    final signature = await keys.signText(bytesOf(epoch, rev, hostSite, keys.publicKeyText, members, order));
    return Roster(epoch: epoch, rev: rev, hostSite: hostSite, hostKey: keys.publicKeyText, members: List.unmodifiable(members), succession: List.unmodifiable(order), signature: signature);
  }

  /// Whether the host's key ([hostKey]) signed exactly this. A roster that says another key is no more than a claim: whoever checks it
  /// also compares [hostKey] with the key it trusts for this session (see [signedBy]).
  Future<bool> verify() => SessionKeys.verifyText(hostKey, bytesOf(epoch, rev, hostSite, hostKey, members, succession), signature);

  /// Whether this roster is signed, and by [trusted], the host key that this device holds for the session.
  Future<bool> signedBy(String trusted) async => hostKey == trusted && await verify();

  RosterMember? member(String site) {
    for (final m in members) {
      if (m.site == site) return m;
    }
    return null;
  }

  /// Whether this is a later roster than [other] (a later host, or the same one with more changes).
  bool newerThan(Roster other) => epoch > other.epoch || (epoch == other.epoch && rev > other.rev);

  Map<String, Object?> toJson() => {
        'e': epoch,
        'r': rev,
        'h': hostSite,
        'k': hostKey,
        'm': [for (final m in members) m.toJson()],
        's': succession,
        'sig': signature,
      };

  /// The roster in [j], or null if it is not one (wrong shapes, too many members, a succession naming someone who is not a member or has no key).
  /// Its signature is not looked at here: see [verify].
  static Roster? fromJson(Object? j) {
    if (j is! Map) return null;
    final e = j['e'], r = j['r'], h = j['h'], k = j['k'], m = j['m'], s = j['s'], sig = j['sig'];
    if (e is! int || r is! int || e < 1 || r < 0 || h is! String || k is! String || sig is! String || m is! List || s is! List) return null;
    if (m.length > maxMembers || s.length > successors) return null;
    final members = <RosterMember>[];
    for (final x in m) {
      final member = RosterMember.fromJson(x);
      if (member == null || members.any((o) => o.site == member.site) || member.site == h) return null;
      members.add(member);
    }
    final succession = <String>[];
    for (final x in s) {
      if (x is! String || succession.contains(x)) return null;
      final member = members.where((o) => o.site == x).firstOrNull;
      if (member == null || member.key == null) return null;
      succession.add(x);
    }
    return Roster(epoch: e, rev: r, hostSite: h, hostKey: k, members: List.unmodifiable(members), succession: List.unmodifiable(succession), signature: sig);
  }
}
