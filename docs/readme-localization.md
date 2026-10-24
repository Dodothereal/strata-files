# Translating the README

`README.md` is the English source. Translations live in `docs/readme/localization/<code>.json`; the generator produces
`docs/readme/README.<code>.md` and the native-language links at the top of every README. English stays the default
repository README. Screenshots, badges, commands and layout are shared, so translations do not need separate assets.

To update the source:

```sh
python3 scripts/readme-localize.py extract
# Translate the new or changed messages in each README language catalog.
python3 scripts/readme-localize.py build
python3 scripts/readme-localize.py check
```

Translate values under `strings`, keeping their English keys. Each message is a complete paragraph, heading, bullet,
table cell or image description. Keep Markdown emphasis, HTML, inline code, link destinations and working English
search examples intact. Menu names and macOS terms should match the app's `Localization/<code>.json`; use the same
register and punctuation conventions throughout. Product names, shortcuts and source-code commands retain their spelling.

Generated READMEs share the English structure and all content, including build and release instructions. Relative
links and image paths are adjusted to their location, privacy links use the matching website language, and badges
keep a stable download-section anchor. Do not edit generated Markdown directly.

To add a README language, copy `docs/readme/localization/en.json` to `<code>.json`, change `code`, and translate every
value. Use a language code already supported in `Localization/`. Its native name comes from that app catalog; no
registration list or generator code needs editing. Run `build` and `check`, review the Markdown on GitHub, and commit
the catalog, generated file and updated language navigation together.

The README translations workflow rejects missing, blank or obsolete messages, altered commands/links/markup and
stale generated files. Regression checks exercise adding a language, wrapped paragraphs, tables, HTML image text,
relative links and code preservation. Run them locally with:

```sh
python3 -m unittest discover -s Tests -p 'test_readme_localization.py'
```
