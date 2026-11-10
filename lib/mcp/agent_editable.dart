import '../extensions/extension_host.dart';

/// An editor that an agent outside the app (see `McpNotes`) can change the open note through. A note that is open must not be
/// written to the database behind its editor's back: the editor writes its own copy over it when it saves.
abstract class AgentEditable {
  /// What the assistant of the note can do with it: insert, replace and format text, and the title.
  ExtensionApi get agentApi;

  /// Replaces the written document with [text], as one step of the note's undo.
  Future<void> agentSetDocument(String text);
}
