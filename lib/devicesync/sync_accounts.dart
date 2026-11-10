/// One cloud account as it travels between the devices of a person: what kind it is, when it last changed, and what it holds
/// (null: it was removed).
class AccountBundle {
  final String kind;
  final int at;
  final Map<String, String>? data;

  const AccountBundle(this.kind, this.at, this.data);

  Map<String, Object?> toJson() => {'kind': kind, 'at': at, 'data': data};

  static AccountBundle? fromJson(Object? j) {
    if (j is! Map || j['kind'] is! String || j['at'] is! int) return null;
    final d = j['data'];
    return AccountBundle(j['kind'] as String, j['at'] as int, d is Map ? {for (final e in d.entries) '${e.key}': '${e.value}'} : null);
  }
}

/// The cloud accounts of the app (Nextcloud, S3, Dropbox, OneDrive), for handing them from one device of the person to another.
/// They go over the proven, sealed line of a sync only, and never into the files of the cloud folder.
abstract class SyncedAccounts {
  /// The accounts here, each with the time it last changed (0 when it never was set up).
  Future<List<AccountBundle>> export();

  /// Takes in the accounts that are newer than the ones here (a removed account removes it). Returns how many changed.
  Future<int> apply(List<AccountBundle> theirs);
}
