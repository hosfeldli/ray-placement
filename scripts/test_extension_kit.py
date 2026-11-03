#!/usr/bin/env python3
"""End-to-end checks for the real CLI, generated programs and portable ZIPs."""
import json
import pathlib
import subprocess
import sys
import tempfile
import zipfile
import unicodedata

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/lima-extension').resolve()

def run(*args, success=True):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=90)
    assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
    return result

with tempfile.TemporaryDirectory(prefix='Lima extension kit ') as temp:
    root = pathlib.Path(temp)
    for template in ['link', 'script', 'form', 'ai-tool']:
        source = root / f'{template} with spaces'
        run('init', source, '--id', f'local.test.{template}', '--name', 'Test command', '--template', template)
        run('check', source)
        assert json.loads(run('check', source, '--json').stdout) == []
        if template == 'script':
            assert 'Hello from Lima' in run('run', source, 'run').stdout
        if template == 'form':
            marker = root / 'must-not-exist'
            value = f'Unicode café; touch "{marker}"; {{literal}}'
            assert value in unicodedata.normalize('NFC', run('run', source, 'run', f'message={value}').stdout)
            assert not marker.exists()
            run('run', source, 'run', success=False)
        (source / '.env').write_text('do-not-package-this-fixture')
        archive = root / f'{template}.zip'
        run('pack', source, archive)
        with zipfile.ZipFile(archive) as zipped:
            assert not any('/.' in name or name.startswith('__MACOSX') for name in zipped.namelist())
            manifest = json.loads(zipped.read(f'local.test.{template}/manifest.json'))
            assert manifest['schemaVersion'] == 3
            assert manifest['id'] == f'local.test.{template}'
        original = archive.read_bytes()
        run('pack', source, archive, success=False)
        assert archive.read_bytes() == original
        extracted = root / f'extracted-{template}'
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(extracted)], check=True)
        run('check', extracted / f'local.test.{template}')
        original = (source / 'manifest.json').read_bytes()
        run('init', source, '--id', 'overwrite', '--name', 'Overwrite', success=False)
        assert (source / 'manifest.json').read_bytes() == original
    broken = root / 'broken'
    broken.mkdir()
    (broken / 'manifest.json').write_text('{"id":')
    result = run('check', broken, '--json', success=False)
    assert json.loads(result.stdout)[0]['severity'] == 'error'
print('Extension CLI: all 4 starters, executable/form invocation, literal input, diagnostics, safe ZIPs, extracted packages and overwrite protection passed.')
