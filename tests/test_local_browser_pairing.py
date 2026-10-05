"""Offline contracts for frozen selection, provenance and owned pipe lifetime.

These tests use synthetic artifacts and Python children, never model inference.
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location('local_browser_pairing', Path(__file__).with_name('local_browser_pairing.py'))
pair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pair)


def original_case(case_id='example', *, duplicate=True, expected='click'):
    # Independent known label: click e2, never inferred from a driver result.
    return {'id': case_id, 'source': {'fixture_sha256': 'f' * 64, 'private_oracle': 'GOLD_SOURCE_ONLY'},
            'state': {'goal': 'Open the newest list. Keep  spacing\n',
                      'page': {'coverage': {'truncated': False, 'omitted_node_count': 0, 'clipped_text_count': 0},
                               'groups': [{'context': 'Older', 'content': [{'kind': 'text', 'text': '6\u00a0comments'}],
                                           'controls': [{'ref': 'e1', 'role': 'link', 'name': 'More', 'states': ['enabled']},
                                                        {'ref': 'e2', 'role': 'link', 'name': 'More' if duplicate else 'Next', 'states': ['enabled']}]}]}},
            'questions': {'operation': {'type': 'choice', 'instructions': 'Choose',
                                       'criteria': {'click': 'Click', 'done': 'Done', 'handoff': 'Handoff'}},
                          'target': {'type': 'choice', 'instructions': 'If clicking, choose',
                                     'criteria': {'e1': 'Older list', 'e2': 'Newest list', 'none': 'No target'}}},
            'expected': {'operation': expected, 'target': 'e2' if expected == 'click' else None,
                         'private_label': 'GOLD_LABEL_ONLY'}}


def clean_receipt(kind='chat', *, choice='a0001', code=0, extra=None):
    if kind == 'chat':
        events = [{'type': 'activity', 'message': 'Thinking'}, {'type': 'delta', 'text': choice},
                  {'type': 'usage', 'usage': {'input_tokens': 11, 'output_tokens': 2}}]
        terminal = {'type': 'result', 'result': {}}
    else:
        result = {'model': 'kev-4b@revision', 'usage': {'input_tokens': 19, 'output_tokens': 0},
                  'answers': {'action': {'type': 'choice', 'choice': choice,
                                         'probabilities': {'a0000': 0.1, 'a0001': 0.8, 'a0002': 0.05, 'a0003': 0.05},
                                         'confidence': 0.8}}}
        terminal, events = {'type': 'result', 'result': result}, []
    events.append(terminal)
    receipt = {'child_started': True, 'terminal': terminal, 'events': events,
               'deadline_expired': False, 'transport_error': None,
               'cleanup': {'attempted': True, 'succeeded': True, 'exit_code': code}, 'elapsed_seconds': 0.25}
    if extra:
        receipt.update(extra)
    return receipt


def assessed(kind='chat', **kwargs):
    receipt = clean_receipt(kind, **kwargs)
    result = pair.assess(pair.freeze_case(original_case()), kind, receipt, 'kev-4b@revision')
    result['transport'] = receipt
    return result


class FrozenSelections(unittest.TestCase):
    def test_complete_catalog_exact_refs_original_state_and_no_gold_in_requests(self):
        source = original_case()
        before = copy.deepcopy(source)
        case = pair.freeze_case(source)
        self.assertEqual(source, before)
        self.assertEqual(case['original_state'], before['state'])
        self.assertEqual(case['candidates'], {
            'a0000': {'operation': 'click', 'ref': 'e1'}, 'a0001': {'operation': 'click', 'ref': 'e2'},
            'a0002': {'operation': 'proposed_done', 'ref': None}, 'a0003': {'operation': 'handoff', 'ref': None}})
        self.assertEqual(case['expected_candidate'], 'a0001')
        self.assertIn('6\u00a0comments', case['chat_prompt'])
        for request in (pair.chat_payload(case, pair.CHAT_MODELS[0]),
                        pair.decision_payload(case, {'models_directory': '/chat', 'decision_models_directory': '/decision'})):
            raw = pair.encoded(request).decode()
            self.assertNotIn('GOLD_SOURCE_ONLY', raw)
            self.assertNotIn('GOLD_LABEL_ONLY', raw)
        chat = pair.chat_payload(case, pair.CHAT_MODELS[0])
        self.assertIsNone(chat['request']['projectPath'])
        self.assertEqual(chat['request']['maxTurns'], 1)
        self.assertIsNone(chat['apiKey'])

    def test_duplicate_name_gate_does_not_use_gold_and_excludes_disabled_controls(self):
        source = original_case(expected='handoff')
        case = pair.freeze_case(source)
        self.assertTrue(case['gate']['use_decision'])
        self.assertEqual(case['gate']['duplicate_names'], [{'name': 'More', 'refs': ['e1', 'e2']}])
        source['state']['page']['groups'][0]['controls'][1]['states'] = ['disabled']
        del source['questions']['target']['criteria']['e2']
        case = pair.freeze_case(source)
        self.assertFalse(case['gate']['use_decision'])
        source['state']['page']['groups'][0]['controls'][1]['states'] = ['enabled']
        source['questions']['target']['criteria']['e2'] = 'Newest list'
        source['state']['page']['groups'][0]['controls'][1]['name'] = 'more'
        self.assertFalse(pair.freeze_case(source)['gate']['use_decision'])

    def test_empty_click_inventory_can_propose_done_and_overflow_never_omits_candidates(self):
        source = original_case(expected='done')
        del source['questions']['target']
        case = pair.freeze_case(source)
        self.assertEqual(case['candidates'], {'a0000': {'operation': 'proposed_done', 'ref': None},
                                             'a0001': {'operation': 'handoff', 'ref': None}})
        self.assertEqual(case['expected_candidate'], 'a0000')
        source = original_case()
        source['state']['page']['groups'][0]['controls'] = [
            {'ref': f'e{i}', 'name': f'Control {i}', 'role': 'link', 'states': ['enabled']} for i in range(254)]
        source['questions']['target']['criteria'] = {f'e{i}': f'Control {i}' for i in range(254)}
        with self.assertRaisesRegex(pair.ConfigurationError, 'no omissions'):
            pair.freeze_case(source)

    def test_strict_chat_admission_no_fence_prose_quotes_or_whitespace_repair(self):
        self.assertEqual(assessed()['outcome'], 'passed')
        for text in (' a0001', 'a0001\n', '"a0001"', '```\na0001\n```', 'Choose a0001.', 'a9999'):
            with self.subTest(text=text):
                self.assertEqual(assessed(choice=text)['outcome'], 'invalid_response')
        tool = clean_receipt()
        tool['events'].insert(0, {'type': 'tool_start', 'name': 'read_file'})
        self.assertEqual(pair.assess(pair.freeze_case(original_case()), 'chat', tool, '')['outcome'], 'invalid_response')

    def test_valid_usage_and_model_survive_nonzero_exit_trailing_output_and_late_terminal(self):
        for failure in ({'cleanup': {'succeeded': True, 'exit_code': 7}},
                        {'transport_error': 'Output after terminal'}, {'deadline_expired': True}):
            with self.subTest(failure=failure):
                result = assessed('decision', extra=failure)
                self.assertFalse(result['correct'])
                self.assertIsNone(result['selected_candidate'])
                self.assertEqual(result['model_returned'], 'kev-4b@revision')
                self.assertEqual(result['usage'], {'input_tokens': 19, 'output_tokens': 0, 'total_tokens': 19})
                self.assertEqual(result['probabilities']['a0001'], 0.8)

    def test_distribution_exact_options_argmax_and_typed_usage(self):
        case = pair.freeze_case(original_case())
        self.assertEqual(assessed('decision')['outcome'], 'passed')
        for defect in ('missing_option', 'not_argmax', 'wrong_model', 'unknown_usage', 'boolean_probability'):
            receipt = clean_receipt('decision')
            result = receipt['terminal']['result']
            answer = result['answers']['action']
            if defect == 'missing_option':
                del answer['probabilities']['a0000']
            elif defect == 'not_argmax':
                answer['choice'] = 'a0000'
            elif defect == 'wrong_model':
                result['model'] = 'kev-4b@other'
            elif defect == 'unknown_usage':
                result['usage'] = {'input_tokens': None, 'output_tokens': 0}
            else:
                answer['probabilities']['a0000'] = True
            with self.subTest(defect=defect):
                self.assertEqual(pair.assess(case, 'decision', receipt, 'kev-4b@revision')['outcome'], 'invalid_response')

    def test_multiple_usage_reports_are_not_assumed_additive(self):
        receipt = clean_receipt()
        receipt['events'].insert(0, {'type': 'usage', 'usage': {'input_tokens': 11, 'output_tokens': 1}})
        result = pair.assess(pair.freeze_case(original_case()), 'chat', receipt, '')
        self.assertEqual(result['outcome'], 'passed')
        self.assertIsNone(result['usage'])
        self.assertFalse(result['usage_complete'])
        self.assertEqual(result['known_usage_reports'], 2)

    def test_selective_override_keeps_host_failure_and_all_derived_component_costs(self):
        case, decision = pair.freeze_case(original_case()), assessed('decision')
        for host in (assessed(extra={'deadline_expired': True}), assessed(choice='```a0001```')):
            projection = pair.selection_projection(case, host, decision, selective=True)
            self.assertFalse(projection['correct'])
            self.assertIsNone(projection['selected_candidate'])
            self.assertEqual(projection['derived_serial_seconds'], 0.5)
            self.assertEqual(projection['known_usage']['total_tokens'], 32)
            self.assertEqual(projection['host_outcome'], host['outcome'])
        # An admitted wrong judgment is a different contract from failed transport.
        wrong_host = assessed(choice='a0000')
        projection = pair.selection_projection(case, wrong_host, decision, selective=True)
        self.assertTrue(projection['correct'])
        self.assertEqual(projection['host_outcome'], 'selection_mismatch')
        nongated = pair.freeze_case(original_case(duplicate=False))
        self.assertFalse(pair.selection_projection(nongated, wrong_host, decision, selective=True)['correct'])
        active = {'outcome': 'provider_failure', 'correct': False, 'selected_candidate': None,
                  'usage': None, 'usage_complete': False, 'transport': {'elapsed_seconds': None}}
        self.assertIsNone(pair.selection_projection(case, active, None, selective=True)['derived_serial_seconds'])


class NativePipeLifetime(unittest.TestCase):
    def child(self, directory, code):
        script = directory / 'mock_child.py'
        script.write_text(code)
        return [sys.executable, str(script), 'evaluate']

    def test_eof_late_large_terminal_preserves_facts_and_deadline_for_partial_or_empty_prefix(self):
        # A 100 KiB terminal exceeds common pipe capacity. The owner must drain
        # during cleanup, not kill a child blocked while emitting its terminal.
        event = clean_receipt('decision')['terminal']
        event['result']['padding'] = 'x' * 100_000
        raw = pair.encoded(event) + b'\n'
        for partial in (False, True):
            with self.subTest(partial=partial), tempfile.TemporaryDirectory() as name:
                directory = Path(name)
                split = len(raw) // 2 if partial else 0
                code = ('import sys\n'
                        'sys.stdin.buffer.readline()\n'
                        f'raw={raw!r}\n'
                        f'sys.stdout.buffer.write(raw[:{split}]); sys.stdout.buffer.flush()\n'
                        'sys.stdin.buffer.read()\n'
                        f'sys.stdout.buffer.write(raw[{split}:]); sys.stdout.buffer.flush()\n')
                receipt = pair.evaluate_child(self.child(directory, code), b'{}', {}, directory, timeout=0.15)
                self.assertTrue(receipt['deadline_expired'])
                self.assertTrue(receipt['terminal_received_during_cleanup'])
                self.assertIsNone(receipt['transport_error'])
                self.assertEqual(receipt['cleanup']['exit_code'], 0)
                self.assertTrue(receipt['cleanup']['succeeded'])
                result = pair.assess(pair.freeze_case(original_case()), 'decision', receipt, 'kev-4b@revision')
                self.assertEqual(result['outcome'], 'provider_failure')
                self.assertEqual(result['usage']['input_tokens'], 19)
                self.assertEqual(result['model_returned'], 'kev-4b@revision')
                self.assertEqual((directory / 'stdout.bin').read_bytes(), raw)

    def test_extra_terminal_nonfinite_events_and_oversize_output_are_not_admitted(self):
        terminal = pair.encoded(clean_receipt('decision')['terminal']) + b'\n'
        for raw in (terminal + terminal, b'{"type":"result","result":{"x":NaN}}\n',
                    terminal + b'x' * (pair.MAX_OUTPUT_BYTES + 1)):
            stream = pair.EventStream('decision')
            stream.feed(raw)
            stream.finish()
            self.assertIsNotNone(stream.error)
            self.assertLessEqual(len(stream.raw), pair.MAX_OUTPUT_BYTES + 1)
        for raw in (b'{"type":"result","type":"error"}\n', b'{"type":"result"'):
            stream = pair.EventStream('decision')
            stream.feed(raw)
            stream.finish()
            self.assertIsNotNone(stream.error)

    def test_chat_progress_not_terminal_and_nonzero_exit_retains_reported_usage(self):
        events = clean_receipt()['events']
        raw = b''.join(pair.encoded(event) + b'\n' for event in events)
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            code = 'import sys\nsys.stdin.buffer.readline()\n' + f'sys.stdout.buffer.write({raw!r}); sys.stdout.buffer.flush()\n' + 'sys.exit(9)\n'
            command = self.child(directory, code)
            command[-1] = 'chat'
            receipt = pair.evaluate_child(command, b'{}', {}, directory, timeout=2)
            self.assertEqual(len(receipt['events']), 4)
            self.assertEqual(receipt['cleanup']['exit_code'], 9)
            result = pair.assess(pair.freeze_case(original_case()), 'chat', receipt, '')
            self.assertEqual(result['outcome'], 'invalid_response')
            self.assertEqual(result['final_answer'], 'a0001')
            self.assertEqual(result['usage']['total_tokens'], 13)

    def test_owned_group_cleanup_does_not_signal_an_unrelated_process(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)'], start_new_session=True)
            try:
                code = ('import signal,sys,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                        'sys.stdin.buffer.readline()\ntime.sleep(20)\n')
                receipt = pair.evaluate_child(self.child(directory, code), b'{}', {}, directory, timeout=0.15)
                self.assertTrue(receipt['cleanup']['succeeded'])
                self.assertIn('SIGKILL', receipt['cleanup']['signals'])
                self.assertIsNone(unrelated.poll())
            finally:
                os.killpg(unrelated.pid, signal.SIGKILL)
                unrelated.wait(timeout=2)


class ProtocolAndReports(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.root_patch = mock.patch.object(pair, 'ROOT', self.directory)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.temporary.cleanup)
        resources = self.directory / 'dist/FritzDebugmock.app/Contents/Resources'
        resources.mkdir(parents=True)
        (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleName': 'FritzDebugmock',
            'CFBundleIdentifier': 'test.owned.debug', 'CFBundleVersion': '1'}))
        for binary in ('fritz-harness', 'fritz-decision-harness'):
            (resources / binary).write_text('#!/bin/sh\nexit 1\n')
            (resources / binary).chmod(0o700)
        self.chat_directory, self.decision_directory = self.directory / 'chat', self.directory / 'decision'
        self.chat_directory.mkdir()
        self.decision_directory.mkdir()
        chat_models = []
        for index, model in enumerate(pair.CHAT_MODELS):
            body = f'synthetic weight {index}'.encode()
            filename = model + '.gguf'
            (self.chat_directory / filename).write_bytes(body)
            chat_models.append({'id': model, 'revision': 'revision', 'file': filename, 'size': len(body),
                                'sha256': pair.digest(body), 'disable_thinking': True})
        self.chat_catalog = resources / 'LocalModels.json'
        self.chat_catalog.write_bytes(pair.encoded({'models': chat_models}))
        body = b'synthetic decision weights'
        (self.decision_directory / 'weights.bin').write_bytes(body)
        self.decision_catalog = resources / 'DecisionModels.json'
        self.decision_catalog.write_bytes(pair.encoded({'models': [{'id': 'kev-4b', 'revision': 'revision',
            'files': [{'file': 'weights.bin', 'size': len(body), 'sha256': pair.digest(body)}]}]}))
        self.corpora = []
        for corpus in range(2):
            path = self.directory / f'corpus{corpus}.json'
            path.write_bytes(pair.encoded({'version': 1, 'scope': 'fixture',
                'cases': [original_case(f'c{corpus}-{index}', duplicate=index == 0) for index in range(6)]}))
            self.corpora.append(path)
        self.preregistration = self.directory / 'preregistration.md'
        self.preregistration.write_text('Frozen selection proxy; no browser execution.\n')
        self.preregistration_patch = mock.patch.object(pair, 'PREREGISTRATION_SHA256', pair.file_hash(self.preregistration))
        self.preregistration_patch.start()
        self.addCleanup(self.preregistration_patch.stop)
        self.validation_output = self.directory / 'validation'
        self.arguments = ['--validate', '--output', str(self.validation_output), '--bin-dir', str(resources),
                          '--models-directory', str(self.chat_directory),
                          '--decision-models-directory', str(self.decision_directory),
                          '--chat-catalog', str(self.chat_catalog), '--decision-catalog', str(self.decision_catalog),
                          '--preregistration', str(self.preregistration),
                          '--preregistration-sha256', pair.file_hash(self.preregistration)]
        for path in self.corpora:
            self.arguments.extend(['--corpus', str(path)])

    def validate(self):
        sentinel = mock.Mock(side_effect=AssertionError('Validation must never start a child'))
        with mock.patch('sys.stdout'):
            self.assertEqual(pair.main(self.arguments, transport=sentinel), 0)
        sentinel.assert_not_called()
        return self.validation_output / 'protocol.json'

    def inference_arguments(self, protocol, output):
        return ['--protocol', str(protocol), '--protocol-sha256', pair.file_hash(protocol), '--output', str(output)]

    def test_validation_freezes_all_48_requests_and_full_artifact_hashes_without_inference(self):
        protocol = self.validate()
        frozen = pair.strict_json(protocol.read_bytes())
        self.assertEqual(len(frozen['plan']), 48)
        self.assertEqual(len({item['run_id'] for item in frozen['plan']}), 48)
        self.assertEqual(frozen['bounds']['deadline_seconds'], 125)
        self.assertEqual(frozen['preregistration']['sha256'], pair.file_hash(self.preregistration))
        self.assertEqual(frozen['plan'][-1]['payload']['modelStore'], {
            'directory': str(self.chat_directory.resolve()), 'modelDirectories': {'kev-4b': str(self.decision_directory.resolve())}})
        for model in frozen['models'].values():
            self.assertTrue(all(item['actual_sha256'] == item['expected_sha256']
                                and item['validation'] == 'full_sha256' for item in model['artifacts']))
        self.assertEqual(os.stat(self.validation_output).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(protocol).st_mode & 0o777, 0o600)

    def test_modified_input_model_and_protocol_fail_before_any_child(self):
        protocol = self.validate()
        arguments = self.inference_arguments(protocol, self.directory / 'inference')
        transport = mock.Mock(side_effect=AssertionError('Changed provenance must not execute'))
        original = self.corpora[0].read_bytes()
        self.corpora[0].write_bytes(original + b' ')
        with mock.patch('sys.stderr'):
            self.assertEqual(pair.main(arguments, transport=transport), 1)
        self.corpora[0].write_bytes(original)
        weight = self.chat_directory / (pair.CHAT_MODELS[0] + '.gguf')
        weight.write_bytes(b'x' * weight.stat().st_size)
        with mock.patch('sys.stderr'):
            self.assertEqual(pair.main(arguments, transport=transport), 1)
        altered = protocol.read_bytes() + b' '
        protocol.write_bytes(altered)
        with mock.patch('sys.stderr'):
            self.assertEqual(pair.main(arguments, transport=transport), 1)
        transport.assert_not_called()
        self.assertFalse((self.directory / 'inference').exists())

    def test_all_48_serial_attempts_project_gate_without_extra_calls_or_hidden_retries(self):
        protocol = self.validate()
        commands = []
        def transport(command, payload, environment, output):
            commands.append(command)
            self.assertEqual(environment['FRITZ_MODELS_DIR'], str(self.chat_directory.resolve()))
            self.assertTrue(Path(environment['FRITZ_DATA_DIR']).is_relative_to(output))
            self.assertNotIn('OPENAI_API_KEY', environment)
            self.assertNotIn('FRITZ_KEYCHAIN_SERVICE', environment)
            request = pair.strict_json(payload)
            if command[-1] == 'chat':
                self.assertIsNone(request['request']['projectPath'])
                self.assertEqual(request['request']['maxTurns'], 1)
            return clean_receipt('decision' if command[-1] == 'evaluate' else 'chat')
        output = self.directory / 'inference'
        with mock.patch.dict(os.environ, {'OPENAI_API_KEY': 'not-to-read', 'FRITZ_KEYCHAIN_SERVICE': 'personal'}), mock.patch('sys.stdout'):
            self.assertEqual(pair.main(self.inference_arguments(protocol, output), transport=transport), 0)
        report = pair.strict_json((output / 'report.json').read_bytes())
        self.assertEqual(len(commands), 48)
        self.assertEqual(report['summary']['attempted'], 48)
        self.assertEqual(report['summary']['unattempted'], 0)
        self.assertTrue(all(row['correct'] for row in report['records']))
        selective = report['summary']['proxies'][pair.CHAT_MODELS[0]]['selective']
        self.assertEqual(sum(row['use_decision'] for row in selective), 2)
        self.assertEqual(selective[0]['derived_serial_seconds'], 0.5)
        self.assertEqual(selective[1]['derived_serial_seconds'], 0.25)

    def test_unknown_cleanup_stops_after_first_attempt_and_preserves_denominators(self):
        protocol = self.validate()
        transport = mock.Mock(return_value=clean_receipt(extra={'cleanup': {'attempted': True,
            'succeeded': None, 'exit_code': 0}}))
        output = self.directory / 'inference'
        with mock.patch('sys.stdout'):
            self.assertEqual(pair.main(self.inference_arguments(protocol, output), transport=transport), 1)
        report = pair.strict_json((output / 'report.json').read_bytes())
        self.assertEqual(transport.call_count, 1)
        self.assertEqual(report['status'], 'aborted')
        self.assertEqual(report['summary']['attempted'], 1)
        self.assertEqual(report['summary']['unattempted'], 47)
        self.assertEqual(report['summary']['cleanup_unknown'], 1)
        self.assertTrue(report['records'][0]['correct'])

    def test_interrupt_keeps_attempt_and_known_usage_and_never_rescues_it(self):
        protocol = self.validate()
        receipt = clean_receipt()
        transport = mock.Mock(side_effect=pair.InterruptedAttempt(receipt))
        output = self.directory / 'inference'
        with mock.patch('sys.stdout'):
            self.assertEqual(pair.main(self.inference_arguments(protocol, output), transport=transport), 130)
        report = pair.strict_json((output / 'report.json').read_bytes())
        self.assertEqual(report['summary']['attempted'], 1)
        self.assertEqual(report['records'][0]['phase'], 'interrupted')
        self.assertEqual(report['records'][0]['usage']['total_tokens'], 13)
        self.assertFalse(report['records'][0]['correct'])
        self.assertIsNone(report['records'][0]['selected_candidate'])


if __name__ == '__main__':
    unittest.main()
