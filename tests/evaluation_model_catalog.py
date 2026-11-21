"""Inspect local artifacts pinned by the staged master catalog."""

from pathlib import Path, PurePosixPath
import re

from local_browser_pairing import MAX_CORPUS_BYTES, digest, encoded, file_hash, pin, require, strict_json


def inspect_model(catalog, model, directory, *, decision=False):
    directory = Path(directory)
    require(directory.is_absolute() and directory.is_dir(), 'Explicit model storage must exist and be absolute')
    catalog_pin = pin(catalog)
    require(catalog_pin['bytes'] <= MAX_CORPUS_BYTES, 'Catalog exceeds bound')
    data = Path(catalog).read_bytes()
    require(digest(data) == catalog_pin['sha256'], 'Catalog changed during inspection')
    inventory = strict_json(data)['local_decision' if decision else 'local_chat']['models']
    matches = [entry for entry in inventory if entry.get('id') == model]
    require(len(matches) == 1, 'Model must have one catalog manifest')
    manifest = matches[0]
    require(isinstance(manifest.get('revision'), str) and manifest['revision'], 'Manifest revision missing')
    files = manifest.get('files') if decision else [manifest]
    require(isinstance(files, list) and files, 'Manifest files missing')

    root, artifacts, names = directory.resolve(), [], set()
    for entry in files:
        name, size, expected = entry.get('file'), entry.get('size'), entry.get('sha256')
        require(isinstance(name, str) and name and name not in names
                and not PurePosixPath(name).is_absolute() and '..' not in PurePosixPath(name).parts
                and '\\' not in name, 'Model filenames must be unique and relative')
        names.add(name)
        require(type(size) is int and size > 0 and isinstance(expected, str)
                and re.fullmatch(r'[0-9a-f]{64}', expected), 'Manifest needs exact sizes and SHA-256')
        path = (root / name).resolve()
        require(path.is_relative_to(root) and path.is_file(), 'Model artifact escapes store or is missing')
        require(path.stat().st_size == size, 'Model size differs from manifest')
        actual = file_hash(path)
        require(actual == expected, 'Model SHA-256 differs from manifest')
        artifacts.append({'file': name, 'path': str(path), 'bytes': size,
                          'expected_sha256': expected, 'actual_sha256': actual,
                          'validation': 'full_sha256'})
    return {'id': model, 'directory': str(root), 'catalog': catalog_pin,
            'manifest': manifest, 'manifest_sha256': digest(encoded(manifest)), 'artifacts': artifacts}
