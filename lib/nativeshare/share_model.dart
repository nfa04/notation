import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'native_share_provider.dart';

enum ShareKind { note, folder }

/// Whether the person gave the share, or received it.
enum ShareDirection {
  outgoing('out'),
  incoming('in');

  final String id;
  const ShareDirection(this.id);
}

/// Whether the share is still going. A share that [ended] is kept in the list (and its notes stay) until the person removes it from there.
enum ShareState { active, ended }

/// One person a share was given to.
class ShareRecipient {
  final SharePerson person;
  final ShareRole role;

  /// The service's id of this share, to change or remove it.
  final String shareId;

  /// A link to give to the person, if the service needs one for them to find the share.
  final String? link;

  const ShareRecipient(this.person, this.role, this.shareId, {this.link});

  ShareRecipient withRole(ShareRole r) => ShareRecipient(person, r, shareId, link: link);

  Map<String, Object?> toJson() => {'id': person.id, 'name': person.label, 'detail': person.detail, 'role': role.id, 'share': shareId, if (link != null) 'link': link};

  static ShareRecipient fromJson(Map j) => ShareRecipient(
        SharePerson(j['id'] as String, j['name'] as String? ?? j['id'] as String, detail: j['detail'] as String? ?? ''),
        ShareRole.byId(j['role'] as String?),
        j['share'] as String? ?? '',
        link: j['link'] as String?,
      );
}

/// A note or a folder shared with other people through a cloud service, as this device knows it.
class NativeShare {
  final String id;
  final String providerId;
  final ShareDirection direction;
  final ShareKind kind;

  /// The note or folder here that it is about.
  final String rootId;

  /// What the person sees it called.
  final String name;
  final ShareState state;

  /// Where its files are at the service ([NativeShareProvider.folderAt]).
  final String place;

  /// Given: the people it is given to. Received: empty.
  final List<ShareRecipient> recipients;

  /// Received: what the person may do, who gave it, the service's id of it (to leave it), and the folder it was put in (null: at the top).
  final ShareRole role;
  final String owner;
  final String providerShareId;
  final String? targetFolderId;

  /// The secret for working on a note live with the others of the share (base64; see `ShareLive`); null for a share that has none yet.
  final String? liveSecret;
  final int createdAt;
  final int? lastSync;

  /// When something about the share last changed (who has it, its state), not counting its runs: the newer of two copies on the devices of
  /// one person wins.
  final int updatedAt;

  NativeShare({
    required this.id,
    required this.providerId,
    required this.direction,
    required this.kind,
    required this.rootId,
    required this.name,
    required this.place,
    this.state = ShareState.active,
    this.recipients = const [],
    this.role = ShareRole.editor,
    this.owner = '',
    this.providerShareId = '',
    this.targetFolderId,
    this.liveSecret,
    required this.createdAt,
    this.lastSync,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  bool get outgoing => direction == ShareDirection.outgoing;

  /// Whether this device writes to the shared folder (the owner always does; a person who received it only with edit rights).
  bool get writes => outgoing || role == ShareRole.editor;

  NativeShare copyWith({String? name, ShareState? state, List<ShareRecipient>? recipients, int? lastSync, ShareRole? role, int? updatedAt, String? liveSecret}) => NativeShare(
        id: id,
        providerId: providerId,
        direction: direction,
        kind: kind,
        rootId: rootId,
        name: name ?? this.name,
        place: place,
        state: state ?? this.state,
        recipients: recipients ?? this.recipients,
        role: role ?? this.role,
        owner: owner,
        providerShareId: providerShareId,
        targetFolderId: targetFolderId,
        liveSecret: liveSecret ?? this.liveSecret,
        createdAt: createdAt,
        lastSync: lastSync ?? this.lastSync,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> dataJson() => {
        'name': name,
        'place': place,
        'recipients': [for (final r in recipients) r.toJson()],
        'role': role.id,
        'owner': owner,
        'shareId': providerShareId,
        if (targetFolderId != null) 'target': targetFolderId,
        if (liveSecret != null) 'live': liveSecret,
        if (lastSync != null) 'last': lastSync,
        'at': updatedAt,
      };

  /// The share as it goes to the other devices of the person (they have their own runs).
  Map<String, Object?> toProfileJson() => {
        'id': id,
        'provider': providerId,
        'direction': direction.id,
        'kind': kind.name,
        'root': rootId,
        'state': state.name,
        'created': createdAt,
        'data': {...dataJson()..remove('last')},
      };

  static NativeShare? fromProfileJson(Object? j) {
    if (j is! Map) return null;
    try {
      return fromRow({
        'id': j['id'],
        'provider': j['provider'],
        'direction': j['direction'],
        'kind': j['kind'],
        'root_id': j['root'],
        'state': j['state'],
        'created_at': j['created'],
        'data': jsonEncode(j['data']),
      });
    } catch (_) {
      return null;
    }
  }

  static NativeShare? fromRow(Map<String, Object?> r) {
    try {
      final d = jsonDecode(r['data'] as String) as Map;
      return NativeShare(
        id: r['id'] as String,
        providerId: r['provider'] as String,
        direction: ShareDirection.values.firstWhere((x) => x.id == r['direction']),
        kind: ShareKind.values.firstWhere((x) => x.name == r['kind']),
        rootId: r['root_id'] as String,
        name: d['name'] as String? ?? '',
        place: d['place'] as String,
        state: ShareState.values.where((x) => x.name == r['state']).firstOrNull ?? ShareState.active,
        recipients: [for (final j in (d['recipients'] as List? ?? const [])) ShareRecipient.fromJson(j as Map)],
        role: ShareRole.byId(d['role'] as String?),
        owner: d['owner'] as String? ?? '',
        providerShareId: d['shareId'] as String? ?? '',
        targetFolderId: d['target'] as String?,
        liveSecret: d['live'] as String?,
        createdAt: r['created_at'] as int,
        lastSync: d['last'] as int?,
        updatedAt: d['at'] as int?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The shares in the database.
class ShareStore {
  final Database _db;

  const ShareStore(this._db);

  Future<List<NativeShare>> all() async => [
        for (final r in await _db.query('native_shares', orderBy: 'created_at')) ?NativeShare.fromRow(r),
      ];

  Future<void> save(NativeShare s) => _db.insert(
        'native_shares',
        {
          'id': s.id,
          'provider': s.providerId,
          'direction': s.direction.id,
          'kind': s.kind.name,
          'root_id': s.rootId,
          'state': s.state.name,
          'data': jsonEncode(s.dataJson()),
          'created_at': s.createdAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Removes the share from the list, and what it remembers of what belongs to it. The notes stay.
  Future<void> delete(String id) async {
    await _db.delete('native_shares', where: 'id = ?', whereArgs: [id]);
    await _db.delete('native_share_items', where: 'share_id = ?', whereArgs: [id]);
  }
}
