#!/usr/bin/env python3
"""Separate, opt-in Bosun extension of an immutable frozen selection comparison.

No browser, downloads, credentials, retries or repair of baseline failures.
Validation compiles public metadata only; inference requires complete parity.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import importlib.util
import math
from pathlib import Path
import sys


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


pair = module('frozen_pairing_core', Path(__file__).with_name('local_browser_pairing.py'))
official = module('frozen_bosun_compiler', Path(__file__).with_name('bosun_reference.py'))
owned = module('bosun_owned_transport', Path(__file__).with_name('bosun_transport.py'))
MODEL = 'bosun-v3.1-0.6b-f16'
PREREGISTRATION_SHA256 = '768df1060e66df7ae543678b81de83bb5682505183820a74c66529ef153cacf2'
MAX_ATTEMPTS = 12
MAX_DOCUMENT_BYTES = 32_000_000
TOLERANCE = 0.005
FOLLOWUP_SHA256 = 'e38226f7018dd2657ef2f259ea97570896c607b3942337a6e77313f3b1a9610f'
INITIAL_FAILURE_SHA256 = '509a8875a0672a376d25168b85911933fdf316a7546361d1b8d8b95195a9497c'
SCOPE = 'separate Bosun frozen selection proxy; no browser, tools, integrated agent or warm pairing'
require = pair.require


def read_document(path):
    artifact = pair.pin(path)
    require(artifact['bytes'] <= MAX_DOCUMENT_BYTES, 'Evidence document exceeds bound')
    return pair.strict_json(Path(path).read_bytes()), artifact


def verify_pin(artifact):
    path = Path(artifact['path'])
    require(path.is_absolute() and path.is_file() and path.stat().st_size == artifact['bytes']
            and pair.file_hash(path) == artifact['sha256'], 'Pinned evidence changed')


def probabilities(values, count):
    require(isinstance(values, list) and len(values) == count
            and all(type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1 for value in values)
            and abs(math.fsum(values) - 1) <= 0.00001, 'Complete finite normalized parity probabilities required')
    return values


def best(values):
    return max(range(len(values)), key=values.__getitem__)


def validate_reference_mirror(original, mirrored):
    values = probabilities(mirrored, len(original))
    require(all(actual in (expected, math.nextafter(expected, -math.inf), math.nextafter(expected, math.inf))
                for expected, actual in zip(original, values)),
            'Mirrored CPU reference exceeds one adjacent finite f64 representation per option')
    return sum(actual != expected for expected, actual in zip(original, values))


def artifact_manifest(files):
    require(isinstance(files, list) and files, 'Full parity artifact manifest required')
    result = {}
    for item in files:
        name, size, sha = item.get('file'), item.get('size'), item.get('sha256')
        require(isinstance(name, str) and name and name not in result
                and type(size) is int and size > 0 and isinstance(sha, str)
                and pair.re.fullmatch(r'[0-9a-f]{64}', sha), 'Parity artifact size/SHA missing')
        result[name] = {'size': size, 'sha256': sha}
    return result


def clean_parity_process(receipt):
    require(isinstance(receipt, dict) and receipt.get('exit_code') == 0
            and receipt.get('forced_kill') is False and receipt.get('succeeded') is True
            and receipt.get('transport_version') == owned.VERSION,
            'Clean successful parity process required')


def validate_parity(cpu, receipt, compiler, *, compiler_sha256, cpu_sha256, binary_sha256,
                    manifest, source_sha256):
    """Recompute the gate from retained measurements, never trust a passed label."""
    require(cpu.get('schema') == 'fritz-bosun-cpu-reference-v1' and cpu.get('status') == 'complete'
            and cpu.get('compiler_reference_sha256') == compiler_sha256,
            'Complete frozen official CPU reference required')
    require(isinstance(cpu.get('runtime_lock_sha256'), str)
            and pair.re.fullmatch(r'[0-9a-f]{64}', cpu['runtime_lock_sha256'])
            and cpu.get('runtime_lock', {}).get('schema') == 'fritz-bosun-cpu-runtime-lock-v1'
            and cpu.get('settings', {}).get('device') == 'cpu'
            and cpu.get('settings', {}).get('dtype') == 'float32'
            and cpu.get('settings', {}).get('attention') == 'eager'
            and cpu.get('settings', {}).get('generation') is False,
            'Frozen official CPU runtime and non-generative settings required')
    require(receipt.get('schema') == 'fritz-bosun-parity-receipt-v1' and receipt.get('status') == 'complete'
            and receipt.get('compiler_reference_sha256') == compiler_sha256
            and receipt.get('cpu_reference_sha256') == cpu_sha256
            and receipt.get('runtime_lock_sha256') == cpu.get('runtime_lock_sha256'),
            'Complete native parity receipt from this binary required')
    native, retained_cpu = receipt.get('native', {}), receipt.get('cpu', {})
    require(cpu.get('transport_protocol') == receipt.get('transport_protocol') == owned.provenance(),
            'Parity transport version/source/core differs from this corrected cohort')
    for document, name in ((cpu,'bosun_cpu_reference.py'),(receipt,'bosun_native_parity.py')):
        require(document.get('driver') == pair.pin(Path(__file__).with_name(name).resolve())
                and document.get('generator_sha256') == document['driver']['sha256'],
                'Parity consuming driver source pin differs')
    followup = cpu.get('followup')
    require(isinstance(followup, dict) and retained_cpu.get('followup') == receipt.get('followup') == followup
            and followup.get('preregistration', {}).get('sha256') == FOLLOWUP_SHA256
            and followup.get('initial_failure', {}).get('sha256') == INITIAL_FAILURE_SHA256,
            'Separate diagnostic cohort must retain its preregistration and original failed receipt')
    for artifact in followup.values():
        verify_pin(artifact)
    require(receipt.get('transport', {}).get('transport_version') == owned.VERSION,
            'Actual native supervisor transport receipt missing')
    require(native.get('binary_sha256') == binary_sha256 and native.get('model') == MODEL
            and native.get('revision') == manifest['revision']
            and native.get('engine_revision') == manifest['engine_revision']
            and native.get('source_sha256') == source_sha256,
            'Parity binary, runtime sources or native model pin mismatch')
    require(isinstance(native.get('test_executable_sha256'), str)
            and pair.re.fullmatch(r'[0-9a-f]{64}', native['test_executable_sha256'])
            and isinstance(native.get('test_executable_path'), str)
            and Path(native['test_executable_path']).is_absolute(), 'Actual native parity test executable provenance missing')
    require(artifact_manifest(native.get('artifacts')) == artifact_manifest(manifest['files']),
            'Native parity used another installed artifact')
    for key in ('source_files','base_files'):
        require(artifact_manifest(cpu.get(key)) == artifact_manifest(retained_cpu.get(key)),
                'Full official source/base-weight provenance missing or differs')
    require(retained_cpu.get('runtime_lock') == cpu.get('runtime_lock')
            and isinstance(cpu.get('runtime_lock'), dict), 'Official CPU runtime lock missing')
    require(retained_cpu.get('rows') == cpu.get('rows') and retained_cpu.get('attempts') == cpu.get('attempts'),
            'Combined receipt differs from retained CPU attempts')
    clean_parity_process(native.get('cleanup'))
    gold = compiler.get('rows')
    require(compiler.get('schema') == 'fritz-bosun-compiler-reference-v1'
            and isinstance(gold, list) and len(gold) == 5, 'Exactly five frozen compiler cases required')
    for report in (cpu, native):
        require(isinstance(report.get('rows'), list) and len(report['rows']) == len(gold), 'Parity rows missing')
    require(isinstance(cpu.get('attempts'), list) and len(cpu['attempts']) == len(gold), 'Official CPU attempts missing')
    for attempt, expected in zip(cpu['attempts'], gold):
        require(attempt.get('case_id') == expected['case_id'] and attempt.get('status') == 'complete',
                'Failed or reordered CPU attempt')
        clean_parity_process(attempt.get('cleanup'))
        require(attempt.get('transport', {}).get('transport_version') == owned.VERSION,
                'Actual CPU attempt transport receipt missing')
    authoritative_errors, changed_mirrors = [], 0
    for source, measured, expected in zip(cpu['rows'], native['rows'], gold):
        for key in ('case_id', 'question_name', 'request', 'prompt', 'token_ids', 'candidate_to_slot'):
            require(source.get(key) == measured.get(key) == expected.get(key), 'Parity prompt/token/slot identity mismatch')
        count = len(expected['candidates'])
        a, b = probabilities(source.get('probabilities'), count), probabilities(measured.get('probabilities'), count)
        error = max(abs(left-right) for left, right in zip(a, b))
        authoritative_errors.append(error)
        require(error <= TOLERANCE and best(a) == best(b),
                'Native probability or selected-candidate parity failed')
        changed_mirrors += validate_reference_mirror(a, measured.get('reference_probabilities'))
        require(measured.get('selected_index') == best(b)
                and measured.get('reference_selected_index') == best(a)
                and measured.get('passed') is True
                and type(measured.get('max_absolute_probability_error')) in (int,float)
                and math.isfinite(measured['max_absolute_probability_error'])
                and abs(measured['max_absolute_probability_error']-error) <= 1e-12,
                'Native parity summary differs from measured vectors')
        for logits in (source.get('slot_logits'), measured.get('slot_logits')):
            require(isinstance(logits, list) and len(logits) == count
                and all(type(value) in (int, float) and math.isfinite(value) for value in logits),
                'Official eligible final-position logits missing')
        usage = pair.reported_usage(measured.get('usage'))
        require(usage is not None and usage['input_tokens'] == len(expected['token_ids'])
                and usage['output_tokens'] == 0, 'Native parity token usage must confirm no generated answer')
    return {'passed': True, 'cases': len(gold), 'probability_tolerance': TOLERANCE,
            'max_absolute_probability_error': max(authoritative_errors),
            'reference_mirror': {
                'policy': 'one_adjacent_finite_f64_per_option_metadata_only_v1',
                'changed_options': changed_mirrors,
                'reason': 'Pinned Rust JSON decoding mirrored some CPU numbers at an adjacent f64. '
                          'The original CPU vectors remain authoritative for native error and selected-index grading; '
                          'no probability vector is rounded, repaired or replaced.'},
            'scope': 'five-case limited compiler/token/probability parity; no calibration or browser qualification'}


def verify_relocation(document, original, original_pin):
    require(document.get('schema') == 'fritz-staged-bundle-relocation-v1'
            and document.get('original_protocol', {}).get('sha256') == original_pin['sha256']
            and document.get('all_regular_files_verified') is True,
            'Complete original-bundle relocation receipt required')
    root = Path(document['captured_bundle']).resolve()
    source = Path(document['source_bundle'])
    require(root.is_absolute() and root.is_dir() and str(source) == original['binaries']['bundle']['path'],
            'Relocation belongs to another original bundle')
    for phase in ('before','after'):
        signatures = document.get('signatures', {}).get(phase)
        require(isinstance(signatures, list) and len(signatures) == 4
                and {item.get('artifact') for item in signatures} == {'bundle','fritz','fritz-harness','fritz-decision-harness'}
                and all(item.get('exit_code') == 0 for item in signatures),
                'Original and captured bundle signature verification required')
    manifest, declared = document.get('regular_file_manifest'), {}
    require(isinstance(manifest, list) and manifest, 'Captured regular-file manifest missing')
    for item in manifest:
        require(isinstance(item, dict), 'Invalid captured regular-file entry')
        relative, size, sha = item.get('relative_path'), item.get('size'), item.get('sha256')
        require(isinstance(relative, str) and relative and relative not in declared
                and not pair.PurePosixPath(relative).is_absolute()
                and '..' not in pair.PurePosixPath(relative).parts and '\\' not in relative
                and str(pair.PurePosixPath(relative)) == relative
                and type(size) is int and size >= 0
                and isinstance(sha, str) and pair.re.fullmatch(r'[0-9a-f]{64}', sha),
                'Invalid or duplicate captured regular-file pin')
        path = root / relative
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root),
                'Captured regular-file pin is missing or escapes bundle')
        declared[relative] = {'path': str(path.resolve()), 'bytes': size, 'sha256': sha}
        verify_pin(declared[relative])
    actual = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file() and not path.is_symlink()}
    require(actual == set(declared), 'Captured regular-file manifest incomplete')
    require(document.get('regular_files_count') == len(declared)
            and document.get('regular_files_bytes') == sum(item['bytes'] for item in declared.values()),
            'Captured regular-file inventory totals differ')
    files, mapping = document.get('files'), {}
    require(isinstance(files, list) and len(files) == 6, 'Six principal relocation pins required')
    for item in files:
        path = Path(item['captured_path'])
        require(path.is_absolute() and path.resolve().is_relative_to(root)
                and item.get('matches') is True
                and item['sha256'] == item['source_sha256'] == item['captured_sha256'],
                'Relocation file integrity or containment mismatch')
        original_path = str(Path(item['source_path']))
        require(original_path not in mapping
                and str(Path(item['relative_path'])) == str(Path(original_path).relative_to(source))
                and path == root / item['relative_path'], 'Duplicate or inconsistent relocation mapping')
        principal = {'path': str(path.resolve()), 'bytes': item['size'], 'sha256': item['sha256']}
        require(declared.get(item['relative_path']) == principal,
                'Principal relocation pin differs from full regular-file manifest')
        mapping[original_path] = principal
    links = document.get('symlinks')
    require(isinstance(links, dict) and links == {str(path.relative_to(root)): str(path.readlink())
            for path in root.rglob('*') if path.is_symlink()}, 'Captured symlink manifest differs')
    require(all((root/name).resolve().is_relative_to(root) for name in links), 'Captured symlink escapes bundle')
    required = [*original['catalogs'].values(), original['binaries']['chat'], original['binaries']['decision'],
                original['binaries']['bundle']['info_plist']]
    for artifact in required:
        moved = mapping.get(artifact['path'])
        require(moved is not None and moved['bytes'] == artifact['bytes'] and moved['sha256'] == artifact['sha256'],
                'Relocated original artifact differs from original protocol')
    return mapping


def validate_baseline(protocol, report, protocol_pin, report_path, relocation):
    require(protocol.get('version') == 1 and protocol.get('scope') == pair.SCOPE
            and protocol['preregistration']['sha256'] == pair.PREREGISTRATION_SHA256
            and report.get('protocol_sha256') == protocol_pin['sha256']
            and report.get('status') == 'completed', 'Completed immutable original comparison required')
    for artifact in [protocol['driver'], protocol['preregistration'], *protocol['corpora']]:
        verify_pin(artifact)
    require(Path(protocol['driver']['path']).resolve() == Path(pair.__file__).resolve(), 'Another frozen core was supplied')
    cases, _ = pair.load_corpora([Path(item['path']) for item in protocol['corpora']])
    require(cases == protocol['cases'] and pair.attempt_plan(protocol) == protocol['plan']
            and protocol['bounds']['max_attempts'] == 48 and protocol['bounds']['deadline_seconds'] == 125,
            'Original cases, gates, candidate inventory or bounds changed')
    mapping = verify_relocation(relocation, protocol, protocol_pin)
    for model in (*pair.CHAT_MODELS, pair.DECISION_MODEL):
        frozen = protocol['models'][model]
        moved_catalog = mapping[frozen['catalog']['path']]['path']
        checked = pair.inspect_model(moved_catalog, model, Path(frozen['directory']), decision=model == pair.DECISION_MODEL)
        require(checked['manifest'] == frozen['manifest']
                and checked['manifest_sha256'] == frozen['manifest_sha256']
                and checked['artifacts'] == frozen['artifacts'], 'Original model artifacts or catalog changed')
    records = report.get('records')
    require(isinstance(records, list) and len(records) == 48, 'All 48 original attempts, including failures, required')
    cases_by_id = {case['id']: case for case in cases}
    for record, planned in zip(records, protocol['plan']):
        require(all(record.get(key) == planned[key] for key in ('run_id', 'case_id', 'kind', 'model', 'payload_sha256')),
                'Original attempt identity/order changed')
        receipt = record.get('transport')
        require(isinstance(receipt, dict) and record.get('phase') == 'completed', 'Original attempted receipt missing')
        assessed = pair.assess(cases_by_id[record['case_id']], record['kind'], receipt,
                               pair.DECISION_MODEL + '@' + protocol['models'][pair.DECISION_MODEL]['manifest']['revision'])
        require(all(record.get(key) == assessed[key] for key in ('outcome', 'correct', 'selected_candidate', 'usage', 'usage_complete')),
                'Original outcome was repaired or differs from its retained receipt')
        for stream in ('stdout', 'stderr'):
            verify_pin({'path': str(Path(report_path).parent / record['run_id'] / (stream+'.bin')),
                        'bytes': receipt[stream+'_bytes'], 'sha256': receipt[stream+'_sha256']})
        stdout = (Path(report_path).parent / record['run_id'] / 'stdout.bin').read_bytes()
        parsed = pair.EventStream(record['kind']); parsed.feed(stdout); parsed.finish()
        require(parsed.events == receipt.get('events') and parsed.terminal == receipt.get('terminal'),
                'Original receipt differs from retained raw terminal/events')
    return cases, records


def extension_payload(original, directory):
    request = copy.deepcopy(original['request'])
    request['model'] = MODEL
    return {'request': request, 'backend': {'kind': 'ollaya'}, 'apiKey': None,
            'modelStore': {'directory': str(directory), 'modelDirectories': {MODEL: str(directory)}}}


def compile_extension(plan, cache):
    require(cache.is_absolute() and cache.is_dir(), 'Explicit existing compiler metadata cache required')
    # The official helper may fetch missing metadata. Require every asset before calling it.
    assets = []
    for name, (_url, sha256) in official.ASSETS.items():
        artifact = pair.pin(cache / name)
        require(artifact['sha256'] == sha256, 'Pinned official compiler metadata missing or changed')
        assets.append(artifact)
    rows = official.reference_rows({'cases': [{'id': item['case_id'], 'request': item['payload']['request']} for item in plan]}, cache)
    require(len(rows) == MAX_ATTEMPTS and all(2 <= len(row['candidates']) <= 255
            and 0 < len(row['token_ids']) <= 2048 for row in rows), 'Complete Bosun prompts exceed runtime bounds; no truncation')
    return {'scope': 'official AST/Jinja/tokenizer metadata only; native extension token IDs unmeasured',
            'generator': pair.pin(Path(official.__file__).resolve()), 'assets': assets,
            'packages': official.COMPILER_PACKAGES, 'rows': rows}


def prepare_protocol(options):
    original, original_pin = read_document(options.baseline_protocol)
    require(original_pin['sha256'] == options.baseline_protocol_sha256, 'Original protocol SHA mismatch')
    report, report_pin = read_document(options.baseline_report)
    require(report_pin['sha256'] == options.baseline_report_sha256, 'Original report SHA mismatch')
    relocation, relocation_pin = read_document(options.relocation_receipt)
    require(relocation_pin['sha256'] == options.relocation_sha256, 'Relocation receipt SHA mismatch')
    cases, records = validate_baseline(original, report, original_pin, options.baseline_report, relocation)
    preregistration = pair.pin(options.preregistration)
    require(preregistration['sha256'] == options.preregistration_sha256 == PREREGISTRATION_SHA256,
            'Extension preregistration mismatch')
    binaries = pair.inspect_binaries(options.bin_dir)
    require(options.decision_catalog.resolve().is_relative_to(Path(binaries['bundle']['path'])), 'Use new staged decision catalog')
    model = pair.inspect_model(options.decision_catalog, MODEL, options.models_directory, decision=True)
    require(model['manifest'].get('engine') == 'bosun' and model['manifest'].get('max_prompt_tokens') == 2048,
            'Pinned Bosun native manifest required')
    cpu, cpu_pin = read_document(options.cpu_reference)
    native, native_pin = read_document(options.native_parity)
    compiler, compiler_pin = read_document(options.compiler_reference)
    require(options.compiler_reference.resolve() == Path(__file__).with_name('fixtures').joinpath('bosun-compiler-reference.json').resolve(),
            'Use the unchanged independently frozen five-case compiler fixture')
    source_paths = {'bosun': pair.ROOT/'src/decision/local/bosun.rs', 'local': pair.ROOT/'src/decision/local.rs',
                    'harness': pair.ROOT/'src/decision/harness.rs', 'catalog': options.decision_catalog}
    sources = {key: pair.pin(path) for key,path in source_paths.items()}
    gate = validate_parity(cpu, native, compiler, compiler_sha256=compiler_pin['sha256'],
                           cpu_sha256=cpu_pin['sha256'], binary_sha256=binaries['decision']['sha256'],
                           manifest=model['manifest'], source_sha256={key:item['sha256'] for key,item in sources.items()})
    native_test = pair.pin(Path(native['native']['test_executable_path']), executable=True)
    require(native_test['sha256'] == native['native']['test_executable_sha256'], 'Actual parity test executable changed')
    require(cpu_pin['sha256'] == options.cpu_reference_sha256
            and native_pin['sha256'] == options.native_parity_sha256, 'Frozen parity receipt SHA mismatch')
    plan = []
    for item in original['plan']:
        if item['kind'] == 'decision':
            payload = extension_payload(item['payload'], options.models_directory.resolve())
            require(len(pair.encoded(payload)) <= pair.MAX_INPUT_BYTES
                    and len(pair.encoded(payload['request'])) <= 80_000, 'Extension private input/common decision body exceeds bound')
            plan.append({'run_id': MODEL+'-'+item['case_id'], 'case_id': item['case_id'], 'kind': 'decision',
                         'model': MODEL, 'payload': payload, 'payload_sha256': pair.digest(pair.encoded(payload))})
    compiled = compile_extension(plan, options.compiler_cache)
    return {'version': 1, 'scope': SCOPE, 'created_at': pair.timestamp(),
            'driver': pair.pin(Path(__file__).resolve()), 'core': original['driver'], 'preregistration': preregistration,
            'baseline': {'protocol': original_pin, 'report': report_pin, 'relocation': relocation_pin},
            'baseline_records': records, 'cases': cases, 'plan': plan, 'compiler': compiled,
            'transport_protocol': owned.provenance(),
            'parity': {'cpu': cpu_pin, 'native': native_pin, 'compiler': compiler_pin, 'sources': sources,
                       'native_test': native_test, 'gate': gate},
            'binaries': binaries, 'model': model, 'models_directory': str(options.models_directory.resolve()),
            'time_rss': True, 'time_binary': pair.pin(Path('/usr/bin/time'), executable=True),
            'bounds': {'max_attempts': MAX_ATTEMPTS, 'deadline_seconds': 125, 'cleanup_grace_seconds': [2,1,1],
                       'no_retries': True, 'stop_on_failed_or_unknown_cleanup': True},
            'limits': ['Known fixtures; supplied frozen milestone bypasses the planner',
                       'Native token parity is measured for five reference cases; extension compiler facts are metadata predictions',
                       'Host failures retained; serial cost is derived, no warm or combined-memory claim']}


def revalidate(protocol):
    require(protocol.get('version') == 1 and protocol.get('scope') == SCOPE
            and protocol['preregistration']['sha256'] == PREREGISTRATION_SHA256
            and protocol['bounds']['max_attempts'] == MAX_ATTEMPTS and protocol['bounds']['deadline_seconds'] == 125,
            'Saved extension schema or bounds mismatch')
    require(protocol.get('transport_protocol') == owned.provenance(), 'Saved extension transport changed')
    for artifact in [protocol['driver'], protocol['core'], protocol['preregistration'], protocol['time_binary'],
                     *protocol['baseline'].values(), *[protocol['parity'][key] for key in ('cpu','native','compiler')],
                     *protocol['parity']['sources'].values(),
                     protocol['parity']['native_test'],
                     protocol['compiler']['generator'], *protocol['compiler']['assets'],
                     protocol['binaries']['decision'], protocol['binaries']['bundle']['info_plist'], protocol['model']['catalog']]:
        verify_pin(artifact)
    require(Path(protocol['driver']['path']).resolve() == Path(__file__).resolve(), 'Saved extension belongs to another driver')
    original = pair.strict_json(Path(protocol['baseline']['protocol']['path']).read_bytes())
    report_path = Path(protocol['baseline']['report']['path'])
    report = pair.strict_json(report_path.read_bytes())
    relocation = pair.strict_json(Path(protocol['baseline']['relocation']['path']).read_bytes())
    cases, records = validate_baseline(original, report, protocol['baseline']['protocol'], report_path, relocation)
    require(cases == protocol['cases'] and records == protocol['baseline_records'], 'Original baseline changed')
    checked = pair.inspect_model(protocol['model']['catalog']['path'], MODEL, Path(protocol['models_directory']), decision=True)
    require(checked == protocol['model'], 'Bosun artifact manifest changed')
    expected_plan = []
    for item in original['plan']:
        if item['kind'] == 'decision':
            payload = extension_payload(item['payload'], protocol['models_directory'])
            expected_plan.append({'run_id': MODEL+'-'+item['case_id'], 'case_id': item['case_id'], 'kind': 'decision',
                                  'model': MODEL, 'payload': payload, 'payload_sha256': pair.digest(pair.encoded(payload))})
    require(expected_plan == protocol['plan'], 'Extension changed more than the model/store fields')
    compiled = compile_extension(expected_plan, Path(protocol['compiler']['assets'][0]['path']).parent)
    require(compiled == protocol['compiler'], 'Official Bosun compiler facts changed')
    documents = {key: pair.strict_json(Path(protocol['parity'][key]['path']).read_bytes()) for key in ('cpu','native','compiler')}
    validate_parity(documents['cpu'], documents['native'], documents['compiler'],
                    compiler_sha256=protocol['parity']['compiler']['sha256'], cpu_sha256=protocol['parity']['cpu']['sha256'],
                    binary_sha256=protocol['binaries']['decision']['sha256'], manifest=protocol['model']['manifest'],
                    source_sha256={key:item['sha256'] for key,item in protocol['parity']['sources'].items()})


def summarize(protocol, records):
    hosts = {(item['model'], item['case_id']): item for item in protocol['baseline_records']}
    decisions = {item['case_id']: item for item in records}
    return {'planned': MAX_ATTEMPTS, 'attempted': len(records), 'unattempted': MAX_ATTEMPTS-len(records),
            'correct': sum(item['correct'] for item in records),
            'correct_rate_all_attempts': sum(item['correct'] for item in records)/len(records) if records else None,
            'outcomes': dict(Counter(item['outcome'] for item in records)),
            'usage_unknown_or_partial': sum(not item.get('usage_complete') for item in records),
            'known_reported_tokens': sum(item['usage']['total_tokens'] for item in records if item.get('usage') is not None),
            'cleanup_failed': sum(item.get('transport', {}).get('cleanup', {}).get('succeeded') is False for item in records),
            'cleanup_unknown': sum(item.get('transport', {}).get('cleanup', {}).get('succeeded') is None
                                   and item.get('transport', {}).get('child_started') is not False for item in records),
            'baseline_attempts_retained': len(protocol['baseline_records']),
            'baseline_failures_retained': sum(not item['correct'] for item in protocol['baseline_records']),
            'proxies': {model: {'host_only': [pair.selection_projection(case, hosts.get((model,case['id'])),
                                                   decisions.get(case['id']), selective=False) for case in protocol['cases']],
                               'selective': [pair.selection_projection(case, hosts.get((model,case['id'])),
                                                   decisions.get(case['id']), selective=True) for case in protocol['cases']]}
                        for model in pair.CHAT_MODELS}}


def assess_bosun(case, receipt, expected_model, expected_tokens):
    result = pair.assess(case, 'decision', receipt, expected_model)
    if result['outcome'] in ('passed','selection_mismatch'):
        usage = result['usage']
        if receipt.get('transport_version') != owned.VERSION or usage['output_tokens'] != 0 or usage['input_tokens'] != expected_tokens or abs(
                result['confidence']-max(result['probabilities'].values())) > 1e-6:
            result.update(outcome='invalid_response', correct=False, selected_candidate=None,
                          reason='Bosun no-generation/token-count/maximum-option confidence contract failed')
    return result


def save(output, protocol, records, status, *, active=None, reason=None):
    report = {'scope': SCOPE, 'status': status, 'protocol_sha256': protocol['_sha256'],
              'records': records, 'summary': summarize(protocol, records), 'active_run_id': active,
              'abort_reason': reason, 'updated_at': pair.timestamp()}
    pair.write_json(output/'report.json', report, replace=True)
    return report


def main(argv=None, *, transport=owned.evaluate_child):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--protocol', type=Path)
    parser.add_argument('--protocol-sha256')
    fields = ('baseline-protocol','baseline-report','relocation-receipt','preregistration','cpu-reference',
              'native-parity','compiler-reference','compiler-cache','bin-dir','decision-catalog','models-directory')
    hashes = ('baseline-protocol','baseline-report','relocation','preregistration','cpu-reference','native-parity')
    for name in fields: parser.add_argument('--'+name, type=Path)
    for name in hashes: parser.add_argument('--'+name+'-sha256')
    options = parser.parse_args(argv)
    protocol, records = None, []
    try:
        require(options.output.is_absolute() and not options.output.exists(), 'Fresh absolute output required')
        if options.validate:
            require(options.protocol is None and options.protocol_sha256 is None
                    and all(getattr(options, name.replace('-','_')) is not None for name in fields)
                    and all(getattr(options, name.replace('-','_')+'_sha256') is not None for name in hashes),
                    'Validation requires explicit frozen inputs, receipts, catalogs and stores')
            protocol = prepare_protocol(options)
        else:
            require(options.protocol is not None and options.protocol_sha256 is not None
                    and all(getattr(options, name.replace('-','_')) is None for name in fields)
                    and all(getattr(options, name.replace('-','_')+'_sha256') is None for name in hashes),
                    'Inference settings come only from the saved extension protocol')
            raw = options.protocol.read_bytes()
            require(pair.digest(raw) == options.protocol_sha256, 'Saved extension protocol SHA mismatch')
            protocol = pair.strict_json(raw)
            revalidate(protocol)
        options.output.mkdir(mode=0o700)
        pair.write_json(options.output/'protocol.json', protocol)
        protocol['_sha256'] = pair.file_hash(options.output/'protocol.json')
        require(options.validate or protocol['_sha256'] == options.protocol_sha256, 'Noncanonical saved protocol')
        save(options.output, protocol, records, 'validated' if options.validate else 'running')
        if options.validate:
            print(pair.encoded({'output':str(options.output),'protocol_sha256':protocol['_sha256'],'planned_attempts':12}).decode())
            return 0
        cases = {case['id']:case for case in protocol['cases']}
        tokens = {row['case_id']:len(row['token_ids']) for row in protocol['compiler']['rows']}
        for planned in protocol['plan']:
            record = {key:planned[key] for key in ('run_id','kind','model','case_id','payload_sha256')}
            record.update(outcome='provider_failure', phase='in_flight', correct=False, selected_candidate=None,
                          usage=None, usage_complete=False, gate=cases[record['case_id']]['gate'],
                          transport={'elapsed_seconds':None,'cleanup':{'succeeded':None}})
            records.append(record)
            save(options.output, protocol, records, 'running', active=record['run_id'])
            attempt_directory = options.output/record['run_id']; attempt_directory.mkdir(mode=0o700)
            data = attempt_directory/'data'; data.mkdir(mode=0o700)
            pair.write_json(attempt_directory/'request.json', planned['payload'])
            command = ['/usr/bin/time','-l',protocol['binaries']['decision']['path'],'evaluate']
            expected = MODEL+'@'+protocol['model']['manifest']['revision']
            try:
                receipt = transport(command, pair.encoded(planned['payload']), pair.child_environment(protocol,data), attempt_directory)
                record.update(assess_bosun(cases[record['case_id']], receipt, expected, tokens[record['case_id']]),
                              transport=receipt, phase='completed')
            except owned.InterruptedAttempt as error:
                record.update(assess_bosun(cases[record['case_id']], error.receipt, expected, tokens[record['case_id']]),
                              outcome='provider_failure', correct=False, selected_candidate=None, transport=error.receipt,
                              phase='interrupted', reason='Interrupted; no retry')
                pair.write_json(attempt_directory/'receipt.json', record)
                save(options.output, protocol, records, 'interrupted', reason='Owned attempt interrupted')
                return 130
            except Exception as error:
                record.update(phase='unknown', reason='Unknown transport/cleanup: '+type(error).__name__)
            pair.write_json(attempt_directory/'receipt.json', record)
            if record['transport'].get('cleanup',{}).get('succeeded') is not True and record['transport'].get('child_started') is not False:
                save(options.output, protocol, records, 'aborted', reason='Owned cleanup failed or unknown; no further attempts')
                return 1
            save(options.output, protocol, records, 'running')
        save(options.output, protocol, records, 'completed')
        return int(any(not item['correct'] for item in records))
    except KeyboardInterrupt:
        if protocol is not None and options.output.exists() and '_sha256' in protocol:
            save(options.output, protocol, records, 'interrupted', reason='Interrupted outside an owned attempt')
        return 130
    except (pair.ConfigurationError, owned.frozen.ConfigurationError, OSError, ValueError, KeyError, TypeError) as error:
        print('Bosun extension stopped: '+str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
