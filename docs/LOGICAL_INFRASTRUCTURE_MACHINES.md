# Logical Infrastructure Machines

The `DLX001`-`DLX050` machines extend the original five general-purpose
`digital-logic` examples into a reusable library of 55 logical infrastructure
machines.

These machines are intended as connective tissue for the Reality Engine
universe. They implement common ASIC-style temporal regular expressions over
4-bit control/status lanes and emit compact 2-bit match lanes.

## Contract

Each `DLX` machine uses:

- Input: 4D binary lane `[primary, secondary, tertiary, qualifier]`
- Output: 2D binary lane
  - `[1,0]` = regular expression matched
  - `[0,1]` = reserved for downstream clear/available semantics
- Category: `digital-logic`
- Domain: `Digital Logic - Infrastructure`

Every machine includes `inputSequences` with explicit output assertions, so the
C++ e2e corpus validates the authored regular expression behavior.

## Regex Catalog

The generated set covers 50 common temporal patterns used in ASIC control,
power, reset, bus, CDC, FIFO, scan, and safety logic:

| ID | Pattern | Regex |
| --- | --- | --- |
| `DLX001` | Rising Edge Detector | `0*1` |
| `DLX002` | Falling Edge Detector | `1*0` |
| `DLX003` | Single Cycle Pulse | `0*10` |
| `DLX004` | Pulse Stretch Start | `01+` |
| `DLX005` | Pulse Stretch End | `1+0` |
| `DLX006` | Glitch Reject Two High | `0*11` |
| `DLX007` | Glitch Detect One High | `010` |
| `DLX008` | Stable High Window | `1{3}` |
| `DLX009` | Stable Low Window | `0{3}` |
| `DLX010` | Alternating Toggle | `(01)+` |
| `DLX011` | Req Ack Handshake | `REQ ACK` |
| `DLX012` | Req Hold Ack | `REQ+ ACK` |
| `DLX013` | Req Ack Done | `REQ ACK DONE` |
| `DLX014` | Valid Ready Transfer | `VALID READY` |
| `DLX015` | Valid Before Ready | `VALID+ READY` |
| `DLX016` | Ready Before Valid | `READY+ VALID` |
| `DLX017` | Start Busy Done | `START BUSY+ DONE` |
| `DLX018` | Start Done No Busy | `START DONE` |
| `DLX019` | Reset Assert Release | `RST+ !RST` |
| `DLX020` | Reset Sync Two Stage | `RST 10 11` |
| `DLX021` | Enable Qualified Valid | `EN VALID` |
| `DLX022` | Enable Disable Cycle | `EN+ DIS` |
| `DLX023` | Clock Gate Request Grant | `CG_REQ CG_ACK` |
| `DLX024` | Clock Gate Open Close | `OPEN+ CLOSE` |
| `DLX025` | Power Up Sequence | `PWR ISO RET CLK` |
| `DLX026` | Power Down Sequence | `CLKOFF RET ISO PWRDN` |
| `DLX027` | Isolation Enable Before Powerdown | `ISO PWRDN` |
| `DLX028` | Retention Save Restore | `SAVE RESTORE` |
| `DLX029` | Scan Shift Capture | `SHIFT+ CAPTURE` |
| `DLX030` | Scan Enable Deassert | `SCAN_EN+ !SCAN_EN` |
| `DLX031` | Jtag Select Capture Shift Update | `SEL CAP SHIFT UPDATE` |
| `DLX032` | Interrupt Assert Clear | `IRQ+ CLR` |
| `DLX033` | Error Sticky Clear | `ERR+ CLR` |
| `DLX034` | Watchdog Kick Window | `ARM KICK` |
| `DLX035` | Watchdog Timeout | `ARM !KICK !KICK` |
| `DLX036` | Timeout Retry Success | `TIMEOUT RETRY ACK` |
| `DLX037` | Fifo Empty To Not Empty | `EMPTY WRITE` |
| `DLX038` | Fifo Almost Full Full | `AFULL FULL` |
| `DLX039` | Fifo Full To Not Full | `FULL READ` |
| `DLX040` | Credit Decrement Increment | `DEC+ INC` |
| `DLX041` | One Hot Grant | `REQ GRANT_ONEHOT` |
| `DLX042` | Mutex Lock Unlock | `LOCK+ UNLOCK` |
| `DLX043` | Arbiter Request Grant Release | `REQ GRANT RELEASE` |
| `DLX044` | Bus Address Data Valid | `ADDR DATA VALID` |
| `DLX045` | Bus Burst Last | `BEAT+ LAST` |
| `DLX046` | Write Response | `WVALID BVALID` |
| `DLX047` | Read Response | `ARVALID RVALID` |
| `DLX048` | Cdc Stable Two Sample | `A A` |
| `DLX049` | Cdc Toggle Ack | `TOGGLE ACK_TOGGLE` |
| `DLX050` | Metastability Settled | `X0 X0 STABLE` |

## Reuse Guidelines

Use these machines when a domain machine needs a common temporal guard before it
should fire or dispatch downstream action.

Recommended uses:

- Place a `DLX` machine between noisy upstream signals and sensitive downstream
  machines.
- Use edge, pulse, and debounce machines to convert raw sensor or PE source
  changes into clean events.
- Use handshake and valid/ready machines to coordinate multi-machine workflows.
- Use reset, power, scan, and CDC machines to model infrastructure safety
  conditions before enabling domain logic.
- Use FIFO, credit, bus, and arbiter machines as reusable transaction gates.
- Route a `DLX` output `[1,0]` into a downstream input lane when the downstream
  machine should only proceed after the regex has matched.

Avoid mapping unrelated machine outputs into the same `DLX` input lane unless
the overlap is intentional and documented. A shared lane is a real connection,
not an annotation.

## Regeneration

Run:

```bash
python3 scripts/generate_logical_infrastructure_machines.py
node scripts/repack_machine_connection_matrix.mjs
```

The repack step preserves existing overlaps while removing unused coordinate
positions from the global example-machine matrix.
