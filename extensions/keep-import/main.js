// Google Keep, from a Takeout: one .json per note (title, textContent or listContent, labels, attachments) and the pictures beside them.
notation.importer('takeout', async (ctx) => {
  const notes = [];
  const notices = [];
  const byName = new Map();
  for (const f of ctx.files) byName.set(f.name, f);
  let trashed = 0;
  let unreadable = 0;
  const done = new Set();
  for (const f of ctx.files) {
    if (!/\.json$/i.test(f.name)) continue;
    let j;
    try { j = JSON.parse(await f.read()); } catch (e) { unreadable++; continue; }
    if (!j || typeof j !== 'object' || !('userEditedTimestampUsec' in j || 'textContent' in j || 'listContent' in j)) continue;
    if (j.isTrashed) { trashed++; continue; }
    const lines = [];
    if (Array.isArray(j.listContent) && j.listContent.length) {
      for (const item of j.listContent) lines.push('- [' + (item.isChecked ? 'x' : ' ') + '] ' + (item.text || ''));
    }
    const text = (j.textContent || '').trim();
    let body = [text, lines.join('\n')].filter(Boolean).join('\n\n');
    const attachments = [];
    for (const a of j.attachments || []) {
      const file = byName.get(a.filePath);
      if (!file) { notices.push('Missing picture: ' + a.filePath); continue; }
      attachments.push({ name: a.filePath, base64: await file.readBytes() });
      body += (body ? '\n\n' : '') + '![](' + a.filePath + ')';
    }
    const title = (j.title || '').trim() || (text.split('\n')[0] || '').slice(0, 60) || 'Untitled';
    const tags = (j.labels || []).map((l) => String(l.name).trim().toLowerCase().replace(/\s+/g, '-')).filter(Boolean);
    if (j.isArchived) tags.push('archived');
    const edited = j.userEditedTimestampUsec ? new Date(Math.floor(j.userEditedTimestampUsec / 1000)).toISOString() : undefined;
    notes.push({ path: '', title, markdown: body, tags, attachments, updated: edited, sourceId: 'keep:' + f.path });
    done.add(f.path);
  }
  if (trashed) notices.push(trashed + ' note' + (trashed === 1 ? '' : 's') + ' in the trash of Keep ' + (trashed === 1 ? 'was' : 'were') + ' left out.');
  if (unreadable) notices.push(unreadable + ' file' + (unreadable === 1 ? '' : 's') + ' could not be read.');
  if (!notes.length) notices.push('No Keep notes were found in what you picked.');
  return { notes, notices };
});
