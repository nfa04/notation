part of 'settings_screen.dart';

/// Live sessions: where the signalling server is, and the name others see.
class _LiveSettings extends StatefulWidget {
  final CollabService service;

  const _LiveSettings({required this.service});

  @override
  State<_LiveSettings> createState() => _LiveSettingsState();
}

class _LiveSettingsState extends State<_LiveSettings> {
  late final _server = TextEditingController(text: widget.service.customServer ?? '');
  late final _name = TextEditingController(text: widget.service.nameSetting);
  late bool _own = widget.service.customServer != null || !widget.service.hasBuiltInServer;
  String? _result;
  bool _ok = false;
  bool _testing = false;

  @override
  void dispose() {
    _server.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final problem = await widget.service.testServer(_server.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ok = problem == null;
      _result = problem ?? 'The server answers.';
    });
    if (problem == null) await widget.service.setServer(_server.text);
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Live collaboration', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(
        'Work on a note together with others at the same time. Everything is sealed with a key that only the invite '
        'link holds; the signalling server only introduces your devices to each other and sees nothing of the note '
        '(but it does see the addresses of the devices that connect, and when). You can use the one that comes with '
        'the app or run your own: the source has versions for Cloudflare Workers, Node and Dart in tool/signaling. '
        'Everyone in a session uses the server of whoever made the invite.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
      ),
      const SizedBox(height: 12),
      if (service.hasBuiltInServer)
        SegmentedButton<bool>(
            showSelectedIcon: false,
          key: const ValueKey('collab-which'),
          segments: const [
            ButtonSegment(value: false, label: Text('Built-in server')),
            ButtonSegment(value: true, label: Text('My own server')),
          ],
          selected: {_own},
          onSelectionChanged: (v) {
            setState(() {
              _own = v.first;
              _result = null;
            });
            if (!_own) service.setServer(null); // back to the built-in one
          },
        )
      else
        const Text('This build has no built-in server: enter one.', key: ValueKey('collab-no-builtin')),
      if (_own) ...[
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('collab-server'),
              controller: _server,
              decoration: InputDecoration(labelText: tr('Signalling server'), hintText: tr('wss://signal.example.org')),
              onChanged: (_) => setState(() => _result = null), // the button waits for an address
              onSubmitted: (_) => _test(),
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              key: const ValueKey('collab-test'),
              onPressed: _testing || _server.text.trim().isEmpty ? null : _test,
              child: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)) : const Text('Test and use'),
            ),
          ),
        ]),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_result!,
                key: const ValueKey('collab-result'), style: TextStyle(color: _ok ? Colors.green[700] : Theme.of(context).colorScheme.error)),
          ),
      ] else
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Using the built-in server.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('collab-name'),
        controller: _name,
        decoration: InputDecoration(labelText: tr('Your name in sessions')),
        onSubmitted: service.setName,
        onTapOutside: (_) => service.setName(_name.text),
      ),
      if (service.ice != null) ...[
        const SizedBox(height: 16),
        _RelaySettings(ice: service.ice!),
      ],
    ]);
  }
}

/// The relay (TURN) server for connections between devices that cannot reach each other directly - on a mobile network, say.
class _RelaySettings extends StatefulWidget {
  final IceSettings ice;

  const _RelaySettings({required this.ice});

  @override
  State<_RelaySettings> createState() => _RelaySettingsState();
}

class _RelaySettingsState extends State<_RelaySettings> {
  late final _urls = TextEditingController(text: widget.ice.urls);
  late final _user = TextEditingController(text: widget.ice.username);
  late final _password = TextEditingController(text: widget.ice.credential);
  String? _problem;
  bool _saved = false;

  @override
  void dispose() {
    _urls.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = IceSettings.check(_urls.text);
    setState(() {
      _problem = problem;
      _saved = false;
    });
    if (problem != null) return;
    await widget.ice.save(urls: _urls.text, username: _user.text, credential: _password.text);
    if (mounted) setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    void edited() => setState(() {
          _saved = false;
          _problem = null;
        });
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Relay server (for mobile networks)', style: Theme.of(context,).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text(
        'Two devices connect to each other directly. On a mobile network, and behind some other networks, that does not work: '
        'a relay (a TURN server) then passes the data between them. It sees nothing of it, as everything is sealed. Run your '
        'own (coturn, say) or use a service that offers one, and enter its address and the name and password it gave you. '
        'This stays on this device; set it on the devices that are on such a network (it does not hurt on the others).',
        style: muted,
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('relay-urls'),
        controller: _urls,
        decoration: InputDecoration(labelText: tr('Relay address'), hintText: tr('turn:turn.example.org:3478')),
        onChanged: (_) => edited(),
      ),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('relay-user'),
            controller: _user,
            decoration: InputDecoration(labelText: tr('Name')),
            onChanged: (_) => edited(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: const ValueKey('relay-password'),
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(labelText: tr('Password')),
            onChanged: (_) => edited(),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton(key: const ValueKey('relay-save'), onPressed: _save, child: const Text('Save')),
        const SizedBox(width: 12),
        if (_problem != null)
          Expanded(child: Text.rich(TextSpan(text: _problem), key: const ValueKey('relay-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error)))
        else if (_saved)
          Text(_urls.text.trim().isEmpty ? 'No relay.' : 'Saved. New connections use it.', key: const ValueKey('relay-saved'), style: muted),
      ]),
    ]);
  }
}
