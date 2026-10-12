# Translating Strata

Each language is one JSON file in this folder: `de.json`, `fr.json`, `ja.json`… Adding a language is adding a file. No
Xcode, no code changes, nothing to register: the build picks up every file here and the app lists it.

## Add or improve a language

1. Start the file (skip this to improve an existing one):

   ```sh
   scripts/localize.py new xx        # xx: the language code, like de, pt-BR or zh-Hans
   ```

2. Translate the strings in `Localization/xx.json`. Leave a string empty to keep the English for now.
3. Check it:

   ```sh
   scripts/localize.py check xx
   ```

4. Open a pull request. The checks run again there, and `scripts/localize.py stats` shows how complete each language is.

To see it in the app, build Strata (`scripts/build.sh`) and pick the language in **Settings ▸ General ▸ Language** (or in
System Settings ▸ General ▸ Language & Region ▸ Applications).

## The file

```json
{
  "language": "Deutsch",
  "english": "German",
  "code": "de",
  "maintainers": ["Your Name"],
  "strings": {
    "Move to Trash": "In den Papierkorb legen",
    "“%@” couldn’t be opened.": "„%@“ konnte nicht geöffnet werden.",
    "Rename %lld Items…": { "one": "%lld Objekt umbenennen…", "other": "%lld Objekte umbenennen…" }
  }
}
```

- **Keys** are the English text exactly as the app has it. Don't change them; `en.json` lists every one, with a note
  on where it appears. A few keys are names instead (`git.status.modified`), for an English word used with two
  meanings; `en.json` has their English. Keys starting with `infoplist.` are the texts macOS shows when Strata first
  asks to open your Desktop, Documents, Downloads, network volumes or external drives.
- **Placeholders** stand for what the app fills in: `%@` text (a file name, say), `%lld` a whole number, `%lf` a
  number. Keep each one. To put them in a different order, number them: `%2$@ … %1$@`.
- **Plural forms**: a string that depends on a number is an object with one form per plural category your language
  uses (from the Unicode CLDR): English and German use `one` and `other`; Polish and Ukrainian `one`, `few`, `many` and
  `other`; Japanese, Korean and Chinese only `other`. `new` puts in the right ones, and `check` tells you if a form is
  missing or doesn't belong.
- Typographic quotes and the ellipsis (“ ” … ’) are part of the text: use your language's own (`„…“`, `« … »`, `「…」`).

## Words to keep

- **Use the words macOS uses.** Strata sits next to Finder: the Trash, Get Info, Quick Look, Show in Finder, Tags and
  menu names should read the way they do in Finder in your language (open Finder's menus with your Mac set to it).
  A few: German *Papierkorb*, *Im Finder zeigen*, *Informationen*; French *Corbeille*, *Afficher dans le Finder*,
  *Lire les informations*; Spanish *Papelera*, *Mostrar en Finder*, *Obtener información*; Italian *Cestino*,
  *Mostra nel Finder*, *Ottieni informazioni*; Japanese ゴミ箱, Finderに表示, 情報を見る.
- **Don't translate**: the app's name (Strata), Finder, iCloud, Spotlight, AirDrop, Git, and keyboard shortcuts.
- **Search words stay English**: what you type to search (`ext:`, `kind:`, `size:`, `tag:`, `camera:`, `regex:`,
  `case:`…) and the plain-English searches ("pdfs from last week") are the same in every language. Translate the
  explanations around them, not the words themselves.

## For developers

Strings come from the code: wrap text the user sees in `String(localized:)` (SwiftUI's `Text("…")` already is). A
string that changes with a number gets `comment: "plural"`:

```swift
String(localized: "Rename \(count) Items…", comment: "plural")
```

Then run `scripts/localize.py extract` (it builds once to find every string) and write the English singular in
`en.json` (`"one": "Rename %lld Item…"`). CI checks that `en.json` is up to date and that every language file is
valid.
