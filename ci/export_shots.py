import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

NAMES = re.compile(r'(?:store-(?:en|zh-Hans|zh-Hant|ja)-0[1-5]-[a-z]+|paid-01-paywall)')


def export(result, output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result),
                        '--output-path', str(root)], check=True)
        manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
        found = set()
        for test in manifest:
            for attachment in test.get('attachments', []):
                filename = str(attachment.get('exportedFileName', ''))
                label = str(attachment.get('suggestedHumanReadableName', ''))
                path = root / filename
                match = NAMES.search(label)
                if path.suffix.lower() != '.png' or not path.is_file() or not match:
                    continue
                name = match.group()
                if name in found:
                    raise SystemExit(f'Duplicate screenshot: {name}')
                shutil.copy2(path, output / (name + '.png'))
                found.add(name)
        expected = {'paid-01-paywall'} | {f'store-{lang}-{number:02d}-{scene}'
            for lang in ('en', 'zh-Hans', 'zh-Hant', 'ja')
            for number, scene in enumerate(('practice', 'feedback', 'review', 'progress', 'challenge'), 1)}
        if found != expected:
            raise SystemExit(f'Missing screenshots: {sorted(expected - found)}; unexpected: {sorted(found - expected)}')
        print(f'Exported {len(found)} screenshots to {output}')


if __name__ == '__main__':
    export(Path(sys.argv[1]), Path(sys.argv[2]))
