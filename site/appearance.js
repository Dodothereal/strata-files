// Runs before styles paint. CSS follows the system even when JavaScript or storage is unavailable.
(() => {
  const root = document.documentElement;
  const key = 'strata-website-appearance';
  const valid = value => ['light', 'dark'].includes(value) ? value : 'system';
  let choice = 'system';
  try { choice = valid(localStorage.getItem(key)); } catch { /* Keep the system appearance. */ }
  root.dataset.appearance = choice;

  const refresh = () => {
    root.dataset.appearance = choice;
    document.querySelectorAll('[data-appearance-choice]').forEach(button => {
      button.setAttribute('aria-pressed', String(button.dataset.appearanceChoice === choice));
    });
    const tint = document.querySelector('meta[name="theme-color"]');
    if (tint) tint.content = getComputedStyle(root).backgroundColor;
  };

  document.addEventListener('DOMContentLoaded', () => {
    if (!CSS.supports('color', 'light-dark(white, black)')) return;
    document.querySelectorAll('.appearance-picker').forEach(picker => {
      picker.hidden = false;
      picker.querySelectorAll('[data-appearance-choice]').forEach(button => {
        button.addEventListener('click', () => {
          choice = valid(button.dataset.appearanceChoice);
          try {
            if (choice === 'system') localStorage.removeItem(key);
            else localStorage.setItem(key, choice);
          } catch { /* This tab can still change appearance. */ }
          refresh();
          picker.open = false;
          picker.querySelector('summary').focus();
        });
      });
      document.addEventListener('click', event => { if (!picker.contains(event.target)) picker.open = false; });
      picker.addEventListener('keydown', event => {
        if (event.key === 'Escape') {
          picker.open = false;
          picker.querySelector('summary').focus();
        }
      });
    });
    refresh();
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refresh);
    window.addEventListener('storage', event => {
      if (event.key === key || event.key === null) { choice = valid(event.newValue); refresh(); }
    });
  });
})();
