#!/usr/bin/env bash
# Unit tests for scripts/openapi/validate.py.
#
# A validator that passes everything is worse than no validator: it reports
# green and nothing is checked. So every test here takes a document that passes,
# breaks exactly one thing, and asserts the validator goes red *and names it*.
# The green case is one test out of many; the rest are the proof that green
# means something.
#
# The defects reproduced are the real ones from RealityEngine_CI#403 and #402,
# not invented ones — if these fixtures stopped failing, those defects could
# come back unnoticed.
#
# Usage: bash scripts/tests/test-openapi-validate.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATE="$CI_DIR/scripts/openapi/validate.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

# A minimal document that passes every check. Each test copies this and breaks
# one thing, so a failure is unambiguously attributable to the break.
write_valid() {
  cat > "$1" <<'YAML'
openapi: 3.1.0
info:
  title: Fixture API
  version: 1.0.0
paths:
  /api/thing/{id}:
    get:
      operationId: get_thing
      parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
      responses:
        '200':
          description: Success
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Thing'
        '500':
          $ref: '#/components/responses/InternalError'
components:
  responses:
    InternalError:
      description: Internal server error
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Error'
  schemas:
    Thing:
      type: object
      properties:
        value:
          type: string
    Error:
      type: object
      properties:
        error:
          type: string
YAML
}

# expect_red <name> <pattern> — the fixture at $TMP/case.yaml must fail
# validation with a message matching <pattern>.
expect_red() {
  local name="$1" pattern="$2" out status
  out="$(python3 "$VALIDATE" "$TMP/case.yaml" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    bad "$name: validator PASSED a document that should fail"
    return
  fi
  if ! grep -qE "$pattern" <<<"$out"; then
    bad "$name: failed, but no message matching /$pattern/"
    sed 's/^/        /' <<<"$out"
    return
  fi
  ok "$name"
}

echo "openapi/validate.py"

# ── The green case ───────────────────────────────────────────────────────────
write_valid "$TMP/case.yaml"
if python3 "$VALIDATE" --quiet "$TMP/case.yaml" >/dev/null 2>&1; then
  ok "a well-formed document passes"
else
  bad "a well-formed document was rejected"
  python3 "$VALIDATE" "$TMP/case.yaml" 2>&1 | sed 's/^/        /'
fi

# ── #403: the dangling response reference ────────────────────────────────────
# `InternalError` was defined in re_components and not in pe_components, while
# build_paths attached it to every operation on both surfaces. 43 references per
# PE document, resolvable in none of them.
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
i = t.index("  responses:\n    InternalError:")
j = t.index("  schemas:")
p.write_text(t[:i] + t[j:])
PY
expect_red "a dangling \$ref is caught" "unresolved .ref.*InternalError"

# The count must be per distinct target, not per occurrence — reading Redocly's
# occurrence count as a schema count is what made #403's first report wrong.
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text().replace("#/components/schemas/Thing", "#/components/schemas/Absent")
p.write_text(t)
PY
out="$(python3 "$VALIDATE" "$TMP/case.yaml" 2>&1)"
if grep -q "1 problem" <<<"$out"; then
  ok "one missing target reports as one problem"
else
  bad "one missing target did not report as one problem"
  sed 's/^/        /' <<<"$out"
fi

# ── #402: a path template with no declared parameter ─────────────────────────
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text().replace("/api/thing/{id}:", "/api/thing/{id}/part/{partId}:")
p.write_text(t)
PY
expect_red "an undeclared path template is caught" "path template .partId. has no declared parameter"

# A parameter declared through a $ref still counts as declared — the generated
# documents use YAML anchors and component refs, and a validator that missed
# that would fail every real document.
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
t = t.replace("""      parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
""", """      parameters:
      - $ref: '#/components/parameters/ThingId'
""")
t = t.replace("""components:
  responses:""", """components:
  parameters:
    ThingId:
      name: id
      in: path
      required: true
      schema:
        type: string
  responses:""")
p.write_text(t)
PY
if python3 "$VALIDATE" --quiet "$TMP/case.yaml" >/dev/null 2>&1; then
  ok "a \$ref'd path parameter counts as declared"
else
  bad "a \$ref'd path parameter was not resolved"
  python3 "$VALIDATE" "$TMP/case.yaml" 2>&1 | sed 's/^/        /'
fi

# ── #403: 3.0 syntax inside a 3.1 document ───────────────────────────────────
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text().replace("""        value:
          type: string""", """        value:
          type: string
          nullable: true""")
p.write_text(t)
PY
expect_red "nullable in a 3.1 document is caught" "nullable.*removed in OpenAPI 3.1"

# The same keyword in a 3.0 document is correct and must NOT be flagged. This is
# the half that would have been wrong: #403 first reported the two
# RealityEngine_AI documents as defective for using valid 3.0 syntax.
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text().replace("openapi: 3.1.0", "openapi: 3.0.3").replace("""        value:
          type: string""", """        value:
          type: string
          nullable: true""")
p.write_text(t)
PY
if python3 "$VALIDATE" --quiet "$TMP/case.yaml" >/dev/null 2>&1; then
  ok "nullable in a 3.0 document is left alone"
else
  bad "nullable was flagged in a 3.0 document, where it is correct"
  python3 "$VALIDATE" "$TMP/case.yaml" 2>&1 | sed 's/^/        /'
fi

# ── The empty-paths case, which is valid OpenAPI ─────────────────────────────
# An empty `paths` map is legal, so nothing downstream objects — which is how
# the RE document generated 0 routes from prose for two months. Valid and empty
# is what a parser failure looks like.
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
t = p.read_text()
i, j = t.index("paths:"), t.index("components:")
p.write_text(t[:i] + "paths: {}\n" + t[j:])
PY
expect_red "an empty paths map is caught" "paths: empty"

# ── Colliding operationIds ───────────────────────────────────────────────────
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
block = t[t.index("  /api/thing/{id}:"):t.index("components:")]
p.write_text(t.replace(block, block + block.replace("/api/thing/{id}:", "/api/other/{id}:"), 1))
PY
expect_red "a duplicate operationId is caught" "operationId .get_thing. already used"

# An absent operationId is NOT an error — it is optional in OpenAPI, and
# requiring it failed 60 valid operations on this validator's first run.
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("      operationId: get_thing\n", ""))
PY
if python3 "$VALIDATE" --quiet "$TMP/case.yaml" >/dev/null 2>&1; then
  ok "an absent operationId is allowed"
else
  bad "an absent operationId was rejected, but it is optional"
  python3 "$VALIDATE" "$TMP/case.yaml" 2>&1 | sed 's/^/        /'
fi

# ── An operation with no responses ───────────────────────────────────────────
write_valid "$TMP/case.yaml"
python3 - "$TMP/case.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
i, j = t.index("      responses:"), t.index("components:")
p.write_text(t[:i] + t[j:])
PY
expect_red "an operation with no responses is caught" "no responses declared"

# ── Non-documents ────────────────────────────────────────────────────────────
printf 'this: [is, not\n  valid yaml\n' > "$TMP/case.yaml"
expect_red "unparseable YAML is caught" "not parseable as YAML"

printf -- "- just\n- a\n- list\n" > "$TMP/case.yaml"
expect_red "a non-mapping document is caught" "top level is not a mapping"

# ── The committed documents ──────────────────────────────────────────────────
# The point of the exercise. If this fails, the generator emits something the
# specification does not allow.
if python3 "$VALIDATE" --quiet "$CI_DIR"/docs/openapi/*.yaml >/dev/null 2>&1; then
  ok "every committed document in docs/openapi/ validates"
else
  bad "a committed document in docs/openapi/ does not validate"
  python3 "$VALIDATE" "$CI_DIR"/docs/openapi/*.yaml 2>&1 | sed 's/^/        /'
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "openapi/validate.py: $PASS passed, $FAIL FAILED"
  exit 1
fi
echo "openapi/validate.py: $PASS passed"
