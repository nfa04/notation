// Standard Notes: { items: [{ uuid, content_type: 'Note' | 'Tag', content: { title, text, trashed, archived, references } }] }.
notation.importer('backup', async (ctx) => {
  const notes = [];
  const notices = [];
  let encrypted = false;
  let trashed = 0;
  for (const f of ctx.files) {
    if (!/\.(json|txt)$/i.test(f.name)) continue;
    let j;
    try { j = JSON.parse(await f.read()); } catch (e) { continue; }
    if (!j || !Array.isArray(j.items)) continue;
    const tagsOf = new Map();
    for (const item of j.items) {
      if (item.content_type !== 'Tag' || !item.content || typeof item.content !== 'object') continue;
      for (const ref of item.content.references || []) {
        if (!tagsOf.has(ref.uuid)) tagsOf.set(ref.uuid, []);
        tagsOf.get(ref.uuid).push(String(item.content.title || '').toLowerCase().replace(/\s+/g, '-'));
      }
    }
    for (const item of j.items) {
      if (item.content_type !== 'Note') continue;
      if (typeof item.content === 'string') { encrypted = true; continue; }
      const c = item.content || {};
      if (c.trashed) { trashed++; continue; }
      const tags = (tagsOf.get(item.uuid) || []).filter(Boolean);
      if (c.archived) tags.push('archived');
      notes.push({
        path: '', title: String(c.title || '').trim() || 'Untitled', markdown: String(c.text || ''), tags,
        created: item.created_at, updated: item.updated_at, sourceId: 'standardnotes:' + item.uuid,
      });
    }
  }
  if (encrypted) notices.push('Some notes are encrypted in this backup and cannot be read. Download a backup without encryption (Account, Data Backups) and import that.');
  if (trashed) notices.push(trashed + ' note' + (trashed === 1 ? '' : 's') + ' in the trash ' + (trashed === 1 ? 'was' : 'were') + ' left out.');
  if (!notes.length && !encrypted) notices.push('No Standard Notes notes were found in what you picked.');
  return { notes, notices };
});
