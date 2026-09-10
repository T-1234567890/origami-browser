(() => {
  const config = window.ORIGAMI_SITE || {};
  if (config.siteURL && /^https:\/\//.test(config.siteURL)) {
    const canonical = document.createElement('link');
    canonical.rel = 'canonical'; canonical.href = config.siteURL; document.head.append(canonical);
    document.querySelector('meta[property="og:image"]').content = new URL('assets/origami-icon.png', config.siteURL).href;
    const url = document.createElement('meta'); url.setAttribute('property', 'og:url'); url.content = config.siteURL; document.head.append(url);
  }
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  // One-shot entrances use the Web Animations API. Content is visible by
  // default, so a missing observer or JavaScript never leaves it hidden.
  const entranceAnimations = new Set();
  const entrances = [...document.querySelectorAll(
    '.site-header, .hero > *, .introduction > *, .meet-screen > *, .chapter-inner, ' +
    '.fundamentals > h2, .fundamentals > .subtitle, .feature-grid > li, ' +
    '.native > *, .footer-top, .footer-bottom'
  )];
  if ('IntersectionObserver' in window && typeof Element.prototype.animate === 'function') {
    const reveal = new IntersectionObserver(entries => {
      entries.forEach(({target, isIntersecting}) => {
        if (!isIntersecting) return;
        reveal.unobserve(target);
        if (reduced.matches) return;
        const siblings = [...target.parentElement.children];
        const stagger = Math.min(siblings.indexOf(target) % 4, 3) * 65;
        const animation = target.animate([
          {opacity: 0, transform: 'translateY(18px)'},
          {opacity: 1, transform: 'translateY(0)'}
        ], {duration: 700, delay: stagger, easing: 'cubic-bezier(.22,1,.36,1)', fill: 'backwards'});
        entranceAnimations.add(animation);
        animation.onfinish = () => entranceAnimations.delete(animation);
        animation.oncancel = () => entranceAnimations.delete(animation);
      });
    }, {threshold: .08});
    entrances.forEach(element => reveal.observe(element));
  }
  reduced.addEventListener('change', () => {
    if (reduced.matches) entranceAnimations.forEach(animation => animation.cancel());
  });
  const saveData = Boolean(navigator.connection?.saveData);
  const chapters = [...document.querySelectorAll('.scroll-stack .chapter')];
  const videos = chapters.map(chapter => chapter.querySelector('video'));
  let activeVideo = null;
  let frame = 0;

  function stop(video) { video.pause(); }
  function updatePlayback() {
    frame = 0;
    // Sticky panels remain geometrically visible when covered. Select the last
    // arriving panel explicitly instead of relying on intersection alone.
    let candidate = null;
    if (!document.hidden && !reduced.matches && !saveData) {
      chapters.forEach((chapter, index) => {
        const bounds = chapter.getBoundingClientRect();
        if (bounds.top < innerHeight * .55 && bounds.bottom > 100) candidate = videos[index];
      });
    }
    if (candidate === activeVideo) return;
    videos.forEach(video => { if (video !== candidate) stop(video); });
    activeVideo = candidate;
    if (!candidate) return;
    candidate.poster = candidate.dataset.poster;
    if (!candidate.getAttribute('src')) {
      candidate.src = candidate.dataset.src;
      candidate.load();
    }
    candidate.muted = true;
    candidate.play().catch(() => {
      // Keep the real poster visible when autoplay is unavailable.
      if (activeVideo === candidate) {
        candidate.removeAttribute('src');
        candidate.load();
      }
    });
  }
  function schedulePlayback() {
    if (!frame) frame = requestAnimationFrame(updatePlayback);
  }
  function fitPanels() {
    chapters.forEach(chapter => {
      const inset = 24 + Number(chapter.style.getPropertyValue('--stack-index')) * 9;
      chapter.classList.toggle('stack-static', chapter.offsetHeight + inset > innerHeight);
    });
    schedulePlayback();
  }
  videos.forEach(video => {
    video.addEventListener('error', () => {
      video.parentElement.querySelector('.video-error').hidden = false;
    });
  });
  if ('IntersectionObserver' in window) {
    const posters = new IntersectionObserver(entries => entries.forEach(({target, isIntersecting}) => {
      if (!isIntersecting) return;
      const video = target.querySelector('video');
      video.poster = video.dataset.poster;
      posters.unobserve(target);
    }), {rootMargin: '300px'});
    chapters.forEach(chapter => posters.observe(chapter));
  } else {
    videos.forEach(video => { video.poster = video.dataset.poster; });
  }
  reduced.addEventListener('change', () => {
    if (reduced.matches) {
      videos.forEach(video => {
        stop(video);
        video.removeAttribute('src');
        video.load();
      });
      activeVideo = null;
    }
    fitPanels();
  });
  document.addEventListener('visibilitychange', schedulePlayback);
  window.addEventListener('scroll', schedulePlayback, {passive: true});
  window.addEventListener('resize', fitPanels);
  if ('ResizeObserver' in window) {
    const sizing = new ResizeObserver(fitPanels);
    chapters.forEach(chapter => sizing.observe(chapter));
  }
  fitPanels();
})();
