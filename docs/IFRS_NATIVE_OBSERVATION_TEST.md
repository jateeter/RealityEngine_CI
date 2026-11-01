# IFRS native observations to document assessments

This is a TEST_ONLY workflow using fictional entity assets and actual native
engine emissions. It does not grant production accounting approval. The
operator's independent-signoff waiver applies only to the workflow test.

Start isolated C++, LSP and Scala RE/PE pairs using the canonical runtime
launchers and a materialized corpus containing all 225 IFRS machines. Use a
separate instance registry and instance state. Automatic source interning must
yield 225 test sources per runtime. Check exact machine membership, full-depth
ISRE/OSRE agreement and IFRS CES agreement before capturing observations.

Against those isolated, armed instances, capture one additional real PE push:

```bash
python3 scripts/capture-ifrs-native-observations.py \
  --instance-registry "$RE_REGISTRY_URL" \
  --machines "$MACHINES_REPO/machines/domains/ifrs-accounting" \
  --output "$TEST_OUTPUT/native-observations"
```

The collector requires all three voters, all 225 resident machine names, and
matching contribution membership and values. It waits for each engine's step
completion point and retains raw runtime machines, push emissions and ISRE/OSRE
pairs. Every handoff references hashes of that evidence and the exact authored
machine. Runtime sequence identities are mapped through their actual names to
authored sequence identities. The vector is the native machine's **merged
contribution**, attributed to the emitted contributing sequences; it is not a
new calculation of any sequence's output or any accounting amount.

Pass the resulting bundle to the connected verifier alongside its existing
repository, licensed source bundle, private index-state and gateway arguments:

```bash
python3 scripts/verify-ifrs-workflows.py \
  --machines "$MACHINES_REPO" --localai "$LOCALAI_REPO" \
  --openclaw "$OPENCLAW_REPO" --bundle "$LICENSED_SOURCE_BUNDLE" \
  --output "$TEST_OUTPUT/connected" --index-state "$PRIVATE_INDEX_STATE" \
  --openclaw-bin "$OPENCLAW_BIN" --live-model \
  --native-observations "$TEST_OUTPUT/native-observations/observations.json"
```

The verifier revalidates raw hashes and authored machine hashes before using
authenticated, machine-scoped `observe` calls. It checks dispatch replay,
declared document owners, assessment-only actions, unchanged document heads and
zero native writes. Selected native assessment task IDs are delivered to the
real gateway worker for eligibility and dividend reporting, including verified
RAG retrieval and canonical artifact inspection. Assessment tasks remain open
until an explicit canonical disposition is supplied; a generated draft does
not resolve an impact assessment or imply approval.

Local evidence includes `native-observation-handoffs.json`,
`native-agent-rag-assessments.json` and the connected `receipt.json`. Keep raw
licensed passages, private index state, credentials and model output outside
Git. Record only sanitized summaries and hashes in the approval ledger.

Run integrity guards with:

```bash
python3 scripts/tests/test-ifrs-native-observations.py
```
