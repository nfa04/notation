import '../cloudsync/cloud_folder.dart';

/// What a person who is given a share may do with it.
enum ShareRole {
  viewer('read', 'Can view'),
  editor('write', 'Can edit');

  final String id;
  final String label;
  const ShareRole(this.id, this.label);

  static ShareRole byId(String? id) => values.where((r) => r.id == id).firstOrNull ?? viewer;
}

/// Someone at the service a share can be given to. [id] is what the service needs to name them (a user name, an e-mail address); [label]
/// is what the person sees.
class SharePerson {
  final String id;
  final String label;

  /// More to tell two people with the same name apart (an e-mail address, the server).
  final String detail;

  const SharePerson(this.id, this.label, {this.detail = ''});

  @override
  bool operator ==(Object other) => other is SharePerson && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A share the service holds: [id] is the service's own, to change or remove it again.
class ProviderShare {
  final String id;
  final SharePerson person;
  final ShareRole role;

  /// A link to give to the person, for a service where they cannot find the share by themselves (see [NativeShareProvider.acceptsLinks]).
  final String? link;

  const ProviderShare(this.id, this.person, this.role, {this.link});
}

/// A share that someone gave to the signed-in person.
class IncomingShare {
  /// The service's id of the share; with the service, what tells one share from another.
  final String id;

  /// What the folder is called, and who gave it.
  final String name;
  final String owner;
  final ShareRole role;

  /// Not accepted at the service yet (it has to be before its files can be reached).
  final bool pending;

  /// Whether [role] is what the person will get: a service may not tell before the share is accepted.
  final bool roleKnown;

  /// Where its files are, in the terms of the service ([NativeShareProvider.folderAt]); empty while it is [pending].
  final String place;

  const IncomingShare({required this.id, required this.name, required this.owner, required this.role, this.pending = false, this.roleKnown = true, this.place = ''});
}

/// The service did not do what a share needed, with words for the person.
class NativeShareException implements Exception {
  final String message;
  const NativeShareException(this.message);

  @override
  String toString() => message;
}

/// What a cloud service offers for sharing a folder with the people who have an account there. The files of a share are read and
/// written through the [CloudFolder] of the service, as the sync through a cloud folder does; this adds only the sharing: who may
/// reach the folder, and what shares have been given to this account.
///
/// To offer another service, implement this and add it to the providers of `NativeShareService`. A service that cannot share with
/// people, in general or for this account, says so in [unsupportedReason] and is not offered for it.
abstract class NativeShareProvider {
  /// The same id as the `CloudProvider` of the service.
  String get id;

  /// What the person calls it: "Nextcloud".
  String get label;

  /// Whether an account is connected on this device.
  bool get available;

  /// Why sharing with people cannot be used with this service or this account (null when it can). Shown to the person.
  String? get unsupportedReason => null;

  /// Whether a share given to the person is found from a link that comes with the invitation, because the service cannot list them (or
  /// not for long). Then [recognizes] and [addLink] read the link, and [ProviderShare.link] is what to give to the person.
  bool get acceptsLinks => false;

  /// Whether [text] is a link to a share of this service.
  bool recognizes(String text) => false;

  /// Reads a link to a share and returns the share it opens; the share is listed by [incoming] from now on.
  Future<IncomingShare> addLink(String text) => throw UnsupportedError('addLink');

  /// The people at the service whose name or address starts with [query].
  Future<List<SharePerson>> searchPeople(String query);

  /// Gives the folder [place] (in the account of the signed-in person) to [person]. A service may return the share that is there
  /// already, with the role it has now changed.
  Future<ProviderShare> share(String place, SharePerson person, ShareRole role);

  /// Who the folder [place] is shared with.
  Future<List<ProviderShare>> sharesOf(String place);

  Future<void> changeRole(ProviderShare share, ShareRole role);

  /// Takes the access of one person away.
  Future<void> unshare(ProviderShare share);

  /// Removes the folder [place] itself, and with it every share of it.
  Future<void> removeFolder(String place);

  /// The shares given to the signed-in person, accepted or waiting.
  Future<List<IncomingShare>> incoming();

  /// Accepts a share that is waiting; returns it with the place of its files.
  Future<IncomingShare> accept(IncomingShare share) async => share;

  /// The person no longer wants a share they received.
  Future<void> leave(IncomingShare share);

  /// The files at [place]: a folder of the signed-in person, or one shared with them.
  CloudFolder folderAt(String place);
}

/// How the folders of shares are named at the service, so that the shares of Notation can be told from the other folders that were
/// shared with the person: `Physics (Notation 3fa9c1)`.
class ShareNaming {
  // (a service may give the name back in other letters: Dropbox keeps paths in lower case)
  static final _mine = RegExp(r'\(Notation ([0-9a-f]{6})\)', caseSensitive: false);

  /// The name of the folder of the share [shareId] for something called [title].
  static String folderName(String title, String shareId) {
    final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = clean.isEmpty ? 'Shared' : (clean.length > 60 ? clean.substring(0, 60).trim() : clean);
    return '$short (Notation ${shareId.substring(0, 6)})';
  }

  /// Whether a folder shared with the person has a name made by [folderName].
  static bool isOurs(String name) => _mine.hasMatch(name);

  /// The part of [name] before the mark, for showing.
  static String shown(String name) => name.replaceAll(_mine, '').trim();
}
