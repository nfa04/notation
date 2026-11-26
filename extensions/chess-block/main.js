// A block: ctx.text is what is written in the fence (a FEN, such as `rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w`),
// ctx.width the room there is. It answers with lines and texts to draw: no HTML, no pictures.
const PIECES = { K: '♔', Q: '♕', R: '♖', B: '♗', N: '♘', P: '♙', k: '♚', q: '♛', r: '♜', b: '♝', n: '♞', p: '♟' };
notation.block('board', (ctx) => {
  const fen = ctx.text.trim().split(/\s+/)[0] || '';
  const rows = fen.split('/');
  if (rows.length !== 8) throw new Error('A FEN has 8 rows separated by "/", e.g. rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR');
  const sq = 40;
  const strokes = [];
  const texts = [];
  rows.forEach((row, r) => {
    let file = 0;
    for (const ch of row) {
      if (/[1-8]/.test(ch)) { file += Number(ch); continue; }
      if (!PIECES[ch]) throw new Error('"' + ch + '" is not a piece (KQRBNP, kqrbnp).');
      texts.push({ x: file * sq + 5, y: r * sq + 1, text: PIECES[ch], size: 34, color: ch === ch.toUpperCase() ? '#ffffff' : '#000000' });
      file++;
    }
    if (file !== 8) throw new Error('Row ' + (r + 1) + ' has ' + file + ' squares, not 8.');
    for (let f = 0; f < 8; f++) {
      const x = f * sq, y = r * sq;
      strokes.push({ points: [[x, y], [x + sq, y], [x + sq, y + sq], [x, y + sq], [x, y]], fill: (f + r) % 2 ? '#b58863' : '#f0d9b5', color: '#8b6b4a', width: 0.5 });
    }
  });
  // the pieces come after the squares so that they are on top
  return { width: sq * 8, height: sq * 8, strokes, texts };
});
