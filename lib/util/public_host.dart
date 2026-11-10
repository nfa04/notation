import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../l10n/language.dart';

/// Whether [a] is an address of this device or of a private network (loopback, link-local, 10/8, 172.16/12, 192.168/16, 100.64/10,
/// fc00::/7, an IPv4 address inside an IPv6 one): a page on the web has no business there.
bool isPrivateAddress(InternetAddress a) {
  final r = a.rawAddress;
  if (r.length == 16) {
    final mapped = r.sublist(0, 10).every((b) => b == 0) && r[10] == 0xff && r[11] == 0xff;
    if (mapped) return isPrivateAddress(InternetAddress.fromRawAddress(Uint8List.fromList(r.sublist(12))));
    if (r.every((b) => b == 0) || (r.sublist(0, 15).every((b) => b == 0) && r[15] == 1)) return true; // :: and ::1
    return (r[0] & 0xfe) == 0xfc || (r[0] == 0xfe && (r[1] & 0xc0) == 0x80); // fc00::/7, fe80::/10
  }
  return r[0] == 0 ||
      r[0] == 10 ||
      r[0] == 127 ||
      (r[0] == 100 && r[1] >= 64 && r[1] < 128) ||
      (r[0] == 169 && r[1] == 254) ||
      (r[0] == 172 && r[1] >= 16 && r[1] < 32) ||
      (r[0] == 192 && r[1] == 168);
}

/// Throws if the host of [url] is, or names, an address of this device or of a private network.
Future<void> checkPublicHost(Uri url, {Future<List<InternetAddress>> Function(String host)? lookup}) async {
  final host = url.host.toLowerCase();
  final refuse = StateError(tr('Pages on this device or in a private network cannot be saved.'));
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) throw refuse;
  final literal = InternetAddress.tryParse(host);
  if (literal != null) {
    if (isPrivateAddress(literal)) throw refuse;
    return;
  }
  if (kIsWeb) return; // (a browser makes the request, and has its own rules)
  final List<InternetAddress> found;
  try {
    found = await (lookup ?? InternetAddress.lookup)(host);
  } on SocketException {
    return; // (the request itself will say that the name is not found)
  }
  if (found.any(isPrivateAddress)) throw refuse;
}
