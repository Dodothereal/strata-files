// Strata Files: stratafiles.app. No trackers, no third parties: the only requests go to GitHub's public API, for the
// latest release (so Download points straight at the disk image) and the star count.
(() => {
  const REPO = 'cristipufu/strata';
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // --- Latest release and stars, cached for the session ---------------------------------------------------------

  const cached = async (key, url) => {
    try {
      const hit = JSON.parse(sessionStorage.getItem(key) || 'null');
      if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit.value;
    } catch { /* storage unavailable: fetch instead */ }
    const response = await fetch(url, { headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
    const value = await response.json();
    try { sessionStorage.setItem(key, JSON.stringify({ at: Date.now(), value })); } catch { /* fine */ }
    return value;
  };

  const megabytes = (bytes) => `${Math.max(1, Math.round(bytes / 1e6))} MB`;

  cached('strata-release', `https://api.github.com/repos/${REPO}/releases/latest`)
    .then((release) => {
      const assets = release.assets || [];
      const asset = assets.find((a) => a.name.endsWith('.dmg')) || assets.find((a) => a.name.endsWith('.zip'));
      if (!asset) return;
      document.querySelectorAll('[data-download]').forEach((link) => {
        link.href = asset.browser_download_url;
      });
      const version = String(release.tag_name || '').replace(/^v/, '');
      document.querySelectorAll('[data-version]').forEach((label) => {
        label.textContent = `Version ${version} · ${megabytes(asset.size)} · Free`;
      });
    })
    .catch(() => { /* links keep pointing at the Releases page */ });

  cached('strata-repo', `https://api.github.com/repos/${REPO}`)
    .then((repo) => {
      const stars = repo.stargazers_count;
      if (!stars) return;
      const label = stars >= 1000 ? `${(stars / 1000).toFixed(stars >= 10000 ? 0 : 1)}k` : String(stars);
      document.querySelectorAll('[data-stars]').forEach((el) => { el.textContent = `Star · ${label}`; });
    })
    .catch(() => {});

  // --- Navigation backdrop once the page scrolls ----------------------------------------------------------------

  const nav = document.querySelector('[data-nav]');
  const onScroll = () => nav && nav.classList.toggle('is-scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // --- Reveal on scroll -----------------------------------------------------------------------------------------

  const revealables = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !reduceMotion) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('is-in');
        observer.unobserve(entry.target);
      }
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    revealables.forEach((el) => observer.observe(el));
  } else {
    revealables.forEach((el) => el.classList.add('is-in'));
  }

  // --- Spotlight that follows the pointer on cards --------------------------------------------------------------

  document.querySelectorAll('[data-spotlight]').forEach((card) => {
    card.addEventListener('pointermove', (event) => {
      const rect = card.getBoundingClientRect();
      card.style.setProperty('--mx', `${event.clientX - rect.left}px`);
      card.style.setProperty('--my', `${event.clientY - rect.top}px`);
    });
  });

  // --- Search demo: types a few queries and swaps the results ---------------------------------------------------

  const demo = document.querySelector('.demo-search');
  const query = document.querySelector('[data-typewriter]');
  const chips = document.querySelector('[data-chips]');
  const results = document.querySelector('[data-results]');
  const examples = [
    {
      text: 'videos bigger than 500 MB', chips: ['Movies', 'Over 500 MB'], kind: 'video',
      rows: [['Launch Film (master).mov', '3.57 GB'], ['Launch Film 1080p.mp4', '1.26 GB'], ['Product Demo.mp4', '671.1 MB']],
    },
    {
      text: 'pdfs from last month', chips: ['PDF', 'Modified last month'], kind: 'doc',
      rows: [['Invoice 2026-09.pdf', '214 KB'], ['Brand Guidelines.pdf', '8.4 MB'], ['Offsite Agenda.pdf', '96 KB']],
    },
    {
      text: 'ext:swift modified:<7d', chips: ['.swift', 'Last 7 days'], kind: 'doc',
      rows: [['BrowserViewController.swift', '52 KB'], ['Summarizer.swift', '18 KB'], ['FileIndex.swift', '31 KB']],
    },
  ];

  const render = (example) => {
    chips.replaceChildren(...example.chips.map((text) => Object.assign(document.createElement('span'), { textContent: text })));
    results.replaceChildren(...example.rows.map(([name, size]) => {
      const row = document.createElement('li');
      const icon = Object.assign(document.createElement('span'), { className: `ficon ficon--${example.kind}` });
      const sizeLabel = Object.assign(document.createElement('em'), { textContent: size });
      row.append(icon, name, sizeLabel);
      return row;
    }));
  };

  if (demo && query && chips && results && !reduceMotion) {
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    let visible = false;
    new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; }).observe(demo);
    (async () => {
      let index = 0;
      await sleep(2600);
      for (;;) {
        if (!visible || document.hidden) { await sleep(500); continue; }
        // Erase, type the next example, then show its results.
        for (let n = query.textContent.length; n >= 0; n -= 1) {
          query.textContent = query.textContent.slice(0, n);
          await sleep(22);
        }
        index = (index + 1) % examples.length;
        const example = examples[index];
        demo.classList.add('is-swapping');
        for (let n = 1; n <= example.text.length; n += 1) {
          query.textContent = example.text.slice(0, n);
          await sleep(55 + Math.random() * 45);
        }
        render(example);
        demo.classList.remove('is-swapping');
        await sleep(3200);
      }
    })();
  }

  // --- Views tabs -----------------------------------------------------------------------------------------------

  document.querySelectorAll('[data-tabs]').forEach((root) => {
    const tabs = [...root.querySelectorAll('[role="tab"]')];
    const select = (tab, focus) => {
      tabs.forEach((other) => {
        const selected = other === tab;
        other.setAttribute('aria-selected', String(selected));
        other.tabIndex = selected ? 0 : -1;
        document.getElementById(other.getAttribute('aria-controls')).hidden = !selected;
      });
      if (focus) tab.focus();
    };
    tabs.forEach((tab, i) => {
      tab.addEventListener('click', () => select(tab, false));
      tab.addEventListener('keydown', (event) => {
        const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
        if (!step) return;
        event.preventDefault();
        select(tabs[(i + step + tabs.length) % tabs.length], true);
      });
    });
  });
})();
