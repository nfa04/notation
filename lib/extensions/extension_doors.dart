import 'extension_manifest.dart' show ManifestException;

/// The "doors" an extension can add to the app besides tools and actions: importers, exporters, commands, settings, rendered blocks,
/// events it reacts to, capture handlers, agent tools and no-code templates. Each is described in the manifest and checked here, with
/// a reason a person can read when it is wrong.

final _part = RegExp(r'^[a-z0-9_-]{1,40}$');

({String id, String title}) _entry(Map m, String what) {
  final id = m['id'], title = m['title'];
  if (id is! String || !_part.hasMatch(id)) throw ManifestException('A $what has no valid "id" (a-z, digits, "-" "_").');
  if (title is! String || title.trim().isEmpty || title.length > 60) throw ManifestException('The $what "$id" has no "title" (up to 60 letters).');
  return (id: id, title: title.trim());
}

List<Map> _list(Object? v, String key, {int max = 20}) {
  if (v == null) return const [];
  if (v is! List || v.length > max || v.any((e) => e is! Map)) throw ManifestException('"$key" has to be a list of at most $max entries.');
  return v.cast<Map>();
}

List<String> _words(Object? v, String what, {int max = 10, int length = 40, RegExp? pattern}) {
  if (v == null) return const [];
  if (v is! List || v.length > max || v.any((e) => e is! String || e.isEmpty || e.length > length || (pattern != null && !pattern.hasMatch(e)))) {
    throw ManifestException('$what has to be a list of at most $max short words.');
  }
  return v.cast<String>();
}

String _optText(Map m, String key, String what, {int max = 200}) {
  final v = m[key];
  if (v == null) return '';
  if (v is! String || v.length > max) throw ManifestException('"$key" of $what has to be text of up to $max letters.');
  return v.trim();
}

/// A way to bring notes in from somewhere else: its script gets the files the person picked (or nothing, for an account) and answers
/// with the notes to make.
class ExtensionImporter {
  final String id, title, description;

  /// What it takes: file endings (`.enex`), `folder`, `zip` or `account` (no files: the script fetches by itself).
  final List<String> accepts;
  const ExtensionImporter(this.id, this.title, this.accepts, [this.description = '']);

  bool get fromAccount => accepts.contains('account');
  bool get fromFolder => accepts.contains('folder');

  /// The endings of files to offer in the picker (without the dot); empty: any.
  List<String> get extensions => [
        for (final a in accepts)
          if (a.startsWith('.')) a.substring(1).toLowerCase() else if (a == 'zip') 'zip',
      ];

  static final _accept = RegExp(r'^(\.[a-z0-9]{1,8}|folder|zip|account)$');

  static List<ExtensionImporter> parse(Object? json) => [
        for (final m in _list(json, 'importers'))
          () {
            final e = _entry(m, 'importer');
            final accepts = _words(m['accepts'], 'The "accepts" of the importer "${e.id}"', pattern: _accept);
            if (accepts.isEmpty) throw ManifestException('The importer "${e.id}" needs "accepts": file endings like ".enex", "folder", "zip" or "account".');
            if (accepts.contains('account') && accepts.length > 1) throw ManifestException('The importer "${e.id}": "account" cannot be mixed with files.');
            return ExtensionImporter(e.id, e.title, accepts, _optText(m, 'description', 'the importer "${e.id}"'));
          }(),
      ];

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'accepts': accepts, if (description.isNotEmpty) 'description': description};
}

/// A way to write a note out as a file of another kind.
class ExtensionExporter {
  final String id, title;

  /// The ending of the file it makes, without the dot (`tex`).
  final String extension;
  const ExtensionExporter(this.id, this.title, this.extension);

  static List<ExtensionExporter> parse(Object? json) => [
        for (final m in _list(json, 'exporters'))
          () {
            final e = _entry(m, 'exporter');
            final ext = m['extension'];
            if (ext is! String || !RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext)) throw ManifestException('The exporter "${e.id}" needs an "extension" like "tex" (letters and digits, no dot).');
            return ExtensionExporter(e.id, e.title, ext);
          }(),
      ];

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'extension': extension};
}

/// Where a command shows up.
enum CommandPlace {
  noteMenu('noteMenu'),
  dashboard('dashboard'),
  palette('palette');

  final String id;
  const CommandPlace(this.id);
  static CommandPlace? byId(Object? id) => values.where((p) => p.id == id).firstOrNull;
}

/// Something the person can run without selecting text: from the menu of a note, the dashboard or the list of commands; it can also be
/// bound to a key and used by automations.
class ExtensionCommand {
  final String id, title;
  final List<CommandPlace> where;
  const ExtensionCommand(this.id, this.title, [this.where = const [CommandPlace.palette, CommandPlace.noteMenu]]);

  static List<ExtensionCommand> parse(Object? json) => [
        for (final m in _list(json, 'commands'))
          () {
            final e = _entry(m, 'command');
            final raw = m['where'];
            final places = <CommandPlace>[];
            if (raw != null) {
              if (raw is! List || raw.length > 3) throw ManifestException('"where" of the command "${e.id}" has to be a list of noteMenu, dashboard, palette.');
              for (final r in raw) {
                final p = CommandPlace.byId(r);
                if (p == null) throw ManifestException('"where" of the command "${e.id}": "$r" is not noteMenu, dashboard or palette.');
                if (!places.contains(p)) places.add(p);
              }
            }
            return ExtensionCommand(e.id, e.title, places.isEmpty ? const [CommandPlace.palette, CommandPlace.noteMenu] : places);
          }(),
      ];

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'where': [for (final p in where) p.id]};
}

/// What a field of settings, of a form or of an action holds.
enum FieldType {
  text('text'),
  number('number'),
  boolean('boolean'),
  choice('choice'),
  secret('secret'),
  date('date');

  final String id;
  const FieldType(this.id);
  static FieldType? byId(Object? id) => values.where((p) => p.id == id).firstOrNull;
}

/// A field: a setting of an extension, an option of one of its actions, or a line of a form it shows.
class ExtensionField {
  final String id, title;
  final FieldType type;
  final Object? initial;
  final Map<String, String> choices;
  const ExtensionField(this.id, this.title, this.type, {this.initial, this.choices = const {}});

  static List<ExtensionField> parse(Object? json, String key, {int max = 20, bool allowSecret = true}) => [
        for (final m in _list(json, key, max: max))
          () {
            final e = _entry(m, 'field');
            final type = m['type'] == null ? FieldType.text : FieldType.byId(m['type']);
            if (type == null) throw ManifestException('The field "${e.id}" has an unknown "type" (text, number, boolean, choice, secret, date).');
            if (type == FieldType.secret && !allowSecret) throw ManifestException('The field "${e.id}": a secret can only be a setting.');
            final choices = <String, String>{};
            if (type == FieldType.choice) {
              final raw = m['choices'];
              if (raw is List && raw.isNotEmpty && raw.length <= 30 && raw.every((c) => c is String && c.isNotEmpty && c.length <= 60)) {
                for (final c in raw) {
                  choices[c as String] = c;
                }
              } else if (raw is Map && raw.isNotEmpty && raw.length <= 30 && raw.entries.every((c) => c.value is String && '${c.key}'.length <= 60 && (c.value as String).length <= 60)) {
                for (final c in raw.entries) {
                  choices['${c.key}'] = c.value as String;
                }
              } else {
                throw ManifestException('The choice "${e.id}" needs "choices": a list of up to 30 short texts.');
              }
            }
            final initial = m['default'];
            if (initial != null) {
              final fine = switch (type) {
                FieldType.number => initial is num && initial.isFinite,
                FieldType.boolean => initial is bool,
                FieldType.choice => initial is String && choices.containsKey(initial),
                FieldType.secret => false,
                _ => initial is String && initial.length <= 400,
              };
              if (!fine) throw ManifestException('The "default" of the field "${e.id}" does not fit its type.');
            }
            return ExtensionField(e.id, e.title, type, initial: initial, choices: choices);
          }(),
      ];

  /// The fields a script asks for in a form ([ExtensionField.parse], from what a script wrote).
  static List<ExtensionField> parseForm(List raw) {
    try {
      return parse([for (final f in raw) f is Map ? {'title': f['title'] ?? f['id'], ...f} : f], 'fields', max: 12, allowSecret: false);
    } on ManifestException catch (e) {
      throw FormatException(e.message);
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'type': type.id,
        if (initial != null) 'default': initial,
        if (choices.isNotEmpty) 'choices': choices.keys.toList(),
      };
}

/// A language of fenced code blocks that an extension draws.
class ExtensionBlock {
  final String id, title, language;
  const ExtensionBlock(this.id, this.title, this.language);

  static List<ExtensionBlock> parse(Object? json) => [
        for (final m in _list(json, 'blocks'))
          () {
            final e = _entry(m, 'block');
            final lang = m['language'];
            if (lang is! String || !RegExp(r'^[a-z0-9][a-z0-9+#_-]{0,19}$').hasMatch(lang)) throw ManifestException('The block "${e.id}" needs a "language" like "chess" (lower case, up to 20 letters).');
            return ExtensionBlock(e.id, e.title, lang);
          }(),
      ];

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'language': language};
}

/// A tool the assistant in Agent mode may call.
class ExtensionAgentTool {
  final String id, title, description;

  /// The arguments: name to a short description (all are text, numbers or true/false as the script reads them).
  final Map<String, String> args;
  const ExtensionAgentTool(this.id, this.title, this.description, this.args);

  static List<ExtensionAgentTool> parse(Object? json) => [
        for (final m in _list(json, 'agentTools', max: 10))
          () {
            final e = _entry(m, 'agent tool');
            final description = _optText(m, 'description', 'the agent tool "${e.id}"', max: 300);
            if (description.isEmpty) throw ManifestException('The agent tool "${e.id}" needs a "description" the assistant can read.');
            final raw = m['args'];
            final args = <String, String>{};
            if (raw != null) {
              if (raw is! Map || raw.length > 8) throw ManifestException('"args" of the agent tool "${e.id}" has to be an object of up to 8 entries.');
              for (final a in raw.entries) {
                if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,29}$').hasMatch('${a.key}') || a.value is! String || (a.value as String).length > 200) {
                  throw ManifestException('"args" of the agent tool "${e.id}": names are letters and digits, each with a short description.');
                }
                args['${a.key}'] = a.value as String;
              }
            }
            return ExtensionAgentTool(e.id, e.title, description, args);
          }(),
      ];

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'description': description, if (args.isNotEmpty) 'args': args};
}

/// A handler that runs for the web pages that [sites] name, when something is kept from them (a note made from a page).
class ExtensionCapture {
  final String id, title;
  final List<String> sites;
  const ExtensionCapture(this.id, this.title, this.sites);

  static final _site = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');

  static List<ExtensionCapture> parse(Object? json) => [
        for (final m in _list(json, 'capture'))
          () {
            final e = _entry(m, 'capture handler');
            final sites = _words(m['sites'], 'The "sites" of the capture handler "${e.id}"', length: 80, pattern: _site);
            if (sites.isEmpty) throw ManifestException('The capture handler "${e.id}" needs "sites": website names like "arxiv.org".');
            return ExtensionCapture(e.id, e.title, sites);
          }(),
      ];

  bool matches(String host) {
    final h = host.toLowerCase();
    return sites.any((s) => h == s || h.endsWith('.$s'));
  }

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'sites': sites};
}

/// A template note that an extension brings along, without code: [file] is a Markdown file of the package.
class ExtensionTemplate {
  final String id, title, file;
  const ExtensionTemplate(this.id, this.title, this.file);

  static final _path = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_./-]{0,80}\.md$');

  static List<ExtensionTemplate> parse(Object? json) => [
        for (final m in _list(json, 'templates', max: 30))
          () {
            final e = _entry(m, 'template');
            final file = m['file'];
            if (file is! String || !_path.hasMatch(file) || file.contains('..') || file.contains('//')) throw ManifestException('The template "${e.id}" needs a "file": a .md file of the package.');
            return ExtensionTemplate(e.id, e.title, file);
          }(),
      ];

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'file': file};
}

/// The events of the automations an extension asks to hear about.
const reactableEvents = {'noteCreated', 'noteOpened', 'noteClosed', 'notePaused', 'appStarted', 'taskCompleted', 'captureReceived', 'pdfImported', 'noteLinked'};

/// `on`: an object of event name to the id of the action that runs for it (`{ "noteClosed": "tidy" }`).
Map<String, String> parseReactions(Object? json) {
  if (json == null) return const {};
  if (json is! Map || json.length > 12) throw ManifestException('"on" has to be an object of event names and action ids.');
  final out = <String, String>{};
  for (final e in json.entries) {
    final event = '${e.key}', action = e.value;
    if (!reactableEvents.contains(event)) throw ManifestException('"on": "$event" is not an event an extension can react to (${reactableEvents.join(', ')}).');
    if (action is! String || !_part.hasMatch(action)) throw ManifestException('"on": the action for "$event" has to be the id of one of its actions.');
    out[event] = action;
  }
  return out;
}

/// The scripts of a package that come before the main one.
List<String> parseModules(Object? json, String main) {
  if (json == null) return const [];
  final path = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_./-]{0,80}\.js$');
  if (json is! List || json.length > 10 || json.any((e) => e is! String || !path.hasMatch(e) || e.contains('..') || e.contains('//') || e == main)) {
    throw ManifestException('"modules" has to be a list of up to 10 .js files of the package (not the main one).');
  }
  if (json.toSet().length != json.length) throw ManifestException('"modules" names a file twice.');
  return json.cast<String>();
}
