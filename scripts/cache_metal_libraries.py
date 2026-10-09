#!/usr/bin/env python3
"""Cache the pinned inference build's relocatable Metal libraries, not build trees."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

XCRUN = '/usr/bin/xcrun'


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'expected regular cache input/output: {path}')
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def request(args):
    # These are the two audited command shapes from the pinned inference build.
    # Other xcrun uses keep their normal tool invocation, without caching.
    if args[:3] != ['--sdk', 'macosx', 'metal'] or len(args) < 6:
        return None
    if not args[3].startswith('-std=metal'):
        return None
    if args[4].startswith('-working-directory=') and args[5:10] == ['-Wall', '-Wextra', '-O3', '-c', '-w']:
        sources = [Path(value) for value in args[10:]]
        directory = Path(args[4].split('=', 1)[1])
        if not sources or any(not path.is_absolute() or path.suffix != '.metal' for path in sources):
            return None
        outputs = [directory / (path.stem + '.air') for path in sources]
        headers = sorted({path for parent in {p.parent for p in sources}
                          for path in parent.rglob('*')
                          if path.suffix in ('.metal', '.h', '.hpp', '.inc')})
        inputs = {str(path): digest(path) for path in headers}
        arguments = args[:4] + ['-working-directory=<output>'] + args[5:]
    elif args[4] == '-o':
        sources = [Path(value) for value in args[6:]]
        outputs = [Path(args[5])]
        if not sources or outputs[0].suffix != '.metallib' or any(not p.is_absolute() or p.suffix != '.air' for p in sources):
            return None
        inputs = [[path.name, digest(path)] for path in sources]
        arguments = args[:4] + ['-o', '<output>'] + [path.name for path in sources]
    else:
        return None
    if any(not p.is_absolute() for p in outputs) or len({p.name for p in outputs}) != len(outputs):
        raise ValueError('Metal outputs must have distinct names and absolute paths')
    return {'arguments': arguments, 'inputs': inputs, 'outputs': [p.name for p in outputs]}, outputs


def tool_identity():
    def query(*args):
        return subprocess.check_output([XCRUN, '--sdk', 'macosx', *args], text=True).strip()
    compiler = Path(query('--find', 'metal')).resolve(strict=True)
    sdk = Path(query('--show-sdk-path')).resolve(strict=True)
    return {'compiler': str(compiler), 'compiler_sha256': digest(compiler),
            'compiler_version': query('metal', '--version'),
            'sdk': str(sdk), 'sdk_version': query('--show-sdk-version'),
            'sdk_build': query('--show-sdk-build-version'),
            'sdk_settings': digest(sdk / 'SDKSettings.json'),
            'machine': os.uname().machine,
            'environment': {name: os.environ.get(name) for name in
                            ('DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET',
                             'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'CCC_OVERRIDE_OPTIONS',
                             'SOURCE_DATE_EPOCH', 'MTL_ENABLE_DEBUG_INFO')},
            'implementation': digest(Path(__file__))}


def cache_command(args, root, *, identity=None, runner=subprocess.run):
    parsed = request(args)
    if parsed is None:
        return runner([XCRUN, *args]).returncode
    spec, outputs = parsed
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    toolchain = identity if identity is not None else tool_identity()
    key = hashlib.sha256(json.dumps({'format': 1, 'request': spec,
                        'toolchain': toolchain}, sort_keys=True).encode()).hexdigest()
    entry = root / key
    lock = root / (key + '.lock')
    if lock.is_symlink() or entry.is_symlink():
        raise ValueError('refusing symlink Metal cache entry/lock')
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        if request(args)[0] != spec:
            raise ValueError('Metal inputs changed while waiting for the cache lock')
        if entry.exists():
            if (entry / 'manifest.json').is_symlink():
                raise ValueError('refusing linked Metal cache manifest')
            manifest = json.loads((entry / 'manifest.json').read_text())
            if set(manifest) != set(spec['outputs']):
                raise ValueError(f'invalid Metal cache manifest: {entry}')
            for output in outputs:
                source = entry / output.name
                if digest(source) != manifest[output.name]:
                    raise ValueError(f'corrupt Metal cache artifact: {source}')
            for output in outputs:
                if output.is_symlink():
                    raise ValueError(f'refusing linked Metal output: {output}')
                output.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
                    copied = Path(temporary.name)
                try:
                    shutil.copyfile(entry / output.name, copied)
                    copied.chmod(0o644)
                    copied.replace(output)
                finally:
                    copied.unlink(missing_ok=True)
            if request(args)[0] != spec:
                raise ValueError('Metal inputs changed during cache reuse')
            print(f'[Metal cache] hit {key[:12]} ({len(outputs)} outputs)', file=sys.stderr)
            return 0
        for output in outputs:
            if output.is_symlink():
                raise ValueError(f'refusing linked Metal output: {output}')
            output.unlink(missing_ok=True)
        result = runner([XCRUN, *args])
        if result.returncode:
            return result.returncode
        # Reject changing inputs and never publish partial compiler results.
        if request(args)[0] != spec or (identity is None and tool_identity() != toolchain):
            raise ValueError('Metal inputs changed during compilation')
        temporary = Path(tempfile.mkdtemp(prefix='.publish-', dir=root))
        try:
            manifest = {}
            for output in outputs:
                manifest[output.name] = digest(output)
                shutil.copyfile(output, temporary / output.name)
                (temporary / output.name).chmod(0o444)
            (temporary / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True))
            (temporary / 'manifest.json').chmod(0o444)
            temporary.rename(entry)
            entry.chmod(0o555)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        print(f'[Metal cache] stored {key[:12]} ({len(outputs)} outputs)', file=sys.stderr)
        return 0


def main():
    configured = os.environ.get('FRITZ_METAL_CACHE_ROOT')
    if not configured or not Path(configured).is_absolute():
        raise ValueError('FRITZ_METAL_CACHE_ROOT must be an absolute cache path')
    if os.environ.get('CARGO_PKG_NAME') not in ('mistralrs-quant', 'mistralrs-paged-attn'):
        return subprocess.call([XCRUN, *sys.argv[1:]])
    return cache_command(sys.argv[1:], Path(configured))


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'error: Metal library cache: {error}')
