import 'dart:convert';
import 'dart:typed_data';
import '../l10n/language.dart';

import 'package:file_picker/file_picker.dart';
import 'note_file_actions.dart' show pickerFilter;
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../sync/device_calendar_service.dart';
import '../sync/ics_service.dart';
import '../style/platform_dialog.dart';

/// The calendars shown next to the tasks that are not on a server: the phone's own, and `.ics` files and links.
/// (The Nextcloud account, and the calendars taken from it, are in the app settings.)
class CalDavSettingsScreen extends StatefulWidget {
  /// The phone's own calendars (Android and iOS); null or unsupported hides that part.
  final DeviceCalendarService? device;

  /// Calendars from `.ics` files and links; null hides that part.
  final IcsCalendarService? ics;

  /// Lets the user choose an `.ics` file (its name and text), or null if none was chosen.
  /// Tests pass a fake; the real one opens the system's file chooser.
  final Future<({String name, String content})?> Function()? pickIcsFile;

  const CalDavSettingsScreen({super.key, this.device, this.ics, this.pickIcsFile});

  @override
  State<CalDavSettingsScreen> createState() => _CalDavSettingsScreenState();
}

class _CalDavSettingsScreenState extends State<CalDavSettingsScreen> {
  bool _icsBusy = false;

  // ---- phone calendars ------------------------------------------------------

  List<PhoneCalendar>? _phoneCalendars;
  bool _phoneDenied = false;

  DeviceCalendarService? get _device => widget.device?.isSupported == true ? widget.device : null;

  @override
  void initState() {
    super.initState();
    // calendars chosen earlier: list them again without asking anything new
    final device = _device;
    if (device != null && device.selected.isNotEmpty) _loadPhoneCalendars();
  }

  Future<void> _loadPhoneCalendars() async {
    List<PhoneCalendar>? list;
    try {
      list = await _device!.requestCalendars();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Phone calendars: {error}', {'error': e}))));
    }
    if (!mounted) return;
    setState(() {
      _phoneCalendars = list;
      _phoneDenied = list == null;
    });
  }

  List<Widget> _phoneSection() {
    final device = _device!;
    final calendars = _phoneCalendars;
    return [
      const Divider(height: 48),
      Text('On this phone', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('Show events from the calendars set up on this phone (read-only). '
          'If the phone already syncs your Nextcloud calendar, choose it here or above, not both: '
          'its events would appear twice.'),
      const SizedBox(height: 8),
      if (calendars == null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _loadPhoneCalendars,
            icon: const Icon(Icons.phone_android),
            label: const Text('Choose phone calendars'),
          ),
        ),
      if (_phoneDenied)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Calendar access was not allowed. Allow it for this app in the system settings, then try again.',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      for (final c in calendars ?? const <PhoneCalendar>[])
        CheckboxListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text.verbatim(c.name),
          subtitle: c.account == null ? null : Text.verbatim(c.account!),
          value: device.selected.contains(c.id),
          onChanged: (v) async {
            final next = {...device.selected};
            v == true ? next.add(c.id) : next.remove(c.id);
            await device.setSelected(next);
            if (mounted) setState(() {});
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calendars')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('A Nextcloud calendar is connected in the settings under Sharing and files, with the other services.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              if (_device != null) ..._phoneSection(),
              if (widget.ics != null) ..._icsSection(widget.ics!),
            ],
          ),
        ),
      ),
    );
  }

  // ---- .ics files and links -------------------------------------------------

  static Future<({String name, String content})?> _chooseFile() async {
    final file = await FilePicker.pickFile(
      type: pickerFilter(const ['ics', 'ical', 'ifb']).type,
      allowedExtensions: pickerFilter(const ['ics', 'ical', 'ifb']).extensions,
    );
    if (file == null) return null;
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on Exception {
      throw const FormatException('The file could not be read.');
    }
    return (name: file.name, content: utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _icsAction(Future<String> Function() action) async {
    setState(() => _icsBusy = true);
    String message;
    try {
      message = await action();
    } on FormatException catch (e) {
      message = e.message;
    } catch (e) {
      message = tr('That did not work: {error}', {'error': e});
    }
    if (!mounted) return;
    setState(() => _icsBusy = false);
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _importFile() => _icsAction(() async {
        final file = await (widget.pickIcsFile ?? _chooseFile)();
        if (file == null) return '';
        final source = await widget.ics!.importFile(file.name, file.content);
        return trCount(source.eventCount, 'Imported 1 event into "{name}".', 'Imported {n} events into "{name}".').replaceAll('{name}', source.name);
      });

  Future<void> _addLink() async {
    final controller = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Follow a calendar link'),
        content: TextField(
          key: const ValueKey('ics-link'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: tr('Address of the .ics calendar'),
            hintText: tr('https:// or webcal://'),
            helperText: tr('The calendar is read again when it gets old. Read-only.'),
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('ics-link-add'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Add')),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (address == null || address.trim().isEmpty) return;
    await _icsAction(() async {
      final source = await widget.ics!.addLink(address);
      return trCount(source.eventCount, 'Added "{name}" with 1 event.', 'Added "{name}" with {n} events.').replaceAll('{name}', source.name);
    });
  }

  Future<void> _renameIcs(IcsSource s) async {
    final controller = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Rename the calendar'),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Rename')),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name != null) await widget.ics!.rename(s.id, name);
  }

  List<Widget> _icsSection(IcsCalendarService ics) {
    return [
      const Divider(height: 48),
      Text('Calendar files and links', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('Import an .ics file (an export from Google, Apple, Outlook, a timetable...) or follow a link to one. '
          'Their events show in the calendar, read-only; nothing is sent anywhere.'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          key: const ValueKey('ics-import'),
          onPressed: _icsBusy ? null : _importFile,
          icon: _icsBusy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
              : const Icon(Icons.upload_file),
          label: const Text('Import a file'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('ics-add-link'),
          onPressed: _icsBusy ? null : _addLink,
          icon: const Icon(Icons.link),
          label: const Text('Follow a link'),
        ),
      ]),
      ListenableBuilder(
        listenable: ics,
        builder: (context, _) => Column(children: [
          for (final s in ics.sources)
            ListTile(
              key: ValueKey('ics-${s.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(s.url == null ? Icons.event_note : Icons.rss_feed),
              title: Text.verbatim(s.name),
              subtitle: Text.verbatim('${trCount(s.eventCount, '1 event', '{n} events')} - '
                  '${s.url == null ? tr('from a file') : tr('from a link')}, '
                  '${s.importedAt.year}-${s.importedAt.month.toString().padLeft(2, '0')}-${s.importedAt.day.toString().padLeft(2, '0')}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (s.url != null)
                  IconButton(
                    key: ValueKey('ics-refresh-${s.id}'),
                    tooltip: tr('Read it again'),
                    icon: const Icon(Icons.refresh),
                    onPressed: _icsBusy
                        ? null
                        : () => _icsAction(() async {
                              await ics.refresh(s.id);
                              return tr('Updated "{name}".', {'name': s.name});
                            }),
                  ),
                IconButton(tooltip: tr('Rename'), icon: const Icon(Icons.edit_outlined), onPressed: () => _renameIcs(s)),
                IconButton(
                  key: ValueKey('ics-remove-${s.id}'),
                  tooltip: tr('Remove'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => ics.remove(s.id),
                ),
              ]),
            ),
        ]),
      ),
    ];
  }
}
