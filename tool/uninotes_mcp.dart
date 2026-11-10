import 'dart:convert';
import 'dart:io';

import 'package:notes/mcp/mcp_bridge.dart';

/// Lets an agent that starts programs (and talks to them over stdin and stdout) use the notes of the Notation app that is running on
/// this computer. The token is shown in the settings of the app, under *Connect an AI agent*.
///
///     UNINOTES_MCP_TOKEN=... dart run tool/notation_mcp.dart [--url http://127.0.0.1:7332/mcp]
///
/// or compiled once: `dart compile exe tool/notation_mcp.dart -o notation-mcp`.
Future<void> main(List<String> args) async {
  final at = args.indexOf('--url');
  final url = Uri.parse(at >= 0 && at + 1 < args.length ? args[at + 1] : Platform.environment['UNINOTES_MCP_URL'] ?? 'http://127.0.0.1:7332/mcp');
  final token = Platform.environment['UNINOTES_MCP_TOKEN'] ?? '';
  if (token.isEmpty) {
    stderr.writeln('Set UNINOTES_MCP_TOKEN to the token in the settings of Notation (Connect an AI agent).');
    exitCode = 64;
    return;
  }
  await runMcpBridge(stdin.transform(utf8.decoder).transform(const LineSplitter()), stdout.writeln, url: url, token: token);
}
