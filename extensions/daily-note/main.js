notation.command('today', async (ctx) => {
  const s = await notation.settings.get();
  const day = ctx.day || new Date().toISOString().slice(0, 10); // (ctx.day is only given by tests)
  const title = 'Daily ' + day;
  const found = (await notation.notes.search(title, { limit: 5 })).find((n) => n.title === title);
  if (found) return 'Today\'s note is there already: "' + title + '".';
  if (s.ask && !(await notation.ui.confirm('Make the note "' + title + '"?'))) return 'Not made.';
  const text = String(s.template || '# {date}\n').replace(/\{date\}/g, day);
  const made = await notation.notes.create(title, text, s.folder ? { folder: s.folder } : {});
  await notation.notes.tag(made.id || made, ['daily']);
  return 'Made "' + title + '".';
});
