# Letting an AI agent use your notes (MCP)

Notation can act as a [Model Context Protocol](https://modelcontextprotocol.io) server, so an AI agent on the same computer (Claude Code, an editor
with AI, any program that speaks MCP) can find, read and write your notes, folders, tags and tasks. It is for **Linux, macOS and Windows**; on a phone
the app is stopped as soon as it is not on the screen, so the code is left out of those builds altogether (`mcpSupported`).

It is **off** until you turn it on in *Settings > Extensions > Connect an AI agent*.

## Connecting an agent

Turn on *Let an agent use my notes*. The settings then show a token and the address, `http://127.0.0.1:7332/mcp` (the port can be changed).

* **Claude Code:** *Copy the command for Claude Code* and run it:
  `claude mcp add --transport http notation http://127.0.0.1:7332/mcp --header "Authorization: Bearer <token>"`
* **Another client that takes a server as JSON:** *Copy the settings as JSON*.
  `{"mcpServers": {"notation": {"type": "http", "url": "http://127.0.0.1:7332/mcp", "headers": {"Authorization": "Bearer <token>"}}}}`
* **A client that can only start a program** (Claude Desktop, say): `tool/notation_mcp.dart` is a bridge from stdin/stdout to the app. Compile it once
  with `dart compile exe tool/notation_mcp.dart -o notation-mcp` and give the client that program, with the token in the environment:
  `{"command": "/path/to/notation-mcp", "env": {"UNINOTES_MCP_TOKEN": "<token>"}}` (`UNINOTES_MCP_URL` if the port is not 7332).

The app has to be running. *New token* lets out every agent that has the old one.

## What an agent can do

*Read only* offers the first group; *Read and change* (the default once it is on) all of them.

| Tool | |
|---|---|
| `list_notes`, `search_notes`, `read_note`, `list_folders`, `list_tags`, `list_tasks`, `list_trash`, `inspect_note_formatting` | Look. Search covers titles, written documents, text boxes, the text of PDFs and handwriting the app has read. |
| `create_note`, `append_to_note`, `replace_in_note`, `format_note_text`, `set_note_title`, `set_note_text` | Write. `append_to_note` can put text after or before a line, or at the start. Text is Markdown. |
| `move_note`, `set_note_tags`, `set_note_favorite`, `trash_note`, `restore_note` | Organise. |
| `create_folder`, `rename_folder`, `move_folder`, `delete_folder` | Folders. Deleting one keeps its notes (in no folder). |
| `add_task`, `set_task_done`, `update_task`, `delete_task` | Tasks. `delete_task` cannot be taken back. |
| `resolve_tracked_changes` | Accepts or rejects every tracked change (`{++put in++}`, `{--taken out--}`) of a note. |
| `read_pdf`, `search_pdf` | The text of the PDF of a note, a few pages at a time, and which pages have some words. |
| `list_pages`, `add_page`, `delete_page`, `move_page`, `set_up_pages` | The pages of a note: what is on each, adding, deleting and moving them (what is on a page and its bookmark go with it), and the paper (size, direction, ruling, margins). The pages of a PDF can only be changed while the note is open in the app. |
| `list_text_boxes`, `add_text_box`, `move_text_box`, `delete_text_box`, `list_images`, `move_image`, `delete_image`, `draw_shape`, `draw_strokes` | What is placed on the pages: text boxes, pictures (moved and resized, not added) and drawings. Positions are measured from the top left of a page; `list_pages` has its size. |
| `add_flashcards` | Keeps flashcards of a note for review. |
| `list_calendar_events`, `add_calendar_event` | The calendars the app shows, and adding an event to one that takes them. |
| `list_reminders`, `add_reminder`, `remove_reminder` | Reminders; one can be about a note (`note_id`: tapping it opens the note). `remove_reminder` cannot be taken back. |

Most tools are the ones of the assistant's *Agent* mode (`agentTools` in `lib/ai/note_agent.dart`): same arguments, same checks, with the note's id added.
A tool added there for a note shows up here by adding it to `McpNotes.tools` with `_viaAssistant` (for one about tasks, the calendar or reminders:
`_viaLibrary`). A note that is open does it through its editor (`agentApi`); one that is not through `StoredNoteApi`, which has to know the call too,
or the tool says it cannot be done there. The calendar, reminders and flashcards tools are left out where the app does not offer those.
The assistant's `clipboard.write` is not here: it would write to the clipboard of the computer the app runs on.

## What keeps your notes safe

* **Only this computer, only with the token.** The server listens on `127.0.0.1`, and a request is turned away before it is read unless it names a
  loopback address in `Host` (a web page cannot make the browser send another name here: DNS rebinding), does not come from another site (`Origin`),
  and carries the token (`Authorization: Bearer`, compared in constant time). The token is made on first use and kept in the system's keystore.
* **Locked notes are never available**: not listed, not found by a search, not read, not changed, whatever the state of their lock. You unlocked them
  for yourself, not for the agent.
* **A version before and after every change** to a note, in the note's history (*Agent (MCP): ...*), to bring back.
* **No permanent deletion.** A note can be put in the trash (and brought back); nothing empties it. Deleting a folder keeps its notes.
* **A note that is open is changed through its editor**, as the assistant in the app does, and so is one step of the note's undo. It is never written
  to the database behind the editor's back (the editor would write over it). An open note cannot be trashed.
* **One call at a time.** Two agents, or one that does not wait, cannot change a note at once.

What the agent reads goes to whatever AI service it belongs to. That is not something the app can limit: connect only agents you trust with your notes,
and use *Read only* when it need not write. Text in a note is read by the agent too, so a note that came from somewhere you do not trust can try to
steer it.

## What you see while an agent works

* **A note that is open** shows the change as it happens, in its editor (and it is one step of the note's undo). The agent never writes to the database behind an
  open editor's back. If the editor does not finish saving the note within 10 seconds, the call fails with a message and changes nothing; it does not hold up the calls
  after it.
* **The lists** (the dashboard, the folder view, the trash and the tasks of the calendar) look again on their own when something changes behind their back, a moment
  after the last change (`debouncedChanges`, listening to the repositories' change streams). The same goes for a sync that brings changes in.
* **A notice** at the bottom of the window, "An agent changed "<title>"", with *Open* when that note is not the one on screen (`McpService.activity`, shown by the
  shell).

## The protocol

Streamable HTTP, one endpoint (`POST /mcp`), JSON replies. Both families of revisions are served, told apart by how a request begins, with no session:

* `2025-11-25`, `2025-06-18`, `2025-03-26`: `initialize`, then `tools/list` and `tools/call`.
* `2026-07-28`: no handshake; every request carries `_meta` with the version, and the headers `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` that
  repeat it (a mismatch is a 400, `-32020`). `server/discover` tells the versions and the tools; a version it does not speak is `-32022`.

`GET` and `DELETE` are 405: there is no stream to listen on and no session to end. Tools only (no resources or prompts).

## Testing it

* **`flutter test test/mcp`** runs everything, with a real database, real HTTP and real note versions, in a few seconds. `mcp_e2e_test.dart` is the one to run after
  any change to `lib/mcp/`: an agent on each protocol revision (find, read, change, organise, tasks, locked notes, read only, errors), the checks at the door, and a
  whole session through the stdio bridge. The parts are tested beside it (`mcp_protocol_test.dart`, `mcp_server_test.dart`, `mcp_notes_test.dart`,
  `mcp_service_test.dart`, `mcp_bridge_test.dart`), and `mcp_live_test.dart` runs the whole app (the shell, a real editor) with an agent over HTTP; `test/live_lists_test.dart` covers the lists. They share `support/mcp_fixture.dart` (a made-up library: folders, tagged and starred notes, a locked note, one in
  the trash, tasks) and `support/mcp_test_client.dart` (an agent that speaks HTTP in either revision); a new scenario is a few lines on those.
* **A server to point an agent at**, over the same made-up library (never your notes):
  `UNINOTES_MCP_DEV=1 flutter test test/mcp/dev_server_test.dart --timeout none` listens on `127.0.0.1:7333` (`UNINOTES_MCP_DEV_PORT` for another) with the token
  `notation-dev-token-0000000000000000`, until it is stopped. Then, for Claude Code:
  `claude mcp add --transport http notation-dev http://127.0.0.1:7333/mcp --header "Authorization: Bearer notation-dev-token-0000000000000000"`
  (restart Claude Code or `/mcp` to see its tools), or with `curl` / `tool/notation_mcp.dart` / the MCP Inspector. Stop it by the PID that listens on the port
  (`ss -ltnp | grep 7333`).

## In the code

`lib/mcp/`: `mcp_protocol.dart` (JSON-RPC and the revisions, no I/O), `mcp_notes.dart` (the tools), `stored_note_api.dart` (the assistant's API for a note
that is not open), `agent_editable.dart` (what an open editor offers), `mcp_server.dart` (HTTP and the checks), `mcp_service.dart` (settings, token,
start and stop, what agents change), `mcp_bridge.dart` (stdio to HTTP), `mcp_support.dart`; `lib/data/debounced_changes.dart` (how the lists keep up). The settings card is `lib/screens/settings_mcp.dart`. Tests are in `test/mcp/` (see above).
The macOS release build needs the `com.apple.security.network.server` entitlement to listen; it is in `macos/Runner/Release.entitlements`.
