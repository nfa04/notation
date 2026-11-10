import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';

import 'support/mcp_fixture.dart';

/// Not a test: a MCP server over a made-up library (see `support/mcp_fixture.dart`) to point an agent at, without touching your notes.
/// It is skipped unless asked for, and then it runs until it is stopped:
///
///     UNINOTES_MCP_DEV=1 flutter test test/mcp/dev_server_test.dart --timeout none
///
/// It listens on 127.0.0.1:7333 (`UNINOTES_MCP_DEV_PORT` for another) with the token `mcpDevToken`. See `docs/mcp.md`.
void main() {
  final env = Platform.environment;

  test('the dev server', () async {
    AppDatabase.initFfi();
    final f = await startMcpFixture(port: int.parse(env['UNINOTES_MCP_DEV_PORT'] ?? '7333'));
    // ignore: avoid_print
    print('MCP dev server ready: ${f.url}  token: ${f.token}');
    await Future<void>.delayed(const Duration(hours: 12));
    await f.close();
  }, skip: env['UNINOTES_MCP_DEV'] == null ? 'a server to point an agent at: set UNINOTES_MCP_DEV=1 (see docs/mcp.md)' : false, timeout: Timeout.none);
}
