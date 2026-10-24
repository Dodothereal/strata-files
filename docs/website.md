# Website checks and publishing

The public site is built from `site/` and the real app screenshots in `docs/screenshots/`.
The themes stack is composed from actual Strata windows with demo files, including native System Light.
Its PNG is shared by the README and the website; the build creates responsive lossless WebP versions
at 800, 1100, 1400, 2360 and the original 3960 pixels. The homepage preload and image use the same
responsive candidates so only the appropriate size is downloaded.

The Quick Look image uses live Strata windows with Acme Studio demo files. Native window captures retain the real
controls, materials, borders and shadows at their screen positions; the selected Brand Assets folder stays visible
above the preview. Its shared source is `docs/screenshots/quicklook.png`; the website build creates lossless WebP
versions at 800, 1100, 1400 and the original 2904 pixels. Keep it immediately after Disk Usage in both the README and
the homepage.

The Views tabs and README show all five views plus Dual Pane, captured from the same live app and Acme Studio
demo files. Columns opens Photos → Selects → Autumn Campaign with a photo selected at the deepest level.
Native window borders, shadows and color profiles are retained; the website creates lossless 800, 1100, 1400 and
2704-pixel versions. List and Disk Usage use their own captures rather than a column browser or a simulated map.
The Disk Usage section shares that same native map. Demo photographs are from
[Unsplash](https://unsplash.com/license), including
[Alpine Morning](https://images.unsplash.com/photo-1464822759023-fed622ff2c3b),
[Lake Reflection](https://images.unsplash.com/photo-1470770841072-f978cf4d019e),
[Golden Hour](https://images.unsplash.com/photo-1500530855697-b586d89ba3ee),
[Forest Trail](https://images.unsplash.com/photo-1448375240586-882707db888b),
[Ocean Light](https://images.unsplash.com/photo-1507525428034-b723cf961d3e) and
[Mountain Pass](https://images.unsplash.com/photo-1501785888041-af3ef285b470).

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
