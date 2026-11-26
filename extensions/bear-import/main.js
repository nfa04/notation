// Bear: each note is a folder `Name.textbundle` with text.md (or .markdown, .txt) and assets/ (the pictures).
notation.importer('textbundle', async (ctx) => {
  const bundles = new Map();
  for (const f of ctx.files) {
    const m = /^(.*?[^/]*\.textbundle)\/(.+)$/i.exec(f.path);
    if (!m) continue;
    if (!bundles.has(m[1])) bundles.set(m[1], { text: null, assets: new Map() });
    const b = bundles.get(m[1]);
    if (/^text\.(md|markdown|txt)$/i.test(m[2])) b.text = f;
    else if (/^assets\//i.test(m[2])) b.assets.set(m[2], f);
  }
  const notes = [];
  const notices = [];
  let missing = 0;
  for (const [dir, b] of bundles) {
    if (!b.text) continue;
    const text = (await b.text.read()).replace(/\r\n/g, '\n');
    const attachments = [];
    for (const m of text.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)/g)) {
      const name = decodeURIComponent(m[1]);
      const file = b.assets.get(name);
      if (file && !attachments.some((a) => a.name === name)) attachments.push({ name, base64: await file.readBytes() });
      else if (!file && /^assets\//i.test(name)) missing++;
    }
    // the tags: #word and #several words# outside code
    const tags = new Set();
    let fence = false;
    for (const line of text.split('\n')) {
      if (/^\s*(```|~~~)/.test(line)) { fence = !fence; continue; }
      if (fence) continue;
      for (const m of line.replace(/`[^`]*`/g, '').matchAll(/(?:^|\s)#([^\s#][^#\n]*?#|[\w][\w/-]*)(?=\s|$)/g)) tags.add(m[1].replace(/#$/, '').trim().toLowerCase().replace(/\s+/g, '-'));
    }
    const heading = /^#\s+(.+)$/m.exec(text);
    const first = text.split('\n').find((l) => l.trim());
    const title = ((heading && heading[1]) || (first || '').replace(/^#+\s*/, '') || dir.replace(/^.*\//, '').replace(/\.textbundle$/i, '')).trim().slice(0, 120) || 'Untitled';
    notes.push({ path: '', title, markdown: text, tags: [...tags], attachments, sourceId: 'bear:' + dir });
  }
  if (missing) notices.push(missing + ' picture' + (missing === 1 ? ' was' : 's were') + ' not in the export.');
  if (!notes.length) notices.push('No TextBundle notes were found in what you picked.');
  return { notes, notices };
});
