"""Versioned, bounded private transport for the Bosun follow-up cohort only.

The historical comparison remains immutable. Its finite event parser and output
bounds are reused; cleanup waits for the owned group as well as its direct child.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time

import local_browser_pairing as frozen

VERSION = 'fritz-bosun-owned-group-transport-v2'
FROZEN_CORE_SHA256 = '6b68245c16282ca3c390634af518184d0b4257da517a6de1c1c9012748b239a1'
GRACE_SECONDS = (2, 1, 1)
InterruptedAttempt = frozen.InterruptedAttempt


def provenance():
    core = frozen.pin(Path(frozen.__file__).resolve())
    frozen.require(core['sha256'] == FROZEN_CORE_SHA256, 'Historical transport core changed')
    return {'version': VERSION, 'driver': frozen.pin(Path(__file__).resolve()), 'core': core,
            'cleanup_grace_seconds': list(GRACE_SECONDS)}


def cleanup_child(child, pump=None):
    """Caller must own a child created with start_new_session=True, hence PGID=PID."""
    receipt = {'transport_version': VERSION, 'attempted': True, 'succeeded': None,
               'pid': child.pid, 'process_group': child.pid, 'signals': [],
               'exit_code': None, 'forced_kill': False, 'grace_waits': []}
    try:
        frozen.require(child.pid > 1 and child.pid not in (os.getpid(), os.getpgrp()),
                       'Refusing cleanup of this process or its inherited group')
        if child.stdin is not None:
            try:
                child.stdin.close()
            except BrokenPipeError:
                pass

        def group_present():
            try:
                os.killpg(child.pid, 0)
                return True
            except ProcessLookupError:
                return False
            except PermissionError:
                # Darwin may transiently deny SIG0 while a killed group is being
                # reaped. Wait within the declared grace; absence remains unproven.
                return None

        def wait(grace, phase):
            started = time.monotonic()
            until = started + grace
            while True:
                if pump is not None:
                    pump()
                code, present = child.poll(), group_present()
                if code is not None and present is False:
                    break
                remaining = until - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(0.02, remaining))
            receipt['grace_waits'].append({'phase': phase, 'limit_seconds': grace,
                'elapsed_seconds': round(time.monotonic()-started, 6),
                'direct_child_exit_code': code,
                'group_absent': None if present is None else not present})
            return present

        present = wait(GRACE_SECONDS[0], 'eof')
        for sig, grace in zip((signal.SIGTERM, signal.SIGKILL), GRACE_SECONDS[1:]):
            if present is not True:
                break
            try:
                os.killpg(child.pid, sig)
                receipt['signals'].append(signal.Signals(sig).name)
            except ProcessLookupError:
                pass
            present = wait(grace, signal.Signals(sig).name)
        receipt['exit_code'] = child.poll()
        present = group_present()
        receipt['succeeded'] = None if present is None else receipt['exit_code'] is not None and present is False
        if receipt['succeeded'] is None:
            receipt['reason'] = 'Owned process group remained unobservable within its declared grace'
    except (OSError, ValueError, frozen.ConfigurationError) as error:
        receipt['exit_code'] = child.poll()
        receipt['reason'] = 'Owned process cleanup failed or remains unknown: '+type(error).__name__+': '+str(error)
    receipt['forced_kill'] = 'SIGKILL' in receipt['signals']
    return receipt


def evaluate_child(command, payload, environment, output, *, timeout=frozen.DEADLINE_SECONDS):
    frozen.require(type(timeout) in (int, float) and 0 < timeout <= 725,
                   'A bounded explicit child deadline is required')
    frozen.require(isinstance(payload, bytes) and len(payload) <= frozen.MAX_INPUT_BYTES,
                   'Private child input exceeds the historical byte bound')
    started, child = time.monotonic(), None
    stream = frozen.EventStream('decision' if command[-1] == 'evaluate' else 'chat')
    receipt = {'transport_version': VERSION, 'child_started': False, 'terminal': None,
               'events': [], 'deadline_expired': False, 'transport_error': None,
               'transport_error_outcome': 'provider_failure', 'terminal_received_during_cleanup': False,
               'cleanup': {'transport_version': VERSION, 'attempted': False, 'succeeded': None,
                           'reason': 'child_not_started'}}
    errors = bytearray()
    interrupted = False
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, start_new_session=True, bufsize=0)
        receipt['child_started'], receipt['owned_pid'] = True, child.pid
        request, sent = payload+b'\n', 0
        for pipe in (child.stdin, child.stdout, child.stderr):
            os.set_blocking(pipe.fileno(), False)
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdin, selectors.EVENT_WRITE)
            selector.register(child.stdout, selectors.EVENT_READ)
            selector.register(child.stderr, selectors.EVENT_READ)
            while stream.terminal is None and receipt['transport_error'] is None:
                remaining = timeout-(time.monotonic()-started)
                if remaining <= 0:
                    receipt['deadline_expired'] = True
                    break
                ready = selector.select(remaining)
                if not ready:
                    receipt['deadline_expired'] = True
                    break
                for key, _mask in ready:
                    if key.fileobj is child.stdin:
                        try:
                            sent += os.write(child.stdin.fileno(), request[sent:sent+65536])
                        except BlockingIOError:
                            continue
                        if sent == len(request):
                            selector.unregister(child.stdin)
                    else:
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            if key.fileobj is child.stdout and stream.terminal is None:
                                receipt['transport_error'] = 'Disconnected before terminal'
                            continue
                        if key.fileobj is child.stderr:
                            errors.extend(chunk[:max(0, frozen.MAX_STDERR_BYTES+1-len(errors))])
                            if len(errors) > frozen.MAX_STDERR_BYTES:
                                receipt.update(transport_error='stderr exceeded byte bound',
                                               transport_error_outcome='invalid_response')
                        else:
                            stream.feed(chunk)
                            if stream.terminal is not None and sent != len(request):
                                receipt.update(transport_error='Terminal before complete input write',
                                               transport_error_outcome='invalid_response')
                            if stream.terminal is not None and time.monotonic()-started > timeout:
                                receipt['deadline_expired'] = True
                            if stream.error:
                                receipt.update(transport_error=stream.error,
                                               transport_error_outcome='invalid_response')
    except KeyboardInterrupt:
        interrupted = True
    except (OSError, ValueError):
        receipt['transport_error'] = 'Owned harness transport failed'
    finally:
        if child is not None:
            before = stream.terminal
            def pump():
                for pipe, limit in ((child.stdout, frozen.MAX_OUTPUT_BYTES), (child.stderr, frozen.MAX_STDERR_BYTES)):
                    try:
                        while True:
                            remaining = limit+1-(len(stream.raw) if pipe is child.stdout else len(errors))
                            if remaining <= 0:
                                break
                            chunk = os.read(pipe.fileno(), min(65536, remaining))
                            if not chunk:
                                break
                            if pipe is child.stdout:
                                stream.feed(chunk)
                            else:
                                errors.extend(chunk)
                    except (BlockingIOError, OSError):
                        pass
            receipt['cleanup'] = cleanup_child(child, pump)
            pump()
            for pipe in (child.stdout, child.stderr):
                pipe.close()
            receipt['terminal_received_during_cleanup'] = before is None and stream.terminal is not None
        stream.finish()
        receipt.update(terminal=stream.terminal, events=stream.events,
            stdout_sha256=frozen.digest(bytes(stream.raw)), stdout_bytes=len(stream.raw),
            stderr_sha256=frozen.digest(bytes(errors)), stderr_bytes=len(errors),
            stdout_truncated=len(stream.raw)>frozen.MAX_OUTPUT_BYTES,
            stderr_truncated=len(errors)>frozen.MAX_STDERR_BYTES,
            elapsed_seconds=round(time.monotonic()-started, 6))
        receipt['transport_error'] = stream.error or receipt['transport_error']
        if stream.error:
            receipt['transport_error_outcome'] = 'invalid_response'
        if len(errors) > frozen.MAX_STDERR_BYTES:
            receipt.update(transport_error='stderr exceeded byte bound', transport_error_outcome='invalid_response')
        for name, data in (('stdout', stream.raw), ('stderr', errors)):
            descriptor = os.open(output/(name+'.bin'), os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'wb') as file:
                file.write(data)
        match = re.findall(rb'^\s*(\d+)\s+maximum resident set size\s*$', bytes(errors), re.MULTILINE)
        receipt['maximum_resident_set_size_bytes'] = int(match[-1]) if command[0] == '/usr/bin/time' and match else None
        receipt['rss_scope'] = 'optional time -l process measurement; not combined residency or 24 GB feasibility'
    if interrupted:
        raise InterruptedAttempt(receipt)
    return receipt
