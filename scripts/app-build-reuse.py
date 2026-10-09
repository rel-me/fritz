#!/usr/bin/env python3
"""Reuse only this checkout's verified local app with identical build inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        name = str(path.relative_to(root))
        if stat.S_ISLNK(mode):
            path.resolve(strict=True).relative_to(root.resolve())
            result[name] = ['link', os.readlink(path)]
        elif stat.S_ISREG(mode):
            result[name] = ['file', stat.S_IMODE(mode), digest(path)]
        elif not stat.S_ISDIR(mode):
            raise ValueError(f'unsupported build input: {path}')
    return result


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, stderr=subprocess.STDOUT).decode().strip()


def signing_identity(identity):
    if identity == '-':
        return identity
    identities = re.findall(r'\b([0-9A-Fa-f]{40}) "([^"]+)"',
                            command('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'))
    matches = {fingerprint.upper() for fingerprint, name in identities
               if identity.upper() == fingerprint.upper() or identity == name}
    if len(matches) != 1:
        raise ValueError('select one exact signing certificate name or SHA-1 identity')
    return matches.pop()


def fingerprint(root, settings):
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root
    ).decode().split('\0')
    sources = {}
    for name in sorted(set(names) - {''}):
        path = root / name
        if path.is_symlink():
            target = path.resolve(strict=True)
            sources[name] = ['link', os.readlink(path), str(target),
                             digest(target) if target.is_file() else inventory(target)]
        elif path.is_file():
            sources[name] = [stat.S_IMODE(path.stat().st_mode), digest(path)]
        elif not path.exists():
            sources[name] = ['missing']
        else:
            raise ValueError(f'unsupported source input: {path}')
    cargo_home = Path(os.environ.get('CARGO_HOME', str(Path.home() / '.cargo')))
    configs = [cargo_home / name for name in ('config', 'config.toml')]
    for parent in (root, *root.parents):
        configs += [parent / '.cargo' / name for name in ('config', 'config.toml')]
    swift_configs = [root / package / '.swiftpm/configuration' for package in ('', 'app')]
    tools = {name: command(*args) for name, args in {
        'xcode': ['xcodebuild', '-version'], 'swift': ['swift', '--version'],
        'sdk': ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-build-version'],
        'sdk_path': ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
        'rust': ['rustc', '-vV'], 'cargo': ['cargo', '--version'],
    }.items()}
    wrapper = os.environ.get('RUSTC_WRAPPER')
    if wrapper:
        tools['rust_wrapper'] = digest(Path(wrapper))
    environment = {name: value for name, value in os.environ.items()
                   if name.startswith(('CARGO_', 'RUST', 'SCCACHE_', 'SWIFT', 'MISTRALRS_',
                                       'FRITZ_')) or name in
                   ('PATH', 'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET',
                    'CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'CPATH',
                    'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'SOURCE_DATE_EPOCH')}
    inputs = {'format': 1, 'root': str(root), 'sources': sources, 'settings': settings,
              'tools': tools, 'os': list(os.uname()), 'environment': environment,
              'codesign': digest(Path('/usr/bin/codesign')),
              'cargo_configuration': {str(p): digest(p) if p.exists() else None for p in configs},
              'swift_configuration': {str(p): inventory(p) if p.exists() else None for p in swift_configs}}
    # Store only the digest, never environment values or package-manager credentials.
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def atomic_json(path, data):
    if path.is_symlink():
        raise ValueError(f'refusing linked reuse state: {path}')
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            json.dump(data, output, sort_keys=True)
            output.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def verify(app, settings):
    if app.is_symlink():
        raise ValueError('refusing linked app for reuse')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = {'CFBundleIdentifier': settings['bundle'], 'CFBundleExecutable': settings['name'],
                'CFBundleShortVersionString': settings['version'],
                'CFBundleVersion': settings['build_number']}
    if any(info.get(k) != v for k, v in expected.items()):
        raise ValueError('staged app identity differs from build request')
    for name in ('fritz', 'fritz-harness', 'fritz-decision-harness'):
        binary = app / 'Contents/Resources' / name
        if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f'missing bundled executable: {binary}')
    args = ['/usr/bin/codesign', '--verify', '--deep', '--strict']
    identity = settings['identity']
    if identity != '-':
        args += ['-R', f'=certificate leaf = H"{identity}"']
    elif 'Signature=adhoc' not in command('/usr/bin/codesign', '-dvv', str(app)):
        raise ValueError('expected ad-hoc signature')
    subprocess.run([*args, str(app)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'record'))
    parser.add_argument('app', type=Path)
    parser.add_argument('settings', nargs='+')
    args = parser.parse_args()
    settings = dict(value.split('=', 1) for value in args.settings)
    if (os.environ.get('FRITZ_BUILD_CACHE_ACTIVE') != str(ROOT)
            or os.environ.get('FRITZ_DISTRIBUTION', '0') == '1'
            or args.app != ROOT / 'dist' / (settings['name'] + '.app')):
        raise ValueError('reuse requires a locked local build in this checkout')
    settings['identity'] = signing_identity(settings['identity'])
    state = ROOT / 'dist' / ('.build-reuse-' + settings['configuration'] + '.json')
    request = state.with_suffix('.request.json')
    if state.is_symlink() or request.is_symlink():
        raise ValueError('refusing linked reuse state')
    current = {'settings': settings, 'fingerprint': fingerprint(ROOT, settings)}
    if args.action == 'record':
        if current != json.loads(request.read_text()):
            raise ValueError('build inputs changed during compilation; no app reuse state recorded')
        verify(args.app, settings)
        atomic_json(state, dict(current, app=inventory(args.app)))
        return
    atomic_json(request, current)
    saved = json.loads(state.read_text()) if state.exists() else None
    if saved and {k: saved.get(k) for k in current} == current and args.app.exists():
        if saved['app'] != inventory(args.app):
            raise ValueError('cached app contents changed; remove reuse state and rebuild')
        verify(args.app, settings)
        print(f'Reusing verified unchanged app: {args.app}')
        return
    print('App inputs changed or no verified app exists; compiling and staging')
    raise SystemExit(10)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'error: Fritz app reuse: {error}')
