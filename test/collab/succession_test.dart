import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/link_stats.dart';
import 'package:notes/collab/roster.dart';
import 'package:notes/collab/succession.dart';

/// Who the host names to take over, on a clock of the test's own.
void main() {
  final t0 = DateTime(2026, 11, 9, 12);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));
  const good = (band: LinkBand.good, relayed: false);
  const fair = (band: LinkBand.fair, relayed: false);
  const poor = (band: LinkBand.poor, relayed: false);
  const unknown = (band: LinkBand.unknown, relayed: false);
  const relayed = (band: LinkBand.fair, relayed: true);

  List<RosterMember> roster(String sites, {String web = ''}) => [for (final s in sites.split('')) RosterMember(s, 'key-$s', web: web.contains(s))];
  Set<String> all(String sites) => sites.split('').toSet();

  setUp(() => Succession.hold = const Duration(minutes: 10));

  group('the score: what the others measured', () {
    test('the median of those that know anything', () {
      expect(Succession.scoreOf(const [Observation(LinkBand.good), Observation(LinkBand.good), Observation(LinkBand.poor)]).band, LinkBand.good,
          reason: 'one that lies (or is far away) does not move it');
      expect(Succession.scoreOf(const [Observation(LinkBand.poor), Observation(LinkBand.poor), Observation(LinkBand.good)]).band, LinkBand.poor);
      expect(Succession.scoreOf(const [Observation(LinkBand.good), Observation(LinkBand.unknown), Observation(LinkBand.unknown)]).band, LinkBand.good,
          reason: 'those that do not know do not count');
      expect(Succession.scoreOf(const []).band, LinkBand.unknown);
    });

    test('with two, the worse of them: a liar can make another look worse, never better', () {
      expect(Succession.scoreOf(const [Observation(LinkBand.good), Observation(LinkBand.poor)]).band, LinkBand.poor);
      expect(Succession.scoreOf(const [Observation(LinkBand.poor), Observation(LinkBand.good)]).band, LinkBand.poor);
    });

    test('relayed when at least half of those that know say so', () {
      expect(Succession.scoreOf(const [Observation(LinkBand.fair, relayed: true), Observation(LinkBand.good)]).relayed, isTrue);
      expect(Succession.scoreOf(const [Observation(LinkBand.fair, relayed: true), Observation(LinkBand.good), Observation(LinkBand.good)]).relayed, isFalse);
    });
  });

  group('who is named', () {
    test('by seniority among those that measure good or fair, at most three; not by how good they are', () {
      final s = Succession();
      final list = s.choose(members: roster('abcde'), present: all('abcde'), scores: {'a': fair, 'b': good, 'c': good, 'd': good, 'e': good}, now: t0);
      expect(list, ['a', 'b', 'c'], reason: 'a fair one that came first comes before good ones that came later');
    });

    test('nobody that is not measured yet, is poor, is away, or has no key', () {
      final s = Succession();
      final members = [...roster('abcd'), const RosterMember('e', null)];
      final list = s.choose(members: members, present: all('abce'), scores: {'a': unknown, 'b': poor, 'c': good, 'd': good, 'e': good}, now: t0);
      expect(list, ['c']);
    });

    test('direct ones before those reached through a relay, whatever their seniority', () {
      final s = Succession();
      final list = s.choose(members: roster('abcd'), present: all('abcd'), scores: {'a': relayed, 'b': fair, 'c': relayed, 'd': good}, now: t0);
      expect(list, ['b', 'd', 'a']);
    });

    test('a web page only while fewer than two others may', () {
      final s = Succession();
      expect(s.choose(members: roster('abc', web: 'a'), present: all('abc'), scores: {'a': good, 'b': good, 'c': good}, now: t0), ['b', 'c'],
          reason: 'two others: no web page at all, though there is room');
      final t = Succession();
      expect(t.choose(members: roster('abc', web: 'a'), present: all('abc'), scores: {'a': good, 'b': good, 'c': poor}, now: t0), ['b', 'a'],
          reason: 'only one other: the web page after it');
      final u = Succession();
      expect(u.choose(members: roster('abc', web: 'a'), present: all('abc'), scores: {'a': good, 'b': relayed, 'c': relayed}, now: t0), ['b', 'c'],
          reason: 'relayed apps still before a web page');
    });

    test('one that failed when it was to take over is not named again', () {
      final s = Succession()..struck.add('a');
      expect(s.choose(members: roster('abc'), present: all('abc'), scores: {'a': good, 'b': good, 'c': good}, now: t0), ['b', 'c']);
    });
  });

  group('a device that says it should not (low battery, metered)', () {
    test('is taken off at once, though the list may not change yet, and the place is filled', () {
      final s = Succession();
      final m = roster('abcd');
      final good4 = {'a': good, 'b': good, 'c': good, 'd': good};
      expect(s.choose(members: m, present: all('abcd'), scores: good4, now: at(0)), ['a', 'b', 'c']);
      expect(s.choose(members: m, present: all('abcd'), scores: good4, now: at(1), vetoed: {'a'}), ['b', 'c', 'd']);
    });

    test('comes back only a while after it last said so, when the list may change', () {
      final s = Succession();
      final m = roster('abcd');
      final good4 = {'a': good, 'b': good, 'c': good, 'd': good};
      s.choose(members: m, present: all('abcd'), scores: good4, now: at(0), vetoed: {'a'});
      s.choose(members: m, present: all('abcd'), scores: good4, now: at(4), vetoed: {'a'});
      expect(s.choose(members: m, present: all('abcd'), scores: good4, now: at(12)), ['b', 'c', 'd'], reason: 'said so last 8 minutes ago');
      expect(s.choose(members: m, present: all('abcd'), scores: good4, now: at(15)), ['a', 'b', 'c']);
    });

    test('is not named even when nobody else may', () {
      final s = Succession();
      expect(s.choose(members: roster('ab'), present: all('ab'), scores: {'a': good, 'b': poor}, now: t0, vetoed: {'a'}), isEmpty);
    });
  });

  group('not too often', () {
    test('one on the list stays while it is poor, for a while; then the next takes its place', () {
      final s = Succession();
      final m = roster('abcd');
      expect(s.choose(members: m, present: all('abcd'), scores: {'a': good, 'b': good, 'c': good, 'd': good}, now: at(0)), ['a', 'b', 'c']);
      expect(s.choose(members: m, present: all('abcd'), scores: {'a': poor, 'b': good, 'c': good, 'd': good}, now: at(1)), ['a', 'b', 'c']);
      expect(s.choose(members: m, present: all('abcd'), scores: {'a': poor, 'b': good, 'c': good, 'd': good}, now: at(10)), ['a', 'b', 'c'],
          reason: 'poor for 9 minutes');
      expect(s.choose(members: m, present: all('abcd'), scores: {'a': poor, 'b': good, 'c': good, 'd': good}, now: at(12)), ['b', 'c', 'd'],
          reason: 'poor for 11 minutes, and the list has not changed for 12');
    });

    test('one that gets better meanwhile starts over', () {
      final s = Succession();
      final m = roster('abcd');
      final good4 = {'a': good, 'b': good, 'c': good, 'd': good};
      s.choose(members: m, present: all('abcd'), scores: good4, now: at(0));
      s.choose(members: m, present: all('abcd'), scores: {...good4, 'a': poor}, now: at(1));
      s.choose(members: m, present: all('abcd'), scores: good4, now: at(8));
      expect(s.choose(members: m, present: all('abcd'), scores: {...good4, 'a': poor}, now: at(12)), ['a', 'b', 'c'], reason: 'poor again only since minute 12');
    });

    test('a place that becomes free is filled at once', () {
      final s = Succession();
      final m = roster('abcd');
      final good4 = {'a': good, 'b': good, 'c': good, 'd': good};
      expect(s.choose(members: m, present: all('abcd'), scores: good4, now: at(0)), ['a', 'b', 'c']);
      expect(s.choose(members: m, present: all('bcd'), scores: good4, now: at(1)), ['b', 'c', 'd'], reason: 'a left');
    });

    test('a better choice that is not a free place waits until the list may change', () {
      final s = Succession();
      final m = roster('abcd');
      final scores = {'a': good, 'b': relayed, 'c': relayed, 'd': relayed};
      expect(s.choose(members: m, present: all('abcd'), scores: scores, now: at(0)), ['a', 'b', 'c']);
      final direct = {...scores, 'd': good};
      expect(s.choose(members: m, present: all('abcd'), scores: direct, now: at(3)), ['a', 'b', 'c'], reason: 'who is on it does not change yet');
      expect(s.choose(members: m, present: all('abcd'), scores: direct, now: at(11)), ['a', 'd', 'b'], reason: 'the direct one comes in, before the relayed');
    });

    test('one that is not measured any more (no answers yet on a new link) stays on it', () {
      final s = Succession();
      final m = roster('abc');
      s.choose(members: m, present: all('abc'), scores: {'a': good, 'b': good, 'c': good}, now: at(0));
      expect(s.choose(members: m, present: all('abc'), scores: {'a': unknown, 'b': good, 'c': good}, now: at(30)), ['a', 'b', 'c']);
    });
  });
}
