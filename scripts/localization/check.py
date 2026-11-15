#!/usr/bin/env python3
"""Validate Korean UI format arguments and reproduce the compiled display-only dictionary."""
import json
import re
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
entries = json.loads((root / 'scripts/localization/ko-ui.json').read_text())
placeholder = re.compile(r'%(?:\d+\$)?[-+#0]*(?:\d+)?(?:\.\d+)?(?:ll|l|z)?[@sdiufg%]')
for original, translated in entries.items():
    assert placeholder.findall(original) == placeholder.findall(translated), original
    assert not original.startswith(('spotifyglass.', 'ios-feature-')), original

def literal(text):
    return '@' + json.dumps(text.replace('\\n', '\n').replace('\\"', '"'), ensure_ascii=False)
content = '// Generated from scripts/localization/ko-ui.json; display text only.\n'
content += '\n'.join('    ' + literal(key) + ': ' + literal(value) + ',' for key, value in sorted(entries.items())) + '\n'
output = root / 'tweak/Sources/Settings/SGKoreanStrings.inc'
if sys.argv[1:] == ['--write']:
    output.write_text(content)
else:
    assert output.read_text() == content, 'Run scripts/localization/check.py --write'
print(f'PASS: {len(entries)} Korean UI entries, format arguments and generated dictionary')
