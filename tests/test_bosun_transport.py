"""Model-free regressions for owned group grace and immutable cohort provenance."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import bosun_transport as owned
import bosun_cpu_reference as cpu


class OwnedGroupLifetime(unittest.TestCase):
    def run_child(self, function, directory, source, *, timeout=2):
        script = directory/'mock_child.py'
        script.write_text(source)
        receipt = function([sys.executable,str(script),'evaluate'],b'{}',{},directory,timeout=timeout)
        self.addCleanup(self.ensure_group_gone, receipt.get('owned_pid'))
        return receipt

    def ensure_group_gone(self, pid):
        if pid is None:
            return
        until = time.monotonic()+2
        while True:
            try:
                os.killpg(pid,0)
            except ProcessLookupError:
                return
            if time.monotonic() >= until:
                os.killpg(pid,signal.SIGKILL)
                self.fail('Exclusively owned mock group remained after cleanup')
            time.sleep(0.02)

    def test_exit_zero_parent_gets_full_eof_grace_for_its_owned_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name,function in (('historical',owned.frozen.evaluate_child),('corrected',owned.evaluate_child)):
                directory=root/name;directory.mkdir()
                marker=directory/'descendant-state'
                source=('import json,os,signal,sys,time\nfrom pathlib import Path\n'
                    'sys.stdin.buffer.readline()\nr,w=os.pipe()\npid=os.fork()\n'
                    'if pid==0:\n'
                    ' os.close(r)\n'
                    f' marker=Path({str(marker)!r})\n'
                    ' def terminated(_sig,_frame):\n  marker.write_text("signalled");os._exit(0)\n'
                    ' signal.signal(signal.SIGTERM,terminated)\n'
                    ' os.write(w,b"1");os.close(w)\n'
                    ' sys.stdin.buffer.read();marker.write_text("eof")\n'
                    ' time.sleep(0.3);marker.write_text("completed");os._exit(0)\n'
                    'os.close(w);os.read(r,1);os.close(r)\n'
                    'print(json.dumps({"type":"result","result":{"model":"mock","usage":{"input_tokens":3,"output_tokens":0}}}),flush=True)\n'
                    'os._exit(0)\n')
                receipt=self.run_child(function,directory,source)
                self.assertEqual(receipt['cleanup']['exit_code'],0)
                if name=='historical':
                    # Demonstrate the pre-fix failure without modifying frozen source.
                    self.assertIn('SIGTERM',receipt['cleanup']['signals'])
                    self.assertNotEqual(marker.read_text() if marker.exists() else None,'completed')
                else:
                    self.assertEqual(marker.read_text(),'completed')
                    self.assertTrue(receipt['cleanup']['succeeded'])
                    self.assertEqual(receipt['cleanup']['signals'],[])
                    self.assertEqual(receipt['transport_version'],owned.VERSION)
                    self.assertGreaterEqual(receipt['cleanup']['grace_waits'][0]['elapsed_seconds'],0.25)
                self.ensure_group_gone(receipt['owned_pid'])

    def test_forced_cleanup_is_bounded_and_does_not_signal_an_unrelated_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            unrelated=subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)'],start_new_session=True)
            try:
                source=('import signal,sys,time\n'
                    'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                    'sys.stdin.buffer.readline()\ntime.sleep(20)\n')
                real_killpg=os.killpg
                observations={'killed':False,'injected':False}
                def killpg(group,sig):
                    if sig==0 and observations['killed'] and not observations['injected']:
                        observations['injected']=True
                        raise PermissionError('transient post-SIGKILL observation')
                    result=real_killpg(group,sig)
                    if sig==signal.SIGKILL:observations['killed']=True
                    return result
                with mock.patch.object(owned.os,'killpg',side_effect=killpg):
                    receipt=self.run_child(owned.evaluate_child,directory,source,timeout=0.1)
                self.assertTrue(observations['injected'])
                self.assertTrue(receipt['deadline_expired'])
                self.assertTrue(receipt['cleanup']['succeeded'],receipt)
                self.assertTrue(receipt['cleanup']['forced_kill'])
                self.assertEqual(receipt['cleanup']['signals'],['SIGTERM','SIGKILL'])
                self.assertEqual([item['limit_seconds'] for item in receipt['cleanup']['grace_waits']],[2,1,1])
                self.assertLess(receipt['elapsed_seconds'],6)
                self.assertIsNone(unrelated.poll())
            finally:
                os.killpg(unrelated.pid,signal.SIGKILL);unrelated.wait(timeout=2)

    def test_unobservable_group_is_unknown_and_never_claims_success_or_signals(self):
        child=SimpleNamespace(pid=987654321,stdin=None,poll=lambda:0)
        started=time.monotonic()
        with mock.patch.object(owned.os,'killpg',side_effect=PermissionError('unobservable')) as probe:
            receipt=owned.cleanup_child(child)
        self.assertIsNone(receipt['succeeded'])
        self.assertEqual(receipt['exit_code'],0)
        self.assertEqual(receipt['signals'],[])
        self.assertGreater(len(probe.call_args_list),1)
        self.assertEqual({call.args[1] for call in probe.call_args_list},{0})
        self.assertLess(time.monotonic()-started,2.5)

    def test_bounded_late_terminal_preserves_facts_without_admitting_expired_decision(self):
        event={'type':'result','result':{'model':'mock@pin','usage':{'input_tokens':7,'output_tokens':0},'padding':'x'*100_000}}
        raw=owned.frozen.encoded(event)+b'\n'
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            source=('import sys\nsys.stdin.buffer.readline()\n'
                f'raw={raw!r}\nsys.stdout.buffer.write(raw[:100]);sys.stdout.buffer.flush()\n'
                'sys.stdin.buffer.read()\nsys.stdout.buffer.write(raw[100:]);sys.stdout.buffer.flush()\n')
            receipt=self.run_child(owned.evaluate_child,directory,source,timeout=0.1)
            self.assertTrue(receipt['deadline_expired'])
            self.assertTrue(receipt['terminal_received_during_cleanup'])
            self.assertTrue(receipt['cleanup']['succeeded'])
            self.assertEqual(receipt['terminal'],event)
            self.assertIsNone(receipt['transport_error'])
            self.assertEqual((directory/'stdout.bin').read_bytes(),raw)
            assessed=owned.frozen.assess({'candidates':{},'expected_candidate':'unused'},'decision',receipt,'mock@pin')
            self.assertEqual(assessed['outcome'],'provider_failure')
            self.assertEqual(assessed['usage']['input_tokens'],7)

    def test_duplicate_nonfinite_and_oversized_terminal_remain_invalid(self):
        terminal=b'{"type":"result","result":{"model":"mock"}}\n'
        for raw in (terminal+terminal,b'{"type":"result","result":{"p":NaN}}\n',
                    terminal+b'x'*(owned.frozen.MAX_OUTPUT_BYTES+1)):
            with self.subTest(size=len(raw)),tempfile.TemporaryDirectory() as temporary:
                directory=Path(temporary)
                source=('import sys\nsys.stdin.buffer.readline()\n'
                    f'sys.stdout.buffer.write({raw!r});sys.stdout.buffer.flush()\n')
                receipt=self.run_child(owned.evaluate_child,directory,source)
                self.assertIsNotNone(receipt['transport_error'])
                self.assertEqual(receipt['transport_error_outcome'],'invalid_response')
                self.assertLessEqual(receipt['stdout_bytes'],owned.frozen.MAX_OUTPUT_BYTES+1)


class ReferenceInterpreter(unittest.TestCase):
    def test_actual_interpreter_must_match_both_frozen_plan_and_lock_before_package_checks(self):
        packages={name:'1.0' for name in cpu.PACKAGES}
        lock={'schema':'fritz-bosun-cpu-runtime-lock-v1','python':sys.version.split()[0],
              'packages':packages,'wheels':[{'sha256':'retained'}]}
        plan={'python':sys.version.split()[0],'packages':packages}
        with mock.patch.object(cpu.importlib.metadata,'version',return_value='1.0'):
            cpu.validate_runtime(lock,plan)
        for changed in ('lock','plan'):
            a,b=copy.deepcopy(lock),copy.deepcopy(plan)
            (a if changed=='lock' else b)['python']='0.0.0'
            with mock.patch.object(cpu.importlib.metadata,'version') as packages_probe:
                with self.assertRaisesRegex(ValueError,'actual reference interpreter'):
                    cpu.validate_runtime(a,b)
                packages_probe.assert_not_called()

    def test_forced_cleanup_stops_reference_and_retains_the_unadmitted_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);root.chmod(0o700)
            source=root/'source';cache=root/'cache';source.mkdir();cache.mkdir()
            def document(name,value):
                path=root/name;path.write_bytes(owned.frozen.encoded(value));return path
            packages={name:'1.0' for name in cpu.PACKAGES}
            plan=document('plan.json',{'python':sys.version.split()[0],'packages':packages,
                'source_revision':'source','base_revision':'base','source_files':[],'base_files':[]})
            lock=document('lock.json',{'schema':'fritz-bosun-cpu-runtime-lock-v1',
                'python':sys.version.split()[0],'preparer_python':'3.14.7','original_lock_sha256':cpu.ORIGINAL_LOCK_SHA256,
                'packages':packages,'wheels':[{'sha256':'retained'}]})
            compiler=document('compiler.json',{'schema':'fritz-bosun-compiler-reference-v1',
                'rows':[{'case_id':'r'+str(index),'probabilities':None} for index in range(5)]})
            initial=document('initial.json',{'status':'failed'});followup=root/'followup.md';followup.write_text('Separate cohort')
            output=root/'new-reference.json'
            arguments=['cpu-reference','--source-dir',str(source),'--cache-dir',str(cache),
                '--runtime-plan',str(plan),'--runtime-plan-sha256',cpu.file_hash(plan),
                '--runtime-lock',str(lock),'--runtime-lock-sha256',cpu.file_hash(lock),
                '--compiler-reference',str(compiler),'--compiler-reference-sha256',cpu.file_hash(compiler),
                '--cleanup-followup',str(followup),'--cleanup-followup-sha256',cpu.file_hash(followup),
                '--initial-failure',str(initial),'--initial-failure-sha256',cpu.file_hash(initial),'--output',str(output)]
            terminal={'type':'result','result':{'case_id':'r0','probabilities':[0.8,0.2],'token_ids':[1,2,3]}}
            receipt={'transport_version':owned.VERSION,'terminal':terminal,'events':[terminal],
                'transport_error':None,'deadline_expired':False,'cleanup':{'succeeded':True,'exit_code':0,'signals':['SIGKILL']}}
            invoke=mock.Mock(return_value=receipt)
            with mock.patch.object(sys,'argv',arguments),mock.patch.object(cpu,'verify_models'), \
                 mock.patch.object(cpu.importlib.metadata,'version',return_value='1.0'), \
                 mock.patch.object(cpu,'FOLLOWUP_SHA256',cpu.file_hash(followup)), \
                 mock.patch.object(cpu,'INITIAL_FAILURE_SHA256',cpu.file_hash(initial)), \
                 mock.patch.object(cpu,'CORRECTED_LOCK_SHA256',cpu.file_hash(lock)), \
                 mock.patch.object(cpu.owned_transport,'evaluate_child',invoke):
                with self.assertRaisesRegex(ValueError,'cleanup is unknown'):cpu.main()
            retained=json.loads(output.read_bytes())
            self.assertEqual(invoke.call_count,1)
            self.assertEqual(retained['status'],'failed')
            self.assertEqual(retained['rows'],[])
            self.assertEqual(len(retained['attempts']),1)
            self.assertEqual(retained['attempts'][0]['transport']['terminal'],terminal)
            self.assertTrue(retained['attempts'][0]['cleanup']['forced_kill'])
            self.assertEqual(json.loads(initial.read_bytes())['status'],'failed')


if __name__=='__main__':unittest.main()
