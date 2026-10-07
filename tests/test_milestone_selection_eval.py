"""Independent policy and owned serial pipe regressions; no native model/browser."""
import copy
from datetime import timedelta
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SPEC=importlib.util.spec_from_file_location('milestone_eval',Path(__file__).with_name('milestone_selection_eval.py'))
ev=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(ev)
core=ev.core
DOCUMENT=core.strict_json(Path(__file__).with_name('fixtures').joinpath('milestone-selection-v1.json').read_bytes())


def fixture(identifier):
    return copy.deepcopy(next(c for c in DOCUMENT['cases'] if c['id']==identifier))


class EvidencePolicy(unittest.TestCase):
    def test_staged_readiness_uses_attested_time_not_later_validation_time(self):
        receipt={'created_at':(ev.READINESS-timedelta(seconds=19)).isoformat(),
            'resident_ready':True,'decision_binary_sha256':'staged-binary'}
        later=lambda:ev.READINESS+timedelta(minutes=2)
        ev.validate_readiness(receipt,True,'staged-binary',clock=later)
        for defect in ('late','naive','future','non_utc','wrong_binary','wrong_boolean'):
            tampered=copy.deepcopy(receipt)
            if defect=='late':tampered['created_at']=(ev.READINESS+timedelta(seconds=1)).isoformat()
            elif defect=='naive':tampered['created_at']='2026-10-05T02:54:41'
            elif defect=='future':tampered['created_at']=(later()+timedelta(seconds=1)).isoformat()
            elif defect=='non_utc':tampered['created_at']='2026-10-04T19:54:41-07:00'
            elif defect=='wrong_binary':tampered['decision_binary_sha256']='another-binary'
            else:tampered['resident_ready']=1
            with self.subTest(defect=defect),self.assertRaises(ValueError):
                ev.validate_readiness(tampered,True,'staged-binary',clock=later)
        unavailable={**receipt,'resident_ready':False,'created_at':ev.READINESS.isoformat()}
        ev.validate_readiness(unavailable,False,'staged-binary',clock=later)
        with self.assertRaises(ValueError):
            ev.validate_readiness(unavailable,False,'staged-binary',clock=lambda:ev.READINESS-timedelta(seconds=1))
        unavailable['created_at']=receipt['created_at']
        with self.assertRaises(ValueError):
            ev.validate_readiness(unavailable,False,'staged-binary',clock=later)

    def test_completion_requires_actual_current_attributed_facts_and_positive_coverage(self):
        valid=fixture('positive-finite-end')['state']
        self.assertTrue(ev.completion_guard(valid))
        for defect in ('missing','stale','wrong_scope','ledger_only','unknown_end','clipped','bool_count','null_fact'):
            state=copy.deepcopy(valid)
            if defect=='missing':state['evidence_ledger']=[]
            elif defect=='stale':state['evidence_ledger'][0]['snapshot_id']='older'
            elif defect=='wrong_scope':state['evidence_ledger'][0]['source_id']='another-document'
            elif defect=='ledger_only':del state['observations'][0]['facts']['visible_task_ids']
            elif defect=='unknown_end':state['observations'][0]['coverage']['end_observed']=None
            elif defect=='clipped':state['observations'][0]['coverage']['truncated']=True
            elif defect=='bool_count':state['observations'][0]['coverage']['omitted_items']=False
            elif defect=='null_fact':
                state['observations'][0]['facts']['visible_task_ids']=None;state['evidence_ledger'][0]['value']=None
            with self.subTest(defect=defect):self.assertFalse(ev.completion_guard(state))
        state=fixture('saved-is-not-submitted')['state'];state['evidence_ledger'][0]['value']='submitted'
        self.assertFalse(ev.completion_guard(state))
        state=fixture('human-verification-block')['state'];state['observations'][0]['facts']['statement_read']=1
        state['evidence_ledger']=[{'source_id':'statement','snapshot_id':'b2','fact':'statement_read','value':1}]
        state['observations'][0]['access']='available'
        self.assertFalse(ev.completion_guard(state))
        state['observations'][0]['facts']['statement_read']=True;state['evidence_ledger'][0]['value']=True
        self.assertTrue(ev.completion_guard(state))
        self.assertFalse(ev.same_value(1,1.0))

    def test_source_freshness_and_exact_value_postconditions_are_independent_of_receipt_success(self):
        source_case=fixture('same-label-different-source');state=source_case['state']
        self.assertTrue(ev.action_guard(state,source_case['expected']))
        wrong={**source_case['expected'],'source_id':'south','snapshot_id':'s2'}
        self.assertFalse(ev.action_guard(state,wrong))
        self.assertFalse(ev.action_guard(state,{**source_case['expected'],'snapshot_id':'older'}))
        exact=fixture('preserve-leading-zero');before=exact['state'];candidate=exact['expected']
        after=copy.deepcopy(before);after['observations'][0]['snapshot_id']='a4'
        after['observations'][0]['controls'][0]['value']='012.50'
        receipt={'native_succeeded':True,'requested_tuple':copy.deepcopy(candidate)}
        self.assertTrue(ev.postcondition_guard(before,candidate,receipt,after))
        self.assertFalse(ev.action_guard(before,{**candidate,'value':'12.50'}))
        for defect in ('wrong_value','stale','wrong_source','wrong_receipt','failed_native'):
            observed=copy.deepcopy(after);ack=copy.deepcopy(receipt)
            if defect=='wrong_value':observed['observations'][0]['controls'][0]['value']='12.50'
            elif defect=='stale':observed['observations'][0]['snapshot_id']='a3'
            elif defect=='wrong_source':observed['observations'][0]['source_id']='another-editor'
            elif defect=='wrong_receipt':ack['requested_tuple']['value']='12.50'
            elif defect=='failed_native':ack['native_succeeded']=False
            with self.subTest(defect=defect):self.assertFalse(ev.postcondition_guard(before,candidate,ack,observed))

    def test_gold_never_enters_request_and_guard_rejection_never_repairs_model_accuracy(self):
        original=copy.deepcopy(DOCUMENT);cases=ev.freeze_cases(DOCUMENT)
        self.assertEqual(DOCUMENT,original)
        protocol={'model_store':{'directory':'/chat','modelDirectories':{'kev-4b':'/decision'}}}
        for case in cases:
            cold=ev.request(case,protocol,'decision_cold');resident=ev.request(case,protocol,'decision_resident')
            self.assertEqual(core.encoded(cold['request']),core.encoded(resident['request']))
            self.assertEqual(cold['request']['state'],next(c['state'] for c in original['cases'] if c['id']==case['id']))
            for payload in (cold,ev.request(case,protocol,'host_cold')):
                text=core.encoded(payload).decode();self.assertNotIn(case['gold_rationale'],text)
                self.assertNotIn('expected_candidate',text);self.assertNotIn('gold_rationale',text)
        case=cases[0];done=next(k for k,v in case['candidates'].items() if v['operation']=='proposed_done')
        result={'model':'kev-4b@revision','usage':{'input_tokens':11,'output_tokens':0},'answers':{'action':{
            'type':'choice','choice':done,'confidence':1.0,'probabilities':{k:float(k==done) for k in case['candidates']}}}}
        terminal={'type':'result','result':result}
        raw={'terminal':terminal,'events':[terminal],'child_started':True,'transport_error':None,
             'deadline_expired':False,'cleanup':{'succeeded':True,'exit_code':0,'forced_kill':False}}
        scored=ev.score(case,'decision',raw,'kev-4b@revision')
        self.assertEqual(scored['outcome'],'selection_mismatch');self.assertFalse(scored['correct'])
        self.assertFalse(scored['simulated_guard']['admitted']);self.assertEqual(scored['selected_candidate'],done)
        raw['cleanup']['forced_kill']=True
        unqualified=ev.score(case,'decision',raw,'kev-4b@revision')
        self.assertEqual(unqualified['outcome'],'provider_failure');self.assertFalse(unqualified['correct'])
        self.assertEqual(unqualified['usage']['input_tokens'],11)


CHILD='''import json,sys
mode=sys.argv[1]
opened=json.loads(sys.stdin.readline())
print(json.dumps({'version':1,'type':'opened','id':opened['id'],'sessionId':opened['id'],'generation':0,'loaded':False,'model':'kev-4b@revision','modelDirectory':'/decision'}),flush=True)
for line in sys.stdin:
 m=json.loads(line)
 if m['type']=='shutdown':
  print(json.dumps({'version':1,'type':'closed','id':m['id'],'sessionId':opened['id'],'generation':generation}),flush=True);break
 generation=m['generation'];keys=list(m['request']['questions']['action']['criteria']);choice=keys[0]
 result={'model':'kev-4b@revision','usage':{'input_tokens':13,'output_tokens':0},'answers':{'action':{'type':'choice','choice':choice,'confidence':1.0,'probabilities':{k:float(k==choice) for k in keys}}}}
 event={'version':True if mode=='wrong-version' and generation==2 else 1,'type':'result','id':m['id'],'sessionId':opened['id'],'generation':99 if mode=='wrong-generation' and generation==2 else generation,'result':result}
 if mode=='late-eof':
  for ignored in sys.stdin:pass
  print(json.dumps(event),flush=True);break
 print(json.dumps(event),flush=True)
'''


class ResidentTransport(unittest.TestCase):
    def exercise(self, mode):
        cases=ev.freeze_cases(DOCUMENT)[:3]
        protocol={'cases':cases,'models':{'kev-4b':{'manifest':{'revision':'revision'}}},
            'models_directory':'/chat','decision_models_directory':'/decision',
            'model_store':{'directory':'/chat','modelDirectories':{'kev-4b':'/decision'}},
            'binaries':{'decision':{'path':'/not-a-native-harness'}}}
        rows=[{'arm':'decision_resident','case_id':c['id'],'phase':'unattempted','outcome':'unattempted','correct':False} for c in cases]
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();child=root/'child.py';child.write_text(CHILD)
            def worker(_command,environment,directory):return ev.Resident([sys.executable,str(child),mode],environment,directory)
            clock=(lambda:ev.CUTOFF-timedelta(seconds=.3)) if mode=='late-eof' else (lambda:ev.CUTOFF-timedelta(seconds=30))
            session=ev.resident_arm(protocol,rows,root,lambda _session:None,worker_factory=worker,clock=clock)
            streams=(root/'resident-session/stdout.bin').read_bytes()
            self.assertTrue(session['cleanup']['succeeded']);self.assertEqual(session['cleanup']['exit_code'],0)
            return rows,session,streams

    def test_serial_resident_preserves_identity_generation_request_usage_and_clean_close(self):
        rows,session,streams=self.exercise('valid')
        self.assertEqual(session['phase'],'completed');self.assertEqual(len(rows),3)
        self.assertTrue(all(r['phase']=='completed' for r in rows))
        self.assertEqual([r['generation'] for r in rows],[1,2,3])
        self.assertEqual(len({r['transport']['owned_pid'] for r in rows}),1)
        self.assertEqual([r['usage']['input_tokens'] for r in rows],[13]*3)
        self.assertEqual(rows[0]['residency'],'load_inclusive_first_request')
        self.assertEqual(rows[1]['residency'],'same_process_resident_warm')
        self.assertEqual(json.loads(streams.splitlines()[-1])['type'],'closed')

    def test_wrong_generation_stops_without_retry_and_retains_decoded_facts(self):
        for mode in ('wrong-generation','wrong-version'):
            with self.subTest(mode=mode):
                rows,session,_streams=self.exercise(mode)
                self.assertEqual(session['phase'],'failed')
                self.assertEqual(rows[1]['outcome'],'provider_failure');self.assertFalse(rows[1]['correct'])
                self.assertEqual(rows[1]['usage']['input_tokens'],13)
                self.assertEqual(rows[1]['model_returned'],'kev-4b@revision')
                self.assertEqual(rows[2]['phase'],'unattempted')
                events=[e for e in session['events'] if e['type']=='result']
                self.assertEqual(len(events),2)
                self.assertEqual(events[1]['generation'],99 if mode=='wrong-generation' else 2)
                self.assertEqual(type(events[1]['version']),bool if mode=='wrong-version' else int)

    def test_late_result_after_deadline_is_retained_but_never_admitted(self):
        rows,session,_streams=self.exercise('late-eof')
        self.assertEqual(session['phase'],'failed');self.assertEqual(rows[0]['outcome'],'provider_failure')
        self.assertTrue(rows[0]['transport']['deadline_expired'])
        self.assertTrue(rows[0]['transport']['terminal_received_during_cleanup'])
        self.assertEqual(rows[0]['usage']['input_tokens'],13);self.assertEqual(rows[0]['model_returned'],'kev-4b@revision')
        self.assertFalse(rows[0]['correct']);self.assertTrue(all(r['phase']=='unattempted' for r in rows[1:]))


class ColdWireCommands(unittest.TestCase):
    def test_main_selects_real_chat_and_decision_commands(self):
        from unittest import mock
        child_source = '''import json, os, sys
role = os.path.basename(sys.argv[0])
expected = 'chat' if role == 'fritz-harness' else 'evaluate'
if sys.argv[1:] != [expected]:
    print('unsupported subcommand: ' + repr(sys.argv[1:]), file=sys.stderr)
    raise SystemExit(2)
payload = json.loads(sys.stdin.readline())
if expected == 'chat':
    assert payload['connection']['provider'] == 'fritz'
    assert payload['request']['messages'][0]['role'] == 'user'
    assert 'questions' not in payload['request']
else:
    assert payload['backend']['kind'] == 'ollaya'
    assert 'action' in payload['request']['questions']
    assert 'messages' not in payload['request']
assert payload['apiKey'] is None
print(json.dumps({'type': 'error', 'message': 'wire admitted: ' + expected}), flush=True)
for ignored in sys.stdin:
    pass
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            binaries = {}
            for kind, name in (('chat', 'fritz-harness'), ('decision', 'fritz-decision-harness')):
                binary = root / name
                binary.write_text('#!' + sys.executable + '\n' + child_source)
                binary.chmod(0o700)
                binaries[kind] = {'path': str(binary)}
            protocol = {'cases': ev.freeze_cases(DOCUMENT)[:1], 'binaries': binaries,
                'models': {ev.DECISION: {'manifest': {'revision': 'wire-fixture'}}},
                'models_directory': str(root / 'Models'), 'decision_models_directory': str(root / 'Models'),
                'model_store': {'directory': str(root / 'Models')}, 'readiness': {'ready': False}}
            saved = root / 'protocol.json'; core.write_json(saved, protocol)
            output = root / 'run'
            with mock.patch.object(ev, 'revalidate'), mock.patch.object(ev, 'remaining', return_value=30):
                ev.main(['--protocol', str(saved), '--protocol-sha256', core.file_hash(saved), '--output', str(output)])
            rows = {row['arm']: row for row in core.strict_json((output / 'report.json').read_bytes())['records']}
            for arm, command in (('host_cold', 'chat'), ('decision_cold', 'evaluate')):
                with self.subTest(arm=arm):
                    receipt = rows[arm]['transport']
                    self.assertEqual(receipt['cleanup']['exit_code'], 0)
                    self.assertTrue(receipt['cleanup']['succeeded'])
                    self.assertEqual(receipt['terminal'], {'type': 'error', 'message': 'wire admitted: ' + command})


if __name__=='__main__':unittest.main()
