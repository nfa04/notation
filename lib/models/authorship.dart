/// Who is using this device, as it goes on what they add to a note (a stroke, a text box, a picture, a highlight),
/// so that a note that several people work on, in a live session or on copies, knows who added what.
///
/// What is stored with a thing is an *author* string: `<user id>:<name>` when the person has an id (they all do
/// once the app has started: the id is made on first use and never changes, so two people who both call themselves
/// "Ben" stay apart), or just the name for what was made before ids, or by an older version. [Author] reads and
/// writes it.
class Authorship {
  static String? _name;
  static String? _id;

  /// The name to show for the person using this device; null while there is none.
  static String? get name => _name;

  /// The id of the person using this device (set when the app starts); null in tests that do not have one.
  static String? get id => _id;

  /// What goes on what the person adds now: null if there is neither a name nor an id.
  static String? get current => Author.encode(_name, _id);

  /// Sets the name (nothing for an empty one); the id stays.
  static void set(String? value) {
    final v = value?.trim();
    _name = v == null || v.isEmpty ? null : v;
  }

  /// Sets the id of the person (see [Author.isId]); null for none.
  static void setId(String? value) => _id = value != null && Author.isId(value) ? value : null;
}

/// An author as written with a thing: a name and, usually, the id of the person.
class Author {
  final String? id;
  final String name;

  const Author(this.name, {this.id});

  static final _idPattern = RegExp(r'^[0-9a-f]{16}$');

  /// Whether [value] looks like the id of a person (16 hex digits).
  static bool isId(String value) => _idPattern.hasMatch(value);

  /// The string to write for [name] and [id]; null if both are missing.
  static String? encode(String? name, String? id) {
    final n = name?.trim() ?? '';
    if (id == null || !isId(id)) return n.isEmpty ? null : n;
    return '$id:$n';
  }

  /// Reads an author string (null for null).
  static Author? parse(String? text) {
    if (text == null) return null;
    if (text.length > 17 && text[16] == ':' && isId(text.substring(0, 16))) return Author(text.substring(17), id: text.substring(0, 16));
    if (text.length == 17 && text[16] == ':' && isId(text.substring(0, 16))) return Author('', id: text.substring(0, 16));
    return Author(text);
  }

  /// The short form of an id to tell two people of one name apart: its first four digits.
  static String shortId(String id) => id.substring(0, 4);

  /// The words to show for each of [authors] (author strings, or null for not known): the name, with the start of
  /// the id after it where two different people have the same name ("Ben (#a3f2)"), and "Unnamed" for none.
  /// [unknown] is the word for null.
  static Map<String?, String> labels(Iterable<String?> authors, {required String unknown, required String unnamed}) {
    final distinct = {...authors};
    final parsed = {for (final a in distinct) a: parse(a)};
    final byName = <String, int>{};
    for (final a in parsed.values) {
      if (a != null) byName[a.name] = (byName[a.name] ?? 0) + 1;
    }
    return {
      for (final e in parsed.entries)
        e.key: switch (e.value) {
          null => unknown,
          final a => () {
              final base = a.name.isEmpty ? unnamed : a.name;
              final clash = (byName[a.name] ?? 0) > 1 || a.name.isEmpty;
              return clash && a.id != null ? '$base (#${shortId(a.id!)})' : base;
            }(),
        },
    };
  }
}
