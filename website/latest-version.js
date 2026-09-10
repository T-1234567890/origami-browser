/* Informational tags only. Download destinations remain in release.json. */
(() => {
  const label = document.querySelector('[data-latest-version]');
  if (!label) return;
  const endpoint = 'https://api.github.com/repos/T-1234567890/origami-browser/tags';
  function parse(tag) {
    if (typeof tag !== 'string') return null;
    const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.(0|[1-9]\d*))?$/.exec(tag);
    if (!match || match[0] !== tag) return null;
    return {tag, core: match.slice(1, 4).map(BigInt), beta: match[4] ? BigInt(match[4]) : null};
  }
  function compare(a, b) {
    for (let i = 0; i < 3; i++) {
      if (a.core[i] !== b.core[i]) return a.core[i] > b.core[i] ? 1 : -1;
    }
    if (a.beta === b.beta) return 0;
    if (a.beta === null) return 1;
    if (b.beta === null) return -1;
    return a.beta > b.beta ? 1 : -1;
  }
  async function load() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
      let latest = null;
      // Paginate because GitHub's tag order is not semantic-version order.
      // Bound requests; on an incomplete result, hide rather than guess.
      for (let page = 1; page <= 10; page++) {
        const response = await fetch(`${endpoint}?per_page=100&page=${page}`, {
          credentials: 'omit', referrerPolicy: 'no-referrer', signal: controller.signal,
          headers: {Accept: 'application/vnd.github+json'}
        });
        if (!response.ok) return;
        const tags = await response.json();
        if (!Array.isArray(tags)) return;
        for (const entry of tags) {
          const version = parse(entry?.name);
          if (version && (!latest || compare(version, latest) > 0)) latest = version;
        }
        if (tags.length < 100) {
          if (latest) {
            label.textContent = `v${latest.core.join('.')}${latest.beta === null ? '' : ` Beta ${latest.beta}`}`;
            label.classList.add('is-available');
            label.removeAttribute('aria-hidden');
          }
          return;
        }
      }
    } catch {
      // Offline, timeout, rate limit, or a private repository: stay quiet.
    } finally {
      clearTimeout(timeout);
    }
  }
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      if (!entries.some(entry => entry.isIntersecting)) return;
      observer.disconnect();
      load();
    }, {rootMargin: '300px'});
    observer.observe(label);
  } else {
    load();
  }
})();
