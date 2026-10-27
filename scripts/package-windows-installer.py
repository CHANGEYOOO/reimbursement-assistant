#!/usr/bin/env python3
"""Create the installer's embedded payload from a self-contained win-x64 publish folder."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--payload-dir', type=Path, required=True)
parser.add_argument('--runtime', type=Path)
parser.add_argument('--output', type=Path, default=Path('build/windows-payload.zip'))
args = parser.parse_args()
root = args.payload_dir.resolve()
if not (root / '报销单助手.exe').is_file():
    raise SystemExit('Missing self-contained app executable: 报销单助手.exe')
files = {}
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        raise SystemExit('Payload must not contain symlinks')
    if path.is_file():
        name = path.relative_to(root).as_posix()
        if name == 'manifest.json' or name.startswith('.installer/'):
            raise SystemExit('Payload publish folder contains reserved installer metadata')
        files[name] = path
if args.runtime:
    if not args.runtime.is_file():
        raise SystemExit('Missing official Microsoft Visual C++ runtime')
    files['.installer/vc_redist.x64.exe'] = args.runtime
manifest = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()}
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name, path in files.items():
        archive.write(path, name)
    archive.writestr('manifest.json', json.dumps(manifest, ensure_ascii=False))
with zipfile.ZipFile(args.output) as archive:
    if archive.testzip() is not None:
        raise SystemExit('Payload ZIP verification failed')
print(json.dumps({'payload': str(args.output), 'files': len(files), 'bytes': args.output.stat().st_size,
                  'vc_runtime_bundled': bool(args.runtime)}, ensure_ascii=False))
