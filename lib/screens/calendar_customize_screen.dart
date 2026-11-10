import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../style/calendar_style.dart';
import '../style/style_dialog.dart';
import '../data/style_repository.dart';
import '../style/style_service.dart';
import '../style/styled_box.dart';
import '../sync/caldav_remote.dart';
import '../sync/caldav_service.dart';
import '../sync/device_calendar_service.dart';
import '../sync/ics_service.dart';
import '../style/platform_dialog.dart';

const _backgrounds = [
  Color(0xFFFFFFFF), Color(0xFFFFF4F8), Color(0xFFFFF6EF), Color(0xFFFFFBE6),
  Color(0xFFF4F9F1), Color(0xFFF1F8FD), Color(0xFFF7F4FD), Color(0xFFF3F3F3),
];

/// Themes and looks for the calendar. Stays on this device: none of it is
/// sent to a CalDAV server or the phone's calendar.
class CalendarCustomizeScreen extends StatelessWidget {
  final StyleService style;
  final CalDavService? caldav;
  final DeviceCalendarService? device;
  final IcsCalendarService? ics;

  const CalendarCustomizeScreen({super.key, required this.style, this.caldav, this.device, this.ics});

  Future<List<CalendarInfo>> _calendars() async => [
        ...await (caldav?.eventCalendars() ?? Future.value(const <CalendarInfo>[])),
        ...await (device?.selectedCalendars() ?? Future.value(const <CalendarInfo>[])),
        ...?ics?.calendarInfos(),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Make it cute')),
      body: ListenableBuilder(
        listenable: style,
        builder: (context, _) {
          final theme = style.theme;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  _preview(context),
                  _title(context, 'Themes'),
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final p in themePresets)
                      ChoiceChip(
                        avatar: Text.verbatim(p.emoji),
                        label: Text(p.name),
                        selected: theme == p.theme,
                        onSelected: (_) => style.setTheme(p.theme),
                      ),
                  ]),
                  _title(context, 'Colors'),
                  const Text('Calendar background'),
                  const SizedBox(height: 6),
                  _swatches(context, theme.background ?? _backgrounds.first, _backgrounds,
                      (c) => style.setTheme(c == _backgrounds.first ? theme.copyWith(clearBackground: true) : theme.copyWith(background: c))),
                  const SizedBox(height: 6),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use my palette instead of the calendars\' own colors'),
                    subtitle: _paletteDots(theme.palette),
                    value: theme.paletteOverridesServerColors,
                    onChanged: (v) => style.setTheme(theme.copyWith(paletteOverridesServerColors: v)),
                  ),
                  _title(context, 'Shape'),
                  _slider(context, 'Corners', theme.radius, 0, 24, (v) => style.setTheme(theme.copyWith(radius: v))),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final b in BorderKind.values)
                      ChoiceChip(
                        label: Text(b.label),
                        selected: theme.border == b,
                        onSelected: (_) => style.setTheme(theme.copyWith(border: b)),
                      ),
                  ]),
                  _slider(context, 'Border thickness', theme.borderWidth, 1, 4, (v) => style.setTheme(theme.copyWith(borderWidth: v))),
                  _title(context, 'Calendars'),
                  const Text('Give each calendar its own color, border and emoji. '
                      'Single events, tasks and days: press and hold (or right-click) them.'),
                  const SizedBox(height: 8),
                  FutureBuilder<List<CalendarInfo>>(
                    future: _calendars(),
                    builder: (context, snapshot) {
                      final list = snapshot.data ?? const <CalendarInfo>[];
                      if (list.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            snapshot.connectionState == ConnectionState.done
                                ? 'No calendars connected yet: add them with the cloud button in the calendar.'
                                : 'Loading...',
                            style: TextStyle(color: Theme.of(context,).colorScheme.onSurfaceVariant),
                          ),
                        );
                      }
                      return Column(children: [for (final c in list) _calendarTile(context, c)]);
                    },
                  ),
                  _title(context, 'Start over'),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton(
                      onPressed: () => style.setTheme(CalendarTheme.standard),
                      child: const Text('Back to the classic theme'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => PlatformAlertDialog(
                            title: const Text('Remove all custom looks?'),
                            content: const Text('Colors, borders and emoji given to single calendars, events, tasks and days are removed. The theme stays.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                            ],
                          ),
                        );
                        if (ok == true) await style.resetItems();
                      },
                      child: const Text('Remove all custom looks'),
                    ),
                  ]),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _title(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 28, bottom: 10),
        child: Text(text, style: Theme.of(context,).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      );

  /// What the current theme looks like, live.
  Widget _preview(BuildContext context) {
    final theme = style.theme;
    final event = style.resolveCalendar('preview-a');
    final other = ResolvedStyle(
      color: style.paletteColor('preview-b'),
      border: theme.border,
      borderWidth: theme.borderWidth,
      radius: theme.radius,
      emoji: '📚',
    );
    final task = ResolvedStyle(
      color: style.app.accent,
      border: theme.border,
      borderWidth: theme.borderWidth,
      radius: theme.radius,
      emoji: '✨',
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: style.backgroundFor(Theme.of(context).brightness) ?? Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 14, backgroundColor: style.app.accent, child: const Text('18', style: TextStyle(color: Colors.white, fontSize: 12))),
          const SizedBox(width: 10),
          const Text('Preview', style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 12),
        StyledBox(style: event, padding: const EdgeInsets.all(10), child: const Text('Brunch with friends')),
        const SizedBox(height: 8),
        StyledBox(style: other, padding: const EdgeInsets.all(10), child: Text(other.label('Study group'))),
        const SizedBox(height: 8),
        StyledBox(style: task, padding: const EdgeInsets.all(10), child: Text(task.label('Hand in essay'))),
      ]),
    );
  }

  Widget _paletteDots(List<Color> palette) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          for (final c in palette)
            Container(width: 16, height: 16, margin: const EdgeInsets.only(right: 4), decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        ]),
      );

  Widget _swatches(BuildContext context, Color selected, List<Color> colors, ValueChanged<Color> onPick) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final c in colors)
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () => onPick(c),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              border: Border.all(
                color: c == selected ? Theme.of(context).colorScheme.primary : Colors.black26,
                width: c == selected ? 3 : 1,
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _slider(BuildContext context, String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 120, child: Text(label)),
      Expanded(child: Slider.adaptive(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
      SizedBox(width: 36, child: Text(value.toStringAsFixed(0))),
    ]);
  }

  Widget _calendarTile(BuildContext context, CalendarInfo c) {
    final resolved = style.resolveCalendar(c.key, serverColor: c.color);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: StyledBox(
        style: resolved,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(resolved.emoji ?? '  '),
      ),
      title: Text.verbatim(c.name),
      trailing: const Icon(Icons.brush_outlined),
      onTap: () async {
        final result = await showStyleDialog(
          context,
          title: c.name,
          sample: c.name,
          initial: style.styleOf(StyleScope.calendar, c.key) ?? const ItemStyle(),
          base: style.resolveCalendar(c.key, serverColor: c.color, ownLook: false),
        );
        if (result != null) await style.setStyle(StyleScope.calendar, c.key, result);
      },
    );
  }
}
