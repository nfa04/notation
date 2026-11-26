// Evernote: an .enex file holds <note>s: <title>, <created>, <tag>, <content> (ENML, a kind of XHTML in CDATA) and <resource>s (base64 data).
function unxml(s) {
  return String(s).replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(Number(d)))
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
}
function field(xml, name) {
  const m = new RegExp('<' + name + '(?:\\s[^>]*)?>([\\s\\S]*?)</' + name + '>').exec(xml);
  return m ? unxml(m[1].replace(/^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/, '$1')) : '';
}
function fileDate(s) {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$/.exec(s || '');
  return m ? m[1] + '-' + m[2] + '-' + m[3] + 'T' + m[4] + ':' + m[5] + ':' + m[6] + 'Z' : undefined;
}

// ENML to Markdown: a walk over the tags, with a stack for lists and for links.
function enmlToMarkdown(enml, mediaName) {
  const body = (/<en-note[^>]*>([\s\S]*)<\/en-note>/.exec(enml) || [0, enml])[1];
  const re = /<(\/?)([a-zA-Z0-9-]+)((?:\s+[^>]*?)?)(\/?)>|([^<]+)|<!--[\s\S]*?-->/g;
  let out = '';
  const lists = [];
  const links = [];
  let pre = false;
  const attr = (a, n) => { const m = new RegExp('\\b' + n + '\\s*=\\s*"([^"]*)"').exec(a); return m ? unxml(m[1]) : ''; };
  const nl = (n) => { out = out.replace(/[ \t]+$/, ''); const have = (/\n*$/.exec(out) || [''])[0].length; if (out.length && have < n) out += '\n'.repeat(n - have); };
  let m;
  while ((m = re.exec(body)) !== null) {
    if (m[5] !== undefined) {
      const text = unxml(m[5]);
      out += pre ? text : text.replace(/\s+/g, ' ');
      continue;
    }
    if (!m[2]) continue;
    const close = m[1] === '/', tag = m[2].toLowerCase(), a = m[3] || '', self = m[4] === '/';
    if (tag === 'br') { out += '  \n'; continue; }
    if (tag === 'hr') { nl(2); out += '---'; nl(2); continue; }
    if (tag === 'en-todo') { out += attr(a, 'checked') === 'true' ? '[x] ' : '[ ] '; continue; }
    if (tag === 'en-media') {
      const name = mediaName(attr(a, 'hash'), attr(a, 'type'));
      out += name ? (/^image\//.test(attr(a, 'type')) ? '![](' + name + ')' : '[' + name + '](' + name + ')') : '';
      continue;
    }
    if (self) continue;
    if (/^h[1-6]$/.test(tag)) { if (close) nl(2); else { nl(2); out += '#'.repeat(Number(tag[1])) + ' '; } continue; }
    if (tag === 'p' || tag === 'div' || tag === 'blockquote' || tag === 'table') {
      if (!close && tag === 'blockquote') { nl(2); out += '> '; } else if (tag === 'div' || tag === 'p') nl(lists.length ? 1 : 2); else nl(1);
      continue;
    }
    if (tag === 'tr') { nl(1); continue; }
    if (tag === 'td' || tag === 'th') { if (close) out += ' | '; continue; }
    if (tag === 'ul' || tag === 'ol') { if (close) { lists.pop(); nl(lists.length ? 1 : 2); } else { nl(lists.length ? 1 : 2); lists.push({ ordered: tag === 'ol', n: 0 }); } continue; }
    if (tag === 'li') {
      if (!close) { nl(1); const l = lists[lists.length - 1] || { ordered: false, n: 0 }; l.n++; out += '  '.repeat(Math.max(0, lists.length - 1)) + (l.ordered ? l.n + '. ' : '- '); }
      continue;
    }
    if (tag === 'b' || tag === 'strong') { out += '**'; continue; }
    if (tag === 'i' || tag === 'em') { out += '*'; continue; }
    if (tag === 's' || tag === 'strike' || tag === 'del') { out += '~~'; continue; }
    if (tag === 'code' && !pre) { out += '`'; continue; }
    if (tag === 'pre') { if (close) { pre = false; out += '\n```'; nl(2); } else { nl(2); out += '```\n'; pre = true; } continue; }
    if (tag === 'a') {
      if (close) { const href = links.pop(); out += href ? '](' + href + ')' : ''; }
      else { const href = attr(a, 'href'); links.push(href); if (href) out += '['; }
      continue;
    }
  }
  return out.replace(/\*\*\s*\*\*/g, '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

notation.importer('enex', async (ctx) => {
  const notes = [];
  const notices = [];
  let noteCount = 0;
  for (const f of ctx.files) {
    if (!/\.enex$/i.test(f.name)) continue;
    const text = await f.read();
    const folder = f.name.replace(/\.enex$/i, '');
    const parts = text.split(/<note>/).slice(1);
    let index = 0;
    for (const part of parts) {
      const xml = part.split('</note>')[0];
      index++;
      const resources = [];
      const byHash = new Map();
      const attachments = [];
      const rre = /<resource>([\s\S]*?)<\/resource>/g;
      let r;
      while ((r = rre.exec(xml)) !== null) {
        const dm = /<data[^>]*>([\s\S]*?)<\/data>/.exec(r[1]);
        if (!dm) continue;
        const mime = field(r[1], 'mime') || 'application/octet-stream';
        const given = field(r[1], 'file-name');
        const ext = (/\/([a-z0-9]+)/i.exec(mime) || [0, 'bin'])[1].replace('jpeg', 'jpg');
        const base = (given || ('file-' + (resources.length + 1) + '.' + ext)).replace(/[\\/:*?"<>|]/g, '_');
        let name = base, n = 2;
        while (attachments.some((x) => x.name === name)) name = n++ + '-' + base;
        const clean = dm[1].replace(/\s+/g, '');
        resources.push(name);
        attachments.push({ name, base64: clean });
        byHash.set(md5Hex(base64ToBytes(clean)), name);
      }
      const used = new Set();
      const mediaName = (hash) => { const n = byHash.get(hash); if (n) used.add(n); return n; };
      const content = field(xml, 'content');
      let markdown = enmlToMarkdown(content, mediaName);
      // pictures the text does not show (Evernote keeps them below it) go at the end
      for (const name of resources) {
        if (!used.has(name)) markdown += (markdown ? '\n\n' : '') + (/\.(png|jpe?g|gif|webp|bmp)$/i.test(name) ? '![](' + name + ')' : '[' + name + '](' + name + ')');
      }
      const tags = [];
      const tre = /<tag>([\s\S]*?)<\/tag>/g;
      let t;
      while ((t = tre.exec(xml)) !== null) tags.push(unxml(t[1]).trim().toLowerCase().replace(/\s+/g, '-'));
      const source = field(xml, 'source-url');
      if (source) markdown += '\n\n[Source](' + source + ')';
      notes.push({
        path: '', title: field(xml, 'title').trim() || 'Untitled', markdown, tags: tags.filter(Boolean),
        attachments, created: fileDate(field(xml, 'created')), updated: fileDate(field(xml, 'updated')),
        sourceId: 'enex:' + f.name + ':' + index,
      });
      noteCount++;
      if (noteCount % 50 === 0) await notation.ui.progress('Evernote: ' + noteCount + ' notes read', null);
    }
    if (folder && parts.length && ctx.files.filter((x) => /\.enex$/i.test(x.name)).length > 1) {
      for (const n of notes.filter((n) => n.sourceId.startsWith('enex:' + f.name + ':'))) n.path = folder + '/' + n.title;
    }
  }
  if (!notes.length) notices.push('No Evernote notes were found in what you picked (it takes .enex files).');
  return { notes, notices };
});
