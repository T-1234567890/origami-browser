#!/usr/bin/env python3
"""Validate shipped catalog languages, completeness, and format argument parity."""
import json
import re
from pathlib import Path
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Origami/Localization/Localizable.xcstrings'
TOKEN = re.compile(r'%(?:(\d+)\$)?(?:[-+ #0]*\d*(?:\.\d+)?)?(lld|ld|llu|lu|@|d|i|u|f|g|s|%)')

def arguments(value):
    result = []
    index = 0
    for match in TOKEN.finditer(value):
        position, kind = match.groups()
        if kind == '%':
            continue
        index += 1
        result.append((int(position) if position else index, kind))
    return Counter(result)

def values(node):
    if 'stringUnit' in node:
        yield node['stringUnit']
    for child in node.get('variations', {}).values():
        for variant in child.values():
            yield from values(variant)

def main():
    catalog = json.loads(CATALOG.read_text())
    assert catalog['sourceLanguage'] == 'en'
    errors = []
    for key, entry in catalog['strings'].items():
        locales = entry.get('localizations', {})
        if set(locales) != {'en', 'zh-Hans'}:
            errors.append(f'{key!r}: requires exactly en and zh-Hans')
        for language, node in locales.items():
            units = list(values(node))
            if not units:
                errors.append(f'{key!r}: missing {language} text')
            for unit in units:
                value = unit['value']
                if unit.get('state') != 'translated' or (key and not value):
                    errors.append(f'{key!r}: incomplete {language}')
                if arguments(value) != arguments(key):
                    errors.append(f'{key!r}: {language} format argument mismatch')
                if any(c in value for c in '\u202a\u202b\u202d\u202e\u202c\u2066\u2067\u2068\u2069'):
                    errors.append(f'{key!r}: unexpected bidi control')
    # Dynamic string lookup is not automatically extracted by the Swift compiler.
    for source in (ROOT / 'Origami').rglob('*.swift'):
        for match in re.finditer(r'L10n\.(?:string|format)\("([^"\\]+)"', source.read_text()):
            if match[1] not in catalog['strings']:
                errors.append(f'{source.relative_to(ROOT)}: missing runtime key {match[1]!r}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Validated {len(catalog["strings"])} keys: English + Simplified Chinese.')

if __name__ == '__main__':
    main()
