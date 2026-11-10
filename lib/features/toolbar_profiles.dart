import 'dart:convert';

import 'feature.dart';

/// The tools of the app that are not part of the editor (the calendar and the automations belong to the app as a whole): a toolbar
/// profile leaves them as they are when it is chosen.
const _appTools = {Feature.calendar, Feature.automations};

/// The tools a toolbar profile chooses from: all that show up in the editor, in its toolbars, drawing bar and menus. A profile only
/// leaves tools out; it never switches one on that the settings have off.
final toolbarTools = [for (final f in Feature.values) if (!_appTools.contains(f)) f];

/// What profiles saved without a record of their tools covered: the writing, creative and maths groups.
final _firstToolbarTools = {
  for (final f in Feature.values)
    if (f.group == FeatureGroup.writing || f.group == FeatureGroup.creative || f.group == FeatureGroup.maths) f,
};

/// A named arrangement of the editor's toolbars with the tools it uses, for switching between ways of working
/// (drawing, maths...) in one tap.
class ToolbarProfile {
  final String id;
  final String name;

  /// The sections of the top bar and of the bottom bar, in order (see `_toolbarSections` of the editor).
  final List<String> top;
  final List<String> bottom;

  /// The sections left out of the bars.
  final Set<String> hidden;

  /// The tools of [toolbarTools] this profile uses. What the editor shows is these and what the settings have on.
  final Set<Feature> tools;

  const ToolbarProfile({required this.id, required this.name, required this.top, required this.bottom, required this.hidden, required this.tools});

  ToolbarProfile copyWith({String? name, List<String>? top, List<String>? bottom, Set<String>? hidden, Set<Feature>? tools}) =>
      ToolbarProfile(id: id, name: name ?? this.name, top: top ?? this.top, bottom: bottom ?? this.bottom, hidden: hidden ?? this.hidden, tools: tools ?? this.tools);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'top': top,
        'bottom': bottom,
        'hidden': hidden.toList(),
        'tools': [for (final f in tools) f.name],
        // (what this version of the app had to choose from, so that a tool added later is not taken for one that was left off)
        'known': [for (final f in toolbarTools) f.name],
      };

  /// A profile from its saved form, null if it is not one.
  static ToolbarProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;
    List<String> strings(String key) => [for (final s in (json[key] as List? ?? const [])) s as String];
    try {
      final known = json['known'] == null ? _firstToolbarTools : {for (final t in strings('known')) ?Feature.byId(t)};
      return ToolbarProfile(
        id: id,
        name: name,
        top: strings('top'),
        bottom: strings('bottom'),
        hidden: strings('hidden').toSet(),
        tools: {
          for (final t in strings('tools')) ?Feature.byId(t),
          // a tool the profile did not know of is on, as for [FeatureSettings]
          ...toolbarTools.where((f) => !known.contains(f)),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

/// A profile for each of [areas] that is a way of working (not working together), with the arrangement of the toolbars the
/// app starts with: the tools of the basics and of that use only, and those of working together if that is chosen too.
/// [name] gives the name of a use (translated).
List<ToolbarProfile> profilesForAreas(Iterable<UseArea> areas, String Function(UseArea) name) {
  final together = areas.contains(UseArea.together) ? UseArea.together.features : const <Feature>{};
  return [
    for (final a in UseArea.values)
      if (areas.contains(a) && a != UseArea.together)
        ToolbarProfile(
          id: 'area-${a.name}',
          name: name(a),
          top: const [],
          bottom: const [],
          hidden: const {},
          tools: {...FeaturePresets.basics, ...a.features, ...together}.where(toolbarTools.contains).toSet(),
        ),
  ];
}

typedef ToolbarProfiles = ({List<ToolbarProfile> profiles, String? active});

/// The saved profiles and the one in use; anything unreadable means none. An active profile that is not in the list is none.
ToolbarProfiles decodeToolbarProfiles(String? saved) {
  const none = (profiles: <ToolbarProfile>[], active: null);
  if (saved == null) return none;
  try {
    final json = jsonDecode(saved) as Map<String, dynamic>;
    final profiles = [for (final p in (json['profiles'] as List? ?? const [])) ?ToolbarProfile.fromJson(p)];
    final active = json['active'];
    return (profiles: profiles, active: profiles.any((p) => p.id == active) ? active as String : profiles.firstOrNull?.id);
  } catch (_) {
    return none;
  }
}

String encodeToolbarProfiles(List<ToolbarProfile> profiles, String? active) =>
    jsonEncode({'active': active, 'profiles': [for (final p in profiles) p.toJson()]});
