#!/usr/bin/env python3
"""Capture native machine contributions for TEST_ONLY document assessments.

Run only against an isolated, already armed IFRS native instance registry.
One additional real PE push is measured on each voter. Merged contributions
are attributed to their actual contributing sequences, never interpreted as
accounting facts or individual sequence output calculations.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
from step_observer import StepObserver


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request(url, body=None):
    req = Request(url, data=None if body is None else json.dumps(body).encode(),
                  headers={'Content-Type': 'application/json'})
    with urlopen(req, timeout=60) as response:
        return response.status, json.load(response)


def validate_bundle(path, machines):
    """Revalidate immutable raw emissions before accepting a handoff bundle."""
    path = Path(path)
    bundle = json.loads(path.read_text())
    assert bundle['approvalContext'] == 'TEST_ONLY' and bundle['productionApproval'] is False
    assert set(bundle['runtimes']) == {'cpp', 'lsp', 'scala'}
    assert bundle['observations'], 'No native observations captured'
    raw_evidence = {}
    for relative, expected in bundle['rawSHA256'].items():
        target = (path.parent / relative).resolve()
        assert target.is_relative_to(path.parent.resolve()), 'Raw evidence path escaped bundle'
        assert digest(target) == expected, 'Native raw evidence hash mismatch'
        raw_evidence[relative] = json.loads(target.read_text())
    for mid, expected in bundle['machineSHA256'].items():
        assert Path(mid).name == mid
        assert digest(Path(machines) / (mid + '.json')) == expected, 'Machine definition changed'
    for observation in bundle['observations']:
        mid, seq = observation['machineId'], observation['sequenceId']
        authored = json.loads((Path(machines) / (mid + '.json')).read_text())['machine']
        assert seq in {s['id'] for s in authored['sequences']}
        for runtime, ref in observation['providers'].items():
            raw = raw_evidence[ref['rawFile']]
            assert raw['runtime'] == runtime, 'Native runtime provenance changed'
            operation = raw['push']['step']['mergeBatch'][ref['operationIndex']]
            assert operation['machineName'] == mid
            assert ref['runtimeSequenceId'] in operation['sequenceIds']
            runtime_machine = next(m for m in raw['machines'] if m['id'] == operation['machineId'])
            runtime_sequence = next(s for s in runtime_machine['sequences'] if s['id'] == ref['runtimeSequenceId'])
            source_sequence = next(s for s in authored['sequences'] if s['id'] == seq)
            assert runtime_sequence['name'] == source_sequence['name'], 'Native sequence attribution changed'
            assert operation['values'] == observation['outputVector'], 'Native contribution changed'
            assert operation['region'] == authored['perceptualMapping']['output']
            assert raw['pair']['stepNumber'] == raw['push']['step']['stepNumber']
        assert set(observation['providers']) == {'cpp', 'lsp', 'scala'}
        assert observation['providerRef'] == 'native:sha256:' + bundle['rawSHA256'][observation['providers']['cpp']['rawFile']] + ':' + mid + ':' + seq
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-registry', required=True)
    parser.add_argument('--machines', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    instances = request(args.instance_registry)[1]['instances']
    instances = [i for i in instances if i.get('role') != 'follower']
    assert len(instances) == 3 and {i['runtime'] for i in instances} == {'cpp', 'lsp', 'scala'}
    authored = {p.stem: json.loads(p.read_text())['machine'] for p in args.machines.glob('*.json')}
    assert len(authored) == 225, 'Expected full IFRS corpus'
    raw_hashes, emissions = {}, {}
    for instance in instances:
        runtime = instance['runtime']
        machines = request(instance['re_url'] + '/api/machines')[1]['machines']
        assert {m['name'] for m in machines} == set(authored), 'Native machine membership differs'
        status, push = request(instance['pe_url'] + '/api/push', {'compact': True, 'includePerceptualSpace': False, 'includeActiveRegions': False})
        observer = StepObserver(lambda url: request(url), instance['re_url'])
        isre, osre = observer.observe_push(push)
        assert not observer.violations
        raw = {'runtime': runtime, 'instance': instance, 'machines': machines, 'push': push,
               'pair': {'stepNumber': push['step']['stepNumber'], 'isre': isre, 'osre': osre}}
        filename = runtime + '-native.json'
        (out / filename).write_text(json.dumps(raw, indent=2) + '\n')
        raw_hashes[filename] = digest(out / filename)
        known = {m['id']: m for m in machines}
        normalized = {}
        for index, operation in enumerate(push['step']['mergeBatch']):
            mid = operation['machineName']; machine = known[operation['machineId']]
            source = authored[mid]
            by_name = {s['name']: s['id'] for s in source['sequences']}
            runtime_sequences = {s['id']: s for s in machine['sequences']}
            for sid in operation['sequenceIds']:
                seq = runtime_sequences[sid]
                canonical_id = sid if sid in {s['id'] for s in source['sequences']} else by_name[seq['name']]
                values = operation['values']
                assert len(values) == source['perceptualMapping']['output']['length']
                assert all(type(v) in (int, float) and v in (0, .5, 1) for v in values)
                normalized[(mid, canonical_id)] = (values, {'rawFile': filename, 'operationIndex': index, 'runtimeSequenceId': sid})
        assert {key[0] for key in normalized} == set(authored), 'Native push did not emit all 225 machines'
        emissions[runtime] = normalized
    keys = set.union(*(set(e) for e in emissions.values()))
    assert all(set(e) == keys for e in emissions.values()), 'Native contributor membership disagrees'
    observations = []
    for mid, sid in sorted(keys):
        values = [emissions[r][(mid, sid)][0] for r in ('cpp', 'lsp', 'scala')]
        assert values[0] == values[1] == values[2], 'Native contribution disagreement: ' + mid
        providers = {r: emissions[r][(mid, sid)][1] for r in emissions}
        observations.append({'machineId': mid, 'sequenceId': sid, 'outputVector': values[0],
                             'providerRef': 'native:sha256:' + raw_hashes['cpp-native.json'] + ':' + mid + ':' + sid,
                             'providers': providers, 'outputSemantics': 'machine-merged-contribution'})
    bundle = {'approvalContext': 'TEST_ONLY', 'productionApproval': False,
              'evidenceClass': 'ACTUAL_NATIVE_SYNTHETIC_STIMULUS', 'runtimes': sorted(emissions),
              'rawSHA256': raw_hashes, 'machineSHA256': {mid: digest(args.machines / (mid + '.json')) for mid in authored},
              'observations': observations}
    path = out / 'observations.json'; path.write_text(json.dumps(bundle, indent=2) + '\n')
    validate_bundle(path, args.machines)
    print(f'PASS: {len(observations)} actual native contribution observations, 225 machines, 3-of-3 agreement')


if __name__ == '__main__':
    main()
