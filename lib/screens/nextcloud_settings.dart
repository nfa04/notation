import 'package:caldav/caldav.dart';
import 'package:flutter/material.dart' hide Text;

import 'package:url_launcher/url_launcher.dart';

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../sync/caldav_service.dart';
import '../sync/nextcloud_login_flow.dart';
import '../style/platform_dialog.dart';

/// The Nextcloud account (any CalDAV server): the login, the calendar the tasks sync with and the calendars
/// whose events are shown. The same account is used for sharing copies and for syncing folders. It is the
/// body of the Nextcloud entry among the sharing services.
class NextcloudSettings extends StatefulWidget {
  final CalDavService service;

  /// For tests: the login flow's server calls, and the opening of the login page.
  final NextcloudLoginFlow? loginFlow;
  final Future<bool> Function(Uri page)? openPage;

  const NextcloudSettings({super.key, required this.service,
    this.loginFlow,
    this.openPage,});

  @override
  State<NextcloudSettings> createState() => _NextcloudSettingsState();
}

class _NextcloudSettingsState extends State<NextcloudSettings> {
  late final _url = TextEditingController(text: widget.service.config?.serverUrl ?? '');
  late final _user = TextEditingController(text: widget.service.config?.username ?? '');
  final _password = TextEditingController();

  bool _busy = false;
  String? _error;

  late final NextcloudLoginFlow _loginFlow =
      widget.loginFlow ?? NextcloudLoginFlow();

  /// A login in the browser is under way (see [_browserLogin]); the person can stop waiting.
  bool _waiting = false;
  bool _stopped = false;

  /// The login page, shown as text when no browser could be opened for it.
  String? _loginLink;

  /// Set after a successful "Connect": the calendars to choose from.
  List<Calendar>? _calendars;
  String _serverUrl = '';
  String? _taskCalendar;
  final Set<String> _eventCalendars = {};

  CalDavService get _service => widget.service;

  @override
  void dispose() {
    _stopped = true;
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Nextcloud's login flow: the login page opens in the browser, the person approves there, and the app gets an app password of its own
  /// (nothing is typed or copied). The calendars are then looked up as after "Connect".
  Future<void> _browserLogin() async {
    final site = NextcloudLoginFlow.siteOf(_url.text);
    if (site == null) {
      setState(() => _error = tr('Enter the address of your Nextcloud first.'));
      return;
    }
    setState(() {
      _busy = true;
      _waiting = true;
      _stopped = false;
      _error = null;
      _loginLink = null;
    });
    LoginFlowResult? result;
    try {
      final flow = await _loginFlow.start(site);
      final opened =
          await (widget.openPage ??
              (u) => launchUrl(u, mode: LaunchMode.externalApplication))(
            flow.loginPage,
          );
      if (mounted && !opened) setState(() => _loginLink = flow.loginPage.toString());
      result = await _loginFlow.wait(
        flow,
        cancelled: () => _stopped || !mounted,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e'.replaceFirst('Bad state: ', ''));
    }
    if (!mounted) return;
    setState(() {
      _waiting = false;
      _busy = false;
      _loginLink = null;
    });
    if (result == null) return;
    _url.text = result.server;
    _user.text = result.loginName;
    _password.text = result.appPassword;
    final hadAccount = _service.isConnected;
    await _connect();
    if (_calendars == null || !mounted) return; // (it did not work: the error is shown)
    // The app password was made for this app and the person approved it, so the account is saved now: nobody has to press anything else.
    // A new account starts without a task calendar and without calendars to show (the calendars are opt-in: "Choose calendars" below); one that was
    // connected before keeps the choices it had.
    if (!hadAccount) {
      _taskCalendar = null;
      _eventCalendars.clear();
    }
    await _save();
  }

  /// Looks up the calendars again with the saved login (no password to type) so that the choices can be changed.
  Future<void> _chooseCalendars() async {
    final login = await _service.login();
    if (login == null) {
      setState(
        () => _error = tr(
          'The password of this account is not in the keystore of this device. Log in again.',
        ),
      );
      return;
    }
    _url.text = login.serverUrl;
    _user.text = login.username;
    _password.text = login.password;
    await _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _service.testConnection(_url.text, _user.text.trim(), _password.text);
      if (!mounted) return;
      final saved = _service.config;
      setState(() {
        _serverUrl = result.serverUrl;
        _calendars = result.calendars;
        // keep earlier choices that still exist, otherwise suggest sensible ones
        final hrefs = result.calendars.map((c) => c.href.toString()).toSet();
        _taskCalendar = saved?.taskCalendar != null && hrefs.contains(saved!.taskCalendar)
            ? saved.taskCalendar
            : result.calendars.where(_supportsTodos).map((c) => c.href.toString()).firstOrNull;
        _eventCalendars
          ..clear()
          ..addAll(saved?.eventCalendars.where(hrefs.contains) ??
              result.calendars.where(_supportsEvents).map((c) => c.href.toString()));
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is FormatException ? e.message : CalDavService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // servers that do not say what a calendar holds are assumed to hold both
  static bool _supportsTodos(Calendar c) => c.supportedComponents.isEmpty || c.supportedComponents.contains('VTODO');
  static bool _supportsEvents(Calendar c) => c.supportedComponents.isEmpty || c.supportedComponents.contains('VEVENT');

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await _service.save(_serverUrl, _user.text.trim(), _password.text,
          taskCalendar: _taskCalendar, eventCalendars: _eventCalendars);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _calendars = null;
        _password.clear();
      });
      _service.sync(); // first sync right away
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = tr('Could not save: {error}', {'error': e});
        });
      }
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Disconnect?'),
        content: const Text('The login is removed from this device. Your tasks stay here, '
            'and nothing is deleted on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok != true) return;
    await _service.disconnect();
    if (mounted) setState(() => _calendars = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final connected = _service.isConnected;
        final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            connected
                ? tr(
                      'Connected as {user}. To sync tasks with a calendar or show its events, choose the calendars.', {'user': _service.config!.username})
                : 'Also syncs your tasks with a CalDAV calendar and shows its events in the Calendar tab. '
                    'Copies of notes are kept for 30 days.',
            style: muted,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: tr('Server address'),
              hintText: tr('https://cloud.example.com'),
              border: OutlineInputBorder(),
            ),
            ),
            const SizedBox(height: 12),
            if (_waiting)
              Row(
                key: const ValueKey('nextcloud-waiting'),
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Waiting for you to approve in the browser...',
                      style: muted,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('nextcloud-stop-waiting'),
                    onPressed: () => setState(() => _stopped = true),
                    child: const Text('Cancel'),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const ValueKey('nextcloud-browser-login'),
                  onPressed: _busy ? null : _browserLogin,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('Log in with the browser'),
                ),
              ),
            if (_loginLink != null) ...[
              const SizedBox(height: 6),
              Text(
                'The browser could not be opened. Open this address yourself:',
                style: muted,
              ),
              SelectableText(
                _loginLink!,
                key: const ValueKey('nextcloud-login-link'),
              ),
            ],
            const SizedBox(height: 16),
            Text('Or enter an app password yourself:', style: muted
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            decoration: InputDecoration(labelText: tr('User name'), border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: tr('App password'),
              helperText: tr('In Nextcloud: Settings > Security > Devices & sessions > create new app password. '
                  'Do not use your main password.'),
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _busy ? null : _connect(),
          ),
          const SizedBox(height: 16),
          Row(children: [
            FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2,))
                  : const Icon(Icons.link),
              label: Text(_calendars == null ? 'Connect' : 'Connect again'),
            ),
            const Spacer(),
                if (connected && _calendars == null)
                  TextButton(
                    key: const ValueKey('nextcloud-choose-calendars'),
                    onPressed: _busy ? null : _chooseCalendars,
                    child: const Text('Choose calendars'),),
            if (connected)
              TextButton(
                onPressed: _busy ? null : _disconnect,
                child: Text('Disconnect', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 12),
            SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_calendars != null) ..._calendarChoices(),
        ]);
      },
    );
  }

  List<Widget> _calendarChoices() {
    final calendars = _calendars!;
    String title(Calendar c) => c.isReadOnly ? '${c.displayName} (read-only)' : c.displayName;

    return [
      const Divider(height: 40),
      Text('Tasks', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('Your tasks are kept in step with this calendar, in both directions.'),
      const SizedBox(height: 8),
      DropdownButtonFormField<String?>(
        initialValue: _taskCalendar,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        items: [
          const DropdownMenuItem(value: null, child: Text('Do not sync tasks')),
          for (final c in calendars.where((c) => _supportsTodos(c) && !c.isReadOnly))
            DropdownMenuItem(value: c.href.toString(), child: Text(title(c))),
        ],
        onChanged: (v) => setState(() => _taskCalendar = v),
      ),
      const SizedBox(height: 24),
      Text('Events', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('These calendars\' events are shown next to your tasks (read-only).'),
      for (final c in calendars.where(_supportsEvents))
        CheckboxListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(title(c)),
          value: _eventCalendars.contains(c.href.toString()),
          onChanged: (v) => setState(() => v == true
              ? _eventCalendars.add(c.href.toString())
              : _eventCalendars.remove(c.href.toString())),
        ),
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save and sync')),
    ];
  }
}
