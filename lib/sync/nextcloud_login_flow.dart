import 'dart:async';

import 'package:dio/dio.dart';

import '../l10n/language.dart';
import 'caldav_connect.dart' show candidateEndpoints;
import '../util/user_agent.dart';

/// What Nextcloud answers when a login flow is started: the page the person logs in on, and where to ask whether they did.
class LoginFlowStart {
  /// The page to open in a browser.
  final Uri loginPage;

  /// Where the result is asked for (a POST with the [token]).
  final Uri pollEndpoint;
  final String token;

  const LoginFlowStart(this.loginPage, this.pollEndpoint, this.token);
}

/// What the person approved: the account, with an app password that Nextcloud made for this app (it shows up in *Settings > Security >
/// Devices & sessions* and can be revoked there) - nobody types or copies a password.
class LoginFlowResult {
  final String server, loginName, appPassword;

  const LoginFlowResult(this.server, this.loginName, this.appPassword);
}

/// Nextcloud's **Login Flow v2**: the app asks the server for a login page, the person opens it in a browser, logs in there (with whatever
/// the server wants: a password, two-factor, single sign-on) and presses "Grant access", and the app - which polls the server meanwhile - is
/// handed an app password. The password of the account never reaches the app.
/// https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html#login-flow-v2
class NextcloudLoginFlow {
  final Dio _dio;

  /// How often [wait] asks whether the person has approved.
  final Duration pollEvery;

  NextcloudLoginFlow({Dio? dio, this.pollEvery = const Duration(seconds: 2)})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (s) => s != null && s < 500,
            ));

  /// The address of the site in what the person typed (see [candidateEndpoints]: a missing `https://` is added, and so is a link from the
  /// browser cut back to the site); null when it is not an address.
  static String? siteOf(String typed) {
    final candidates = candidateEndpoints(typed);
    if (candidates.isEmpty) return null;
    const dav = '/remote.php/dav';
    final site = candidates.first.substring(0, candidates.first.length - dav.length);
    final uri = Uri.tryParse(site);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) return null;
    return site;
  }

  /// Asks the site [server] (see [siteOf]) for a login page. Throws a [StateError] with words for the person when it is not a Nextcloud
  /// that can do this.
  Future<LoginFlowStart> start(String server) async {
    final site = siteOf(server);
    if (site == null) throw StateError(tr('That is not a server address.'));
    final Response<dynamic> r;
    try {
      r = await _dio.post<dynamic>(
        '$site/index.php/login/v2',
        // (a browser does not let a page set this one; the Nextcloud then names the app password after the browser)
        options: Options(headers: userAgentHeader, responseType: ResponseType.json),
      );
    } on DioException catch (e) {
      throw StateError(_unreachable(e));
    }
    final data = r.data;
    final poll = data is Map ? data['poll'] : null;
    final login = data is Map ? data['login'] : null;
    if (r.statusCode != 200 || poll is! Map || login is! String || poll['token'] is! String || poll['endpoint'] is! String) {
      throw StateError(tr('This server did not start a login. Is it a Nextcloud (version 16 or newer), and is the address right?'));
    }
    final page = Uri.tryParse(login), endpoint = Uri.tryParse(poll['endpoint'] as String);
    if (page == null || endpoint == null || !_web(page) || !_web(endpoint)) {
      throw StateError(tr('This server did not start a login. Is it a Nextcloud (version 16 or newer), and is the address right?'));
    }
    return LoginFlowStart(page, endpoint, poll['token'] as String);
  }

  static bool _web(Uri u) => (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;

  /// One look whether the person has approved: null while they have not.
  Future<LoginFlowResult?> check(LoginFlowStart flow) async {
    final Response<dynamic> r;
    try {
      r = await _dio.postUri<dynamic>(
        flow.pollEndpoint,
        data: 'token=${Uri.encodeQueryComponent(flow.token)}',
        options: Options(contentType: Headers.formUrlEncodedContentType, headers: userAgentHeader, responseType: ResponseType.json),
      );
    } on DioException catch (e) {
      throw _PollUnreachable(_unreachable(e));
    }
    if (r.statusCode == 404) return null; // not yet (or the login was cancelled: that shows as running out of time)
    final data = r.data;
    if (r.statusCode != 200 || data is! Map || data['server'] is! String || data['loginName'] is! String || data['appPassword'] is! String) {
      throw StateError(tr('The server did not hand over a login.'));
    }
    return LoginFlowResult(data['server'] as String, data['loginName'] as String, data['appPassword'] as String);
  }

  /// Looks every [every] (by default [pollEvery]) until the person approved, [cancelled] says stop (null is returned) or [timeout] passes (a [StateError]).
  /// The person takes minutes over the login in the browser, and a phone loses its connection in that time: a look that could not reach
  /// the server (or that it answered with an error of its own) is tried again, up to [patience] looks in a row, before the wait gives up.
  Future<LoginFlowResult?> wait(
    LoginFlowStart flow, {
    Duration? every,
    Duration timeout = const Duration(minutes: 10),
    bool Function()? cancelled,
    int patience = 5,
  }) async {
    final end = DateTime.now().add(timeout);
    var failed = 0;
    while (true) {
      if (cancelled?.call() ?? false) return null;
      LoginFlowResult? result;
      try {
        result = await check(flow);
        failed = 0;
      } on _PollUnreachable {
        if (++failed > patience) rethrow;
      }
      if (result != null) return result;
      if (DateTime.now().isAfter(end)) throw StateError(tr('The login was not approved in time. Try again.'));
      await Future<void>.delayed(every ?? pollEvery);
    }
  }

  static String _unreachable(DioException e) => tr('The server could not be reached: {error}', {'error': e.message ?? e.type.name});
}

/// A look at the server that did not get an answer (as opposed to one that got a wrong one): worth trying again.
class _PollUnreachable extends StateError {
  _PollUnreachable(super.message);
}
