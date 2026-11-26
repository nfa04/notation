// Joplin: every item is a text file: its title, a blank line, its text, a blank line, then `key: value` lines (id, parent_id, type_ ...).
// type_ 1 is a note, 2 a notebook, 4 a picture or file (its bytes are in resources/<id>.<ext>), 5 a tag, 6 the link of a tag to a note.
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function bytesToBase64(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)] + (i + 1 < bytes.length ? B64[((b & 15) << 2) | (c >> 6)] : '=') + (i + 2 < bytes.length ? B64[c & 63] : '=');
  }
  return out;
}
function base64ToBytes(text) {
  const t = new Int16Array(128).fill(-1);
  for (let i = 0; i < 64; i++) t[B64.charCodeAt(i)] = i;
  const clean = String(text).replace(/[^A-Za-z0-9+/]/g, '');
  const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const a = t[clean.charCodeAt(i)], b = t[clean.charCodeAt(i + 1)];
    const c = i + 2 < clean.length ? t[clean.charCodeAt(i + 2)] : -1, d = i + 3 < clean.length ? t[clean.charCodeAt(i + 3)] : -1;
    if (o < out.length) out[o++] = (a << 2) | (b >> 4);
    if (c >= 0 && o < out.length) out[o++] = ((b & 15) << 4) | (c >> 2);
    if (d >= 0 && o < out.length) out[o++] = ((c & 3) << 6) | d;
  }
  return out;
}
function utf8(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length;) {
    const c = bytes[i++];
    if (c < 128) s += String.fromCharCode(c);
    else if (c < 224) s += String.fromCharCode(((c & 31) << 6) | (bytes[i++] & 63));
    else if (c < 240) { s += String.fromCharCode(((c & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)); }
    else { const cp = ((c & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63); s += String.fromCodePoint(cp); }
  }
  return s;
}
// the files of a tar: [{ name, bytes }]
function untar(bytes) {
  const files = [];
  let off = 0;
  const str = (a, b) => { let s = ''; for (let i = a; i < b && bytes[i] !== 0; i++) s += String.fromCharCode(bytes[i]); return s; };
  while (off + 512 <= bytes.length) {
    if (bytes[off] === 0) break;
    const name = str(off, off + 100), prefix = str(off + 345, off + 500);
    const size = parseInt(str(off + 124, off + 136).trim() || '0', 8);
    const type = String.fromCharCode(bytes[off + 156] || 48);
    off += 512;
    if (type === '0' || type === '\0') files.push({ name: (prefix ? prefix + '/' : '') + name, bytes: bytes.subarray(off, off + size) });
    off += Math.ceil(size / 512) * 512;
  }
  return files;
}
function parseItem(text) {
  const t = text.replace(/\r\n/g, '\n');
  const cut = t.lastIndexOf('\n\n');
  const meta = {};
  let head = t;
  if (cut >= 0) {
    const lines = t.slice(cut + 2).split('\n').filter(Boolean);
    if (lines.length && lines.every((l) => /^[a-z_]+: ?/.test(l))) {
      for (const l of lines) { const i = l.indexOf(':'); meta[l.slice(0, i)] = l.slice(i + 1).trim(); }
      head = t.slice(0, cut);
    }
  }
  if (meta.id === undefined) return null;
  const nl = head.indexOf('\n');
  meta.title = nl < 0 ? head : head.slice(0, nl);
  meta.body = nl < 0 ? '' : head.slice(nl + 1).replace(/^\n/, '');
  return meta;
}

notation.importer('jex', async (ctx) => {
  const items = [];
  const resourceBytes = new Map();
  const add = (name, text) => { const it = parseItem(text); if (it) items.push(it); };
  for (const f of ctx.files) {
    if (/\.jex$/i.test(f.name) || /\.tar$/i.test(f.name)) {
      for (const e of untar(base64ToBytes(await f.readBytes()))) {
        if (/\.md$/i.test(e.name)) add(e.name, utf8(e.bytes));
        else if (/(^|\/)resources\//.test(e.name)) resourceBytes.set(e.name.replace(/^.*resources\//, '').replace(/\.[^.]*$/, ''), { name: e.name.replace(/^.*\//, ''), base64: bytesToBase64(e.bytes) });
      }
    } else if (/\.md$/i.test(f.name) && !/(^|\/)resources\//.test(f.path)) {
      add(f.path, await f.read());
    } else if (/(^|\/)resources\//.test(f.path)) {
      resourceBytes.set(f.name.replace(/\.[^.]*$/, ''), { name: f.name, _file: f });
    }
  }
  const folders = new Map(items.filter((i) => i.type_ === '2').map((i) => [i.id, i]));
  const tags = new Map(items.filter((i) => i.type_ === '5').map((i) => [i.id, i.title]));
  const noteTags = new Map();
  for (const i of items) if (i.type_ === '6' && tags.has(i.tag_id)) { if (!noteTags.has(i.note_id)) noteTags.set(i.note_id, []); noteTags.get(i.note_id).push(String(tags.get(i.tag_id)).toLowerCase().replace(/\s+/g, '-')); }
  const resources = new Map(items.filter((i) => i.type_ === '4').map((i) => [i.id, i]));
  const pathOf = (id) => { const parts = []; let cur = folders.get(id), guard = 0; while (cur && guard++ < 30) { parts.unshift(cur.title); cur = folders.get(cur.parent_id); } return parts.join('/'); };
  const notes = [];
  for (const n of items) {
    if (n.type_ !== '1') continue;
    const attachments = [];
    const used = new Set();
    const body = n.body.replace(/(!?)\[([^\]]*)\]\(:\/([0-9a-f]{32})\)/g, (m, bang, text, id) => {
      const res = resources.get(id);
      if (res) {
        const found = resourceBytes.get(id);
        const ext = res.file_extension ? '.' + res.file_extension : '';
        const name = (found && found.name) || (id + ext);
        if (!used.has(id)) { used.add(id); attachments.push({ id, name, found }); }
        return (bang ? '![' + text + '](' : '[' + text + '](') + name + ')';
      }
      return bang ? m : '[' + text + '](source:' + id + ')';
    });
    const files = [];
    for (const a of attachments) {
      if (a.found && a.found.base64) files.push({ name: a.name, base64: a.found.base64 });
      else if (a.found && a.found._file) files.push({ name: a.name, base64: await a.found._file.readBytes() });
    }
    const folder = pathOf(n.parent_id);
    if (n.is_todo === '1') n._todo = true;
    notes.push({
      path: folder ? folder + '/' + n.title : '', title: n.title.trim() || 'Untitled',
      markdown: (n.is_todo === '1' ? (n.todo_completed && n.todo_completed !== '0' ? '[x] ' : '[ ] ') : '') + body,
      tags: noteTags.get(n.id) || [], attachments: files, created: n.created_time, updated: n.updated_time, sourceId: n.id,
    });
  }
  const notices = [];
  if (!notes.length) notices.push('No Joplin notes were found in what you picked.');
  return { notes, notices };
});
