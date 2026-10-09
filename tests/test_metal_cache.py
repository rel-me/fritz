#!/usr/bin/env python3
"""Verify native cache isolation, invalidation, corruption and real Metal artifacts."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import cache_metal_libraries as cache


class MetalLibraryCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'kernel.metal'
        self.source.write_text('#include <metal_stdlib>\nusing namespace metal;\nkernel void fill(device float *v [[buffer(0)]], uint i [[thread_position_in_grid]]) { v[i] = 1; }\n')
        self.cache = self.root / 'cache'
        self.identity = {'compiler': 'fixture', 'sdk': 'fixture'}
        self.calls = 0

    def args(self, directory='a'):
        output = self.root / directory
        output.mkdir(exist_ok=True)
        return ['--sdk', 'macosx', 'metal', '-std=metal3.1',
                '-working-directory=' + str(output), '-Wall', '-Wextra', '-O3', '-c', '-w', str(self.source)]

    def compile(self, command):
        self.calls += 1
        _, outputs = cache.request(command[1:])
        for output in outputs:
            output.write_bytes(self.source.read_bytes())
        return subprocess.CompletedProcess(command, 0)

    def run_cache(self, args, **kwargs):
        return cache.cache_command(args, self.cache, identity=kwargs.get('identity', self.identity),
                                   runner=kwargs.get('runner', self.compile))

    def test_cross_checkout_hit_copies_writable_outputs_without_shared_mutation(self):
        self.run_cache(self.args('a'))
        self.run_cache(self.args('b'))
        self.assertEqual(self.calls, 1)
        self.assertEqual((self.root/'a/kernel.air').read_bytes(), (self.root/'b/kernel.air').read_bytes())
        (self.root/'b/kernel.air').write_bytes(b'local edit')
        self.run_cache(self.args('c'))
        self.assertEqual((self.root/'c/kernel.air').read_bytes(), self.source.read_bytes())

    def test_sources_headers_flags_and_toolchain_invalidate(self):
        args = self.args()
        self.run_cache(args)
        self.source.write_text(self.source.read_text() + '// change\n')
        self.run_cache(args)
        (self.root/'header.metal').write_text('header')
        self.run_cache(args)
        changed = args.copy(); changed[3] = '-std=metal3.2'
        self.run_cache(changed)
        self.run_cache(args, identity={'compiler': 'changed', 'sdk': 'changed'})
        self.assertEqual(self.calls, 5)

    def test_failed_and_incomplete_compilation_never_publish(self):
        args = self.args()
        self.assertEqual(self.run_cache(args, runner=lambda c: subprocess.CompletedProcess(c, 42)), 42)
        with self.assertRaisesRegex(ValueError, 'regular cache input/output'):
            self.run_cache(args, runner=lambda c: subprocess.CompletedProcess(c, 0))
        self.assertFalse(list(self.cache.glob('*/manifest.json')))

    def test_corruption_stops_without_compiling(self):
        self.run_cache(self.args())
        artifact = next(self.cache.glob('*/kernel.air'))
        artifact.chmod(0o644); artifact.write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'corrupt Metal cache'):
            self.run_cache(self.args('b'))
        self.assertEqual(self.calls, 1)

    def test_input_mutation_during_compilation_is_rejected(self):
        def changing(command):
            result = self.compile(command)
            self.source.write_text('changed')
            return result
        with self.assertRaisesRegex(ValueError, 'changed during compilation'):
            self.run_cache(self.args(), runner=changing)
        self.assertFalse(list(self.cache.glob('*/manifest.json')))

    def test_concurrent_misses_compile_once(self):
        args = [self.args('a'), self.args('b')]
        with concurrent.futures.ThreadPoolExecutor(2) as workers:
            self.assertEqual(list(workers.map(self.run_cache, args)), [0, 0])
        self.assertEqual(self.calls, 1)

    def test_other_tool_commands_execute_normal_xcrun(self):
        calls = []
        self.run_cache(['--find', 'clang'], runner=lambda command: (calls.append(command) or subprocess.CompletedProcess(command, 0)))
        self.assertEqual(calls, [[cache.XCRUN, '--find', 'clang']])
        self.assertFalse(self.cache.exists())

    def test_real_metal_compile_and_link_reuse_across_output_directories(self):
        # Native compiler, real SDK and relocatable AIR/metallib artifacts.
        second = self.root/'second.metal'
        second.write_text(self.source.read_text().replace('void fill(', 'void fill_second('))
        for directory in ('a', 'b'):
            args = self.args(directory) + [str(second)]
            env = dict(os.environ, FRITZ_METAL_CACHE_ROOT=str(self.cache), CARGO_PKG_NAME='mistralrs-quant')
            wrapper = Path(__file__).resolve().parents[1]/'scripts/native-cache-bin/xcrun'
            subprocess.run([str(wrapper), *args], env=env, check=True)
            output = self.root/directory
            link = ['--sdk', 'macosx', 'metal', '-std=metal3.1', '-o',
                    str(output/'kernel.metallib'), str(output/'kernel.air'), str(output/'second.air')]
            subprocess.run([str(wrapper), *link], env=env, check=True)
        self.assertEqual(cache.digest(self.root/'a/kernel.metallib'), cache.digest(self.root/'b/kernel.metallib'))
        self.assertEqual(len(list(self.cache.glob('*/manifest.json'))), 2)
        # Independently compiled output must match, not just the two cached copies.
        args = self.args('uncached') + [str(second)]
        subprocess.run([cache.XCRUN, *args], check=True)
        output = self.root/'uncached'
        subprocess.run([cache.XCRUN, '--sdk', 'macosx', 'metal', '-std=metal3.1',
                        '-o', str(output/'kernel.metallib'), str(output/'kernel.air'), str(output/'second.air')], check=True)
        self.assertEqual(cache.digest(self.root/'a/kernel.metallib'), cache.digest(output/'kernel.metallib'))
        # Reversing AIR order is a distinct link request, even if a compiler
        # happens to produce the same library for these particular kernels.
        reverse = ['--sdk', 'macosx', 'metal', '-std=metal3.1', '-o',
                   str(self.root/'b/reverse.metallib'), str(self.root/'b/second.air'),
                   str(self.root/'b/kernel.air')]
        subprocess.run([str(wrapper), *reverse], env=env, check=True)
        independent = reverse.copy()
        independent[5:] = [str(output/'reverse.metallib'), str(output/'second.air'), str(output/'kernel.air')]
        subprocess.run([cache.XCRUN, *independent], check=True)
        self.assertEqual(cache.digest(self.root/'b/reverse.metallib'), cache.digest(output/'reverse.metallib'))
        self.assertEqual(len(list(self.cache.glob('*/manifest.json'))), 3)


if __name__ == '__main__':
    unittest.main()
