/* release.json is the only source of release version, channel, and asset URL. */
(() => {
  const buttons = [...document.querySelectorAll('[data-download]')];
  const note = document.querySelector('[data-release-note]');
  fetch(new URL('release.json', document.currentScript.src), {cache: 'no-store', credentials: 'omit'})
    .then(response => {
      if (!response.ok) throw new Error('Release metadata unavailable');
      return response.json();
    })
    .then(release => {
      if (release.version === null && release.channel === null && release.downloadURL === null) return;
      // Fail closed on malformed metadata: never turn a CTA into an arbitrary redirect.
      const version = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.([1-9]\d*))?$/;
      if (typeof release.version !== 'string' || !version.test(release.version)
          || release.channel !== (release.version.includes('-beta.') ? 'beta' : 'stable')) {
        throw new Error('Invalid release metadata');
      }
      const url = new URL(release.downloadURL);
      const prefix = '/T-1234567890/origami-browser/releases/download/v' + release.version + '/';
      if (url.origin !== 'https://github.com' || url.username || url.password || url.search || url.hash
          || !url.pathname.startsWith(prefix) || !url.pathname.endsWith('.zip')
          || decodeURIComponent(url.pathname.slice(prefix.length)).includes('/')) {
        throw new Error('Invalid release asset URL');
      }
      buttons.forEach(button => {
        button.href = release.downloadURL;
        button.removeAttribute('aria-disabled');
        button.removeAttribute('tabindex');
      });
      if (note) note.textContent = `Version ${release.version} · ${release.channel === 'beta' ? 'Beta' : 'Stable'}`;
    })
    .catch(() => {
      if (note) note.textContent = 'Download information is temporarily unavailable. Please check the Origami repository on GitHub.';
    });
})();
