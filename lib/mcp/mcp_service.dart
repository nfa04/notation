import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../sync/caldav_service.dart' show SecretStore;
import 'mcp_notes.dart';
import 'mcp_protocol.dart';
import 'mcp_server.dart';

/// Something an agent changed: which tool, and the note it was about when there is one.
class McpActivity {
  final String tool;
  final String? noteId;
  const McpActivity(this.tool, this.noteId);
}

/// Lets an AI agent on this computer work with the notes through the Model Context Protocol (see `docs/mcp.md`). It is off until the
/// person turns it on; it then listens on 127.0.0.1 only, for requests that carry the token the person gives the agent. The settings
/// stay on this device.
class McpService extends ChangeNotifier {
  static const defaultPort = 7332;
  static const _enabledKey = 'mcp_enabled', _portKey = 'mcp_port', _accessKey = 'mcp_access';

  final McpNotes notes;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  /// Where the token is kept (the keystore of the system); null: it lives as long as the app does.
  final SecretStore? _secret;

  McpService({required this.notes, required Future<String?> Function(String) read, required Future<void> Function(String, String) write, SecretStore? secret})
      : _read = read,
        _write = write,
        _secret = secret;

  late final McpProtocol protocol = McpProtocol(tools: () => notes.tools, canChange: () => _canChange, instructions: mcpInstructions, onChanged: _changed);

  final _activity = StreamController<McpActivity>.broadcast();

  /// What agents change, as they change it (the app tells the person).
  Stream<McpActivity> get activity => _activity.stream;

  void _changed(McpTool tool, Map<String, Object?> args, String result) {
    // (a note that was made says its id in the answer)
    final id = args['note_id'] ?? (tool.name == 'create_note' ? RegExp(r'Its id is (\S+)\.').firstMatch(result)?.group(1) : null);
    if (!_activity.isClosed) _activity.add(McpActivity(tool.name, id is String ? id : null));
  }
  late final McpHttpServer _server = McpHttpServer(protocol, token: () => _token);

  bool _enabled = false;
  bool _canChange = true;
  int _port = defaultPort;
  String? _token;
  String? _error;

  bool get enabled => _enabled;

  /// Whether the agent may change things, or only read.
  bool get canChange => _canChange;
  int get port => _port;

  /// What a request has to present; null before [load].
  String? get token => _token;

  /// Why the server could not be started (the port is taken), or null.
  String? get error => _error;

  bool get running => _server.running;
  String get url => 'http://127.0.0.1:${_server.running ? _server.port : _port}${McpHttpServer.path}';

  /// The `claude` command that connects Claude Code.
  String get claudeCodeCommand => 'claude mcp add --transport http notation $url --header "Authorization: Bearer $_token"';

  /// The settings for a client that is given a server in JSON (`mcpServers`).
  String get jsonSettings => const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          'notation': {
            'type': 'http',
            'url': url,
            'headers': {'Authorization': 'Bearer $_token'},
          },
        },
      });

  static String newToken() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> load() async {
    _enabled = await _read(_enabledKey) == '1';
    _canChange = await _read(_accessKey) != 'read';
    final port = int.tryParse(await _read(_portKey) ?? '');
    if (port != null && port >= 1024 && port <= 65535) _port = port;
    try {
      _token = await _secret?.read();
      if (_token == null || _token!.length < 32) {
        _token = newToken();
        await _secret?.write(_token!);
      }
    } catch (e) {
      debugPrint('the token of the agent connection is not kept (no keystore): $e');
      _token ??= newToken(); // (a new one with every run, then)
    }
    if (_enabled) await _start();
    notifyListeners();
  }

  Future<void> _start() async {
    _error = null;
    try {
      await _server.start(_port);
    } on SocketException catch (e) {
      _error = 'Port $_port cannot be used: ${e.osError?.message ?? e.message}';
    }
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    await _write(_enabledKey, on ? '1' : '0');
    if (on) {
      await _start();
    } else {
      _error = null;
      await _server.stop();
    }
    notifyListeners();
  }

  Future<void> setCanChange(bool on) async {
    _canChange = on;
    await _write(_accessKey, on ? 'write' : 'read');
    notifyListeners();
  }

  /// Another port; the server moves to it if it is running.
  Future<void> setPort(int port) async {
    if (port < 1024 || port > 65535) return;
    _port = port;
    await _write(_portKey, '$port');
    if (_enabled) {
      await _server.stop();
      await _start();
    }
    notifyListeners();
  }

  /// A new token: the agents that had the old one are let out.
  Future<void> regenerateToken() async {
    _token = newToken();
    try {
      await _secret?.write(_token!);
    } catch (e) {
      debugPrint('the token of the agent connection is not kept: $e');
    }
    notifyListeners();
  }

  /// Stops listening without changing the choice (the app is closing: it listens again at the next start if it was on).
  Future<void> stop() => _server.stop();

  @override
  void dispose() {
    _server.stop();
    _activity.close();
    super.dispose();
  }
}
