import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/graph/graph_model.dart';

import '../cloudsync/memory_cloud_folder.dart';
import 'harness.dart';

String _picture(String label, {String mode = 'facts'}) => KnowledgeGraph(
      mode: mode,
      builtAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      nodes: [
        GraphNode(id: 'f1', kind: GraphNodeKind.fact, label: label, detail: 'A sentence.', noteId: 'n1', page: 2, tag: 'Fact', cluster: 0, x: 1, y: 2),
        GraphNode(id: 'f2', kind: GraphNodeKind.fact, label: 'Other', cluster: 0, x: 5, y: 6),
      ],
      edges: const [GraphEdge(0, 1, 0.8, GraphEdgeKind.similar)],
      clusters: const [GraphCluster(0, 'things', 2)],
    ).encode();

Future<void> _later() => Future<void>.delayed(const Duration(milliseconds: 5)); // (the sync tells "newer" by the millisecond)

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late SyncSecret secret;
  late String room;
  late Device a, b;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('graphsync_');
    secret = SyncSecret.create(Random(3));
    room = (await secret.roomKeys()).room;
    a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Tablet', root, profileId: 'aaaaaaaaaaaaaaaa');
    for (final d in [a, b]) {
      for (final other in [a, b]) {
        await d.book.add(PairedDevice(id: other.identity.id, name: other.name, publicKey: other.identity.publicKey, addedAt: 1));
      }
    }
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
    await root.delete(recursive: true);
  });

  Future<void> meet() async {
    final (c1, c2) = await pipe();
    final r = await Future.wait([a.session(c1, secret, room).run(), b.session(c2, secret, room).run()]);
    expect(r[0].ok && r[1].ok, isTrue, reason: '${r[0].problem} ${r[1].problem}');
  }

  Future<int> save(Device d, String name, String picture, {String mode = 'facts', String? folder, int? replace}) =>
      d.repo.knowledge.saveGraph(name: name, mode: mode, folderId: folder, payload: picture, replace: replace);

  Future<Map<String, String>> names(Device d) async => {for (final g in await d.repo.knowledge.listGraphs()) g.uid: g.name};

  /// What the two devices do with graphs, whichever way they meet: [sync] makes them meet.
  Future<void> story(Future<void> Function() sync) async {
    final id = await save(a, 'Facts: All notes', _picture('First'), folder: null);
    await sync();
    final onB = (await b.repo.knowledge.listGraphs()).single;
    final onA = (await a.repo.knowledge.listGraphs()).single;
    expect(onB.uid, onA.uid, reason: 'a graph goes by the same name on every device');
    expect(onB.name, 'Facts: All notes');
    expect(onB.mode, 'facts');
    expect(KnowledgeGraph.decode((await b.repo.knowledge.loadGraph(onB.id))!)!.nodes.first.label, 'First');

    // renamed on the tablet: the laptop follows, and the picture is the same
    await _later();
    await b.repo.knowledge.renameGraph(onB.id, 'Exam facts');
    await sync();
    expect((await a.repo.knowledge.listGraphs()).single.name, 'Exam facts');

    // made again on the laptop (a new picture, in a folder): the tablet gets the newer one, with the name it has
    await _later();
    await save(a, 'ignored', _picture('Second'), folder: 'f1', replace: id);
    await sync();
    final again = (await b.repo.knowledge.listGraphs()).single;
    expect(again.name, 'Exam facts');
    expect(again.folderId, 'f1');
    expect(KnowledgeGraph.decode((await b.repo.knowledge.loadGraph(again.id))!)!.nodes.first.label, 'Second');

    // two graphs made on two devices at once are two tabs on both
    await save(a, 'From the laptop', _picture('L'));
    await save(b, 'From the tablet', _picture('T', mode: 'notes'), mode: 'notes');
    await sync();
    await sync();
    expect((await names(a)).values.toSet(), {'Exam facts', 'From the laptop', 'From the tablet'});
    expect(await names(a), await names(b));

    // removed on the tablet: gone from the laptop, and it does not come back
    await _later();
    await b.repo.knowledge.deleteGraph(again.id);
    await sync();
    await sync();
    expect((await names(a)).values.toSet(), {'From the laptop', 'From the tablet'});
    expect(await names(a), await names(b));
  }

  test('graphs go between two devices that meet: made, renamed, made again, removed', () async {
    await story(meet);
  });

  for (final encrypted in [true, false]) {
    test('graphs go through a cloud folder (${encrypted ? 'sealed' : 'plain'}): made, renamed, made again, removed', () async {
      final cloud = MemoryCloudFolder();
      Future<void> run(Device d) async {
        final r = await FolderSync(
          folder: cloud,
          library: d.library,
          book: d.book,
          settings: d.settings,
          deviceId: d.identity.id,
          deviceName: d.name,
          key: secret.cloudKey,
          encrypted: encrypted,
        ).run();
        expect(r.problems, isEmpty);
      }

      // (each publishes, then reads what the other published, and publishes what it took)
      await story(() async {
        await run(a);
        await run(b);
        await run(a);
      });
    });
  }

  test('a picture that cannot be read, or that is not of the kind the line says, is not taken over', () async {
    final g = SyncGraph('abc', 'Odd', 'facts', null, 1, 2);
    await a.library.applyGraph(g, 'not a graph');
    await a.library.applyGraph(g, _picture('x', mode: 'notes'));
    expect(await a.repo.knowledge.listGraphs(), isEmpty);
    await a.library.applyGraph(g, _picture('x'));
    expect((await a.repo.knowledge.listGraphs()).single.name, 'Odd');
  });

  test('the manifest carries the graphs, and the manifest of an older device has none', () async {
    await save(a, 'Mine', _picture('x'));
    final manifest = await a.library.manifest();
    expect(manifest.graphs, hasLength(1));
    expect(SyncManifest.fromJson(manifest.toJson()).graphs.single.name, 'Mine');
    expect(SyncManifest.fromJson(const {}).graphs, isEmpty, reason: 'an older device says nothing of graphs');
  });
}
