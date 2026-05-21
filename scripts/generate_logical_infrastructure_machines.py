#!/usr/bin/env python3
"""
Generate reusable digital-logic infrastructure machines.

Each machine implements a common ASIC-style temporal regular expression over a
4-bit control/status input lane and emits a 2-bit result:
  [1,0] = pattern matched
  [0,1] = reserved for downstream reuse/clear semantics
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"

SPECS = [
    ("Rising Edge Detector", "0*1", "Detects low-to-high transition on a control bit.", [[0, 0, 0, 0], [1, 0, 0, 0]]),
    ("Falling Edge Detector", "1*0", "Detects high-to-low transition on a control bit.", [[1, 0, 0, 0], [0, 0, 0, 0]]),
    ("Single Cycle Pulse", "0*10", "Detects a one-cycle pulse returning low.", [[0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0]]),
    ("Pulse Stretch Start", "01+", "Detects a pulse that remains asserted for multiple cycles.", [[0, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]]),
    ("Pulse Stretch End", "1+0", "Detects the end of a stretched pulse.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0]]),
    ("Glitch Reject Two High", "0*11", "Accepts high only after two consecutive asserted samples.", [[0, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]]),
    ("Glitch Detect One High", "010", "Detects a narrow one-cycle glitch.", [[0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0]]),
    ("Stable High Window", "1{3}", "Detects three consecutive stable-high samples.", [[1, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]]),
    ("Stable Low Window", "0{3}", "Detects three consecutive stable-low samples.", [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]]),
    ("Alternating Toggle", "(01)+", "Detects repeated low/high toggling.", [[0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0], [1, 0, 0, 0]]),
    ("Req Ack Handshake", "REQ ACK", "Detects request followed by acknowledge.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Req Hold Ack", "REQ+ ACK", "Detects held request followed by acknowledge.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Req Ack Done", "REQ ACK DONE", "Detects request, acknowledge, then completion.", [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
    ("Valid Ready Transfer", "VALID READY", "Detects valid/ready transfer acceptance.", [[1, 0, 0, 0], [1, 1, 0, 0]]),
    ("Valid Before Ready", "VALID+ READY", "Detects valid waiting until ready arrives.", [[1, 0, 0, 0], [1, 0, 0, 0], [1, 1, 0, 0]]),
    ("Ready Before Valid", "READY+ VALID", "Detects ready asserted before valid arrives.", [[0, 1, 0, 0], [0, 1, 0, 0], [1, 1, 0, 0]]),
    ("Start Busy Done", "START BUSY+ DONE", "Detects start, one or more busy cycles, then done.", [[1, 0, 0, 0], [0, 1, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
    ("Start Done No Busy", "START DONE", "Detects immediate completion after start.", [[1, 0, 0, 0], [0, 0, 1, 0]]),
    ("Reset Assert Release", "RST+ !RST", "Detects reset assertion followed by release.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0]]),
    ("Reset Sync Two Stage", "RST 10 11", "Detects two-stage reset synchronizer release.", [[1, 0, 0, 0], [0, 1, 0, 0], [0, 1, 1, 0]]),
    ("Enable Qualified Valid", "EN VALID", "Detects valid only after enable.", [[0, 1, 0, 0], [1, 1, 0, 0]]),
    ("Enable Disable Cycle", "EN+ DIS", "Detects enable interval followed by disable.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Clock Gate Request Grant", "CG_REQ CG_ACK", "Detects clock-gate request acknowledged.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Clock Gate Open Close", "OPEN+ CLOSE", "Detects clock gate open interval then close.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Power Up Sequence", "PWR ISO RET CLK", "Detects power, isolation, retention, clock sequence.", [[1, 0, 0, 0], [1, 1, 0, 0], [1, 1, 1, 0], [1, 1, 1, 1]]),
    ("Power Down Sequence", "CLKOFF RET ISO PWRDN", "Detects ordered low-power entry.", [[0, 0, 0, 1], [0, 0, 1, 1], [0, 1, 1, 1], [1, 1, 1, 1]]),
    ("Isolation Enable Before Powerdown", "ISO PWRDN", "Detects isolation before power-down.", [[0, 1, 0, 0], [1, 1, 0, 0]]),
    ("Retention Save Restore", "SAVE RESTORE", "Detects state save followed by restore.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Scan Shift Capture", "SHIFT+ CAPTURE", "Detects scan shift interval followed by capture.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Scan Enable Deassert", "SCAN_EN+ !SCAN_EN", "Detects end of scan mode.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0]]),
    ("Jtag Select Capture Shift Update", "SEL CAP SHIFT UPDATE", "Detects common JTAG state progression.", [[1, 0, 0, 0], [1, 1, 0, 0], [1, 1, 1, 0], [1, 1, 1, 1]]),
    ("Interrupt Assert Clear", "IRQ+ CLR", "Detects interrupt assertion followed by clear.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Error Sticky Clear", "ERR+ CLR", "Detects sticky error followed by explicit clear.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Watchdog Kick Window", "ARM KICK", "Detects watchdog armed then kicked.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Watchdog Timeout", "ARM !KICK !KICK", "Detects armed watchdog with missing kick window.", [[1, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]]),
    ("Timeout Retry Success", "TIMEOUT RETRY ACK", "Detects retry recovery after timeout.", [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
    ("Fifo Empty To Not Empty", "EMPTY WRITE", "Detects FIFO leaving empty state.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Fifo Almost Full Full", "AFULL FULL", "Detects FIFO pressure escalation.", [[1, 0, 0, 0], [1, 1, 0, 0]]),
    ("Fifo Full To Not Full", "FULL READ", "Detects FIFO relief after read.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Credit Decrement Increment", "DEC+ INC", "Detects credit consumption followed by return.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("One Hot Grant", "REQ GRANT_ONEHOT", "Detects request followed by one-hot grant.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Mutex Lock Unlock", "LOCK+ UNLOCK", "Detects mutual exclusion lock interval followed by unlock.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Arbiter Request Grant Release", "REQ GRANT RELEASE", "Detects arbitration service lifecycle.", [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
    ("Bus Address Data Valid", "ADDR DATA VALID", "Detects address phase, data phase, valid phase.", [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
    ("Bus Burst Last", "BEAT+ LAST", "Detects one or more bus beats followed by last.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Write Response", "WVALID BVALID", "Detects write data accepted then response valid.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Read Response", "ARVALID RVALID", "Detects read address accepted then read data valid.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Cdc Stable Two Sample", "A A", "Detects two equal synchronized samples.", [[1, 0, 0, 0], [1, 0, 0, 0]]),
    ("Cdc Toggle Ack", "TOGGLE ACK_TOGGLE", "Detects CDC toggle followed by returned acknowledge toggle.", [[1, 0, 0, 0], [0, 1, 0, 0]]),
    ("Metastability Settled", "X0 X0 STABLE", "Detects synchronizer settling after uncertain samples.", [[1, 0, 0, 0], [1, 0, 0, 0], [0, 1, 0, 0]]),
]


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def machine_payload(index: int, name: str, regex: str, description: str, pattern: list[list[int]]) -> dict:
    base = 925 + (index - 1) * 6
    input_offset = base
    output_offset = base + 4
    code = f"dlx-{index:03d}"
    machine_name = f"Logical Infrastructure {name}"

    vectors = []
    for step, values in enumerate(pattern, start=1):
        terminal = step == len(pattern)
        vector_id = f"{code}-step-{step}"
        entry = {
            "id": vector_id,
            "elements": vector_elements(values),
            "isInitial": step == 1,
            "metadata": {
                "name": f"STEP_{step}",
                "description": f"{name} regex step {step}: {values}",
            },
        }
        if not terminal:
            entry["nextVectorIds"] = [f"{code}-step-{step + 1}"]
        else:
            entry["outputVectors"] = [{
                "id": f"{code}-match-output",
                "vector": [1, 0],
                "metadata": {
                    "description": f"{name} matched regular expression {regex}.",
                    "state": "MATCH",
                },
            }]
        vectors.append(entry)

    return {
        "version": "1.0.0",
        "machine": {
            "name": machine_name,
            "description": (
                f"Reusable digital-logic infrastructure machine for ASIC-style connective tissue. "
                f"It implements the temporal regular expression `{regex}`. {description} "
                f"Reads a 4D control/status lane at [{input_offset}:{input_offset + 4}] and emits "
                f"a 2D match lane at [{output_offset}:{output_offset + 2}]."
            ),
            "metadata": {
                "category": "digital-logic",
                "domain": "Digital Logic - Infrastructure",
                "author": "Reality Engine",
                "regularExpression": regex,
                "asicPattern": name,
                "reuseRole": "general-purpose logical connective tissue",
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": f"2D binary at [{output_offset}:{output_offset + 2}]: [1,0]=MATCH, [0,1]=CLEAR_OR_AVAILABLE",
                "inputSemantics": ["primary", "secondary", "tertiary", "qualifier"],
                "tags": [
                    "digital-logic",
                    "logical-infrastructure",
                    "asic-pattern",
                    "regular-expression",
                    slug(name),
                ],
                "sequenceCount": 1,
                "reuseGuideline": (
                    "Use this machine by mapping upstream source or machine output bits into its 4D input lane. "
                    "Map its 2D output lane into downstream machine input when a reusable temporal guard, latch trigger, "
                    "handshake detector, CDC detector, bus phase detector, or safety qualifier is needed."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 2},
            },
            "sequences": [
                {
                    "id": f"{code}-match",
                    "name": f"{name}: {regex} -> MATCH",
                    "metadata": {
                        "description": description,
                        "regularExpression": regex,
                        "output": "[1,0]",
                    },
                    "vectors": vectors,
                }
            ],
            "inputSequences": [
                {
                    "name": f"{name} match path",
                    "description": f"Validates regular expression {regex}.",
                    "vectors": pattern,
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[1,0]",
                        "scenario": slug(name),
                    },
                },
                {
                    "name": "Baseline without output",
                    "description": "Single baseline sample does not complete the expression.",
                    "vectors": [pattern[0]],
                    "metadata": {
                        "expectedOutputCount": 0,
                        "scenario": "baseline-no-output",
                    },
                },
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for index, (name, regex, description, pattern) in enumerate(SPECS, start=1):
        path = OUT_DIR / f"DLX{index:03d}_{slug(name)}.json"
        path.write_text(json.dumps(machine_payload(index, name, regex, description, pattern), indent=2) + "\n")
    print(f"Generated {len(SPECS)} logical infrastructure machines in {OUT_DIR}")


if __name__ == "__main__":
    main()
