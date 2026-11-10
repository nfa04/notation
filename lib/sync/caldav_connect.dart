import 'dart:convert';

import 'package:caldav/caldav.dart';
import 'package:dio/dio.dart';
import '../l10n/language.dart';
import '../util/user_agent.dart';

/// The server addresses worth trying for what the user typed, most likely
/// first.
///
/// Nextcloud keeps CalDAV at `<site>/remote.php/dav`. People type the site
/// address, or paste an address from the browser or from a calendar's
/// "copy link" (`.../remote.php/dav/calendars/me/personal`), so everything
/// from `/remote.php/`, `/index.php`, `/apps/` ... on is dropped first. The
/// address as typed comes second, for other CalDAV servers.
List<String> candidateEndpoints(String typed) {
  var url = typed.trim().replaceAll(RegExp(r'/+$'), '');
  if (url.isEmpty) return const [];
  if (!url.contains('://')) url = 'https://$url';

  final schemeEnd = url.indexOf('://') + 3;
  final cut = RegExp(r'/(remote\.php|index\.php|apps|settings|login)(/|$)',).firstMatch(url.substring(schemeEnd));
  final root = cut == null ? url : url.substring(0, schemeEnd + cut.start);

  final nextcloud = '$root/remote.php/dav';
  return [nextcloud, if (url != nextcloud) url];
}

/// Opens [endpoint] and finds the user's calendars.
///
/// For a Nextcloud address ([knownEndpoint]) the `/.well-known/caldav`
/// lookup is skipped: it is only a way to find that very address, and on a
/// server behind a proxy or in a sub-folder it can lead somewhere else.
Future<CalDavClient> openCalDavClient(
  String endpoint,
  String username,
  String password, {
  bool knownEndpoint = false,
  bool allowInsecure = false,
}) async {
  final dio = Dio(BaseOptions(
    baseUrl: endpoint,
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (status) => status != null && status < 400,
    headers: {
      'Authorization': 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        ...userAgentHeader,
    },
  ));
  if (knownEndpoint) {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.uri.path == '/.well-known/caldav') {
        // "not supported": the library then uses the address it was given
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: options, statusCode: 404),
          ),
          true,
        );
      } else {
        handler.next(options);
      }
    }));
  }

  final client = CalDavClient.withDio(baseUrl: endpoint, dio: dio, allowInsecure: allowInsecure);
  try {
    await client.discover();
    return client;
  } catch (_) {
    client.close();
    rethrow;
  }
}

/// Why connecting failed, with one line per address that was tried.
class CalDavConnectError implements Exception {
  final List<String> attempts;

  const CalDavConnectError(this.attempts);

  @override
  String toString() => '${tr('Could not connect.')}\n${attempts.join('\n')}';
}

/// Tries each [candidateEndpoints] and returns the first that works, with the
/// client and the address.
Future<({CalDavClient client, String endpoint})> connectToServer(
  String typed,
  String username,
  String password, {
  bool allowInsecure = false,
}) async {
  final candidates = candidateEndpoints(typed);
  if (candidates.isEmpty) throw FormatException(tr('Enter the server address.'));
  if (!allowInsecure && !candidates.first.startsWith('https://')) {
    throw FormatException(tr('The address must start with https:// (the password is sent to it).'));
  }

  final attempts = <String>[];
  for (final endpoint in candidates) {
    try {
      final client = await openCalDavClient(
        endpoint,
        username,
        password,
        knownEndpoint: endpoint.endsWith('/remote.php/dav'),
        allowInsecure: allowInsecure,
      );
      return (client: client, endpoint: endpoint);
    } on AuthenticationException {
      rethrow; // the server answered and refused the login: other addresses will not help
    } catch (e) {
      attempts.add('$endpoint: ${e is CalDavException ? e.message : e}');
    }
  }
  throw CalDavConnectError(attempts);
}
