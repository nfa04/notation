import '../profile/user_profile.dart';
import 'device_sync_service.dart';

/// [SyncProfile] on the profile of the person ([UserProfile]).
class ProfileSync implements SyncProfile {
  final UserProfile _profile;

  ProfileSync(this._profile);

  @override
  String get id => _profile.id;

  @override
  String get name => _profile.name;

  @override
  Future<void> adopt(String id, String name) => _profile.adopt(id, name);
}
