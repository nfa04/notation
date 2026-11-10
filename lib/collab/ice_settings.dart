import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../sync/caldav_service.dart' show SecretStore;
import 'webrtc_transport.dart' show defaultIceServers;

/// The relay (TURN) server that the direct connections between devices fall back on. Two devices that are both behind the
/// network of a mobile provider (or any network that does not let them reach each other) cannot connect directly; a relay passes
/// the bytes between them. What passes is sealed, so the relay sees nothing of it. The address and the name are kept in the
/// settings of this device, the password in the keystore; none of them travels to the other devices.
class IceSettings extends ChangeNotifier {
  static const _urlsKey = 'ice_relay_urls';
  static const _userKey = 'ice_relay_user';

  final SettingsRepository? _settings;
  final SecretStore? _secret;

  IceSettings({SettingsRepository? settings, SecretStore? secret})
      : _settings = settings,
        _secret = secret;

  String _urls = '';
  String _username = '';
  String _credential = '';

  /// The addresses as typed, one or more (`turn:turn.example.org:3478`, `turns:turn.example.org:443`).
  String get urls => _urls;
  String get username => _username;
  String get credential => _credential;

  /// Whether a relay is set.
  bool get hasRelay => parseUrls(_urls).isNotEmpty;

  Future<void> load() async {
    _urls = await _settings?.get(_urlsKey) ?? '';
    _username = await _settings?.get(_userKey) ?? '';
    _credential = await _secret?.read() ?? '';
    notifyListeners();
  }

  /// Keeps the relay (an empty [urls] takes it away).
  Future<void> save({required String urls, String username = '', String credential = ''}) async {
    _urls = urls.trim();
    _username = username.trim();
    _credential = credential;
    notifyListeners();
    if (_urls.isEmpty) {
      await _settings?.remove(_urlsKey);
      await _settings?.remove(_userKey);
      await _secret?.delete();
      _username = '';
      _credential = '';
      return;
    }
    await _settings?.set(_urlsKey, _urls);
    await _settings?.set(_userKey, _username);
    if (_credential.isEmpty) {
      await _secret?.delete();
    } else {
      await _secret?.write(_credential);
    }
  }

  /// What to hand to WebRTC: the STUN servers every connection uses, and the relay when there is one.
  List<Map<String, Object>> get servers {
    final relay = parseUrls(_urls);
    return [
      ...defaultIceServers,
      if (relay.isNotEmpty)
        {
          'urls': relay,
          if (_username.isNotEmpty) 'username': _username,
          if (_credential.isNotEmpty) 'credential': _credential,
        },
    ];
  }

  static const _schemes = ['turn:', 'turns:', 'stun:', 'stuns:'];

  /// The addresses in [text], separated by spaces, commas, semicolons or lines. One without `turn:` in front is a TURN address.
  static List<String> parseUrls(String text) {
    final out = <String>[];
    for (final part in text.split(RegExp(r'[\s,;]+'))) {
      final u = part.trim();
      if (u.isEmpty) continue;
      out.add(_schemes.any(u.toLowerCase().startsWith) ? u : 'turn:$u');
    }
    return out;
  }

  /// What is wrong with [text] as the address of a relay, in words; null if it is fine (or empty).
  static String? check(String text) {
    for (final u in parseUrls(text)) {
      final host = u.substring(u.indexOf(':') + 1).split('?').first;
      if (host.isEmpty || host.startsWith('/') || host.contains('//')) {
        return tr('"{address}" is not the address of a relay. Use something like turn:turn.example.org:3478', {'address': u});
      }
    }
    return null;
  }
}
