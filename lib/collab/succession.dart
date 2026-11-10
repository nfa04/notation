import 'link_stats.dart';
import 'roster.dart';

/// What one device measured on its link to another: the band, and whether the link goes through a relay.
class Observation {
  final LinkBand band;
  final bool relayed;
  const Observation(this.band, {this.relayed = false});
}

/// How a device is judged as a successor: the median of what the others measured on their links to it. What it says of itself does not
/// count, and a few devices that lie about it cannot move a median.
typedef Score = ({LinkBand band, bool relayed});

/// The host's choice of who takes over when it is lost, in this order (see [Roster.succession]).
///
/// - **Who may:** a member with a key that is here, whose links measure good or fair to the others (the median of their measurements:
///   [scoreOf]). Nothing a device says about its own connection counts; it can only make itself less likely (a web page).
/// - **In which order:** first the direct ones, then those reached through a relay (a relay's bandwidth is kept for whoever has no other
///   way); devices that are web pages last, and only while fewer than two others may. Within that, the longest in the session first: the
///   order is not by how good the links are, so claiming a good connection gets nobody to the front.
/// - **Not too often:** the list changes who is on it at most once in [hold], except to fill a place that became free (somebody left).
///   Whoever is on it stays until measured poor for [hold], and one that is merely not measured yet stays too.
/// - **What a device may say of itself:** only that it should not (a web page; low battery or a metered connection: `vetoed`).
class Succession {
  /// How long the list keeps who is on it, and how long one on it must be poor to be taken off.
  static Duration hold = const Duration(minutes: 10);

  /// The list as it was chosen last.
  List<String> get current => List.unmodifiable(_current);
  List<String> _current = const [];
  DateTime? _changedAt;
  final Map<String, DateTime> _poorSince = {};

  /// Devices that failed when they were to take over: not chosen again in this session.
  final Set<String> struck = {};

  /// When each device last said it should not take over (low battery, a metered connection).
  final Map<String, DateTime> _vetoedAt = {};

  /// Starts from a list that is held already (a roster made earlier).
  void adopt(List<String> list) => _current = List.of(list);

  /// The median of [observations], those that know anything; with two, the worse of them (a device that lies can then make another one
  /// look worse, never better). Relayed when at least half of those who know say so.
  static Score scoreOf(Iterable<Observation> observations) {
    final known = [for (final o in observations) if (o.band != LinkBand.unknown) o];
    if (known.isEmpty) return (band: LinkBand.unknown, relayed: observations.any((o) => o.relayed));
    final bands = [for (final o in known) o.band]..sort((a, b) => a.index.compareTo(b.index));
    final relayed = known.where((o) => o.relayed).length * 2 >= known.length;
    return (band: bands[bands.length ~/ 2], relayed: relayed);
  }

  /// Chooses the list. [members] in the order they came (the oldest first), [present] the sites that are connected now, [scores] what
  /// is measured of each, [vetoed] those that say they should not take over now (see `DeviceBudget`).
  ///
  /// A device that says so is taken off at once (what a device says of itself may only lower it), and may be chosen again only [hold]
  /// after it last said so: one whose battery hovers at the limit, or that says it on and off, does not change the list each time.
  List<String> choose(
      {required List<RosterMember> members,
      required Set<String> present,
      required Map<String, Score> scores,
      required DateTime now,
      Set<String> vetoed = const {}}) {
    for (final s in vetoed) {
      _vetoedAt[s] = now;
    }
    for (final m in members) {
      if (scores[m.site]?.band == LinkBand.poor) {
        _poorSince.putIfAbsent(m.site, () => now);
      } else {
        _poorSince.remove(m.site);
      }
    }
    final seniority = {for (var i = 0; i < members.length; i++) members[i].site: i};
    final byId = {for (final m in members) m.site: m};
    bool eligible(RosterMember m) {
      if (m.key == null || !present.contains(m.site) || struck.contains(m.site)) return false;
      final vetoed = _vetoedAt[m.site];
      if (vetoed != null && now.difference(vetoed) < hold) return false;
      final band = scores[m.site]?.band ?? LinkBand.unknown;
      if (band == LinkBand.good || band == LinkBand.fair) return true;
      if (!_current.contains(m.site)) return false;
      final poor = _poorSince[m.site];
      return poor == null || now.difference(poor) < hold;
    }

    int rank(String site) => (byId[site]!.web ? 2 : 0) + ((scores[site]?.relayed ?? false) ? 1 : 0);
    List<String> ordered(Iterable<String> sites) => sites.toList()
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : seniority[a]!.compareTo(seniority[b]!);
      });
    List<String> pick(Iterable<String> pool) {
      var list = ordered(pool);
      final others = [for (final s in list) if (!byId[s]!.web) s];
      if (others.length >= 2) list = others;
      return list.take(Roster.successors).toList();
    }

    final candidates = [for (final m in members) if (eligible(m)) m.site];
    final List<String> next;
    if (_changedAt == null || now.difference(_changedAt!) >= hold) {
      next = pick(candidates);
    } else {
      // between the times it may change: those on it stay, and only free places are filled
      final kept = [for (final s in _current) if (candidates.contains(s)) s];
      final fill = ordered(candidates.where((s) => !kept.contains(s))).take(Roster.successors - kept.length);
      next = pick([...kept, ...fill]);
    }
    if (next.toSet().length != _current.toSet().length || !next.toSet().containsAll(_current)) _changedAt = now;
    _current = next;
    return current;
  }
}
