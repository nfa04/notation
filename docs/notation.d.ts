// Types for the `notation` object that extensions are given (see extensions.md). Put this file next to your script and your editor
// completes the calls and finds the mistakes. It is kept in step with the app by test/extensions/magic_extension_test.dart.

type Json = string | number | boolean | null | Json[] | { [key: string]: Json };
type Day = string; // 2026-12-24
type Time = string; // 2026-12-24T09:30

interface FileOfImport {
  path: string;
  name: string;
  size: number;
  /** The file as text (at most 48 MB). */
  read(): Promise<string>;
  /** The file as base64. */
  readBytes(): Promise<string>;
}

interface ImportedNote {
  /** `Folder/Sub/Name`: the folders are made. */
  path?: string;
  title?: string;
  markdown: string;
  tags?: string[];
  created?: string | number;
  updated?: string | number;
  attachments?: { name: string; base64: string }[];
  pdf?: { name: string; base64: string };
  /** Stable in the source: running the importer again updates the note it made before. */
  sourceId?: string;
}

interface Field {
  id: string;
  title?: string;
  type?: 'text' | 'number' | 'boolean' | 'choice' | 'date';
  default?: string | number | boolean;
  choices?: string[];
}

interface DrawnStroke {
  points: [number, number][];
  color?: string;
  width?: number;
  dash?: 'solid' | 'dashed' | 'dotted';
  fill?: string;
  brush?: string;
}

interface Notation {
  // what the manifest lists gets its handler here
  tool(id: string, fn: (ctx: { text: string }) => string | { replace?: string; insert?: string; message?: string } | void | Promise<string | { replace?: string; insert?: string; message?: string } | void>): void;
  action(id: string, fn: (ctx: { event: string | null; note: { id: string; title: string }; data?: Json; params?: { [id: string]: Json } }) => string | void | Promise<string | void>): void;
  drawTool(id: string, fn: (ctx: { points: [number, number][]; start: [number, number]; end: [number, number]; pressures: number[] | null; shift: boolean; color: string; width: number; page: { width: number; height: number } }) => { strokes: DrawnStroke[]; message?: string } | Promise<{ strokes: DrawnStroke[]; message?: string }>): void;
  transcriptSource(id: string, fn: (ctx: { input: string }) => Json | Promise<Json>): void;
  importer(id: string, fn: (ctx: { files: FileOfImport[]; name: string }) => { notes: ImportedNote[]; notices?: string[] } | Promise<{ notes: ImportedNote[]; notices?: string[] }>): void;
  exporter(id: string, fn: (ctx: { note: { id: string; title: string; markdown: string; tags: string[] } }) => { name: string; text?: string; base64?: string } | Promise<{ name: string; text?: string; base64?: string }>): void;
  command(id: string, fn: (ctx: { note?: { id: string; title: string } }) => string | void | Promise<string | void>): void;
  block(id: string, fn: (ctx: { text: string; language: string; width: number }) => { width: number; height: number; strokes?: DrawnStroke[]; texts?: { x: number; y: number; text: string; size?: number; color?: string }[] } | Promise<{ width: number; height: number; strokes?: DrawnStroke[]; texts?: { x: number; y: number; text: string; size?: number; color?: string }[] }>): void;
  agentTool(id: string, fn: (ctx: { args: { [name: string]: Json } }) => string | Json | Promise<string | Json>): void;
  capture(id: string, fn: (ctx: { url: string; site: string; title: string; text: string; note: { id: string; title: string } }) => string | void | Promise<string | void>): void;

  note: {
    get(): Promise<{ id: string; title: string; text: string }>;
    insertText(text: string, options?: { after?: string; before?: string; at?: 'start' | 'end' }): Promise<void>;
    inspect(options?: { target?: string }): Promise<string>;
    setTitle(title: string): Promise<void>;
    replaceText(find: string, replacement: string, options?: { all?: boolean }): Promise<number>;
    format(options: { [key: string]: Json }): Promise<string>;
    resolveChanges(options?: { accept?: boolean }): Promise<{ settled: number }>;
    addTags(tags: string[]): Promise<void>;
    moveToFolder(name: string | null): Promise<void>;
  };
  selection: { replace(text: string): Promise<void> };
  pdf: {
    read(options?: { from?: number; to?: number; id?: string }): Promise<string>;
    search(query: string, options?: { id?: string }): Promise<{ page: number; snippet: string }[]>;
  };
  notes: {
    search(query: string, options?: { limit?: number }): Promise<{ id: string; title: string; snippet: string }[]>;
    read(id: string): Promise<{ id: string; title: string; text: string }>;
    create(title: string, text: string, options?: { folder?: string }): Promise<{ id: string }>;
    list(options?: { folder?: string | null; limit?: number }): Promise<{ id: string; title: string; folder: string | null; updated: Day }[]>;
    favorite(id: string, on?: boolean): Promise<void>;
    move(id: string, folder: string | null): Promise<void>;
    tag(id: string, tags: string[]): Promise<void>;
    trash(id: string): Promise<void>;
    restore(id: string): Promise<void>;
    /** The notes that note links to (the open note when no id). */
    links(id?: string | null): Promise<{ id: string; title: string }[]>;
    /** The notes that link to the note, with a snippet around the link. */
    backlinks(id?: string | null): Promise<{ id: string; title: string; page: number | null; snippet: string }[]>;
    byTag(tag: string): Promise<{ id: string; title: string; tags: string[] }[]>;
  };
  folders: {
    list(): Promise<{ name: string; parent: string | null; notes: number }[]>;
    create(name: string, options?: { parent?: string }): Promise<void>;
    rename(name: string, newName: string): Promise<void>;
  };
  tags: { list(): Promise<{ tag: string; notes: number }[]> };
  textBoxes: {
    list(): Promise<{ id: string; page: number; x: number; y: number; width: number; text: string }[]>;
    add(text: string, options?: { page?: number; x?: number; y?: number; width?: number }): Promise<{ id: string }>;
    move(id: string, options: { page?: number; x?: number; y?: number; width?: number }): Promise<void>;
    delete(id: string): Promise<void>;
  };
  images: {
    list(): Promise<{ id: string; page: number; x: number; y: number; width: number; height: number }[]>;
    move(id: string, options: { page?: number; x?: number; y?: number; width?: number }): Promise<void>;
    delete(id: string): Promise<void>;
  };
  draw: {
    strokes(strokes: DrawnStroke[], options?: { page?: number }): Promise<{ drawn: number }>;
    shape(options: { type: 'rectangle' | 'ellipse' | 'triangle' | 'diamond' | 'line' | 'arrow'; x: number; y: number; width?: number; height?: number; x2?: number; y2?: number; page?: number; color?: string; lineWidth?: number; fill?: string; dash?: 'solid' | 'dashed' | 'dotted' }): Promise<{ drawn: number }>;
  };
  pages: {
    setup(options: { paper?: string; orientation?: string; background?: string; margins?: { left?: number; right?: number; top?: number; bottom?: number } }): Promise<string>;
    list(): Promise<{ page: number; kind: 'written' | 'notebook' | 'pdf'; strokes: number; textBoxes: number; images: number; width: number; height: number }[]>;
    add(options?: { at?: number }): Promise<{ page: number }>;
    delete(page: number): Promise<void>;
    move(page: number, to: number): Promise<void>;
  };
  ink: {
    /** What the handwriting reader made of the ink (what is kept; nothing is read now). */
    read(options?: { page?: number }): Promise<{ page: number; top: number; left: number; text?: string; latex?: string }[]>;
    strokes(options?: { page?: number }): Promise<{ points: [number, number][]; color: string; width: number }[]>;
  };
  calendar: {
    events(from: Day, to: Day): Promise<{ title: string; start: Time | Day; end: Time | Day | null; allDay: boolean; calendar: string }[]>;
    addEvent(title: string, start: Time | Day, options?: { end?: Time | Day; allDay?: boolean; calendar?: string; description?: string }): Promise<void>;
  };
  reminders: {
    add(text: string, at: Time, options?: { repeat?: 'once' | 'daily' | 'weekly' | 'monthly' | 'yearly'; aboutNote?: boolean }): Promise<{ id: string }>;
    list(): Promise<{ id: string; text: string; at: Time; repeat: string }[]>;
    remove(id: string): Promise<void>;
  };
  cards: {
    add(cards: { front: string; back: string }[]): Promise<{ added: number }>;
    list(options?: { limit?: number }): Promise<{ id: string; front: string; back: string; source: string; due: Day }[]>;
    due(options?: { limit?: number }): Promise<{ id: string; front: string; back: string; source: string; due: Day }[]>;
  };
  citations: {
    search(query: string): Promise<{ id: string; title: string; authors: string[]; year: number | null }[]>;
    add(source: { title: string; author?: { family: string; given?: string }[]; year?: number; url?: string; doi?: string; [key: string]: Json | undefined }): Promise<string>;
  };
  tasks: {
    add(title: string, options?: { due?: Day }): Promise<void>;
    list(options?: { done?: boolean }): Promise<{ id: string; title: string; due: Day | null; done: boolean }[]>;
    complete(id: string, done?: boolean): Promise<void>;
    update(id: string, changes: { title?: string; due?: Day | null }): Promise<void>;
    remove(id: string): Promise<void>;
  };
  ai: { complete(prompt: string, options?: { maxTokens?: number }): Promise<string> };
  ui: {
    message(text: string): Promise<void>;
    confirm(text: string): Promise<boolean>;
    choose(title: string, items: string[]): Promise<string | null>;
    form(title: string, fields: Field[]): Promise<{ [id: string]: string | number | boolean | null } | null>;
    progress(text: string, fraction: number | null): Promise<void>;
  };
  events: { emit(name: string, data: { [key: string]: Json }): Promise<void> };
  clipboard: { write(text: string): Promise<void> };
  network: { fetch(url: string, options?: { method?: string; headers?: { [name: string]: string }; body?: string; responseType?: 'text' | 'base64' }): Promise<{ status: number; headers: { [name: string]: string }; body: string }> };
  storage: { get(key: string): Promise<Json | undefined>; set(key: string, value: Json): Promise<void>; remove(key: string): Promise<void> };
  settings: { get(): Promise<{ [id: string]: Json }> };
  secrets: { get(key: string): Promise<string | null>; set(key: string, value: string | null): Promise<void>; remove(key: string): Promise<void> };
}

declare const notation: Notation;
