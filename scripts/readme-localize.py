#!/usr/bin/env python3
"""Generate translated READMEs from README.md and complete, auto-discovered language catalogs."""
import argparse
from collections import Counter
from dataclasses import dataclass
import html
import importlib.util
import json
from pathlib import Path
import posixpath
import re
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
NAV = re.compile(r'<!-- readme-languages:start -->.*?<!-- readme-languages:end -->', re.S)
CODE = re.compile(r'(`+)([^`]+?)\1')
LINK = re.compile(r'!?\[[^\]\n]*\]\(([^\s)]+)\)')
PROTECTED = re.compile(r'(?m)^(?P<fence>`{3,}|~{3,})[^\n]*\n(?s:.*?)^(?P=fence)[`~]*[ \t]*(?:\n|$)'
                       r'|(?P<tick>`+)[^`\n]+(?P=tick)')
spec = importlib.util.spec_from_file_location('readme_html', Path(__file__).with_name('site-localize.py'))
markup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(markup)


@dataclass
class Message:
    start: int
    end: int
    key: str
    attribute: bool = False


def messages(source):
    """Extract prose, leaving code blocks, Markdown structure and HTML layout in the English source."""
    result = []
    lines = source.splitlines(keepends=True)
    offsets, offset = [], 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    def add(start, end):
        text = source[start:end]
        lead, trail = len(text) - len(text.lstrip()), len(text) - len(text.rstrip())
        key = markup.normalized(text)
        if key and key != 'Strata Files':
            result.append(Message(start + lead, end - trail, key))

    index = 0
    while index < len(lines):
        line, start = lines[index], offsets[index]
        if line.startswith('<!-- readme-languages:start -->'):
            nav = NAV.match(source, start)
            if not nav:
                raise ValueError('Unclosed README language navigation')
            while index < len(lines) and offsets[index] < nav.end():
                index += 1
            continue
        fence = re.match(r'^(`{3,}|~{3,})', line)
        if fence:
            index += 1
            while index < len(lines) and not re.fullmatch(re.escape(fence[1][0]) + '{' + str(len(fence[1])) + r',}\s*', lines[index]):
                index += 1
            if index == len(lines):
                raise ValueError('Unclosed Markdown code fence')
            index += 1
            continue
        block = re.match(r'^<(p|h[1-6]|table)\b', line)
        if block:
            end_index = index
            while end_index < len(lines) and '</' + block[1] + '>' not in lines[end_index]:
                end_index += 1
            if end_index == len(lines):
                raise ValueError('Unclosed README HTML block')
            fragment = source[start:offsets[end_index] + len(lines[end_index])]
            result.extend(Message(start + a, start + b, key, attribute)
                          for a, b, key, attribute in markup.Document(fragment).messages() if key != 'Strata Files')
            index = end_index + 1
            continue
        if not line.strip() or re.fullmatch(r'\s*(---|<a id="[a-z0-9-]+"></a>)\s*', line):
            index += 1
            continue
        heading = re.match(r'^#{1,6} +', line)
        if heading:
            add(start + heading.end(), start + len(line))
            index += 1
            continue
        if line.startswith('|'):
            # Delimiters inside code spans and escaped pipes are part of a cell.
            spans = [(m.start(), m.end()) for m in CODE.finditer(line)]
            boundaries = [i for i, c in enumerate(line) if c == '|' and (i == 0 or line[i - 1] != '\\')
                          and not any(a <= i < b for a, b in spans)]
            for a, b in zip(boundaries, boundaries[1:]):
                text = line[a + 1:b].strip()
                if text and not re.fullmatch(r':?-+:?', text):
                    add(start + a + 1, start + b)
            index += 1
            continue
        bullet = re.match(r'^- +', line)
        first = start + (bullet.end() if bullet else 0)
        index += 1
        while index < len(lines) and lines[index].strip() and not re.match(r'^(?:[-#|<]|`{3,}|~{3,})', lines[index]):
            index += 1
        end = offsets[index] if index < len(lines) else len(source)
        add(first, end)
    return result


def signature(value):
    literals = Counter(m[2] for m in CODE.finditer(value))
    text = CODE.sub('CODE', value)
    links = Counter(m[1] for m in LINK.finditer(text))
    tags = markup.signature(text)
    emphasis = (text.count('**'), len(re.findall(r'(?<!\*)\*(?!\*)', text)))
    return literals, links, tags, emphasis


def read_catalogs(root, keys):
    result = []
    for path in sorted((root / 'docs/readme/localization').glob('*.json')):
        locale = json.loads(path.read_text())
        code = locale['code']
        if not re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z]{2,4})?', code) or code != path.stem:
            raise ValueError('Invalid README language code: ' + path.name)
        app_path = root / 'Localization' / (code + '.json')
        if not app_path.is_file():
            raise ValueError('README language must be supported by Strata: ' + code)
        locale['language'] = json.loads(app_path.read_text())['language']
        strings = locale['strings']
        missing, stale = keys - strings.keys(), strings.keys() - keys
        if missing or stale:
            raise ValueError(f'{code}: missing {sorted(missing)}, obsolete {sorted(stale)}')
        for key, value in strings.items():
            if not isinstance(value, str) or not value.strip() or '\n' in value:
                raise ValueError(f'{code}: empty translation or unexpected line break: {key}')
            if re.search(r'__\w*\d\w*__|ZXQ|\[S\d{4}', value):
                raise ValueError(f'{code}: unexpected draft marker: {key}')
            if 'Strata' in key and 'Strata' not in value:
                raise ValueError(f'{code}: changed the product name: {key}')
            if signature(key) != signature(value):
                raise ValueError(f'{code}: changed markup, link, command or emphasis: {key}')
            for example in re.findall(r'\*"([^"]+)"\*', key):
                if example not in value:
                    raise ValueError(f'{code}: translated a working English search example: {example}')
        if code == 'en' and any(k != v for k, v in strings.items()):
            raise ValueError('Regenerate the English README catalog with extract')
        result.append(locale)
    if not any(locale['code'] == 'en' for locale in result):
        raise ValueError('An English README catalog is required')
    return result


def output_path(code):
    return Path('README.md') if code == 'en' else Path(f'docs/readme/README.{code}.md')


def navigation(locales, code):
    base = output_path(code).parent.as_posix()
    links = []
    for locale in sorted(locales, key=lambda item: (item['code'] != 'en', item['code'])):
        name = html.escape(locale['language'])
        path = posixpath.relpath(output_path(locale['code']).as_posix(), base)
        links.append('<strong>' + name + '</strong>' if locale['code'] == code else '<a href="' + path + '">' + name + '</a>')
    return '<!-- readme-languages:start -->\n<p align="center">\n  ' + ' · '.join(links) + '\n</p>\n<!-- readme-languages:end -->'


def render(source, units, locale, locales):
    if locale['code'] == 'en':
        return NAV.sub(lambda _: navigation(locales, 'en'), source)
    result = source
    for unit in reversed(units):
        value = locale['strings'][unit.key]
        if unit.attribute:
            value = html.escape(value, quote=True)
        result = result[:unit.start] + value + result[unit.end:]
    result = NAV.sub(lambda _: navigation(locales, locale['code']), result)

    def rebase(url):
        parsed = urlsplit(url)
        if parsed.scheme or url.startswith(('/', '#')):
            if url == 'https://stratafiles.app/privacy/':
                return 'https://stratafiles.app/' + locale['code'].lower() + '/privacy/'
            return url
        path = posixpath.relpath(parsed.path, output_path(locale['code']).parent.as_posix())
        return path + ('?' + parsed.query if parsed.query else '') + ('#' + parsed.fragment if parsed.fragment else '')

    # The navigation already has paths relative to each output.
    nav = NAV.search(result)
    before, after = result[:nav.start()], result[nav.end():]
    def links(text):
        text = re.sub(r'\b(href|src)="([^"]+)"', lambda m: m[1] + '="' + rebase(m[2]) + '"', text)
        def destination(match):
            start = match.start(1) - match.start()
            return match[0][:start] + rebase(match[1]) + match[0][start + len(match[1]):]
        return LINK.sub(destination, text)
    def preserving_code(text):
        pieces, offset = [], 0
        for code in PROTECTED.finditer(text):
            pieces.extend([links(text[offset:code.start()]), code[0]])
            offset = code.end()
        return ''.join(pieces) + links(text[offset:])
    return ('<!-- Generated by scripts/readme-localize.py. Edit its language catalog, not this file. -->\n\n'
            + preserving_code(before) + nav[0] + preserving_code(after))


def outputs(root):
    source = (root / 'README.md').read_text()
    if len(NAV.findall(source)) != 1:
        raise ValueError('README needs one language navigation block')
    units = messages(source)
    keys = {unit.key for unit in units}
    locales = read_catalogs(root, keys)
    return {output_path(locale['code']): render(source, units, locale, locales) for locale in locales}


def save_catalog(path, data):
    data['strings'] = dict(sorted(data['strings'].items()))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['extract', 'build', 'check'])
    args = parser.parse_args()
    if args.command == 'extract':
        keys = sorted({unit.key for unit in messages((ROOT / 'README.md').read_text())})
        save_catalog(ROOT / 'docs/readme/localization/en.json', {'code': 'en', 'strings': {key: key for key in keys}})
        print(f'English README catalog: {len(keys)} messages')
        return
    generated = outputs(ROOT)
    if args.command == 'build':
        for path, text in generated.items():
            (ROOT / path).parent.mkdir(parents=True, exist_ok=True)
            (ROOT / path).write_text(text)
        print(f'Built {len(generated) - 1} translated READMEs and language links')
    else:
        for path, text in generated.items():
            if not (ROOT / path).is_file() or (ROOT / path).read_text() != text:
                raise ValueError(f'Generated README is out of date: {path}; run scripts/readme-localize.py build')
        expected = {ROOT / path for path in generated if path != Path('README.md')}
        stale = set((ROOT / 'docs/readme').glob('README.*.md')) - expected
        if stale:
            raise ValueError('README output has no language catalog: ' + ', '.join(p.name for p in sorted(stale)))
        print(f'{len(generated) - 1} complete README translations, with current generated files')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error))
