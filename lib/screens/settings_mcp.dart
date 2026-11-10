part of 'settings_screen.dart';

/// Lets an AI agent on this computer work with the notes (see `McpService`): the switch, whether the agent may change things, and what
/// the agent is given to connect with.
class _McpSettings extends StatefulWidget {
  final McpService service;

  const _McpSettings({required this.service});

  @override
  State<_McpSettings> createState() => _McpSettingsState();
}

class _McpSettingsState extends State<_McpSettings> {
  late final _port = TextEditingController(text: '${widget.service.port}');
  bool _show = false;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _copy(String what, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text.verbatim(tr('Copied: {what}', {'what': tr(what)}))));
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final token = service.token ?? '';
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connect an AI agent', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'An AI agent on this computer (Claude Code, an editor with AI, any program that speaks the Model Context Protocol) can then find, read and '
            'write your notes, folders, tags and tasks. It connects to this app on this computer only, with the token below. Locked notes are never '
            'available to it, and it cannot delete a note for good. Every change to a note keeps a version of it before and after, which you can '
            'bring back. What the agent reads goes to the AI service it belongs to: connect only agents you trust with your notes.',
            style: muted,
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('mcp-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Let an agent use my notes'),
            subtitle: Text(service.running ? tr('Listening on {url}', {'url': service.url}) : tr('Off')),
            value: service.enabled,
            onChanged: service.setEnabled,
          ),
          if (service.error != null) Text.verbatim(service.error!, key: const ValueKey('mcp-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (service.enabled) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
                showSelectedIcon: false,
              key: const ValueKey('mcp-access'),
              segments: const [
                ButtonSegment(value: false, label: Text('Read only')),
                ButtonSegment(value: true, label: Text('Read and change')),
              ],
              selected: {service.canChange},
              onSelectionChanged: (v) => service.setCanChange(v.first),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: Text.verbatim(
                  _show ? token : '•' * 24,
                  key: const ValueKey('mcp-token'),
                  style: const TextStyle(fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const ValueKey('mcp-token-show'),
                tooltip: tr(_show ? 'Hide the token' : 'Show the token'),
                icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _show = !_show),
              ),
              IconButton(key: const ValueKey('mcp-token-copy'), tooltip: tr('Copy the token'), icon: const Icon(Icons.copy_outlined), onPressed: () => _copy('the token', token)),
            ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: const ValueKey('mcp-copy-claude'),
                icon: const Icon(Icons.terminal),
                label: const Text('Copy the command for Claude Code'),
                onPressed: () => _copy('the command', service.claudeCodeCommand),
              ),
              OutlinedButton.icon(
                key: const ValueKey('mcp-copy-json'),
                icon: const Icon(Icons.data_object),
                label: const Text('Copy the settings as JSON'),
                onPressed: () => _copy('the settings', service.jsonSettings),
              ),
              OutlinedButton.icon(
                key: const ValueKey('mcp-new-token'),
                icon: const Icon(Icons.refresh),
                label: const Text('New token'),
                onPressed: service.regenerateToken,
              ),
            ]),
            const SizedBox(height: 4),
            Text('A new token lets out every agent that has the old one.', style: muted),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey('mcp-port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('Port'), isDense: true, border: const OutlineInputBorder()),
                onSubmitted: (v) async {
                  await service.setPort(int.tryParse(v) ?? service.port);
                  _port.text = '${service.port}';
                },
              ),
            ),
          ],
        ]);
      },
    );
  }
}
