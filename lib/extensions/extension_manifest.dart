import '../models/brush.dart';

/// What an extension may be allowed to do. Each is asked for in the manifest and granted by the person, one by one; what is
/// not granted fails when the script tries it.
enum ExtensionPermission {
  noteRead('note.read', 'Read the text and the title of the note it is used on'),
  noteWrite('note.write', 'Change the text, the title, the text boxes and the pictures of the note it is used on'),
  notesReadAll('notes.readAll', 'Search and read all of your notes, not only the one it is used on'),
  notesManage('notes.manage', 'Create notes, and file notes in folders and with tags'),
  notesDelete('notes.delete', 'Move notes to the trash, and bring them back'),
  drawPage('draw.page', 'Draw lines and shapes on the pages of the note it is used on'),
  pagesEdit('pages.edit', 'Add, delete and move the pages of the note it is used on, and set up their paper'),
  calendarManage('calendar.manage', 'See the events of your calendars and add events to them'),
  remindersManage('reminders.manage', 'See, set and remove reminders'),
  cardsAdd('cards.add', 'Make flashcards for review from the note it is used on'),
  tasks('tasks.add', 'Add tasks to your calendar'),
  tasksManage('tasks.manage', 'See your tasks, change them, tick them off and delete them'),
  clipboard('clipboard.write', 'Put text on the clipboard'),
  network('network', 'Send requests to the websites it lists'),
  eventsEmit('events.emit', 'Announce the events it lists, which automations can react to'),
  draw('draw.add', 'Draw on the pages with the drawing tools it lists');

  final String id;
  final String description;
  const ExtensionPermission(this.id, this.description);

  static ExtensionPermission? byId(String id) => values.where((p) => p.id == id).firstOrNull;
}

/// The manifest of an extension is not valid; [message] says why (shown when the extension is added).
class ManifestException implements Exception {
  final String message;
  ManifestException(this.message);
  @override
  String toString() => message;
}

/// A tool of an extension: it appears in the menu of selected text.
class ExtensionTool {
  final String id, title;
  const ExtensionTool(this.id, this.title);
}

/// An action of an extension: it can be chosen in the automations.
class ExtensionActionDef {
  final String id, title;
  const ExtensionActionDef(this.id, this.title);
}

/// An event of an extension: it announces it with `notation.events.emit`, and an automation can be made for it.
class ExtensionEventDef {
  final String id, title;
  const ExtensionEventDef(this.id, this.title);
}

/// A brush of an extension: a pen that draws with the look [params] describe. No code, and no permission.
class ExtensionBrushDef {
  final String id, title;
  final BrushParams params;
  const ExtensionBrushDef(this.id, this.title, this.params);

  /// The id the brush has in the notes: the extension's, then its own.
  String brushId(String extensionId) => 'ext:$extensionId/$id';
}

/// What a drawing tool shows while the pen is being dragged, before the extension makes its drawing of it.
enum DrawPreview {
  path('path'),
  line('line'),
  rect('rect'),
  ellipse('ellipse');

  final String id;
  const DrawPreview(this.id);

  static DrawPreview? byId(Object? id) => values.where((p) => p.id == id).firstOrNull;
}

/// A drawing tool of an extension: it appears in the drawing bar; a drag with the pen is handed to the extension, which answers
/// with the lines to draw.
class ExtensionDrawTool {
  final String id, title;
  final DrawPreview preview;
  const ExtensionDrawTool(this.id, this.title, [this.preview = DrawPreview.path]);
}

/// The description of an extension (`manifest.json`): what it is called, what it adds to the app and what it asks to be
/// allowed to do. The script itself is `main` (a `.js` file next to it).
class ExtensionManifest {
  final String id, name, version, description, author, main;
  final Set<ExtensionPermission> permissions;

  /// The websites it may send requests to (with the permission `network`), by name, no more.
  final List<String> hosts;
  final List<ExtensionTool> tools;
  final List<ExtensionActionDef> actions;
  final List<ExtensionEventDef> events;
  final List<ExtensionBrushDef> brushes;
  final List<ExtensionDrawTool> drawTools;

  const ExtensionManifest({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.main = 'main.js',
    this.permissions = const {},
    this.hosts = const [],
    this.tools = const [],
    this.actions = const [],
    this.events = const [],
    this.brushes = const [],
    this.drawTools = const [],
  });

  static final _id = RegExp(r'^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$');
  static final _part = RegExp(r'^[a-z0-9_-]{1,40}$');
  static final _file = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,60}\.js$');
  static final _host = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');

  /// Reads and checks a manifest. Anything that is not right is refused with a reason a person can read.
  factory ExtensionManifest.fromJson(Object? json) {
    if (json is! Map) throw ManifestException('The manifest is not a JSON object.');
    String text(String key, {bool required = false, int max = 400}) {
      final v = json[key];
      if (v == null) {
        if (required) throw ManifestException('The manifest has no "$key".');
        return '';
      }
      if (v is! String) throw ManifestException('"$key" has to be text.');
      final t = v.trim();
      if (required && t.isEmpty) throw ManifestException('"$key" is empty.');
      if (t.length > max) throw ManifestException('"$key" is too long.');
      return t;
    }

    List<Map> items(String key) {
      final v = json[key];
      if (v == null) return const [];
      if (v is! List || v.length > 20 || v.any((e) => e is! Map)) throw ManifestException('"$key" has to be a list of at most 20 entries.');
      return v.cast<Map>();
    }

    final id = text('id', required: true, max: 64);
    if (!_id.hasMatch(id)) throw ManifestException('"id" has to be 3 to 64 letters (a-z), digits, "." "-" or "_".');
    final main = text('main', max: 64).isEmpty ? 'main.js' : text('main', max: 64);
    if (!_file.hasMatch(main)) throw ManifestException('"main" has to be a .js file next to the manifest.');

    final perms = <ExtensionPermission>{};
    final rawPerms = json['permissions'];
    if (rawPerms != null) {
      if (rawPerms is! List) throw ManifestException('"permissions" has to be a list.');
      for (final p in rawPerms) {
        final perm = p is String ? ExtensionPermission.byId(p) : null;
        if (perm == null) throw ManifestException('Unknown permission: $p');
        perms.add(perm);
      }
    }
    final hosts = <String>[];
    final rawHosts = json['hosts'];
    if (rawHosts != null) {
      if (rawHosts is! List || rawHosts.length > 10) throw ManifestException('"hosts" has to be a list of at most 10 names.');
      for (final h in rawHosts) {
        if (h is! String || !_host.hasMatch(h.toLowerCase())) throw ManifestException('"$h" is not a website name (no http://, no path, no *).');
        hosts.add(h.toLowerCase());
      }
    }
    if (perms.contains(ExtensionPermission.network) && hosts.isEmpty) throw ManifestException('The permission "network" needs "hosts": the websites it may talk to.');
    if (hosts.isNotEmpty && !perms.contains(ExtensionPermission.network)) throw ManifestException('"hosts" is only for the permission "network".');

    ({String id, String title}) entry(Map m, String what) {
      final eid = m['id'], title = m['title'];
      if (eid is! String || !_part.hasMatch(eid)) throw ManifestException('A $what has no valid "id" (a-z, digits, "-" "_").');
      if (title is! String || title.trim().isEmpty || title.length > 60) throw ManifestException('The $what "$eid" has no "title" (up to 60 letters).');
      return (id: eid, title: title.trim());
    }

    final tools = [for (final m in items('tools')) () { final e = entry(m, 'tool'); return ExtensionTool(e.id, e.title); }()];
    final actions = [for (final m in items('actions')) () { final e = entry(m, 'action'); return ExtensionActionDef(e.id, e.title); }()];
    final events = [for (final m in items('events')) () { final e = entry(m, 'event'); return ExtensionEventDef(e.id, e.title); }()];
    if (events.isNotEmpty && !perms.contains(ExtensionPermission.eventsEmit)) throw ManifestException('"events" needs the permission "events.emit".');
    if (events.isEmpty && perms.contains(ExtensionPermission.eventsEmit)) throw ManifestException('The permission "events.emit" needs "events": the events it announces.');

    double number(Map m, String key, String what, double fallback, double min, double max) {
      final v = m[key];
      if (v == null) return fallback;
      if (v is! num || !v.isFinite || v < min || v > max) throw ManifestException('"$key" of the brush "$what" has to be a number from $min to $max.');
      return v.toDouble();
    }

    final brushes = [
      for (final m in items('brushes'))
        () {
          final e = entry(m, 'brush');
          return ExtensionBrushDef(
            e.id,
            e.title,
            BrushParams(
              width: number(m, 'width', e.id, 1, 0.2, 10),
              pressure: number(m, 'pressure', e.id, 0, 0, 1),
              smoothing: number(m, 'smoothing', e.id, 0.5, 0, 1),
              taper: number(m, 'taper', e.id, 0, 0, 1),
              opacity: number(m, 'opacity', e.id, 1, 0.05, 1),
              jitter: number(m, 'jitter', e.id, 0, 0, 1),
              nibAngle: m['nibAngle'] == null ? null : number(m, 'nibAngle', e.id, 0, -180, 180),
              nibFlatness: number(m, 'nibFlatness', e.id, 0.15, 0.02, 1),
            ),
          );
        }(),
    ];
    final drawTools = [
      for (final m in items('drawTools'))
        () {
          final e = entry(m, 'drawing tool');
          final preview = m['preview'] == null ? DrawPreview.path : DrawPreview.byId(m['preview']);
          if (preview == null) throw ManifestException('"preview" of the drawing tool "${e.id}" has to be one of path, line, rect, ellipse.');
          return ExtensionDrawTool(e.id, e.title, preview);
        }(),
    ];
    if (drawTools.isNotEmpty && !perms.contains(ExtensionPermission.draw)) throw ManifestException('"drawTools" needs the permission "draw.add".');
    if (drawTools.isEmpty && perms.contains(ExtensionPermission.draw)) throw ManifestException('The permission "draw.add" needs "drawTools": the tools that draw.');
    for (final ids in [brushes.map((b) => b.id).toList(), drawTools.map((t) => t.id).toList()]) {
      if (ids.toSet().length != ids.length) throw ManifestException('Two entries have the same "id".');
    }
    for (final ids in [tools.map((t) => t.id).toList(), actions.map((a) => a.id).toList(), events.map((e) => e.id).toList()]) {
      if (ids.toSet().length != ids.length) throw ManifestException('Two entries have the same "id".');
    }
    return ExtensionManifest(
      id: id,
      name: text('name', required: true, max: 60),
      version: text('version', required: true, max: 20),
      description: text('description'),
      author: text('author', max: 80),
      main: main,
      permissions: perms,
      hosts: hosts,
      tools: tools,
      actions: actions,
      events: events,
      brushes: brushes,
      drawTools: drawTools,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        if (description.isNotEmpty) 'description': description,
        if (author.isNotEmpty) 'author': author,
        'main': main,
        'permissions': [for (final p in permissions) p.id],
        if (hosts.isNotEmpty) 'hosts': hosts,
        'tools': [for (final t in tools) {'id': t.id, 'title': t.title}],
        'actions': [for (final a in actions) {'id': a.id, 'title': a.title}],
        if (events.isNotEmpty) 'events': [for (final e in events) {'id': e.id, 'title': e.title}],
        if (brushes.isNotEmpty)
          'brushes': [
            for (final b in brushes)
              {
                'id': b.id,
                'title': b.title,
                'width': b.params.width,
                'pressure': b.params.pressure,
                'smoothing': b.params.smoothing,
                'taper': b.params.taper,
                'opacity': b.params.opacity,
                'jitter': b.params.jitter,
                if (b.params.nibAngle != null) 'nibAngle': b.params.nibAngle,
                'nibFlatness': b.params.nibFlatness,
              },
          ],
        if (drawTools.isNotEmpty) 'drawTools': [for (final t in drawTools) {'id': t.id, 'title': t.title, 'preview': t.preview.id}],
      };
}
