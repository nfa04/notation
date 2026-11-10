import 'dart:typed_data';

import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/nativeshare/native_share_provider.dart';

import '../cloudsync/memory_cloud_folder.dart';

/// A cloud service in memory with several people on it, for tests of sharing: each user has folders, shares given to others show up for
/// them, and a share that is read-only refuses writes, as a real service does.
class FakeShareHub {
  /// The files of every folder that was shared, by `owner/place`.
  final Map<String, MemoryCloudFolder> folders = {};

  /// Who has what: `owner/place` -> user -> (role, the name it appears under for that user, accepted).
  final Map<String, Map<String, ({ShareRole role, String as, bool accepted, String id})>> grants = {};

  /// Every user on the service, by id and name shown.
  final Map<String, String> people = {'alice': 'Alice', 'bob': 'Bob', 'carol': 'Carol'};
  int _next = 1;

  /// Whether a share needs accepting before its files can be reached (some services).
  bool needsAccepting = false;

  /// The service refuses everything (it is down).
  bool down = false;

  FakeShareProvider as(String user) => FakeShareProvider(this, user);

  MemoryCloudFolder folderOf(String owner, String place) => folders.putIfAbsent('$owner/$place', () => MemoryCloudFolder());
}

class FakeShareProvider extends NativeShareProvider {
  final FakeShareHub hub;
  final String user;

  FakeShareProvider(this.hub, this.user);

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  bool get available => true;

  @override
  Future<List<SharePerson>> searchPeople(String query) async => [
        for (final e in hub.people.entries)
          if (e.key != user && (e.key.startsWith(query.toLowerCase()) || e.value.toLowerCase().startsWith(query.toLowerCase()))) SharePerson(e.key, e.value),
      ];

  void _up() {
    if (hub.down) throw const NativeShareException('The service is down.');
  }

  @override
  Future<ProviderShare> share(String place, SharePerson person, ShareRole role) async {
    _up();
    final key = '$user/$place';
    if (!hub.people.containsKey(person.id)) throw const NativeShareException('No such user.');
    final g = hub.grants.putIfAbsent(key, () => {});
    final id = g[person.id]?.id ?? 'sh${hub._next++}';
    g[person.id] = (role: role, as: place.split('/').last, accepted: !hub.needsAccepting, id: id);
    return ProviderShare(id, person, role);
  }

  @override
  Future<List<ProviderShare>> sharesOf(String place) async {
    _up();
    return [
      for (final e in (hub.grants['$user/$place'] ?? const {}).entries) ProviderShare(e.value.id, SharePerson(e.key, hub.people[e.key] ?? e.key), e.value.role),
    ];
  }

  @override
  Future<void> changeRole(ProviderShare share, ShareRole role) async {
    _up();
    for (final g in hub.grants.values) {
      for (final e in g.entries) {
        if (e.value.id == share.id) g[e.key] = (role: role, as: e.value.as, accepted: e.value.accepted, id: e.value.id);
      }
    }
  }

  @override
  Future<void> unshare(ProviderShare share) async {
    _up();
    for (final g in hub.grants.values) {
      g.removeWhere((_, v) => v.id == share.id);
    }
  }

  @override
  Future<void> removeFolder(String place) async {
    _up();
    hub.grants.remove('$user/$place');
    hub.folders.remove('$user/$place');
  }

  @override
  Future<List<IncomingShare>> incoming() async {
    _up();
    return [
      for (final e in hub.grants.entries)
        if (e.value[user] != null)
          IncomingShare(
            id: e.value[user]!.id,
            name: e.value[user]!.as,
            owner: hub.people[e.key.split('/').first] ?? '',
            role: e.value[user]!.role,
            pending: !e.value[user]!.accepted,
            place: e.value[user]!.accepted ? '${e.key.split('/').first}@${e.key.substring(e.key.indexOf('/') + 1)}' : '',
          ),
    ];
  }

  @override
  Future<IncomingShare> accept(IncomingShare share) async {
    _up();
    for (final g in hub.grants.values) {
      final mine = g[user];
      if (mine != null && mine.id == share.id) g[user] = (role: mine.role, as: mine.as, accepted: true, id: mine.id);
    }
    return (await incoming()).firstWhere((s) => s.id == share.id);
  }

  @override
  Future<void> leave(IncomingShare share) async {
    _up();
    for (final g in hub.grants.values) {
      g.removeWhere((k, v) => k == user && v.id == share.id);
    }
  }

  @override
  CloudFolder folderAt(String place) {
    // my own folder, or `owner@place` for one shared with me
    final at = place.indexOf('@');
    if (at < 0) return _Guarded(hub, hub.folderOf(user, place), canWrite: () => true);
    final owner = place.substring(0, at), path = place.substring(at + 1);
    return _Guarded(hub, hub.folderOf(owner, path), canWrite: () => hub.grants['$owner/$path']?[user]?.role == ShareRole.editor, canRead: () => hub.grants['$owner/$path']?[user]?.accepted == true);
  }
}

/// A folder as a user is allowed to use it.
class _Guarded implements CloudFolder {
  final FakeShareHub hub;
  final MemoryCloudFolder inner;
  final bool Function() canWrite;
  final bool Function() canRead;

  _Guarded(this.hub, this.inner, {required this.canWrite, bool Function()? canRead}) : canRead = canRead ?? (() => true);

  void _check({required bool write}) {
    if (hub.down) throw const CloudFolderException('The service is down.', 503);
    if (!canRead()) throw const CloudFolderException('No access.', 403);
    if (write && !canWrite()) throw const CloudFolderException('This share is read-only.', 403);
  }

  @override
  String get label => 'Fake';

  @override
  Future<List<String>> list(String dir) async {
    _check(write: false);
    return inner.list(dir);
  }

  @override
  Future<Uint8List?> read(String path) async {
    _check(write: false);
    return inner.read(path);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    _check(write: true);
    return inner.write(path, bytes);
  }

  @override
  Future<void> delete(String path) async {
    _check(write: true);
    return inner.delete(path);
  }

  @override
  Future<Map<String, String>?> stamps(String dir) async {
    _check(write: false);
    return inner.stamps(dir);
  }
}
