// An exporter: given the open note (ctx.note: id, title, markdown, tags), answers with the file to save.
notation.exporter('page', async (ctx) => {
  const s = await notation.settings.get();
  const today = new Date().toISOString().slice(0, 10);
  const slug = ctx.note.title.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'note';
  const q = (t) => '"' + String(t).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  const date = ctx.date || today;
  let front;
  if (s.format === 'toml') {
    front = ['+++', 'title = ' + q(ctx.note.title), 'date = ' + date, 'draft = ' + (s.draft ? 'true' : 'false'), s.author ? 'author = ' + q(s.author) : null,
      ctx.note.tags.length ? 'tags = [' + ctx.note.tags.map(q).join(', ') + ']' : null, '+++'].filter((l) => l !== null);
  } else {
    front = ['---', 'title: ' + q(ctx.note.title), 'date: ' + date, 'draft: ' + (s.draft ? 'true' : 'false'), s.author ? 'author: ' + q(s.author) : null,
      ctx.note.tags.length ? 'tags: [' + ctx.note.tags.map(q).join(', ') + ']' : null, '---'].filter((l) => l !== null);
  }
  const body = ctx.note.markdown.replace(/^# .*\n+/, '');
  return { name: slug, text: front.join('\n') + '\n\n' + body.trim() + '\n' };
});
