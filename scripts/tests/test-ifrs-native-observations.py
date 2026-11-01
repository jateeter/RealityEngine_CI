"""Integrity and sequence-attribution guards; explicitly synthetic unit fixtures."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('capture', Path(__file__).resolve().parents[1] / 'capture-ifrs-native-observations.py')
capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)


class NativeObservationIntegrity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.machines = self.root / 'machines'; self.machines.mkdir()
        machine = {'id': 'UNIT', 'sequences': [{'id': 'source-seq', 'name': 'first'}, {'id': 'other-seq', 'name': 'second'}], 'perceptualMapping': {'output': {'offset': 12, 'length': 1}}}
        path = self.machines / 'UNIT.json'; path.write_text(json.dumps({'machine': machine}))
        hashes, providers = {}, {}
        for runtime in ['cpp', 'lsp', 'scala']:
            raw = {'runtime': runtime, 'machines': [{'id': 'runtime-machine', 'sequences': [{'id': 'runtime-seq', 'name': 'first'}]}],
                   'push': {'step': {'stepNumber': 1, 'mergeBatch': [{'machineId': 'runtime-machine', 'machineName': 'UNIT', 'sequenceIds': ['runtime-seq'], 'values': [.5], 'region': {'offset': 12, 'length': 1}}]}}, 'pair': {'stepNumber': 1}}
            file = runtime + '.json'; (self.root / file).write_text(json.dumps(raw))
            hashes[file] = capture.digest(self.root / file)
            providers[runtime] = {'rawFile': file, 'operationIndex': 0, 'runtimeSequenceId': 'runtime-seq'}
        self.bundle = {'approvalContext': 'TEST_ONLY', 'productionApproval': False, 'runtimes': ['cpp', 'lsp', 'scala'], 'rawSHA256': hashes, 'machineSHA256': {'UNIT': capture.digest(path)},
                       'observations': [{'machineId': 'UNIT', 'sequenceId': 'source-seq', 'outputVector': [.5], 'providers': providers, 'providerRef': 'native:sha256:' + hashes['cpp.json'] + ':UNIT:source-seq'}]}
        self.path = self.root / 'observations.json'

    def check(self, bundle=None):
        self.path.write_text(json.dumps(bundle or self.bundle))
        return capture.validate_bundle(self.path, self.machines)

    def test_valid_hash_bound_three_runtime_evidence(self):
        self.check()

    def test_raw_tamper_rejected(self):
        (self.root / 'cpp.json').write_text('{}')
        with self.assertRaisesRegex(AssertionError, 'hash mismatch'): self.check()

    def test_wrong_native_vector_rejected(self):
        self.bundle['observations'][0]['outputVector'] = [1]
        with self.assertRaisesRegex(AssertionError, 'contribution changed'): self.check()

    def test_valid_but_wrong_authored_sequence_rejected(self):
        self.bundle['observations'][0]['sequenceId'] = 'other-seq'
        with self.assertRaisesRegex(AssertionError, 'sequence attribution'): self.check()

    def test_two_runtime_evidence_rejected(self):
        self.bundle['runtimes'].remove('lsp')
        with self.assertRaises(AssertionError): self.check()

    def test_one_runtime_cannot_impersonate_three(self):
        self.bundle['observations'][0]['providers']['lsp'] = self.bundle['observations'][0]['providers']['cpp']
        with self.assertRaisesRegex(AssertionError, 'runtime provenance'): self.check()

    def test_machine_revision_drift_rejected(self):
        (self.machines / 'UNIT.json').write_text('{}')
        with self.assertRaisesRegex(AssertionError, 'definition changed'): self.check()

    def test_raw_path_escape_rejected(self):
        self.bundle['rawSHA256']['../outside.json'] = 'invalid'
        with self.assertRaisesRegex(AssertionError, 'escaped'): self.check()

    def test_production_approval_rejected(self):
        self.bundle['productionApproval'] = True
        with self.assertRaises(AssertionError): self.check()


if __name__ == '__main__':
    unittest.main()
