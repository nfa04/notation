// Simplenote: source/notes.json has { activeNotes: [{ id, content, creationDate, lastModified, tags }], trashedNotes: [...] }.
notation.importer('export', async (ctx) => {
  const notes = [];
  const notices = [];
  let trashed = 0;
  const seen = new Set();
  for (const f of ctx.files) {
    if (!/\.json$/i.test(f.name)) continue;
    let j;
    try { j = JSON.parse(await f.read()); } catch (e) { continue; }
    if (!j || !Array.isArray(j.activeNotes)) continue;
    trashed += Array.isArray(j.trashedNotes) ? j.trashedNotes.length : 0;
    for (const n of j.activeNotes) {
      const content = String(n.content || '').replace(/\r\n/g, '\n');
      if (!content.trim()) continue;
      const id = n.id || (f.path + '#' + notes.length);
      if (seen.has(id)) continue;
      seen.add(id);
      const first = content.split('\n').find((l) => l.trim()) || 'Untitled';
      const title = first.replace(/^#+\s*/, '').trim().slice(0, 120) || 'Untitled';
      notes.push({
        path: '', title, markdown: content,
        tags: (n.tags || []).map((t) => String(t).toLowerCase().replace(/\s+/g, '-')),
        created: n.creationDate, updated: n.lastModified, sourceId: 'simplenote:' + id,
      });
    }
  }
  if (trashed) notices.push(trashed + ' note' + (trashed === 1 ? '' : 's') + ' in the trash ' + (trashed === 1 ? 'was' : 'were') + ' left out.');
  if (!notes.length) notices.push('No Simplenote notes were found in what you picked.');
  return { notes, notices };
});
