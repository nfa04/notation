/// SQLite schema of the notes store. Bump [schemaVersion] and add a step to
/// [migrations] for every change; never edit a released step.
///
/// Conventions
///  - ids are client-generated TEXT (UUID-like), so rows can be created
///    offline and merged later; child rows that are never referenced from
///    elsewhere (strokes, highlights) use plain INTEGER keys.
///  - times are INTEGER milliseconds since the epoch (UTC).
///  - colours are INTEGER ARGB (Color.toARGB32()).
///  - positions are in the page space the editor draws in: `pages are
///    notes.page_width wide`, origin top-left, y down. Storing the width lets
///    a note be rescaled if the editor's page size ever changes.
///  - the order rows were drawn in is their rowid / `seq`.
const int schemaVersion = 53;

const List<String> createStatements = [
  '''
  CREATE TABLE folders (
    id          TEXT PRIMARY KEY,
    parent_id   TEXT REFERENCES folders(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    color       INTEGER,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    theme_image TEXT,                    -- banner image, a copy in app storage
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX idx_folders_parent ON folders(parent_id)',

  // One row per note. A note is either a blank notebook (no pdf_* columns,
  // optionally with a written document) or an annotated imported PDF.
  '''
  CREATE TABLE notes (
    id              TEXT PRIMARY KEY,
    folder_id       TEXT REFERENCES folders(id) ON DELETE SET NULL,
    title           TEXT NOT NULL DEFAULT '',

    -- blank notebook
    background      TEXT NOT NULL DEFAULT 'blank'
                    CHECK (background IN ('blank', 'grid', 'lines')),  -- (only these: the other papers are in `paper`, see PageBackground.legacyName)
    layers          TEXT,                          -- the layers beyond the plain one, as JSON (NULL: only the base layer, see LayerStack)
    paper           TEXT,                          -- the paper when it is not one of those three (a dot grid, music paper...); NULL: `background`
    page_format     TEXT NOT NULL DEFAULT 'a4',   -- see PageFormat
    landscape       INTEGER NOT NULL DEFAULT 0,
    theme_image     TEXT,                          -- banner image, a copy in app storage
    last_opened_at  INTEGER,                       -- NULL = not since this was recorded
    favorite        INTEGER NOT NULL DEFAULT 0,    -- 1: starred, shown first and in its own list
    lock_mode       INTEGER NOT NULL DEFAULT 0,    -- 0 none, 1 passcode (kept out of sight), 2 encrypted (see note_locks)
    margin_left     REAL NOT NULL DEFAULT 56,      -- document text area
    margin_right    REAL NOT NULL DEFAULT 56,
    margin_top      REAL NOT NULL DEFAULT 56,
    margin_bottom   REAL NOT NULL DEFAULT 56,
    document_text   TEXT NOT NULL DEFAULT '',
    document_spans  TEXT NOT NULL DEFAULT '[]',  -- JSON [{start,end,type}]

    -- imported PDF: a copy kept in the app's storage, never modified
    pdf_name        TEXT,
    pdf_path        TEXT,
    pdf_sha256      TEXT,
    pdf_page_count  INTEGER,
    native_pages    TEXT NOT NULL DEFAULT '[]',   -- JSON [page, ...]: pages of the PDF that are notebook pages (added ones: the paper shows, not the file)

    page_width      REAL NOT NULL DEFAULT 800,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    deleted_at      INTEGER,                      -- set = in the trash

    CHECK ((pdf_path IS NULL) = (pdf_name IS NULL))
  )
  ''',
  'CREATE INDEX idx_notes_folder ON notes(folder_id) WHERE deleted_at IS NULL',
  'CREATE INDEX idx_notes_updated ON notes(updated_at DESC) WHERE deleted_at IS NULL',

  // Pen strokes. `points` is a packed little-endian float32 x,y sequence
  // (see point_codec.dart): one row per stroke instead of one per point.
  '''
  CREATE TABLE strokes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    uid         TEXT,                              -- names the stroke across devices (NULL = not given yet)
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index  INTEGER NOT NULL,
    color       INTEGER NOT NULL,
    width       REAL NOT NULL,
    points      BLOB NOT NULL,
    author      TEXT,                              -- who drew it (NULL = not known)
    fill        INTEGER,                           -- colour inside a closed line (NULL = none)
    dash        INTEGER NOT NULL DEFAULT 0,        -- 0 solid, 1 dashed, 2 dotted
    pressure    BLOB,                              -- a byte for each point (NULL = no pressure)
    brush       TEXT,                              -- the brush that drew it (NULL = the pen)
    layer       TEXT,                              -- the layer it is on (NULL = the base layer)
    link        TEXT,                              -- a connector: the items its ends are fixed to, as JSON (NULL = a plain line)
    grp         TEXT,                              -- the group it is in (NULL = none)
    curve       TEXT,                              -- a line of the pen for curves: its points and handles, as JSON (NULL = not made with it)
    gradient    TEXT,                              -- the fill runs to another colour: the colour, angle and kind, as JSON (NULL = one colour)
    label       TEXT                               -- text along the line or inside the shape: the text and how it is set, as JSON (NULL = none)
  )
  ''',
  'CREATE INDEX idx_strokes_page ON strokes(note_id, page_index)',

  '''
  CREATE TABLE text_boxes (
    id          TEXT NOT NULL,                     -- unique per note only
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index  INTEGER NOT NULL,
    x           REAL NOT NULL,
    y           REAL NOT NULL,
    width       REAL NOT NULL,
    height      REAL NOT NULL,
    font_size   REAL NOT NULL DEFAULT 16,
    text        TEXT NOT NULL DEFAULT '',          -- Markdown source
    spans       TEXT NOT NULL DEFAULT '[]',        -- JSON, like document_spans
    style       TEXT,                              -- JSON look (fill, border, text colour); NULL = default
    seq         INTEGER NOT NULL DEFAULT 0,        -- stacking order
    author      TEXT,                              -- who made it (NULL = not known)
    layer       TEXT,                              -- the layer it is on (NULL = the base layer)
    grp         TEXT,                              -- the group it is in (NULL = none)
    PRIMARY KEY (note_id, id)
  )
  ''',
  'CREATE INDEX idx_text_boxes_page ON text_boxes(note_id, page_index)',

  '''
  CREATE TABLE highlights (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    uid         TEXT,                              -- names the mark across devices (NULL = not given yet)
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index  INTEGER NOT NULL,
    left        REAL NOT NULL,
    top         REAL NOT NULL,
    right       REAL NOT NULL,
    bottom      REAL NOT NULL,
    color       INTEGER NOT NULL,                  -- alpha included
    comment_box TEXT,                              -- the text box that holds the comment this marks, if it is one
    author      TEXT                               -- who made it (NULL = not known)
  )
  ''',
  'CREATE INDEX idx_highlights_page ON highlights(note_id, page_index)',

  _createImages,
  _createTasks,
  _createSettingsNow,
  _createStyles,
  _createIcsCalendars,
  _createNoteEmbeddings,
  _createNoteVersions,
  _indexNoteVersions,
  _createNoteBranches,
  _createPdfText,
  _createInkText,
  _createTemplates,
  _createNoteLocks,
  _createNoteChunks,
  _createNoteChunkState,
  _createNoteAi,
  _createFacts,
  _indexFacts,
  _createFactState,
  _createSavedGraphs,
  _createEventCache,
  _createTaskEvents,
  _createSyncTombstones,
  _createSyncMarks,
  _createSyncLineage,
  _createSyncDigest,
  _createSyncStubs,
  _createNativeShares,
  _createNativeShareItems,
  _createReviewCards,
  _indexReviewCards,
  _createNoteTags,
  _indexNoteTags,
  _createPageBookmarks,
  _createReminders,
  _indexReminders,
  _createNoteAudio,
  _createAudioMarks,
  _indexNoteAudio,
];

/// Flashcards kept for spaced repetition: the card and where it is in its schedule (see `CardSchedule`). [source] is the note
/// the card came from, or 'graph' for one made from the facts of all notes; [id] is made from both and the question, so
/// making the same card twice keeps one.
const String _createReviewCards = '''
  CREATE TABLE IF NOT EXISTS review_cards (
    id         TEXT PRIMARY KEY,
    source     TEXT NOT NULL,
    front      TEXT NOT NULL,
    back       TEXT NOT NULL,
    page       INTEGER,
    due        INTEGER NOT NULL,                  -- when it is next asked
    interval   REAL NOT NULL DEFAULT 0,           -- days
    ease       REAL NOT NULL DEFAULT 2.5,
    reps       INTEGER NOT NULL DEFAULT 0,
    lapses     INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
  )
  ''';
const String _indexReviewCards = 'CREATE INDEX IF NOT EXISTS idx_review_cards_due ON review_cards(due)';

/// The tags of notes (see `TagRepository`): one row per note and tag, the tag as `normalizeTag` makes it.
const String _createNoteTags = '''
  CREATE TABLE IF NOT EXISTS note_tags (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    tag     TEXT NOT NULL,
    PRIMARY KEY (note_id, tag)
  )
  ''';
const String _indexNoteTags = 'CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag)';

/// Pages of a note the person marked (see `BookmarkRepository`). [page_index] is zero-based; [label] is empty when the page has no name.
const String _createPageBookmarks = '''
  CREATE TABLE IF NOT EXISTS page_bookmarks (
    note_id    TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index INTEGER NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    PRIMARY KEY (note_id, page_index)
  )
  ''';

/// Times at which the person is told something (see `ReminderRepository`). [ref_id] is the note or task it is about; it is not a
/// foreign key (a task is not always a row of this database, and the title is kept for when the thing is gone).
const String _createReminders = '''
  CREATE TABLE IF NOT EXISTS reminders (
    id         TEXT PRIMARY KEY,
    kind       TEXT NOT NULL,                     -- 'custom', 'note' or 'task'
    ref_id     TEXT,
    title      TEXT NOT NULL,
    at         INTEGER NOT NULL,                  -- the first time it goes off
    repeat     TEXT NOT NULL DEFAULT 'none',
    auto       INTEGER NOT NULL DEFAULT 0,        -- 1: made by the app for a task's due date
    fired_to   INTEGER,                           -- the occurrence last announced
    created_at INTEGER NOT NULL
  )
  ''';
const String _indexReminders = 'CREATE INDEX IF NOT EXISTS idx_reminders_ref ON reminders(kind, ref_id)';

/// Sound kept with a note (see `NoteAudioRepository`): what was recorded while writing it down, or the note read aloud into a file.
/// The sound itself is a file in the app's storage, [file] is its name there.
const String _createNoteAudio = '''
  CREATE TABLE IF NOT EXISTS note_audio (
    id          TEXT NOT NULL,                    -- unique per note only (a note file brings its sounds along with their ids)
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,                    -- 'recording' or 'speech'
    title       TEXT NOT NULL DEFAULT '',
    file        TEXT NOT NULL,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    bytes       INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (note_id, id)
  )
  ''';
/// The moment of a recording at which each stroke or text box of the note was written (see `SoundMark`), for playing the sound from there.
const String _createAudioMarks = '''
  CREATE TABLE IF NOT EXISTS audio_marks (
    note_id    TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    audio_id   TEXT NOT NULL,
    element_id TEXT NOT NULL,
    page_index INTEGER NOT NULL,
    offset_ms  INTEGER NOT NULL,
    PRIMARY KEY (note_id, audio_id, element_id)
  )
  ''';
const String _indexNoteAudio = 'CREATE INDEX IF NOT EXISTS idx_note_audio_note ON note_audio(note_id)';

/// The secrets of locked notes. A note locked with a passcode (mode 1) keeps its content where it is and has a [verifier] (a
/// hash of the passcode) to be opened with. An encrypted note (mode 2) has its whole content in [data] (a note file, encrypted
/// with AES-GCM under a key made from the passphrase and [salt]) and nothing of it in the other tables, except while it is
/// [open] (being read or written, in plain, until it is put away again).
/// The text of a note cut into passages with a vector each, to find the passages that answer a question (see `NoteKnowledge`).
const String _createNoteChunks = '''
  CREATE TABLE IF NOT EXISTS note_chunks (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    idx     INTEGER NOT NULL,
    page    INTEGER,                              -- zero-based; null: belongs to no page
    label   TEXT NOT NULL,                        -- 'Page 3', 'Title'
    text    TEXT NOT NULL,
    vector  BLOB,                                 -- packed little-endian float32; null: no model was there to read it
    PRIMARY KEY (note_id, idx)
  )
''';

/// What the passages of a note were made from: they are made again when the text or the model changed.
const String _createNoteChunkState = '''
  CREATE TABLE IF NOT EXISTS note_chunk_state (
    note_id   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    model     TEXT NOT NULL,
    text_hash INTEGER NOT NULL
  )
''';

/// What the AI made of a note (a summary, a presentation, flashcards...), kept with the note so that it is not made again
/// (unless the person asks). `source_hash` is of the text it was made from, to tell that the note has changed since.
const String _createNoteAi = '''
  CREATE TABLE IF NOT EXISTS note_ai (
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,
    key         TEXT NOT NULL DEFAULT '',
    content     TEXT NOT NULL,
    source_hash INTEGER NOT NULL DEFAULT 0,
    model       TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (note_id, kind, key)
  )
''';

/// The facts the graph view takes from the notes (see `FactExtractor`): one statement each, with where it is from and a vector.
const String _createFacts = '''
  CREATE TABLE IF NOT EXISTS facts (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id   TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page      INTEGER,                              -- zero-based; null: no page
    title     TEXT NOT NULL,
    tag       TEXT NOT NULL DEFAULT 'Fact',
    sentence  TEXT NOT NULL,
    keywords  TEXT NOT NULL DEFAULT '',             -- comma-separated
    vector    BLOB                                  -- packed little-endian float32
  )
''';

/// Facts are read, replaced and (with their note) deleted by `note_id`; without this each of those reads every fact.
const String _indexFacts = 'CREATE INDEX IF NOT EXISTS idx_facts_note ON facts(note_id)';

/// What the facts of a note were made from: they are made again when the text changes.
const String _createFactState = '''
  CREATE TABLE IF NOT EXISTS fact_state (
    note_id   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    text_hash INTEGER NOT NULL,
    model     TEXT NOT NULL,                        -- the sentence model (or 'lexical')
    extractor TEXT NOT NULL                         -- 'llm' or 'text'
  )
''';

/// The graphs the person made and kept (see `GraphService`), with their layout, to show at once; one row each, shown as tabs.
/// `folder_id` is the folder the graph was made of (NULL: all notes), to make it again the same way. `uid` is the same on every device
/// of the profile (the sync names a graph by it; `id` is only this device's), `updated_at` when it was made, renamed or made again (what
/// the sync compares).
const String _createSavedGraphs = '''
  CREATE TABLE IF NOT EXISTS saved_graphs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    uid        TEXT NOT NULL UNIQUE,
    name       TEXT NOT NULL,
    mode       TEXT NOT NULL,                       -- 'notes' or 'facts'
    folder_id  TEXT,
    built_at   INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    payload    TEXT NOT NULL
  )
''';

/// The graphs as version 25 kept them (one per mode), for databases that are still on it; [_moveGraphSnapshots] takes them over.
const String _createGraphSnapshots = '''
  CREATE TABLE IF NOT EXISTS graph_snapshots (
    mode     TEXT PRIMARY KEY,
    built_at INTEGER NOT NULL,
    payload  TEXT NOT NULL
  )
''';

/// `saved_graphs` as the first build of version 51 made it (no `uid`, no `updated_at`) becomes what it is now. A table that is the new
/// one already (a database that came from version 50 or is new) has the columns, and a step that adds them again is skipped (see
/// `AppDatabase`). The ids are made at random: only the graphs of the build that had no ids are given them.
const List<String> _graphsGetIds = [
  'ALTER TABLE saved_graphs ADD COLUMN uid TEXT',
  'ALTER TABLE saved_graphs ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
  'UPDATE saved_graphs SET uid = lower(hex(randomblob(8))) WHERE uid IS NULL',
  'UPDATE saved_graphs SET updated_at = built_at WHERE updated_at = 0',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_graphs_uid ON saved_graphs(uid)',
];

/// What the version before kept as "the graph of facts" and "the graph of notes" becomes a saved graph each. Their ids are the same on
/// every device, so that two devices that both made the first one come to one graph when they sync, not two.
const List<String> _moveGraphSnapshots = [
  _createSavedGraphs,
  _createGraphSnapshots, // (a database that was made before version 25 has none to take from)
  "INSERT INTO saved_graphs (uid, name, mode, folder_id, built_at, updated_at, payload) SELECT 'first-' || mode, 'Facts', mode, NULL, built_at, built_at, payload FROM graph_snapshots WHERE mode = 'facts'",
  "INSERT INTO saved_graphs (uid, name, mode, folder_id, built_at, updated_at, payload) SELECT 'first-' || mode, 'Notes', mode, NULL, built_at, built_at, payload FROM graph_snapshots WHERE mode = 'notes'",
  'DROP TABLE IF EXISTS graph_snapshots',
];

/// The events a calendar of the server answered with, kept to show at once the next time (and offline); the server is asked
/// again after that and the answer replaces them. `source` is the calendar service, `range_key` the stretch of days.
const String _createEventCache = '''
  CREATE TABLE IF NOT EXISTS event_cache (
    source     TEXT NOT NULL,
    range_key  TEXT NOT NULL,
    fetched_at INTEGER NOT NULL,
    payload    TEXT NOT NULL,                     -- JSON list of events
    PRIMARY KEY (source, range_key)
  )
''';

/// Notes and folders that were deleted for good, so that the other devices of the profile delete them too (see `DeviceSyncService`).
const String _createSyncTombstones = '''
  CREATE TABLE IF NOT EXISTS sync_tombstones (
    kind       TEXT NOT NULL,                     -- 'note', 'folder' or 'graph'
    id         TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    PRIMARY KEY (kind, id)
  )
''';

/// What another device and this one agreed on at the last sync of each note and folder, to tell which of them changed since:
/// `version` is the note's `updated_at` then, `meta` a fingerprint of where it was (folder, star, trash).
const String _createSyncMarks = '''
  CREATE TABLE IF NOT EXISTS sync_marks (
    peer    TEXT NOT NULL,
    kind    TEXT NOT NULL,
    id      TEXT NOT NULL,
    version INTEGER NOT NULL,
    meta    TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (peer, kind, id)
  )
''';

/// What the version of each note that the sync last saw grew from: `cur` is that version (the note's `updated_at`), `anc` a JSON
/// list of the versions before it, newest first - its own earlier ones and those of the devices it was taken from. A device that
/// finds its version among another's ancestors knows the other's note grew from its own: no conflict, nothing to keep twice.
const String _createSyncLineage = '''
  CREATE TABLE IF NOT EXISTS sync_lineage (
    id  TEXT PRIMARY KEY,
    cur INTEGER NOT NULL,
    anc TEXT NOT NULL DEFAULT '[]'
  )
''';

/// What the content of each version of a note was when it passed through a sync (sent or taken in; the last few), as a digest that leaves out the times: a
/// note that was saved again without a change (opened, a page count or a text layer found) is then not taken for changed on this
/// device, and no copy of it is kept when the other device changes the note.
const String _createSyncDigest = '''
  CREATE TABLE IF NOT EXISTS sync_digest (
    id      TEXT NOT NULL,
    version INTEGER NOT NULL,
    digest  TEXT NOT NULL,
    PRIMARY KEY (id, version)
  )
''';

/// Notes a temporary browser knows of but has not fetched (see `SyncLibrary.lazy`): the row in `notes` holds the title, place and times, and no
/// content. A note leaves this table when its content arrives.
const String _createSyncStubs = '''
  CREATE TABLE IF NOT EXISTS sync_stubs (
    id TEXT PRIMARY KEY
  )
''';

/// Notes and folders shared with other people through a cloud service (see `NativeShareService`): the ones given and the ones
/// received. `root_id` is the note or folder here that the share is about; `data` is the rest of it as JSON (who it is shared with, where
/// it is at the service, where the person put what they received).
const String _createNativeShares = '''
  CREATE TABLE IF NOT EXISTS native_shares (
    id         TEXT PRIMARY KEY,
    provider   TEXT NOT NULL,
    direction  TEXT NOT NULL,                     -- 'out' (given) or 'in' (received)
    kind       TEXT NOT NULL,                     -- 'note', 'folder' or 'graph'
    root_id    TEXT NOT NULL,
    state      TEXT NOT NULL,
    data       TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL
  )
''';

/// Which notes and folders belong to a share: what its participants may change here, and what a deletion told by one of them may reach.
const String _createNativeShareItems = '''
  CREATE TABLE IF NOT EXISTS native_share_items (
    share_id TEXT NOT NULL,
    kind     TEXT NOT NULL,                       -- 'note' or 'folder'
    id       TEXT NOT NULL,
    PRIMARY KEY (share_id, kind, id)
  )
''';

/// Tasks that were put on a calendar as events (see `TaskCalendarMirror`): where, and what they looked like then.
const String _createTaskEvents = '''
  CREATE TABLE IF NOT EXISTS task_events (
    task_id     TEXT PRIMARY KEY,
    target      TEXT NOT NULL,                    -- 'caldav:<calendar href>' or 'phone:<calendar id>'
    remote_id   TEXT NOT NULL,                    -- the event's uid (server) or id (phone)
    fingerprint TEXT NOT NULL
  )
''';

const String _createNoteLocks = '''
  CREATE TABLE IF NOT EXISTS note_locks (
    note_id     TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    mode        INTEGER NOT NULL,
    salt        BLOB NOT NULL,
    iterations  INTEGER NOT NULL,
    verifier    BLOB,
    nonce       BLOB,
    data        BLOB,
    open        INTEGER NOT NULL DEFAULT 0
  )
  ''';

/// Notes the person kept to start others from: a note file ([data]) with a name.
/// Where the first version kept the library of sources, which now lives in the settings (so that it syncs, see `CitationRepository`).
/// Only a database that got to this step has the table; `CitationRepository.adoptLegacy` moves what is in it and drops it. A new
/// database does not have it.
const String _createCitationSources = '''
  CREATE TABLE IF NOT EXISTS citation_sources (
    id          TEXT PRIMARY KEY,
    data        TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
  )
  ''';

const String _createTemplates = '''
  CREATE TABLE IF NOT EXISTS templates (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    data        BLOB NOT NULL
  )
  ''';

/// The text of the pages of an imported PDF, read once so that a search does not have to open every PDF. A page without text has a
/// row too (an empty one): a note whose rows are as many as its pages is read completely.
const String _createPdfText = '''
  CREATE TABLE IF NOT EXISTS pdf_text (
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index  INTEGER NOT NULL,
    text        TEXT NOT NULL,
    PRIMARY KEY (note_id, page_index)
  )
  ''';

/// What the handwriting reader made of the pen strokes of a note, block by block, so that a search can look in it. [key] names the
/// block of strokes as they were ([InkCluster.key]), [text] is what was read (empty: read, nothing found), the rest is where the
/// block lies on its page.
const String _createInkText = '''
  CREATE TABLE IF NOT EXISTS ink_text (
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    key         TEXT NOT NULL,
    page_index  INTEGER NOT NULL,
    text        TEXT NOT NULL,
    left        REAL NOT NULL,
    top         REAL NOT NULL,
    right       REAL NOT NULL,
    bottom      REAL NOT NULL,
    PRIMARY KEY (note_id, key)
  )
  ''';

const String _indexNoteVersions = 'CREATE INDEX idx_note_versions_note ON note_versions(note_id, created_at)';

/// Earlier states of notes (see `NoteHistory`). The note itself is in a file of the app's storage ([file]); the
/// PDF and the pictures it refers to are kept once, by their checksum ([blobs], comma-separated).
const String _createNoteVersions = '''
  CREATE TABLE note_versions (
    id          TEXT PRIMARY KEY,
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    created_at  INTEGER NOT NULL,
    manual      INTEGER NOT NULL DEFAULT 0,       -- 1: saved by the person (kept until they delete it)
    label       TEXT,                             -- the name the person gave it
    reason      TEXT NOT NULL DEFAULT 'edit',     -- why it was made (edit, left, merge, restore, joined, manual, branch)
    branch      TEXT NOT NULL DEFAULT 'main',     -- the line of versions it belongs to (see note_branches)
    who         TEXT,                             -- whose changes came in right after it (for merge)
    fingerprint TEXT NOT NULL,                    -- of the content, to skip a version that is the same as the one before
    file        TEXT NOT NULL,
    blobs       TEXT NOT NULL DEFAULT '',
    size        INTEGER NOT NULL DEFAULT 0
  )
  ''';

/// Lines of versions of a note, besides the main one (which has no row until it is needed): where each began ([base], a version
/// of the line it was made from, which is what a merge compares with), and which one the note is on now.
const String _createNoteBranches = '''
  CREATE TABLE IF NOT EXISTS note_branches (
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    base        TEXT,                              -- the version it began from (NULL for main)
    created_at  INTEGER NOT NULL,
    active      INTEGER NOT NULL DEFAULT 0,        -- 1: the note is on this branch now
    PRIMARY KEY (note_id, name)
  )
  ''';

/// To-do items of the calendar. `due_date` is a calendar day as 'YYYY-MM-DD'
/// (not a moment: a task due on the 5th is due on the 5th in every time
/// zone), NULL for tasks without a date. `done_at` is NULL while open.
///
/// CalDAV sync bookkeeping: `remote_href` / `remote_etag` identify the task on
/// the server as of the last sync (NULL = never uploaded), `dirty` marks local
/// changes not yet uploaded, and `deleted_at` is a tombstone for a task that
/// was deleted here but still has to be deleted on the server.
const String _createTasks = '''
  CREATE TABLE tasks (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    due_date     TEXT,
    done_at      INTEGER,
    created_at   INTEGER NOT NULL,
    remote_href  TEXT,
    remote_etag  TEXT,
    dirty        INTEGER NOT NULL DEFAULT 1,
    deleted_at   INTEGER,
    auto         INTEGER NOT NULL DEFAULT 0     -- 1: made by an automation or found in a note, not typed in
  )
  ''';

/// Small key/value store for non-secret app settings (the CalDAV account
/// name and chosen calendars, ...). Secrets live in the platform keystore.
const String _createSettings = '''
  CREATE TABLE settings (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
  )
  ''';

/// [_createSettings] as it is from version 28 on, for a new database (the step that made the table stays as it was).
const String _createSettingsNow = '''
  CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    changed_at INTEGER NOT NULL DEFAULT 0       -- when the value was set (for syncing settings between devices); 0: not known
  )
  ''';

/// Local-only looks for calendar items (never synced anywhere). `scope` is
/// what is styled - 'calendar', 'event', 'task' or 'day' - and `key` which one:
/// a calendar's identity, `<calendar>|<uid>` of an event, a task id, or a
/// 'YYYY-MM-DD' day. Every column except the key may be NULL = not customised.
const String _createStyles = '''
  CREATE TABLE styles (
    scope   TEXT NOT NULL,
    key     TEXT NOT NULL,
    color   INTEGER,
    border  TEXT,
    emoji   TEXT,
    PRIMARY KEY (scope, key)
  )
  ''';

/// Calendars imported from `.ics` files or followed by link (local only). The
/// text of the file is kept as it is and read when events are needed.
/// What a language model made of the text of a note (see NoteSorter): kept so that only
/// notes whose text changed are read again. `vector` is packed little-endian float32.
const String _createNoteEmbeddings = '''
  CREATE TABLE note_embeddings (
    note_id   TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    model     TEXT NOT NULL,
    text_hash INTEGER NOT NULL,                    -- of the text that was read
    vector    BLOB NOT NULL
  )
''';

const String _createIcsCalendars = '''
  CREATE TABLE ics_calendars (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    color        TEXT,                    -- '#RRGGBB' from the file, or chosen
    url          TEXT,                    -- set for a calendar followed by link
    content      TEXT NOT NULL,
    event_count  INTEGER NOT NULL DEFAULT 0,
    imported_at  INTEGER NOT NULL
  )
  ''';

/// The tasks table as it was in version 3, for databases still on it.
const String _createTasksV3 = '''
  CREATE TABLE tasks (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    due_date    TEXT,
    done_at     INTEGER,
    created_at  INTEGER NOT NULL
  )
  ''';

const String _createImages = '''
  CREATE TABLE images (
    id          TEXT NOT NULL,                     -- unique per note only
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index  INTEGER NOT NULL,
    path        TEXT NOT NULL,                     -- a copy in the app's storage (PNG or JPEG)
    x           REAL NOT NULL,
    y           REAL NOT NULL,
    width       REAL NOT NULL,
    height      REAL NOT NULL,
    seq         INTEGER NOT NULL DEFAULT 0,        -- stacking order
    author      TEXT,                              -- who placed it (NULL = not known)
    layer       TEXT,                              -- the layer it is on (NULL = the base layer)
    grp         TEXT,                              -- the group it is in (NULL = none)
    PRIMARY KEY (note_id, id)
  )
  ''';

/// The images table as it was when it was added (version 6); later columns come by the steps after it.
const String _createImagesV6 = '''
  CREATE TABLE images (
    id          TEXT NOT NULL,                     -- unique per note only
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_index  INTEGER NOT NULL,
    path        TEXT NOT NULL,                     -- a copy in the app's storage (PNG or JPEG)
    x           REAL NOT NULL,
    y           REAL NOT NULL,
    width       REAL NOT NULL,
    height      REAL NOT NULL,
    seq         INTEGER NOT NULL DEFAULT 0,        -- stacking order
    PRIMARY KEY (note_id, id)
  )
  ''';

/// `migrations[v]` upgrades a database from version `v` to `v + 1`.
const Map<int, List<String>> migrations = {
  52: [_createSyncStubs],
  51: _graphsGetIds,
  50: _moveGraphSnapshots,
  49: [_createSyncDigest],
  48: [_createAudioMarks],
  47: ['ALTER TABLE strokes ADD COLUMN label TEXT'],
  46: ['ALTER TABLE strokes ADD COLUMN gradient TEXT'],
  45: [
    'ALTER TABLE strokes ADD COLUMN grp TEXT',
    'ALTER TABLE strokes ADD COLUMN curve TEXT',
    'ALTER TABLE text_boxes ADD COLUMN grp TEXT',
    'ALTER TABLE images ADD COLUMN grp TEXT',
  ],
  // (the check on `background` cannot be widened without making the table again, which would take the rows that point to a note
  // with it: so the papers that came after it have a column of their own, and `background` says "blank" for them to older versions)
  44: ['ALTER TABLE text_boxes ADD COLUMN layer TEXT', 'ALTER TABLE images ADD COLUMN layer TEXT'],
  43: ['ALTER TABLE strokes ADD COLUMN layer TEXT', 'ALTER TABLE notes ADD COLUMN layers TEXT'],
  42: ['ALTER TABLE notes ADD COLUMN paper TEXT'],
  41: ['ALTER TABLE strokes ADD COLUMN link TEXT'],
  40: ["ALTER TABLE notes ADD COLUMN native_pages TEXT NOT NULL DEFAULT '[]'"],
  39: [_createNoteAudio, _indexNoteAudio],
  38: [_createReminders, _indexReminders],
  37: [_createPageBookmarks],
  36: [_createNoteTags, _indexNoteTags],
  35: [_createReviewCards, _indexReviewCards],
  1: ['ALTER TABLE folders ADD COLUMN theme_image TEXT'],
  2: [_createTasksV3],
  3: [
    'ALTER TABLE tasks ADD COLUMN remote_href TEXT',
    'ALTER TABLE tasks ADD COLUMN remote_etag TEXT',
    'ALTER TABLE tasks ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1',
    'ALTER TABLE tasks ADD COLUMN deleted_at INTEGER',
    _createSettings,
  ],
  4: [_createStyles],
  5: [
    "ALTER TABLE notes ADD COLUMN page_format TEXT NOT NULL DEFAULT 'a4'",
    'ALTER TABLE notes ADD COLUMN landscape INTEGER NOT NULL DEFAULT 0',
  ],
  6: [_createImagesV6],
  8: ['ALTER TABLE notes ADD COLUMN theme_image TEXT'],
  9: ['ALTER TABLE text_boxes ADD COLUMN style TEXT'],
  10: ['ALTER TABLE notes ADD COLUMN last_opened_at INTEGER'],
  11: [_createIcsCalendars],
  12: ['ALTER TABLE highlights ADD COLUMN comment_box TEXT'],
  13: [_createNoteEmbeddings],
  14: [
    'ALTER TABLE strokes ADD COLUMN uid TEXT',
    'ALTER TABLE highlights ADD COLUMN uid TEXT',
  ],
  15: [_createNoteVersions, _indexNoteVersions],
  16: [
    'ALTER TABLE strokes ADD COLUMN author TEXT',
    'ALTER TABLE text_boxes ADD COLUMN author TEXT',
    'ALTER TABLE highlights ADD COLUMN author TEXT',
    'ALTER TABLE images ADD COLUMN author TEXT',
  ],
  17: [_createPdfText],
  18: ['ALTER TABLE notes ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0'],
  19: [_createTemplates],
  // (the number is the version the database is upgraded from; a column that is there already is skipped, see `AppDatabase`)
  34: [_createCitationSources],
  33: [_createInkText],
  32: ['ALTER TABLE strokes ADD COLUMN brush TEXT'],
  31: [_createNativeShares, _createNativeShareItems],
  30: [_createSyncLineage],
  29: [
    'ALTER TABLE notes ADD COLUMN margin_top REAL NOT NULL DEFAULT 56',
    'ALTER TABLE notes ADD COLUMN margin_bottom REAL NOT NULL DEFAULT 56',
    "ALTER TABLE note_versions ADD COLUMN branch TEXT NOT NULL DEFAULT 'main'",
    _createNoteBranches,
  ],
  28: [
    'ALTER TABLE notes ADD COLUMN margin_top REAL NOT NULL DEFAULT 56',
    'ALTER TABLE notes ADD COLUMN margin_bottom REAL NOT NULL DEFAULT 56',
  ],
  27: ['ALTER TABLE settings ADD COLUMN changed_at INTEGER NOT NULL DEFAULT 0', _createSyncTombstones, _createSyncMarks],
  26: [_indexFacts],
  25: [_createFacts, _createFactState, _createGraphSnapshots],
  24: [_createEventCache, _createTaskEvents, 'ALTER TABLE tasks ADD COLUMN auto INTEGER NOT NULL DEFAULT 0'],
  23: [_createNoteChunks, _createNoteChunkState, _createNoteAi],
  22: ['ALTER TABLE notes ADD COLUMN lock_mode INTEGER NOT NULL DEFAULT 0', _createNoteLocks],
  21: ['ALTER TABLE strokes ADD COLUMN pressure BLOB'],
  20: [
    'ALTER TABLE strokes ADD COLUMN fill INTEGER',
    'ALTER TABLE strokes ADD COLUMN dash INTEGER NOT NULL DEFAULT 0',
  ],
  7: [
    'ALTER TABLE notes ADD COLUMN margin_left REAL NOT NULL DEFAULT 56',
    'ALTER TABLE notes ADD COLUMN margin_right REAL NOT NULL DEFAULT 56',
  ],
};
