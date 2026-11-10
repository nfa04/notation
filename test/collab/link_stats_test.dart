import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/link_stats.dart';
import 'package:notes/collab/transport.dart';

void main() {
  final t0 = DateTime(2026, 11, 9, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  /// [count] questions, each answered after [rtt] ms.
  void answer(LinkStats s, int count, int rtt, {bool data = false, int from = 0}) {
    for (var i = 0; i < count; i++) {
      final n = s.probe(at(from + i * 1000), data: data);
      s.answered(n, at(from + i * 1000 + rtt));
    }
  }

  test('nothing is known until a few answers came', () {
    final s = LinkStats();
    expect(s.band(t0), LinkBand.unknown);
    answer(s, 2, 30);
    expect(s.band(t0), LinkBand.unknown);
    answer(s, 1, 30, from: 5000);
    expect(s.band(t0), LinkBand.good);
    expect(s.median, const Duration(milliseconds: 30));
  });

  test('time to answer, its spread, and the slowest of it are measured from the answers', () {
    final s = LinkStats();
    for (final rtt in [20, 22, 21, 23, 20, 400, 21, 22]) {
      answer(s, 1, rtt, from: s.samples * 1000);
    }
    expect(s.median!.inMilliseconds, inInclusiveRange(21, 22));
    expect(s.jitter!.inMilliseconds, lessThan(5), reason: 'one slow answer is not jitter');
    expect(s.p95, const Duration(milliseconds: 400));
  });

  test('slow answers, lost questions and broken links make the band worse', () {
    final slow = LinkStats();
    answer(slow, 5, 300);
    expect(slow.band(t0), LinkBand.fair);
    final slower = LinkStats();
    answer(slower, 5, 900);
    expect(slower.band(t0), LinkBand.poor);

    final lossy = LinkStats();
    answer(lossy, 8, 30);
    for (var i = 0; i < 2; i++) {
      lossy.probe(at(20000 + i));
    }
    lossy.expire(at(60000), const Duration(seconds: 20));
    expect(lossy.loss, closeTo(0.2, 0.001));
    expect(lossy.band(t0), LinkBand.fair);
    for (var i = 0; i < 4; i++) {
      lossy.probe(at(70000 + i));
    }
    lossy.expire(at(120000), const Duration(seconds: 20));
    expect(lossy.band(t0), LinkBand.poor);

    final broken = LinkStats();
    answer(broken, 5, 30);
    expect(broken.band(t0), LinkBand.good);
    broken.dropped(t0);
    expect(broken.band(t0), LinkBand.fair, reason: 'a link that broke lately is not good');
    broken.dropped(t0);
    broken.dropped(t0);
    expect(broken.band(t0), LinkBand.poor);
    expect(broken.band(t0.add(const Duration(minutes: 11))), LinkBand.good, reason: 'it is forgiven with time');
    expect(broken.dropsTotal, 3);
  });

  test('a link that answers a tiny question at once but carries a bigger one slowly is not good', () {
    final s = LinkStats();
    answer(s, 5, 20);
    answer(s, 3, 1500, data: true, from: 10000);
    expect(s.band(t0), LinkBand.fair);
  });

  test('a question that was never asked, or was given up on, does not count when the answer comes', () {
    final s = LinkStats();
    s.answered(99, at(10));
    expect(s.samples, 0);
    final n = s.probe(t0);
    s.expire(at(30000), const Duration(seconds: 20));
    s.answered(n, at(31000));
    expect(s.samples, 0);
    expect(s.loss, 1);
  });

  test('nothing answered at all is poor, not unknown', () {
    final s = LinkStats();
    for (var i = 0; i < 4; i++) {
      s.probe(at(i * 1000));
    }
    s.expire(at(60000), const Duration(seconds: 20));
    expect(s.band(t0), LinkBand.poor);
  });

  test('a link through a relay is never better than fair, however well it answers', () {
    final direct = LinkStats()..route = LinkRoute.direct;
    final relayed = LinkStats()..route = LinkRoute.relayed;
    final unknown = LinkStats();
    for (final s in [direct, relayed, unknown]) {
      answer(s, 6, 10);
    }
    expect(direct.band(t0), LinkBand.good);
    expect(unknown.band(t0), LinkBand.good);
    expect(relayed.band(t0), LinkBand.fair);
    // and a relayed link that is bad is as bad as any
    final badRelayed = LinkStats()..route = LinkRoute.relayed;
    answer(badRelayed, 5, 900);
    expect(badRelayed.band(t0), LinkBand.poor);
  });

  test('whoever listens is told once when the band changes, not on every answer', () {
    final s = LinkStats();
    expect(s.bandChanged(t0), isFalse, reason: 'unknown is where it starts');
    answer(s, 3, 30);
    expect(s.bandChanged(t0), isTrue);
    expect(s.bandChanged(t0), isFalse);
    answer(s, 3, 30, from: 10000);
    expect(s.bandChanged(t0), isFalse);
    s.dropped(t0);
    expect(s.bandChanged(t0), isTrue);
    expect(s.reported, LinkBand.fair);
  });

  test('the times past which a link is fair or poor can be set, and loss and drops still count with lenient ones', () {
    final s = LinkStats();
    answer(s, 5, 900);
    expect(s.band(t0), LinkBand.poor);
    LinkStats.timing = LinkTiming.lenient;
    addTearDown(() => LinkStats.timing = const LinkTiming());
    expect(s.band(t0), LinkBand.good, reason: 'slow, but within the lenient times');
    s.dropped(t0);
    expect(s.band(t0), LinkBand.fair, reason: 'a drop still counts');
    LinkStats.timing = const LinkTiming(fairMedian: Duration(milliseconds: 10), poorMedian: Duration(milliseconds: 20));
    final quick = LinkStats();
    answer(quick, 5, 15);
    expect(quick.band(t0), LinkBand.fair, reason: 'stricter times');
  });

  test('a link gets worse at once, but better only by a margin: one at the edge does not flip with every answer', () {
    final s = LinkStats(window: 5);
    answer(s, 5, 300); // fair: slower than 250 ms
    expect(s.band(t0), LinkBand.fair);
    answer(s, 5, 240, from: 10000); // just under the limit
    expect(s.band(t0), LinkBand.fair, reason: 'just under the limit is not better yet');
    answer(s, 5, 160, from: 20000); // well under it (250 * 0.7 = 175)
    expect(s.band(t0), LinkBand.good);
    answer(s, 5, 240, from: 30000);
    expect(s.band(t0), LinkBand.good, reason: 'staying under the limit keeps it good');
    answer(s, 5, 260, from: 40000);
    expect(s.band(t0), LinkBand.fair, reason: 'worse at once');
  });

  test('the margin also holds for a link that comes back from poor', () {
    final s = LinkStats(window: 5);
    answer(s, 5, 900); // poor: slower than 800 ms
    expect(s.band(t0), LinkBand.poor);
    answer(s, 5, 700, from: 10000); // under 800, over 800 * 0.7
    expect(s.band(t0), LinkBand.poor);
    answer(s, 5, 500, from: 20000);
    expect(s.band(t0), LinkBand.fair, reason: 'better than poor by the margin; not yet good (500 > 175)');
    expect(s.band(t0), LinkBand.fair, reason: 'asking again changes nothing');
  });
}
