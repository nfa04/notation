import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_protocol.dart';

/// The Streamable HTTP transport of the Model Context Protocol for [McpProtocol], on this computer only. Anything that can reach a
/// port on localhost can be a web page in the person's browser, so every request is checked before it is read: the address it was sent
/// to (a page cannot make the browser send another name here), where it came from, and the token.
class McpHttpServer {
  final McpProtocol protocol;

  /// What a request has to present as `Authorization: Bearer ...`; null or empty: nothing is let in.
  final String? Function() token;

  /// The largest request that is read.
  final int maxBytes;

  /// The path of the endpoint.
  static const path = '/mcp';

  McpHttpServer(this.protocol, {required this.token, this.maxBytes = 8 * 1024 * 1024});

  HttpServer? _http;

  bool get running => _http != null;
  int get port => _http!.port;

  /// Listens on 127.0.0.1 only (never on the network). Fails when the port is taken.
  Future<void> start(int port) async {
    if (_http != null) return;
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _http = http;
    http.listen(_handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    final http = _http;
    _http = null;
    await http?.close(force: true);
  }

  static bool _loopback(String host) => host == '127.0.0.1' || host == 'localhost' || host == '[::1]' || host == '::1';

  /// Whether [a] and [b] are the same, in a time that tells nothing of where they differ.
  static bool sameToken(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i % (y.isEmpty ? 1 : y.length)];
    }
    return diff == 0 && y.isNotEmpty;
  }

  Future<void> _send(HttpResponse response, int status, [Map<String, Object?>? body, Map<String, String> headers = const {}]) async {
    response.statusCode = status;
    response.headers.set('Cache-Control', 'no-store');
    headers.forEach(response.headers.set);
    if (body != null) {
      response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      response.add(utf8.encode(jsonEncode(body)));
    }
    await response.close();
  }

  Map<String, Object?> _failure(int code, String message) => {'jsonrpc': '2.0', 'id': null, 'error': {'code': code, 'message': message}};

  Future<void> _handle(HttpRequest request) async {
    try {
      await _serve(request);
    } catch (e) {
      try {
        await _send(request.response, HttpStatus.internalServerError, _failure(-32603, 'Internal error'));
      } catch (_) {
        // the connection is gone
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    // a name other than the loopback ones is a page that made the browser send its own to this port (DNS rebinding)
    if (!_loopback(request.headers.host ?? '')) return _send(request.response, HttpStatus.forbidden, _failure(-32600, 'Forbidden host'));
    final origin = request.headers.value('origin');
    if (origin != null && !_loopback(Uri.tryParse(origin)?.host ?? '')) {
      return _send(request.response, HttpStatus.forbidden, _failure(-32600, 'Forbidden origin'));
    }
    if (request.uri.path != path) return _send(request.response, HttpStatus.notFound, _failure(-32601, 'The endpoint is $path'));
    final want = token();
    final given = request.headers.value('authorization');
    final bearer = given != null && given.length > 7 && given.substring(0, 7).toLowerCase() == 'bearer ' ? given.substring(7).trim() : '';
    if (want == null || want.isEmpty || !sameToken(bearer, want)) {
      return _send(request.response, HttpStatus.unauthorized, _failure(-32600, 'A token is needed: send Authorization: Bearer <token>'), {'WWW-Authenticate': 'Bearer'});
    }
    // (no session and no stream to listen on: the older revisions' GET and DELETE are answered as the newest one says)
    if (request.method != 'POST') return _send(request.response, HttpStatus.methodNotAllowed, null, {'Allow': 'POST'});
    if (request.contentLength > maxBytes) return _send(request.response, HttpStatus.requestEntityTooLarge, _failure(-32600, 'The request is too large'));

    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) return _send(request.response, HttpStatus.requestEntityTooLarge, _failure(-32600, 'The request is too large'));
    }
    Object? message;
    try {
      message = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return _send(request.response, HttpStatus.badRequest, _failure(-32700, 'Parse error'));
    }
    final h = request.headers;
    final reply = await protocol.handle(message, McpHeaders(version: h.value('mcp-protocol-version'), method: h.value('mcp-method'), name: h.value('mcp-name')));
    await (reply == null ? _send(request.response, HttpStatus.accepted) : _send(request.response, reply.status, reply.body));
  }
}
