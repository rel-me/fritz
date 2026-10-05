"""Offline rejection and accounting contracts; no weights, native models or browser."""
import copy
import importlib.util
import math
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('bosun_pairing', Path(__file__).with_name('bosun_browser_pairing.py'))
ext = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ext)
pair = ext.pair


def case(name='example'):
    return pair.freeze_case({'id':name, 'source':{'fixture':'independent synthetic state'},
        'state':{'goal':'Open the newest list. Keep  spacing\n', 'page':{'groups':[
            {'controls':[{'ref':'e1','name':'More','states':['enabled']},
                         {'ref':'e2','name':'More','states':['enabled']}]}]}},
        'questions':{'operation':{'type':'choice','instructions':'Choose','criteria':{'click':'Click','handoff':'Stop'}},
                     'target':{'type':'choice','instructions':'Choose target','criteria':{'e1':'Old','e2':'Newest','none':'None'}}},
        'expected':{'operation':'click','target':'e2'}})


def receipt(kind='decision', *, selected='a0001', model=ext.MODEL+'@revision'):
    if kind == 'chat':
        terminal = {'type':'result','result':{}}
        events = [{'type':'delta','text':selected}, {'type':'usage','usage':{'input_tokens':11,'output_tokens':2}}]
    else:
        terminal = {'type':'result','result':{'model':model,'usage':{'input_tokens':19,'output_tokens':0},
            'answers':{'action':{'type':'choice','choice':selected,'confidence':0.8,
                       'probabilities':{'a0000':0.1,'a0001':0.8,'a0002':0.05,'a0003':0.05}}}}}
        events = []
    events.append(terminal)
    return {'terminal':terminal,'events':events,'transport_error':None,'deadline_expired':False,
            'transport_version':ext.owned.VERSION,
            'child_started':True,'cleanup':{'transport_version':ext.owned.VERSION,'succeeded':True,'exit_code':0},'elapsed_seconds':0.25}


def parity():
    manifest = {'revision':'revision','engine_revision':'engine',
                'files':[{'file':'weights.gguf','size':123,'sha256':'a'*64}]}
    sources = {key:'b'*64 for key in ('bosun','local','harness','catalog')}
    gold = [{'case_id':'r'+str(i),'question_name':'action','request':{'state':'Evidence','model':ext.MODEL},
             'prompt':'Exact prompt\n','token_ids':[1,2,3], 'candidate_to_slot':{'a':1,'b':0},
             'candidates':[{'id':'a'},{'id':'b'}]} for i in range(5)]
    rows = [{**copy.deepcopy(item),'probabilities':[0.2,0.8],'slot_logits':[1.0,0.0]} for item in gold]
    clean = {'exit_code':0,'forced_kill':False,'succeeded':True,'transport_version':ext.owned.VERSION}
    followup = {'preregistration':{'path':'/frozen/followup','bytes':1,'sha256':ext.FOLLOWUP_SHA256},
                'initial_failure':{'path':'/frozen/initial-failure','bytes':1,'sha256':ext.INITIAL_FAILURE_SHA256}}
    cpu = {'schema':'fritz-bosun-cpu-reference-v1','status':'complete','compiler_reference_sha256':'c'*64,
           'runtime_lock_sha256':'d'*64,'runtime_lock':{'schema':'fritz-bosun-cpu-runtime-lock-v1'},
           'transport_protocol':ext.owned.provenance(),'followup':followup,
           'settings':{'device':'cpu','dtype':'float32','attention':'eager','generation':False},
           'source_files':[{'file':'adapter.safetensors','size':10,'sha256':'e'*64}],
           'base_files':[{'file':'base.safetensors','size':100,'sha256':'f'*64}],
           'rows':rows,'attempts':[{'case_id':item['case_id'],'status':'complete','cleanup':copy.deepcopy(clean),
                                  'transport':{'transport_version':ext.owned.VERSION}} for item in gold]}
    cpu['driver']=pair.pin(Path(__file__).with_name('bosun_cpu_reference.py').resolve())
    cpu['generator_sha256']=cpu['driver']['sha256']
    native_rows = [{**copy.deepcopy(item),'probabilities':[0.202,0.798], 'reference_probabilities':[0.2,0.8],
                    'slot_logits':[1.0,0.0],'selected_index':1,'reference_selected_index':1,'passed':True,
                    'max_absolute_probability_error':0.002,'usage':{'input_tokens':3,'output_tokens':0}} for item in gold]
    combined = {'schema':'fritz-bosun-parity-receipt-v1','status':'complete','compiler_reference_sha256':'c'*64,
                'cpu_reference_sha256':'1'*64,'runtime_lock_sha256':'d'*64,
                'transport_protocol':ext.owned.provenance(),'followup':copy.deepcopy(followup),
                'transport':{'transport_version':ext.owned.VERSION},
                'cpu':copy.deepcopy(cpu), 'native':{'binary_sha256':'2'*64,'model':ext.MODEL,'revision':'revision',
                    'engine_revision':'engine','source_sha256':sources,'artifacts':manifest['files'],
                    'test_executable_path':'/explicit/native-test','test_executable_sha256':'3'*64,
                    'rows':native_rows,'cleanup':copy.deepcopy(clean)}}
    combined['driver']=pair.pin(Path(__file__).with_name('bosun_native_parity.py').resolve())
    combined['generator_sha256']=combined['driver']['sha256']
    compiler = {'schema':'fritz-bosun-compiler-reference-v1','rows':gold}
    args = {'compiler_sha256':'c'*64,'cpu_sha256':'1'*64,'binary_sha256':'2'*64,
            'manifest':manifest,'source_sha256':sources}
    return cpu, combined, compiler, args


class ParityAdmission(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(ext,'verify_pin')
        patch.start(); self.addCleanup(patch.stop)

    def test_complete_reference_and_native_vectors_are_required_not_passed_labels(self):
        cpu, combined, compiler, args = parity()
        self.assertTrue(ext.validate_parity(cpu,combined,compiler,**args)['passed'])
        for defect in ('compiler_only','null','nan','missing_option','overflow','different_top','wrong_tokens','wrong_binary','unknown_cleanup','missing_base','old_transport','changed_transport_source'):
            with self.subTest(defect=defect):
                a,b,c,kwargs = parity()
                if defect == 'compiler_only': a['status'] = 'compiler-only'
                elif defect == 'null':
                    a['rows'][0]['probabilities'] = None; b['cpu']['rows'] = copy.deepcopy(a['rows'])
                elif defect == 'nan': b['native']['rows'][0]['probabilities'] = [float('nan'),0.8]
                elif defect == 'missing_option': b['native']['rows'][0]['probabilities'] = [1.0]
                elif defect == 'overflow': b['native']['rows'][0]['probabilities'] = [0.21,0.79]
                elif defect == 'different_top':
                    a['rows'][0]['probabilities'] = [0.5001,0.4999]; b['cpu']['rows'] = copy.deepcopy(a['rows'])
                    b['native']['rows'][0]['probabilities'] = [0.4999,0.5001]
                elif defect == 'wrong_tokens': b['native']['rows'][0]['token_ids'] = [3,2,1]
                elif defect == 'wrong_binary': b['native']['binary_sha256'] = '4'*64
                elif defect == 'unknown_cleanup': b['native']['cleanup']['succeeded'] = None
                elif defect == 'missing_base': a['base_files'] = []; b['cpu']['base_files'] = []
                elif defect == 'old_transport':
                    a['attempts'][0]['transport']['transport_version'] = 'historical-one-shot'
                    b['cpu']['attempts'] = copy.deepcopy(a['attempts'])
                elif defect == 'changed_transport_source':
                    a['transport_protocol']['driver']['sha256'] = '0'*64
                    b['transport_protocol'] = copy.deepcopy(a['transport_protocol'])
                    b['cpu']['transport_protocol'] = copy.deepcopy(a['transport_protocol'])
                with self.assertRaises(pair.ConfigurationError): ext.validate_parity(a,b,c,**kwargs)

    def test_requests_candidate_mapping_cpu_attempts_and_zero_generation_are_bound(self):
        for field in ('request','candidate_to_slot','source_sha256','cpu_cleanup','usage','reference_probabilities'):
            with self.subTest(field=field):
                cpu,combined,compiler,args = parity()
                row = combined['native']['rows'][0]
                if field == 'request': row['request']['state'] = 'changed evidence'
                elif field == 'candidate_to_slot': row[field] = {'a':0,'b':1}
                elif field == 'source_sha256': combined['native'][field] = {'bosun':'wrong'}
                elif field == 'cpu_cleanup':
                    cpu['attempts'][0]['cleanup']['exit_code'] = 9; combined['cpu']['attempts'] = copy.deepcopy(cpu['attempts'])
                elif field == 'usage': row['usage']['output_tokens'] = 1
                elif field == 'reference_probabilities': row[field] = [0.8,0.2]
                with self.assertRaises(pair.ConfigurationError): ext.validate_parity(cpu,combined,compiler,**args)

    def test_reference_mirror_accepts_one_adjacent_f64_and_rejects_larger_or_invalid_changes(self):
        for direction in (-math.inf, math.inf):
            cpu,combined,compiler,args = parity()
            original=cpu['rows'][0]['probabilities'][0]
            mirrored=combined['native']['rows'][0]['reference_probabilities']
            mirrored[0]=math.nextafter(original,direction)
            retained=copy.deepcopy((cpu,combined))
            gate=ext.validate_parity(cpu,combined,compiler,**args)
            self.assertTrue(gate['passed'])
            self.assertEqual(gate['reference_mirror']['changed_options'],1)
            self.assertEqual(gate['probability_tolerance'],0.005)
            self.assertAlmostEqual(gate['max_absolute_probability_error'],0.002)
            self.assertEqual((cpu,combined),retained)
            mirrored[0]=math.nextafter(mirrored[0],direction)
            with self.assertRaisesRegex(pair.ConfigurationError,'one adjacent finite f64'):
                ext.validate_parity(cpu,combined,compiler,**args)
        for defect in (None,[0.2],[float('nan'),0.8]):
            cpu,combined,compiler,args = parity()
            combined['native']['rows'][0]['reference_probabilities']=defect
            with self.assertRaises(pair.ConfigurationError):ext.validate_parity(cpu,combined,compiler,**args)

    def test_native_error_is_graded_against_original_cpu_without_mirror_tolerance_expansion(self):
        cpu,combined,compiler,args = parity()
        combined['native']['rows'][0]['reference_probabilities'][0]=math.nextafter(0.2,math.inf)
        row=combined['native']['rows'][0]
        row['probabilities']=[0.2049,0.7951]
        row['max_absolute_probability_error']=0.0049
        gate=ext.validate_parity(cpu,combined,compiler,**args)
        self.assertTrue(gate['passed'])
        self.assertAlmostEqual(gate['max_absolute_probability_error'],0.0049)
        row['probabilities']=[0.2051,0.7949]
        row['max_absolute_probability_error']=0.0051
        with self.assertRaisesRegex(pair.ConfigurationError,'Native probability'):
            ext.validate_parity(cpu,combined,compiler,**args)


class OriginalEvidence(unittest.TestCase):
    def test_all_48_attempts_survive_and_repaired_or_raw_mismatched_baselines_fail(self):
        cases = [case('c'+str(i)) for i in range(12)]
        catalog = {'path':'/original/catalog.json','bytes':1,'sha256':'a'*64}
        models = {model:{'catalog':catalog,'directory':'/explicit','manifest':{'revision':'revision'},
                         'manifest_sha256':'b'*64,'artifacts':[]} for model in (*pair.CHAT_MODELS,pair.DECISION_MODEL)}
        protocol = {'version':1,'scope':pair.SCOPE,'preregistration':{'sha256':pair.PREREGISTRATION_SHA256},
                    'driver':{'path':pair.__file__},'corpora':[], 'cases':cases,'models':models,
                    'models_directory':'/chat','decision_models_directory':'/kev',
                    'bounds':{'max_attempts':48,'deadline_seconds':125}}
        protocol['plan'] = pair.attempt_plan(protocol)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); records = []
            for index,planned in enumerate(protocol['plan']):
                raw = receipt(planned['kind'],selected=' a0001' if index == 0 else 'a0001',model='kev-4b@revision')
                stdout = b''.join(pair.encoded(event)+b'\n' for event in raw['events'])
                owned = root/planned['run_id']; owned.mkdir()
                (owned/'stdout.bin').write_bytes(stdout); (owned/'stderr.bin').write_bytes(b'')
                raw.update(stdout_bytes=len(stdout),stdout_sha256=pair.digest(stdout),stderr_bytes=0,stderr_sha256=pair.digest(b''))
                assessed = pair.assess(cases[index%12],planned['kind'],raw,'kev-4b@revision')
                records.append({**{key:planned[key] for key in ('run_id','kind','model','case_id','payload_sha256')},
                                **assessed,'transport':raw,'phase':'completed'})
            report = {'status':'completed','protocol_sha256':'c'*64,'records':records}
            def checked(_catalog,model,_directory,**_kwargs): return copy.deepcopy(models[model])
            with mock.patch.object(ext,'verify_pin'), mock.patch.object(pair,'load_corpora',return_value=(cases,[])), \
                 mock.patch.object(ext,'verify_relocation',return_value={'/original/catalog.json':{'path':'/copied/catalog.json'}}), \
                 mock.patch.object(pair,'inspect_model',side_effect=checked):
                _cases, retained = ext.validate_baseline(protocol,report,{'sha256':'c'*64},root/'report.json',{})
                self.assertEqual(len(retained),48); self.assertEqual(retained[0]['outcome'],'invalid_response')
                repaired = copy.deepcopy(report); repaired['records'][0]['correct'] = True
                with self.assertRaisesRegex(pair.ConfigurationError,'repaired'): ext.validate_baseline(protocol,repaired,{'sha256':'c'*64},root/'report.json',{})
                altered = copy.deepcopy(report)
                raw = altered['records'][0]['transport']; raw['events'][0]['text'] = 'a0001'
                altered['records'][0].update(pair.assess(cases[0],'chat',raw,''))
                with self.assertRaisesRegex(pair.ConfigurationError,'raw terminal'): ext.validate_baseline(protocol,altered,{'sha256':'c'*64},root/'report.json',{})
                missing = copy.deepcopy(report); missing['records'].pop()
                with self.assertRaisesRegex(pair.ConfigurationError,'All 48'): ext.validate_baseline(protocol,missing,{'sha256':'c'*64},root/'report.json',{})

    def test_authentic_relocation_schema_checks_full_inventory_and_principal_pins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); captured = root/'capture'; captured.mkdir()
            original_root = root/'original'
            files, pins = [], {}
            for name in ('fritz','chat','decision','chat-catalog','decision-catalog','Info.plist'):
                path = captured/name; path.write_bytes(('independent '+name).encode())
                pin = pair.pin(path); source = str(original_root/name)
                pins[name] = {**pin,'path':source}
                files.append({'relative_path':name,'source_path':source,'captured_path':str(path),'size':pin['bytes'],
                              'sha256':pin['sha256'],'source_sha256':pin['sha256'],'captured_sha256':pin['sha256'],'matches':True})
            # The real receipt separates six principal pins from the full inventory.
            asset = captured/'framework-resource'; asset.write_bytes(b'captured supporting asset')
            regular = [{'relative_path':path.name,'size':path.stat().st_size,'sha256':pair.file_hash(path)}
                       for path in captured.iterdir()]
            (captured/'alias').symlink_to('chat')
            original = {'catalogs':{'chat':pins['chat-catalog'],'decision':pins['decision-catalog']},
                        'binaries':{'chat':pins['chat'],'decision':pins['decision'],
                                    'bundle':{'path':str(original_root),'info_plist':pins['Info.plist']}}}
            signatures = [{'artifact':name,'exit_code':0} for name in ('bundle','fritz','fritz-harness','fritz-decision-harness')]
            document = {'schema':'fritz-staged-bundle-relocation-v1','original_protocol':{'sha256':'a'*64},
                        'captured_bundle':str(captured),'source_bundle':str(original_root),'all_regular_files_verified':True,
                        'files':files,'regular_file_manifest':regular,'regular_files_count':len(regular),
                        'regular_files_bytes':sum(item['size'] for item in regular),
                        'symlinks':{'alias':'chat'},'signatures':{'before':signatures,'after':signatures}}
            self.assertEqual(ext.verify_relocation(document,original,{'sha256':'a'*64})[pins['decision']['path']]['sha256'],pins['decision']['sha256'])
            asset.write_bytes(b'tampered supporting asset')
            with self.assertRaises(pair.ConfigurationError): ext.verify_relocation(document,original,{'sha256':'a'*64})
            asset.write_bytes(b'captured supporting asset')
            mismatched = copy.deepcopy(document)
            for key in ('sha256','source_sha256','captured_sha256'):
                mismatched['files'][0][key] = '0'*64
            with self.assertRaisesRegex(pair.ConfigurationError,'Principal relocation pin'):
                ext.verify_relocation(mismatched,original,{'sha256':'a'*64})
            (captured/'alias').unlink(); (captured/'alias').symlink_to('decision')
            with self.assertRaisesRegex(pair.ConfigurationError,'symlink manifest'):
                ext.verify_relocation(document,original,{'sha256':'a'*64})
            (captured/'alias').unlink(); (captured/'alias').symlink_to('chat')
            (captured/'extra').write_bytes(b'unlisted')
            with self.assertRaisesRegex(pair.ConfigurationError,'incomplete'): ext.verify_relocation(document,original,{'sha256':'a'*64})

    def test_model_update_preserves_every_frozen_state_instruction_candidate_and_gold(self):
        frozen = case(); original = pair.decision_payload(frozen,{'models_directory':'/chat','decision_models_directory':'/kev'})
        before = copy.deepcopy(original)
        updated = ext.extension_payload(original,Path('/bosun'))
        wanted = copy.deepcopy(original['request']); wanted['model'] = ext.MODEL
        self.assertEqual(updated['request'],wanted)
        self.assertEqual(original,before)
        self.assertEqual(updated['modelStore'],{'directory':'/bosun','modelDirectories':{ext.MODEL:'/bosun'}})
        self.assertNotIn('expected_candidate',pair.encoded(updated).decode())

    def test_official_compilation_never_fetches_missing_assets_or_truncates_state(self):
        planned = [{'case_id':'r'+str(i),'payload':{'request':{'model':ext.MODEL,'state':'full original'}}} for i in range(12)]
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary).resolve()
            with mock.patch.object(pair,'pin',side_effect=pair.ConfigurationError('missing')), mock.patch.object(ext.official,'reference_rows') as compile_rows:
                with self.assertRaises(pair.ConfigurationError): ext.compile_extension(planned,cache)
                compile_rows.assert_not_called()
            def pin(path):
                sha = ext.official.ASSETS.get(path.name,('', 'a'*64))[1]
                return {'path':str(path),'bytes':1,'sha256':sha}
            rows = [{'candidates':[{},{}],'token_ids':[1,2]} for _ in range(12)]
            with mock.patch.object(pair,'pin',side_effect=pin), mock.patch.object(ext.official,'reference_rows',return_value=rows) as compile_rows:
                ext.compile_extension(planned,cache)
                self.assertEqual(compile_rows.call_args.args[0]['cases'][0]['request']['state'],'full original')
                rows[0]['token_ids'] = [1]*2049
                with self.assertRaisesRegex(pair.ConfigurationError,'no truncation'): ext.compile_extension(planned,cache)


class ExtensionAccounting(unittest.TestCase):
    def test_interruption_retains_partial_receipt_and_stops_without_retry(self):
        frozen = case()
        payload = {'request':{'model':ext.MODEL,'state':frozen['original_state'],
                             'questions':{'action':frozen['question']}},'apiKey':None}
        planned = {'run_id':'owned-1','case_id':frozen['id'],'kind':'decision','model':ext.MODEL,
                   'payload':payload,'payload_sha256':pair.digest(pair.encoded(payload))}
        protocol = {'version':1,'scope':ext.SCOPE,'cases':[frozen],'baseline_records':[],
                    'plan':[planned,{**planned,'run_id':'owned-2'}],
                    'model':{'manifest':{'revision':'revision'}},'models_directory':'/explicit-models',
                    'binaries':{'decision':{'path':'/fake-owned-harness'}},
                    'compiler':{'rows':[{'case_id':frozen['id'],'token_ids':[1]*19}]}}
        raw = receipt()
        before = copy.deepcopy(raw)
        transport = mock.Mock(side_effect=ext.owned.InterruptedAttempt(raw))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); saved = root/'protocol.json'; pair.write_json(saved,protocol)
            with mock.patch.object(ext,'revalidate'):
                status = ext.main(['--protocol',str(saved),'--protocol-sha256',pair.file_hash(saved),
                                   '--output',str(root/'out')],transport=transport)
            self.assertEqual(status,130)
            self.assertEqual(transport.call_count,1)
            report = pair.strict_json((root/'out/report.json').read_bytes())
            self.assertEqual(report['status'],'interrupted')
            self.assertEqual(report['summary']['attempted'],1)
            record = report['records'][0]
            self.assertEqual((record['phase'],record['outcome'],record['correct']),
                             ('interrupted','provider_failure',False))
            self.assertIsNone(record['selected_candidate'])
            self.assertEqual(record['usage'],{'input_tokens':19,'output_tokens':0,'total_tokens':19})
            self.assertEqual(record['model_returned'],ext.MODEL+'@revision')
            self.assertEqual(record['transport'],before)
            self.assertEqual(pair.strict_json((root/'out/owned-1/receipt.json').read_bytes()),record)
            self.assertFalse((root/'out/owned-2').exists())
            self.assertEqual(raw,before)

    def test_host_failure_cannot_be_rescued_and_late_facts_remain_failure(self):
        frozen = case()
        host_receipt = receipt('chat',selected=' a0001')
        host = pair.assess(frozen,'chat',host_receipt,''); host['transport'] = host_receipt
        decision_receipt = receipt()
        decision = ext.assess_bosun(frozen,decision_receipt,ext.MODEL+'@revision',19)
        decision['transport'] = decision_receipt
        self.assertTrue(decision['correct'])
        self.assertFalse(pair.selection_projection(frozen,host,decision,selective=True)['correct'])
        for defect in ('deadline','exit','generated','token_count','confidence'):
            with self.subTest(defect=defect):
                raw = receipt()
                if defect == 'deadline': raw['deadline_expired'] = True
                elif defect == 'exit': raw['cleanup']['exit_code'] = 9
                elif defect == 'generated': raw['terminal']['result']['usage']['output_tokens'] = 1
                elif defect == 'token_count': raw['terminal']['result']['usage']['input_tokens'] = 20
                elif defect == 'confidence': raw['terminal']['result']['answers']['action']['confidence'] = 0.4
                result = ext.assess_bosun(frozen,raw,ext.MODEL+'@revision',19)
                self.assertFalse(result['correct']); self.assertIsNone(result['selected_candidate'])
                self.assertIsNotNone(result['usage']); self.assertEqual(result['model_returned'],ext.MODEL+'@revision')
                self.assertEqual(result['probabilities']['a0001'],0.8)

    def test_unknown_cleanup_stops_and_keeps_failed_attempt_denominator(self):
        frozen = case()
        host_receipt = receipt('chat'); host = pair.assess(frozen,'chat',host_receipt,'')
        host.update(model=pair.CHAT_MODELS[0],case_id=frozen['id'],transport=host_receipt)
        payload = {'request':{'model':ext.MODEL,'state':frozen['original_state'],'questions':{'action':frozen['question']}},'apiKey':None}
        planned = {'run_id':'owned-1','case_id':frozen['id'],'kind':'decision','model':ext.MODEL,'payload':payload,'payload_sha256':pair.digest(pair.encoded(payload))}
        protocol = {'version':1,'scope':ext.SCOPE,'cases':[frozen],'baseline_records':[host],
                    'plan':[planned,{**planned,'run_id':'owned-2'}], 'model':{'manifest':{'revision':'revision'}},
                    'models_directory':'/explicit-models','binaries':{'decision':{'path':'/fake-owned-harness'}},
                    'compiler':{'rows':[{'case_id':frozen['id'],'token_ids':[1]*19}]}}
        raw = receipt(); raw['cleanup']['succeeded'] = None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); saved = root/'protocol.json'; pair.write_json(saved,protocol)
            transport = mock.Mock(return_value=raw)
            with mock.patch.object(ext,'revalidate'):
                status = ext.main(['--protocol',str(saved),'--protocol-sha256',pair.file_hash(saved),'--output',str(root/'out')],transport=transport)
            self.assertEqual(status,1); self.assertEqual(transport.call_count,1)
            report = pair.strict_json((root/'out/report.json').read_bytes())
            self.assertEqual(report['status'],'aborted'); self.assertEqual(report['summary']['attempted'],1)
            self.assertEqual(report['summary']['cleanup_unknown'],1)
            self.assertEqual(report['records'][0]['usage']['input_tokens'],19)
            self.assertEqual((root/'out').stat().st_mode & 0o777,0o700)
            self.assertEqual((root/'out/report.json').stat().st_mode & 0o777,0o600)


if __name__ == '__main__': unittest.main()
