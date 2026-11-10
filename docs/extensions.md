# Extensions and automations: the API

Notation can be extended with small JavaScript programs. An extension adds **tools** to the menu of selected text and **actions** that
the **automations** can run. This page is the whole of what an extension can see and do. (`lib/extensions/` is the code; the same
reference, shortened, is what the *Create with AI* button gives the AI assistant: `lib/extensions/magic_prompt.dart`.)

- [What an extension is](#what-an-extension-is)
- [manifest.json](#manifestjson)
- [Permissions](#permissions)
- [main.js: tools and actions](#mainjs-tools-and-actions)
- [The `notation` API](#the-notation-api)
- [Brushes](#brushes-no-code)
- [Drawing tools](#drawing-tools-drawadd)
- [Where tools and actions run](#where-tools-and-actions-run)
- [Automations](#automations)
- [Limits](#limits)
- [Errors](#errors)
- [Examples](#examples)
- [Installing, switching on, updating](#installing-switching-on-updating)
- [Create with AI](#create-with-ai)

## What an extension is

A folder (or a `.zip` with these files at the top) with two files:

```
manifest.json   what it is called, what it adds, what it asks to be allowed to do
main.js         the script
```

It runs in a sandbox (QuickJS): ECMAScript including `async`/`await` and promises, `JSON`, `Math`, `Date`, `RegExp`, `Map`, `Set` and the other
standard objects. There is **no** network, no file access, no `require`/`import`, no DOM, no `window`, no timers you can rely on, and no
other way out than the one object `notation`. Everything else the script wants has to be given to it by the person, one permission at a
time.

An extension is **off** when it is installed and has **no permission** until the person gives it in *Settings → Extensions*.

## manifest.json

```json
{
  "id": "word-count",
  "name": "Word count",
  "version": "1.0.0",
  "description": "Counts the words of the selected text.",
  "author": "You",
  "main": "main.js",
  "permissions": ["note.read"],
  "hosts": [],
  "tools":   [{ "id": "count", "title": "Count the words" }],
  "actions": [{ "id": "daily", "title": "Make a daily task" }],
  "events":  []
}
```

| field | required | rules |
|---|---|---|
| `id` | yes | 3 to 64 characters: `a-z`, digits, `.`, `-`, `_`; starts and ends with a letter or digit. Installing the same id again **updates** the extension (it keeps being on or off, and keeps the permissions it still asks for). |
| `name` | yes | up to 60 characters. Shown in the settings and in front of the tool's title in the menu (`Word count: Count the words`). |
| `version` | yes | text, up to 20 characters (`1.0.0`). |
| `description` | no | up to 400 characters. |
| `author` | no | up to 80 characters. |
| `main` | no | the script's file name, a `.js` file next to the manifest (default `main.js`). |
| `permissions` | no | a list of [permissions](#permissions). Unknown ones refuse the manifest. |
| `hosts` | with `network` | the website names it may talk to, e.g. `["api.example.com"]`: no `https://`, no path, no `*`, at most 10. Only with the permission `network` (and `network` needs at least one). |
| `tools` | no | up to 20 entries `{ "id", "title" }`: the id is `a-z`, digits, `-`, `_` (up to 40); the title up to 60 characters. Ids are unique. |
| `actions` | no | the same shape, up to 20. |
| `brushes` | no | up to 20 entries: pens that draw with a look the numbers describe, with no code and no permission. See [Brushes](#brushes-no-code). |
| `drawTools` | with `draw.add` | up to 20 entries `{ "id", "title", "preview" }`: tools of the drawing bar that hand a drag of the pen to the script. See [Drawing tools](#drawing-tools-drawadd). |
| `events` | with `events.emit` | the same shape, up to 20: the events the extension [announces](#events-an-extension-announces). Only with the permission `events.emit` (and `events.emit` needs at least one). |

A manifest that is wrong is refused with the reason, and nothing is installed.

## Permissions

Each is asked for in the manifest and given by the person in *Settings → Extensions*. A call without the permission fails with an
error the script can catch (`This extension did not ask for the permission "…"` or `The permission "…" was not given to this extension.`).

| permission | lets the script | calls |
|---|---|---|
| *(none)* | work on the text it is given, show a message, keep a little data of its own | `ctx`, `notation.ui.message`, `notation.storage.*` |
| `note.read` | read the text and the title of the note it is used on, how it is formatted, which pages it has and what is on them | `notation.note.get`, `notation.note.inspect`, `notation.pdf.read`, `notation.pdf.search`, `notation.pages.list`, `notation.textBoxes.list`, `notation.images.list` |
| `note.write` | insert text into the note, replace the selection or other text, format text, set the title, and place, move and delete text boxes and pictures | `notation.note.insertText`, `notation.note.setTitle`, `notation.selection.replace`, `notation.note.replaceText`, `notation.note.format`, `notation.note.resolveChanges`, `notation.textBoxes.add`, `notation.textBoxes.move`, `notation.textBoxes.delete`, `notation.images.move`, `notation.images.delete` |
| `notes.readAll` | search, list and read **all** of the person's notes, not only the one it is used on, and see the folders | `notation.notes.search`, `notation.notes.read`, `notation.notes.list`, `notation.folders.list` |
| `notes.manage` | create notes and folders, rename folders, and file notes in folders and give them tags | `notation.notes.create`, `notation.note.addTags`, `notation.note.moveToFolder`, `notation.notes.move`, `notation.notes.tag`, `notation.notes.favorite`, `notation.folders.create`, `notation.folders.rename` |
| `notes.delete` | put notes in the trash and bring them back (nothing is deleted for good) | `notation.notes.trash`, `notation.notes.restore` |
| `pages.edit` | add, delete and move the pages of the note it is used on, and set up their paper | `notation.pages.add`, `notation.pages.delete`, `notation.pages.move`, `notation.pages.setup` |
| `draw.page` | draw lines and shapes on the pages of the note it is used on (directly, not through a drawing tool) | `notation.draw.shape`, `notation.draw.strokes` |
| `calendar.manage` | see the events of the person's calendars and add events to them | `notation.calendar.events`, `notation.calendar.addEvent` |
| `reminders.manage` | set reminders, see the ones the person set and remove them | `notation.reminders.add`, `notation.reminders.list`, `notation.reminders.remove` |
| `cards.add` | make flashcards for spaced-repetition review from the note it is used on | `notation.cards.add` |
| `tasks.add` | add tasks to the calendar | `notation.tasks.add` |
| `tasks.manage` | see the tasks, change them, tick them off and delete them | `notation.tasks.list`, `notation.tasks.complete`, `notation.tasks.update`, `notation.tasks.remove` |
| `clipboard.write` | put text on the clipboard | `notation.clipboard.write` |
| `network` | send https requests to the websites in `hosts` and no others | `notation.network.fetch` |
| `draw.add` | draw lines on the page, with the drawing tools it lists in `drawTools` | `notation.drawTool` (what the handler returns) |
| `events.emit` | announce the events it lists in `events`, which automations can react to | `notation.events.emit` |

A tool that only returns a string (or `{ replace, insert, message }`) needs **no** permission: the app puts the result in place itself. Ask
for the least that works.

## main.js: tools and actions

The script runs once per use, from the top; it registers handlers with `notation.tool(id, fn)` and `notation.action(id, fn)`, and then the
handler of the tool or action that was used is called. Every id in the manifest needs a handler with the same id.

```js
// a tool: gets { text } (the selected text)
notation.tool('count', (ctx) => ({ message: ctx.text.trim().split(/\s+/).length + ' words' }));

// an action: gets { event, note: { id, title } }
notation.action('daily', async (ctx) => {
  await notation.tasks.add('Review ' + ctx.note.title, { due: '2026-12-24' });
  return 'task added';
});
```

Handlers may be `async` (return a promise). An error that is thrown (or a promise that rejects) is shown to the person with the extension's name.

### Tools

`notation.tool(id, (ctx) => result)`

- `ctx.text`: the selected text (a string, never empty).
- The **result**:
  - a **string**: it **replaces the selection**;
  - an **object** with any of `replace` (text that replaces the selection), `insert` (text put in **after** the selection) and `message` (shown to the person);
  - nothing (`undefined`/`null`): nothing changes.
- The text is only replaced if the selection is still what it was when the tool started; else the person is told and nothing changes.
- `notation.selection.replace(text)` (needs `note.write`) replaces the selection from inside the handler, e.g. before another `await`.

### Actions

`notation.action(id, (ctx) => result)`

- `ctx.event`: what happened, as the name of the [automation event](#automations) (`appStarted`, `noteCreated`, `noteOpened`, `noteClosed`,
  `notePaused`, `pageAdded`, `highlightAdded`, `noteLinked`, `pdfImported`, `audioRecorded`, `taskCompleted`, `calendarEventStarting`, `dateFound`,
  `todoFound`, `calendarEventEnded`, `captureReceived`, `triggerPressed`, `noteStale`, `shareReceived`), or `null`. What the event says in words (`{pages}`, `{target}`, ...) is in `ctx.data.vars`.
- `ctx.note`: `{ id, title }` of the note the event is about; `id` is empty and `title` is `''` for `appStarted`.
- The **result**: a string (shown as the automation's last result, up to 300 characters), an object with `message`, or nothing (`Done`).
- An action runs in the background: it has no editor, so it cannot change the note (see [the note](#the-note-noteread-notewrite)); it can read it, add tasks, use the clipboard, the network and `storage`.

## The `notation` API

`notation` is the only object of the app the script can reach. Every call returns a **promise** (use `await`). `notation.version` is `1`.
Arguments of the wrong kind fail with a message such as `"text" has to be text.`

### Registering

| call | |
|---|---|
| `notation.tool(id, fn)` | `fn(ctx)` for the tool `id` of the manifest |
| `notation.action(id, fn)` | `fn(ctx)` for the action `id` of the manifest |
| `notation.drawTool(id, fn)` | `fn(ctx)` for the drawing tool `id` of the manifest (see [Drawing tools](#drawing-tools-drawadd)) |

### The note (`note.read`, `note.write`)

| call | returns / does | permission |
|---|---|---|
| `await notation.note.get()` | `{ id, title, text }`: the note the tool or action is used on; `text` is the note's text, cut after about 20 000 characters | `note.read` |
| `await notation.note.insertText(text, { after, before, at })` | puts `text` into the note **right after the selection** (up to 100 000 characters); only in a tool, where there is an editor. With `after` or `before` (text copied from the note) it goes on a line of its own after or before the line that has it; `at: "start"` puts it at the start of the note | `note.write` |
| `await notation.pdf.read({ from, to, id })` | the text of the pages `from` to `to` (numbers from 1; the first page to as far as fits by default) of the PDF of the note, each under `Page N:`, as a string. It gives about 12 000 characters at a time and ends with a line that says where to go on (`"from": 7`); a page with no text (a scan, or only pictures) says so. With `id` (from `notes.search`) it is the PDF of that other note, as the app has read it (a note whose PDF has not been read yet fails); that needs `notes.readAll` | `note.read` |
| `await notation.pdf.search(query, { id })` | `[{ page, snippet }]`: the pages of the PDF that have **all** the words of `query` (at most 20), with a snippet around the first word; `id` as for `pdf.read` | `note.read` |
| `await notation.note.inspect({ target })` | how the text is formatted, as a string: each line as it is written (Markdown marks and the `{align=.. indent=.. spacing=..}` layout token of a paragraph included) and the *looks* that are kept beside the text and that Markdown cannot say (font, size, colour, highlight, underline). `target` is `"all"` (the default), `"selection"` or text of the note | `note.read` |
| `await notation.note.setTitle(title)` | sets the title (up to 200 characters) | `note.write` |
| `await notation.selection.replace(text)` | replaces the selected text, in a tool | `note.write` |
| `await notation.note.replaceText(find, replacement, { all })` | replaces `find` (as it is written, or as it reads: without the Markdown marks, whatever the capitals) in the text of the note, the first one or with `all: true` every one; returns how many; fails when `find` is not there | `note.write` |
| `await notation.note.format(options)` | formats text of the note and returns what came of it; see below | `note.write` |
| `await notation.note.resolveChanges({ accept })` | settles every tracked change of the note (`{++put in++}` and `{--taken out--}`, as *Track changes* writes them): `accept: true` (the default) keeps the insertions and drops the deletions, `false` does the opposite. Returns `{ settled }`, how many; fails when there are none | `note.write` |

`note.format` takes an object. `like` is other text of the note whose formatting is copied first (font, size, colour, highlight, underline, bold and the rest, the kind of line and the layout of its paragraph), and what else is given then changes that. `target` says where: `"selection"` (the default), `"all"`, or text quoted from the note (the first place it is found). The rest says how it
is to look, and asking twice does what asking once does: `bold`, `italic`, `strikethrough`, `code`, `underline`, `superscript`, `subscript` (`true` puts it on, `false` takes it
off), `block` (`"paragraph"`, `"heading1"` to `"heading6"`, `"bullet"`, `"numbered"`, `"task"`, `"quote"`: for each line it touches), `align` (`"left"`, `"center"`, `"right"`,
`"justify"`), `indent` (0-8), `spacing` (0.5-4), `color` and `highlight` (`"#RRGGBB"`, a name such as `"red"`, or `"none"`), `font` (`"Sans"`, `"Serif"`, `"Mono"`, `"DejaVu Sans"`),
`size` (points, 6-96) and `clear: true` (takes the formatting off first). It is written the way the formatting bar writes it: Markdown where Markdown can say it (`**bold**`,
`==yellow==`, `^raised^`), the rest as a look of the text. Tables, code blocks, rules and empty lines are left alone. An unknown name or a wrong value fails with a message that
lists what is possible.

In an **action** (an automation, no editor) only `note.get` works: it reads the note from storage. `insertText`, `setTitle` and `selection.replace` fail
(`Text cannot be inserted here.`, `The title cannot be changed here.`, `There is no selection here.`): an action that should write something down adds a
task, puts text on the clipboard or returns a message instead.

### Other notes, and filing (`notes.readAll`, `notes.manage`)

| call | returns / does | permission |
|---|---|---|
| `await notation.notes.search(query, { limit })` | `[{ id, title, snippet }]`: the notes that have **all** the words of `query` (in the title, the text, the text boxes, the PDF or the handwriting that was read), the best first; `limit` 1-20 (10) | `notes.readAll` |
| `await notation.notes.read(id)` | `{ id, title, text }` of that note (cut after about 20 000 characters); a locked note cannot be read | `notes.readAll` |
| `await notation.notes.create(title, text, { folder })` | makes a note with that title and that text (Markdown, written into its document); `folder` is the name of a folder; returns `{ id }` | `notes.manage` |
| `await notation.note.addTags(tags)` | gives the note the tags (a list of names); the tags it has stay | `notes.manage` |
| `await notation.note.moveToFolder(name)` | moves the note into the folder called `name`; `null` takes it out of all folders | `notes.manage` |
| `await notation.notes.list({ folder, limit })` | `[{ id, title, folder, updated }]`: the notes, the last changed first (`folder` is the name of a folder or `null`, `updated` a day); only those in the folder called `folder` if given; `limit` 1-50 (20). A locked note shows as `Locked note` | `notes.readAll` |
| `await notation.folders.list()` | `[{ name, parent, notes }]`: every folder, the name of the folder it is in (or `null`) and how many notes are in it | `notes.readAll` |
| `await notation.folders.create(name, { parent })` | makes a folder, inside the folder called `parent` if given; fails when there is a folder of that name already | `notes.manage` |
| `await notation.folders.rename(name, newName)` | renames the folder called `name` | `notes.manage` |
| `await notation.notes.move(id, folder)` | moves *another* note (by id) into the folder called `folder`; `null` takes it out of all folders | `notes.manage` |
| `await notation.notes.favorite(id, on)` | stars *another* note (by id); `on: false` takes the star away (default `true`) | `notes.manage` |
| `await notation.notes.tag(id, tags)` | gives *another* note (by id) the tags; the ones it has stay | `notes.manage` |
| `await notation.notes.trash(id)` | puts that note in the trash (it can be brought back for 30 days; never the note the tool is used on) | `notes.delete` |
| `await notation.notes.restore(id)` | brings a note back from the trash | `notes.delete` |

They work in a tool, like the rest of the note API that changes things; in an action only `note.get` does. A folder that does not exist fails with a message that lists the folders, and a locked note cannot be moved, tagged or trashed.

### Pages (`note.read`, `pages.edit`)

Page numbers start at **1**, as on the page list in the editor. They work in a tool, on a notebook or on a PDF note (not on an infinite canvas); every change is one step for the editor's undo.

| call | returns / does | permission |
|---|---|---|
| `await notation.pages.list()` | `[{ page, kind, strokes, textBoxes, images, width, height }]`: `kind` is `"written"` for the page with the written document, `"notebook"` or `"pdf"`; the counts say what is on the page; `width` and `height` are in **page units** (a sheet of A4 upright is 800 wide, and positions are measured from the top left of a page). A notebook always ends with one empty page. | `note.read` |
| `await notation.pages.setup({ paper, orientation, background, margins })` | sets up the paper of a notebook (not a PDF or a canvas) and says what it set. `paper`: `"a4"`, `"a5"`, `"a3"`, `"b5"`, `"letter"`, `"legal"` or `"square"`; `orientation`: `"portrait"` or `"landscape"`; `background`: `"blank"`, `"grid"`, `"lines"`, `"dots"`, `"isometric"`, `"staff"` or `"tab"`; `margins`: `{ left, right, top, bottom }` of the written document in millimetres (0-80). Say at least one | `pages.edit` |
| `await notation.pages.add({ at })` | puts a blank page at number `at` (what was there moves down) and returns `{ page }`; without `at` at the end. The page with the written document is page 1: a page cannot be put before it | `pages.edit` |
| `await notation.pages.delete(page)` | deletes that page **with everything on it**; not the page with the written document, and not the last page of a PDF | `pages.edit` |
| `await notation.pages.move(page, to)` | moves page `page` to number `to`; the pages in between move over by one. The page with the written document stays where it is | `pages.edit` |

A number that is not a page fails with `There is no page 9: the note has 4 pages.`

### Text boxes, pictures and drawing (`note.read`, `note.write`, `draw.page`)

Text boxes and pictures are placed on a page with `x` and `y`, measured in page units from the top left corner of the page (see `pages.list` for its size). Every change is one step for the editor's undo. The pictures that are there can be moved, resized and deleted; a script cannot add a picture. Comments (the cards beside the page) are not text boxes here.

| call | returns / does | permission |
|---|---|---|
| `await notation.textBoxes.list()` | `[{ id, page, x, y, width, text }]` (the text is cut after 200 characters) | `note.read` |
| `await notation.textBoxes.add(text, { page, x, y, width })` | places a text box and returns `{ id }`; `page` defaults to the page in view (x, y to its top left), `width` to 260; it fails when the layer in use is hidden or locked | `note.write` |
| `await notation.textBoxes.move(id, { page, x, y, width })` | moves the box and/or gives it another width | `note.write` |
| `await notation.textBoxes.delete(id)` | removes the box with its text | `note.write` |
| `await notation.images.list()` | `[{ id, page, x, y, width, height }]` | `note.read` |
| `await notation.images.move(id, { page, x, y, width })` | moves the picture and/or resizes it (`width`; the height follows) | `note.write` |
| `await notation.images.delete(id)` | removes the picture from the page | `note.write` |
| `await notation.draw.shape({ type, x, y, width, height, x2, y2, page, color, lineWidth, fill, dash })` | draws a shape and returns `{ drawn }`. `type`: `"rectangle"`, `"ellipse"`, `"triangle"`, `"diamond"` (a box at `x`, `y` of `width` by `height`) or `"line"`, `"arrow"` (from `x`, `y` to `x2`, `y2`; no `fill`). `color` and `fill` are `"#rrggbb"`, `dash` is `"solid"`, `"dashed"` or `"dotted"`, `lineWidth` 0.1-300. `page` defaults to the page in view | `draw.page` |
| `await notation.draw.strokes(strokes, { page })` | draws lines, `[{ points: [[x, y], ...], color, width, fill, dash }]`, with the same limits as the result of a [drawing tool](#drawing-tools-drawadd); returns `{ drawn }` | `draw.page` |

A drawing is one step to take back, and counts as drawn by the person.

### The calendar (`calendar.manage`)

| call | returns / does |
|---|---|
| `await notation.calendar.events(from, to)` | `[{ title, start, end, allDay, calendar }]`: the events of the days `from` to `to` (days like `2026-12-24`, `to` on or after `from`, at most 62 days; at most 100 events) of every calendar the calendar tab shows (server, phone, subscribed). `start` and `end` are times like `2026-12-24T09:30`, or days for an all-day event; `end` can be `null` |
| `await notation.calendar.addEvent(title, start, { end, allDay, calendar, description })` | adds an event. `start` and `end` are times like `2026-12-24T09:30` (no `end`: one hour later); with `allDay: true` they are days and `end` is the last day. It goes to the calendar called `calendar`, or the first calendar that can take events; with none connected it fails with a message that says so, and a name that is not a calendar fails with a list of the calendars |

They work in a tool.

### Reminders and flashcards (`reminders.manage`, `cards.add`)

| call | returns / does | permission |
|---|---|---|
| `await notation.reminders.add(text, at, { repeat, aboutNote })` | sets a reminder that shows `text` at `at`, a local time like `2026-12-24T09:30`; `repeat` is `"once"` (the default), `"daily"`, `"weekly"`, `"monthly"` or `"yearly"`; with `aboutNote: true` tapping it opens the note the tool is used on. A time in the past is refused unless it repeats. Returns `{ id }` | `reminders.manage` |
| `await notation.reminders.list()` | `[{ id, text, at, repeat }]`: the reminders the person set (not the ones the app makes for tasks) | `reminders.manage` |
| `await notation.reminders.remove(id)` | removes that reminder | `reminders.manage` |
| `await notation.cards.add(cards)` | keeps 1-30 flashcards `[{ front, back }]` of the note for review (the *Review* button); a card with a question that is there already is not added again; returns `{ added }`, how many were new | `cards.add` |

### Tasks (`tasks.add`, `tasks.manage`)

`await notation.tasks.add(title, { due: 'YYYY-MM-DD' })`: adds a task to the calendar. `title` is up to 300 characters; `due` is optional and has to be a
day like `2026-12-24` (else `"due" has to be a day like 2026-12-24.`). Needs `tasks.add`.

With `tasks.manage` a script can also look at and change the tasks that are there (in a tool; an action has no editor but can add tasks):

| call | returns / does |
|---|---|
| `await notation.tasks.list({ done })` | `[{ id, title, due, done }]` (at most 100): open tasks first, then by day; `due` is `"YYYY-MM-DD"` or `null`; `done: false` gives only the open tasks, `done: true` only the finished ones |
| `await notation.tasks.complete(id, done)` | ticks the task off (`done` defaults to `true`; `false` opens it again) |
| `await notation.tasks.update(id, { title, due })` | gives the task a new title and / or day; `due: null` takes the day away. Say at least one of them |
| `await notation.tasks.remove(id)` | deletes the task |

An unknown `id` fails with a message that says to look at `tasks.list` for the ids. Changes go to the calendar and to the CalDAV server like any other change of a task.

### The clipboard (`clipboard.write`)

`await notation.clipboard.write(text)`: puts `text` on the clipboard.

### The network (`network`)

`await notation.network.fetch(url, { method, headers, body })` → `{ status, headers, body }` (`body` is text).

- `url` has to be `https://` and its host has to be listed in the manifest's `hosts` (exactly: `api.example.com` does not allow `example.com`).
- `method` defaults to `GET`; `headers` is an object of strings; `body` a string (`JSON.stringify(...)` for JSON).
- No redirects are followed; an answer larger than 1 MB fails. Parse JSON yourself: `JSON.parse(res.body)`.
- A status of 4xx/5xx is **not** an error: look at `res.status`.

### Events an extension announces (`events.emit`)

`notation.events.emit(name, data)`: announces the event `name`, one of those in the manifest's `events`, with `data` (a JSON object, at most 8 KB).
The event is called `ext:<extension id>/<name>` (that is what an automation and `ctx.event` show) and appears in the Automations tab as
`<extension name>: <title>` while the extension is on and has the permission. Any action can then be set to run when it happens; the action gets
`data` as `ctx.data`.

- It does not wait for whoever reacts: the call returns at once, and the reacting action runs after this one is done.
- An extension cannot announce an event that is not its own, nor the one its action is reacting to; at most 20 events a minute.

### Keeping data (`storage`, no permission)

What the extension keeps between runs: one JSON object per extension, at most 64 KB in all.

| call | |
|---|---|
| `await notation.storage.get(key)` | the value, or `undefined`/`null` |
| `await notation.storage.set(key, value)` | `value` has to be JSON (strings, numbers, booleans, arrays, plain objects) |
| `await notation.storage.remove(key)` | |

### Showing things

| call | |
|---|---|
| `await notation.ui.message(text)` | shows a short message (a snack bar) in a **tool** (up to 2000 characters); in an action it does nothing, return the text instead |
| `console.log(...)` | goes to the app's log (at most 50 lines of 500 characters are kept) |

## Brushes (no code)

A brush is a pen with a look of its own. It is a few numbers in the manifest, so it needs **no permission** and runs no script: the app draws it itself, as
fast as the built-in pens. A brush appears in the *Brush* menu of the drawing bar while its extension is on.

```json
"brushes": [
  { "id": "pencil", "title": "Soft pencil", "width": 0.8, "pressure": 0.7, "opacity": 0.85, "jitter": 0.4, "taper": 0.5 },
  { "id": "nib",    "title": "Calligraphy", "nibAngle": 45, "nibFlatness": 0.15, "smoothing": 0.7 }
]
```

| number | range | default | meaning |
|---|---|---|---|
| `width` | 0.2 to 10 | 1 | how thick it draws compared to the width chosen in the bar |
| `pressure` | 0 to 1 | 0 | how much the pressure of the pen matters to the thickness |
| `smoothing` | 0 to 1 | 0.5 | how much the corners between points are rounded off |
| `taper` | 0 to 1 | 0 | how far the ends of a line run out to a point |
| `opacity` | 0.05 to 1 | 1 | how opaque the line is; where it crosses itself it does not get darker |
| `jitter` | 0 to 1 | 0 | how uneven the edges are, like pencil on rough paper |
| `nibAngle` | -180 to 180 | none | the angle of a flat nib in degrees; without it the tip is round |
| `nibFlatness` | 0.02 to 1 | 0.15 | with a nib: how thick it is compared to how wide |

A line keeps the brush it was drawn with as `ext:<extension id>/<brush id>`, and its points, colour and width as ever. Where the extension is
not there (it was switched off or removed, or the note is opened on a device without it) the line is drawn as the pen draws it; nothing is lost.
The lines of a brush are exported to PDF as they look.

## Drawing tools (`draw.add`)

A drawing tool hands the drag of the pen to the script, which answers with the lines to draw in its place: a ruler, a shape recogniser, a stamp,
a grid. The permission `draw.add` has to be given; without it the tool is not offered. Tools are in the *Drawing tools* menu of the drawing bar.

```json
"permissions": ["draw.add"],
"drawTools": [{ "id": "ruler", "title": "Ruler", "preview": "line" }]
```

`preview` is what the person sees while dragging, before the script has answered: `path` (the pen's own line, the default), `line`, `rect` or `ellipse`.

```js
// a ruler: whatever the hand did, a straight horizontal line from where it began
notation.drawTool('ruler', (ctx) => ({
  strokes: [{ points: [ctx.start, [ctx.end[0], ctx.start[1]]] }],
  message: 'Ruled',
}));
```

`notation.drawTool(id, (ctx) => result)`:

- `ctx.points`: the drag as `[x, y]` pairs in the coordinates of the page (at most 2000, spread evenly). For `line`, `rect` and `ellipse` previews these are just the start and the end.
- `ctx.start`, `ctx.end`: the first and the last point. `ctx.pressures`: 0 to 1 for each point, or `null`. `ctx.shift`: whether Shift was held.
- `ctx.color` (`#rrggbb`) and `ctx.width`: what is chosen in the bar. `ctx.page`: `{ width, height }`.
- The **result**: `{ strokes: [...], message }` or just the list. Nothing: the drag is dropped and nothing is drawn.
- Each stroke: `points` (`[x, y]` pairs, 2 to 5000), and optionally `color` (`#rgb`, `#rrggbb`, `#rrggbbaa`), `width` (0.1 to 300), `dash` (`solid`, `dashed`, `dotted`), `fill` (a colour, for a closed line) and `brush` (`pen`, `roller` or the id of a brush that is on; anything else is the pen). Colour and width left out are those of `ctx`.
- At most 200 strokes and 20 000 points in all, and coordinates within 100 000 of the page; an answer that is not right draws nothing and the person is told why.
- What is drawn is one step to take back, and counts as drawn by the person.

## Where tools and actions run

- **Tools** are in the menu of **selected text** (right click, or the toolbar after selecting), each as *Extension name: Tool title*:
  - in the **written document** and in **text boxes** (the result replaces the selection);
  - in **text that can only be read** (a PDF page, a note shown in Select mode): the tool runs on the selected text, and what it would put in place (`replace`
    and `insert`) goes to the clipboard, with its message shown.
  Only tools of extensions that are **on** appear, and only with text selected.
- **Actions** are chosen in the **Automations** tab: *Run an action of an extension*, and run when the rule's event happens.
- Runs go one after the other (a second waits for the first).

## The assistant as an agent

The assistant beside a note has two modes, the **Ask / Agent** switch at the top of its panel. In *Agent* mode it can act on the note that is open, with **the same
calls as an extension** (`lib/ai/note_agent.dart`): `note.get`, `note.inspect`, `pdf.read`, `pdf.search`, `note.insertText` (also after or before a line, or at the start), `note.replaceText`, `note.format` (also `like`: copy the formatting of other text), `note.setTitle`, `pages.list`, `pages.add`, `pages.delete`, `pages.move`, `pages.setup`, `textBoxes.list`, `textBoxes.add`, `textBoxes.move`, `textBoxes.delete`, `images.list`, `images.move`, `images.delete`, `draw.shape`, `draw.strokes`, `notes.search`, `notes.read`, `notes.list`, `notes.create`, `notes.move`, `notes.tag`, `notes.favorite`, `notes.trash`, `notes.restore`, `folders.list`, `folders.create`, `folders.rename`, `note.addTags`, `note.moveToFolder`, `calendar.events`, `calendar.addEvent`, `reminders.add`, `reminders.list`, `reminders.remove`, `cards.add`, `tasks.add`, `tasks.list`, `tasks.complete`, `tasks.update`, `tasks.remove` and `clipboard.write`, each under the
permission an extension would need for it (`note.read`, `note.write`, `pages.edit`, `draw.page`, `notes.readAll`, `notes.manage`, `notes.delete`, `reminders.manage`, `cards.add`, `calendar.manage`, `tasks.add`, `tasks.manage`, `clipboard.write`). Nothing else is reachable: no network, no storage, no drawing, no events,
so that text in a note (a PDF, a pasted page) cannot make the assistant send the note anywhere.

The difference is who decides. An extension is given its permissions in the Settings ahead of time; the assistant **asks when it wants to do something**: a card in the
conversation says what it would do (and shows the text it would write), with *Allow*, *Allow for this chat* (that permission for the rest of the conversation; a new
conversation or *clear* asks again) and *Don't allow* (it is told, and does not try again). Before it asks, the app **tries the change on copies of the text** and shows what would differ in the card, as lines (red: taken out, green: put in, a line of context around them);
nothing of the note is touched by looking. A replacement or format whose quoted text is not in the note fails at once instead of asking. A formatting that only changes looks kept
beside the text (colour, size, underline) has no lines to show, only its description. Reading the note asks nothing: the assistant reads it for every question anyway.
Stopping the assistant answers an open question with *Don't allow*.

How it works, with a **service that takes tools** (the OpenAI-compatible provider: OpenAI, Gemini's endpoint, OpenRouter, ...): the tools go with the request as functions (JSON
schemas; a dot is not allowed in a function name, so `note.format` is `note_format` on the wire) and the model answers with structured calls, which are answered one by one under
their ids. A server whose model says it takes no tools (a model of your own on Ollama) is asked again with the text form below, and stays on it for that conversation. With a model
that has no such API (the one on the device) it is the text form: the model is told the tools and writes a call as `<tool>{"name": ..., "args": {...}}</tool>` (any model that can write text can; a bare or fenced JSON call is
read too). The app checks the call, asks, does it and tells the model what came of it ("Done: ..." or the error), up to eight rounds, until the model answers in plain
text. A call that fails (a quoted text that is not in the note) is reported to the model, which may try again; the same call twice is not done twice. **Versions:** before each change of the note's text, title or pages the app keeps the note as a version (*Before the assistant: ...*), and after it another (*Made by the assistant: ...*), each
named for what the assistant did. The History panel shows them with a sparkle icon and a tinted row, apart from the versions you or the app made, and "where does this come from" (blame) names
them too. They are versions like the others: thinned out as they get older (all of the last day), unless you keep one with a name. A note that keeps no versions (an encrypted one) gets none, and
the assistant is not held up by it. Where nothing changed since the last version, that one is used instead of making another. A change is one step for the note's
**undo button**, so it can be taken back; it works on the written document and on the text boxes (not on comments or a PDF's own text), and not while the note is shown for reading
or its layer is locked. In *Ask* mode, as before, the note is never changed.

## Automations

An automation is a rule: **when** *event* happens (for notes in a folder, or whose title/PDF name contains a word), **do** *action*. It is
made in the Automations tab, or by *Create with AI* (which can make the extension and the rules that use its actions in one go).

### Events

| event (`ctx.event`) | when | has a note | editor open |
|---|---|---|---|
| `appStarted` | the app starts | no | no |
| `noteCreated` | a note is created | yes | no |
| `noteOpened` | a note is opened | yes | yes |
| `noteClosed` | a note is closed (the canvas is left) | yes | yes |
| `notePaused` | a note was changed and then left alone for half a minute (it may still be open) | yes | no |
| `pageAdded` | a page of a note got something on it for the first time, or a PDF was put in (`{pages}`: how many pages the note has now) | yes | no |
| `highlightAdded` | something was highlighted in a note (`{n}`: how many) | yes | no |
| `noteLinked` | a link to another note was written into a note (`{target}`: the title of that note) | yes | no |
| `pdfImported` | a PDF became a note, also one that was shared to the app or clipped (`{pdf}`: its file name) | yes | no |
| `audioRecorded` | a recording or dictation was kept with a note (`{audio}`: its title, `{minutes}`: how long) | yes | no |
| `taskCompleted` | a task was ticked off in the app (`{title}`: the task, `{due}`: the day it was due) | no | no |
| `calendarEventStarting` | a calendar event starts within `minutes` minutes (default 10; looked at every minute, each event once; all-day events are left out). `{title}`, `{start}` (time), `{day}` | no | no |
| `calendarEventEnded` | the event of a `meetingNote` rule is over (up to half an hour ago); the note is the meeting's note, so `summarizeToBox`, `sortIntoFolder`, `setReminder` ("Summarize and file {title}") and the like can work on it. `{title}`, `{start}`, `{day}` | yes | no |
| `captureReceived` | a note was made from something kept from outside: a web page or a selection of one, text or a file shared to the app, a quick note. It is complete: it has its words, so it can be summarized, tagged or filed. `{kind}` (`note`, `clip`, `page`, `pdf`, `picture`), `{url}`, `{site}` | yes | no |
| `triggerPressed` | the person pressed a trigger: a key bound to "Run the automations of trigger 1" (or 2, 3) in the settings of the shortcuts, or the side button of the pen when that is set to "Run automation trigger 1" (Settings, pen; in draw mode the pen does not draw while it is pressed). The rule says which trigger it is for (`trigger`, 1 by default). The note that is open is the note of the event (none when no note is open) and its editor is there, so a PDF or pictures can be made. `{trigger}` | yes | yes |
| `dateFound` | a date (and maybe a time) is found in the text of an imported PDF, once per date | yes | no |
| `todoFound` | a line that asks for something to be done is found in the words or the (read) handwriting of a note when it is closed, once per line: `to do: ...`, `action: ...`, `Aufgabe: ...`, an empty box `☐` / `[ ]` / `- [ ]` (a ticked box is done). `{summary}`: what is to be done, `{line}`: the line, `{found}`: the day it says (a date, today, tomorrow, "by Friday", next week) | yes | no |
| `noteStale` | a note has not been opened for `weeks` weeks (checked when the app starts and every few hours) | yes | no |
| `shareReceived` | a note or folder that someone shared with the person through the cloud service was taken in (`ctx.data`: `name`, `kind` = `note` or `folder`, `owner`) | no | no |
| `ext:<id>/<name>` | an extension [announces](#events-an-extension-announces) it | no | no |

The words in `{braces}` can be used in the text of a task, a text box, a reminder or a note title that a rule makes, next to `{title}` (the note's title, or the task's or event's) and `{date}` (today).

After `noteOpened` and `noteClosed` an automation runs only for a note that was **edited since it last ran for that note**.

### Actions (what a rule does)

| action | needs | parameters |
|---|---|---|
| `extensionAction` (*Run an action of an extension*) | an extension that is on | `extension`: `<extension id>/<action id>` |
| `exportPdf` | the editor open (`noteOpened`, `noteClosed`) | `dir`: the folder the PDF goes to |
| `addTask` | any event | `title` (`{title}` is the note's title, `{date}` today; for `dateFound` also `{found}`, `{time}`, `{line}`, `{summary}`), `due`: `none`, `today`, `tomorrow`, `inAWeek` |
| `moveToFolder` | a note | `folder`: the folder's id |
| `sortIntoFolder` | `noteOpened`, `noteClosed`, `noteStale`, `dateFound` | `within`, `unfiledOnly`, `strictness` |
| `saveNoteFile` | a note | `dir` |
| `convertHandwriting` | `noteOpened`, `noteClosed` | none |
| `prepareInk` | `noteOpened` | `what`: `both`, `text`, `formulas` |
| `indexInk` | `appStarted` | none |
| `makeFlashcards` | `noteClosed`, `noteStale` | `count` (default 6): the assistant writes about that many flashcards from the note's text; they are kept for review with the note as their source, a question that is kept already is not added again |
| `reviewCardsTask` | an event with no note | `title` (`{n}`: how many cards are due; default "Review {n} flashcards"): one task a day, due today, while cards are due |
| `titleNote` | `noteClosed`, `notePaused` | none: a note whose title is empty or "Untitled Note" is named (the language model writes the title if it is installed, else the first line is used when it is short enough); a note with a title is never changed |
| `appendToNote` | any event | `where` (`this` or `daily`), `title` (the daily note's title, default `Daily {date}`; made if there is none), `folder`, `text`: a text box under the rest of the last page. Waits a few seconds for an editor that has the note open to let go, and writes nothing if it stays open |
| `addTag` | a note | `tag` (e.g. `school/maths`; the `{words}` of the event work here too: `reading/{kind}`) |
| `starNote` | a note | none: the note is a favourite |
| `addCitation` | `captureReceived` | none: the page the note was made from (address, title, site, the day it was kept) becomes a source of the citation library, cited as `[@key]`; a page that is a source already is not added again |
| `askAboutNote` | a note | none: the note is listed on the dashboard ("Still relevant?"), and nothing changes until the person answers: keep it (counts as opened), archive it (folder `Archive`), remind me in a week, make flashcards of it, or not now |
| `translateToBox` | a note | `language` (a code like `de`): the assistant's translation as a text box (`auto-translation-<code>`) that a later run replaces; the original stays |
| `summarizeToBox` | a note | none: a summary as a text box (`auto-summary`) that a later run replaces |
| `outlineToBox` | a note | none: the outline (topics and points) as a text box (`auto-outline`) that a later run replaces |
| `createNoteFromTemplate` | any event | `template` (the id of a template of the app, or `saved:<id>`), `title`, `folder` |
| `meetingNote` | `calendarEventStarting` | `template` (optional), `title` (default `{title} {day}`), `folder`, `carry` (`yes`: the lines still to do from the note of the last meeting with that name, found as for `todoFound`, are put in the new note): a note for the meeting, remembered for `calendarEventEnded` |
| `setReminder` | any event | `when` (`inAnHour`, `thisEvening`, `tomorrow`, `inAWeek`), `text`: a reminder for the note (a plain one when there is no note) |
| `exportImages` | `noteOpened`, `noteClosed` | `dir`, `preset` (`web`, `screen`, `print`, `square`, `slide`, `tall`): a PNG of each page |

A rule can have **steps** (`then`, a list of `{ action, params }`): they run after the first action, one after the other, in the background, each with what
the one before said as `{result}`; one that says it could not do its work ends the chain. Steps cannot be actions that need the open editor
(`exportPdf`, `exportImages`, `prepareInk`, `convertHandwriting`), `indexInk`, `reviewCardsTask` or actions of extensions.

The last runs of every rule are kept (twenty are shown) with the steps that take back what they did (`task`, `tag`, `star`, `move`, `note`, `reminder`,
`cards`, `title`, `box`); *Describe a rule* turns a request into rules that are off (`lib/automations/rule_writer.dart`).

Other fields of a rule: `folderId` (only notes in that folder, or any), `contains` (words separated by commas: only notes whose title or PDF name
contains one of them), `weeks` (for `noteStale`, a whole number of at least 1), `enabled`.

Extensions can only be reached through `extensionAction`; whatever an action should do (add a task, change the note, call a website) it does
through the API above.

## Limits

- A script is at most **256 KB**.
- Every run gets **a new engine**: nothing stays between runs except what is in `storage`.
- A piece of the script that computes for more than **1.5 seconds** without waiting is stopped; a whole run is over after **15 seconds** (waiting
  for the network counts); the engine may use **32 MB**; the stack is limited (very deep recursion fails).
- At most 32 timers, 64 callbacks, 64 pending promises.
- One call's text is at most 100 000 characters (a title 200, a task 300, a message 2000); a request's answer at most 1 MB; `storage` 64 KB.

## Errors

A script's problems come back as text with the extension's name, e.g. `Word count: The permission "note.read" was not given to this extension.`
The usual ones:

| message | cause |
|---|---|
| `This extension did not ask for the permission "…"` | the permission is not in the manifest |
| `The permission "…" was not given to this extension.` | the person has not given it (Settings → Extensions) |
| `There is no note here.` / `There is no selection here.` / `Text cannot be inserted here.` | the place does not offer it (e.g. an action has no selection) |
| `This extension may not talk to …` / `Only https addresses can be used.` | the host is not in `hosts`, or the address is not https |
| `This extension has no tool "…"` | the manifest lists a tool the script does not register |
| `The script ran for too long.` / `used too much memory.` / `calls itself too deeply.` | the limits |
| `Extensions cannot run on this device.` | the script engine's native library is not there (Settings → Extensions says so) |

## Examples

**A tool that needs nothing** (replaces the selection):

```json
{ "id": "shout", "name": "Shout", "version": "1.0.0", "tools": [{ "id": "loud", "title": "Make it loud" }] }
```
```js
notation.tool('loud', (ctx) => ctx.text.toUpperCase() + '!');
```

**A tool that adds to the note** (no permission: it returns `insert`, and the app puts it in):

```json
{ "id": "dated-quote", "name": "Dated quote", "version": "1.0.0", "tools": [{ "id": "quote", "title": "Quote with today's date" }] }
```
```js
notation.tool('quote', (ctx) => ({ insert: '\n> ' + ctx.text.trim() + ' (' + new Date().toISOString().slice(0, 10) + ')' }));
```

**A tool that calls a website** (`network`):

```json
{ "id": "define", "name": "Define", "version": "1.0.0", "permissions": ["network"], "hosts": ["api.dictionaryapi.dev"],
  "tools": [{ "id": "define", "title": "Define the word" }] }
```
```js
notation.tool('define', async (ctx) => {
  const word = ctx.text.trim().split(/\s+/)[0];
  const res = await notation.network.fetch('https://api.dictionaryapi.dev/api/v2/entries/en/' + encodeURIComponent(word));
  if (res.status !== 200) return { message: 'No definition for "' + word + '"' };
  const meaning = JSON.parse(res.body)[0].meanings[0].definitions[0].definition;
  return { insert: '\n**' + word + '**: ' + meaning };
});
```

**An action for an automation** (`tasks.add`, event `noteStale`): *"remind me when a note has not been opened for 6 weeks"*

```json
{ "id": "stale-reminder", "name": "Stale reminder", "version": "1.0.0", "permissions": ["tasks.add"],
  "actions": [{ "id": "remind", "title": "Remind me to look at the note" }] }
```
```js
notation.action('remind', async (ctx) => {
  await notation.tasks.add('Look at "' + ctx.note.title + '" again');
  return 'reminder added for ' + ctx.note.title;
});
```
with the rule *event* `noteStale`, `weeks` 6, *action* `extensionAction`, `extension` = `stale-reminder/remind`.

**Keeping a count between runs** (`storage`, no permission):

```js
notation.action('count-opens', async (ctx) => {
  const n = ((await notation.storage.get('opens')) || 0) + 1;
  await notation.storage.set('opens', n);
  return 'opened ' + n + ' times';
});
```

## Installing, switching on, updating

*Settings → Extensions*:

- **Install from a file (.zip)**: a zip with `manifest.json` and the script (at the top, or in one folder).
- **Write one**: type the manifest and the script in a dialog (with an example in it).
- **Create with AI**: describe what you want in your own words; see below.
- Each extension has a **switch** (off when installed) and the **permissions** it asks for, each with its own switch. A new version that asks for more has to be
  given the new permissions again. **Remove** deletes it with the data it kept.

## Create with AI

*Settings → Extensions → Create with AI* (and *Automations → Create with AI*) lets you describe a tool or an automation in plain language, e.g.
*"a tool that turns the selected lines into a markdown checklist"* or *"when a note has not been opened for a month, add a task to look at it"*.

What happens (`lib/extensions/magic_extension.dart`):

1. The AI provider you chose in Settings (on the device, or in the cloud) is given **this API** (the short reference of `magic_prompt.dart`), the rules
   (ask for the fewest permissions, return what the format says) and **your request**. *Nothing else is sent: no notes, no files.* With a cloud
   provider your request and the reference leave the device; with a model on the device nothing does.
2. It answers with a manifest, a script, the automations that should use the extension's actions, and a short explanation, in a fixed format.
3. The answer is **checked**: the manifest is read by the same rules as an installed one; every tool and action has a handler; the permissions the script uses
   (`notation.note.get`, `tasks.add`, ...) are asked for in the manifest (any that were forgotten are added and shown); the script is read by the engine for
   syntax errors (when it is available); the automations name events and actions that exist. A problem is told back to the model, which tries again (up to
   twice).
4. You see **what it made**: the name, what it adds, the **permissions it asks for** (each in words), the automations, and the script. You can ask for a change
   ("make it keep the first line", "only for PDFs") and it is made again from the first answer.
5. **Install** puts it in the list, **off** and with **no permission**; **Install and allow** also switches it on and gives the permissions you saw. The
   automations it made are added **switched off** unless you used *Install and allow*.

You are always the one who reads and decides: a script the AI wrote is only as trustworthy as any other script, which is why it is shown to you, runs in
the sandbox, and has only the permissions you gave.
