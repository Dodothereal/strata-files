# Website checks and publishing

The public site is built from `site/` and the real app screenshots in `docs/screenshots/`.
The themes stack is composed from actual Strata windows with demo files, including native System Light.
Its PNG is shared by the README and the website; the build creates responsive lossless WebP versions
at 800, 1100, 1400, 2360 and the original 3960 pixels. The homepage preload and image use the same
responsive candidates so only the appropriate size is downloaded.

Run the same checks locally as the Website workflow:

```sh
python3 -m unittest discover -s Tests -p test_site.py
scripts/site.sh
npm ci --prefix Tests/site --ignore-scripts
cd Tests/site && npx playwright install chromium && npm test
```

The browser checks cover downloads, analytics initialization, tab controls and keyboard navigation,
image loading, narrow layouts, 44-pixel touch targets and CSP enforcement. Packaging tests verify
fingerprints, rewritten URLs, retention of previous assets and rejection of unsafe or corrupt manifests.
Pull requests run these checks; main publishes only after they pass.

## Security and caching

`scripts/site-assets.py` adds a Content Security Policy before resources load in each HTML document.
Executable JavaScript is external; local scripts and Plausible are allowed. Network requests are limited
to GitHub's API and Plausible. Inline CSS remains allowed for the homepage's embedded styles and artwork.
Changes to external resources must update this policy and the browser checks together.

GitHub Pages does not support custom HTTP response headers. The HTML policy cannot set
`frame-ancestors`, HSTS, `X-Frame-Options` or `X-Content-Type-Options`, nor can it provide report-only CSP.
No CDN or DNS configuration is changed here. The `.app` domain is already covered by TLD HSTS preload.
`llms.txt` and `llms-full.txt` remain ordinary text resources, not HTML pages.

Assets have content-hashed URLs, so changes get new URLs. GitHub Pages still controls their cache lifetime:
fingerprinting alone does not enable long-lived `immutable` caching. Original asset aliases stay available
for social metadata and external links. Publishing downloads the previous deployment's asset manifest and
retains its verified hashed files, keeping cached pages working across deployments. Downloads are restricted
to HTTPS on the same host, checked against SHA-256 filenames and bounded by per-file and total size limits.
Only a missing manifest (404 on the first such deployment) is ignored; other errors stop publishing.

The retained archive is deliberately bounded at 2,000 files or 128 MiB. Reaching either limit requires a
retention review rather than silently breaking old URLs. If hosting later supports response headers, use
short HTML caching and long-lived immutable caching for `/immutable/`, and enforce framing restrictions
through HTTP headers. Do not claim those protections are active until live responses confirm them.
