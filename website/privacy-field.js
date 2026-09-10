/* Native-resolution ASCII glyphs on a fixed grid. Drifting, irregular density patches
   animate the decorative wall behind readable HTML. No icons or bitmap scaling. */
(() => {
  const section = document.querySelector('.privacy-field');
  if (!section) return;
  const canvas = section.querySelector('canvas');
  const stage = section.querySelector('.privacy-field-stage');
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const saveData = navigator.connection?.saveData;
  const lines = [...section.querySelectorAll('.field-line')];
  let activeLine = -1;
  function showLine() {
    const sequencing = !reduced.matches;
    section.classList.toggle('is-scroll-sequence', sequencing);
    const bounds = section.getBoundingClientRect();
    const stageBounds = stage.getBoundingClientRect();
    const stageHeight = Math.max(1, stageBounds.height);
    const travel = Math.max(1, bounds.height - stageHeight);
    const clamp = value => Math.max(0, Math.min(1, value));
    const ease = value => value * value * (3 - 2 * value);
    const entry = sequencing ? ease(clamp(bounds.top / stageHeight)) : 0;
    const exit = sequencing ? ease(clamp((-bounds.top - travel) / stageHeight)) : 0;
    const edge = Math.max(entry, exit);
    // Reversible entry/exit: open to full screen, then gently close as the
    // stage leaves. No opacity fade or change to the text's scroll ordering.
    stage.style.setProperty('--field-inset', `${Math.round(edge * stageBounds.width * .08)}px`);
    stage.style.setProperty('--field-inset-y', `${Math.round(edge * stageHeight * .06)}px`);
    stage.style.setProperty('--field-radius', `${Math.round(Math.sqrt(edge) * 64)}px`);
    stage.style.setProperty('--field-blur', `${(.65 + edge * .35).toFixed(2)}px`);
    stage.style.setProperty('--field-text-y', `${Math.round((entry - exit) * 24)}px`);
    const progress = Math.max(0, Math.min(1, -bounds.top / travel));
    const index = sequencing ? Math.min(lines.length - 1, Math.floor(progress * lines.length)) : -1;
    if (index === activeLine) return;
    activeLine = index;
    lines.forEach((line, i) => line.classList.toggle('is-current', i === index));
  }
  let width = 0, height = 0, visible = false, timer = 0, frame = 0, phase = 0;
  let texture, dpr = 1, dx = 9, dy = 13, columns = 0, rows = 0;
  const glyphs = ['@', '#', '$', '%', '*', '+', '=', '-', ':', '.'];
  // Smooth, seeded patches drift through the grid without repeating stripes.
  function hash(x, y) {
    let n = Math.imul(x, 374761393) ^ Math.imul(y, 668265263);
    n = Math.imul(n ^ (n >>> 13), 1274126177);
    return ((n ^ (n >>> 16)) >>> 0) / 4294967295;
  }
  function flow(x, y) {
    const ix = Math.floor(x), iy = Math.floor(y);
    let fx = x - ix, fy = y - iy;
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    const a = hash(ix, iy), b = hash(ix + 1, iy);
    const c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1);
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
  }
  function surface(w, h) {
    const layer = document.createElement('canvas');
    layer.width = Math.ceil(w * dpr); layer.height = Math.ceil(h * dpr);
    layer.getContext('2d').setTransform(dpr, 0, 0, dpr, 0, 0);
    return layer;
  }
  function prepare() {
    const bounds = stage.getBoundingClientRect();
    width = bounds.width; height = bounds.height;
    if (!width || !height) return;
    dpr = devicePixelRatio || 1;
    canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    dx = width < 600 ? 10 : 9; dy = width < 600 ? 14 : 13;
    columns = Math.ceil(width / dx); rows = Math.ceil(height / dy);
    // Rasterize the atlas at native screen resolution. Cell positions never
    // slide across fractional pixels, and sprites are never enlarged.
    texture = surface(dx * glyphs.length, dy);
    const t = texture.getContext('2d');
    t.font = `600 ${width < 600 ? 12 : 11}px ui-monospace, Menlo, monospace`;
    t.textAlign = 'center'; t.textBaseline = 'middle';
    t.fillStyle = '#23745e';
    glyphs.forEach((glyph, i) => t.fillText(glyph, (i + .5) * dx, dy / 2));
    draw(reduced.matches || saveData ? null : phase);
    section.classList.add('is-rendered');
  }
  function draw(time) {
    if (!texture) return;
    ctx.clearRect(0, 0, width, height);
    const t = time ?? 0;
    // A slow travelling change in character density; no translated bitmap,
    // blur, fading sheet, or high-frequency random substitutions.
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < columns; col++) {
        const density = flow(col / 11 - t * .16, row / 8 + t * .055);
        const detail = hash(col + 913, row + 271);
        const glyph = Math.min(glyphs.length - 1, Math.floor((density * .65 + detail * .35) * glyphs.length));
        ctx.globalAlpha = 1;
        ctx.drawImage(texture, glyph * dx * dpr, 0, dx * dpr, dy * dpr,
          Math.round(col * dx * dpr) / dpr, Math.round(row * dy * dpr) / dpr, dx, dy);
      }
    }
    ctx.globalAlpha = 1;
  }
  function stop() { clearTimeout(timer); cancelAnimationFrame(frame); timer = frame = 0; }
  function tick() {
    if (!visible || document.hidden || reduced.matches || saveData) return;
    const delay = width < 600 ? 100 : 83;
    draw(phase); phase += delay / 1000;
    timer = setTimeout(() => { frame = requestAnimationFrame(tick); }, delay);
  }
  function sync() {
    stop();
    showLine();
    if (reduced.matches || saveData) { draw(null); return; }
    if (visible && !document.hidden) tick();
  }
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    if (visible && !texture) prepare();
    sync();
  }).observe(section);
  new ResizeObserver(() => { if (texture || visible) prepare(); showLine(); }).observe(stage);
  let scrollFrame = 0;
  document.addEventListener('scroll', () => {
    if (scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => { scrollFrame = 0; showLine(); });
  }, {passive: true});
  reduced.addEventListener('change', sync);
  document.addEventListener('visibilitychange', sync);
})();
