#!/usr/bin/env python3
"""Undo what an MQTT stage leaves on each PE (rust-conformance.sh mqtt-yuma).

    mqtt_sensors.py snapshot <instance-data> <file>
        record each PE's source ids before the stage.
    mqtt_sensors.py restore <instance-data> <file>
        disable each PE's bridge, and delete the `mqtt:` sources it holds that
        the snapshot did not, so the next run sees the PE as it was.

A PE that does not answer is reported and skipped; this is cleanup, never a
verdict.
"""
import json
import sys
import urllib.request


def call(method, url):
    req = urllib.request.Request(url, method=method, headers={"Content-Type": "application/json"},
                                 data=b"{}" if method == "POST" else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
    return json.loads(body) if body else None


def pes(path):
    return [(i["id"], i["pe_url"].rstrip("/")) for i in json.load(open(path))["instances"] if i.get("pe_url")]


def main():
    mode, registry, file = sys.argv[1:4]
    if mode == "snapshot":
        held = {}
        for iid, url in pes(registry):
            try:
                held[iid] = [s["id"] for s in call("GET", url + "/api/sources")["sources"]]
            except Exception as exc:  # noqa: BLE001
                print(f"mqtt_sensors: {iid}: sources unreadable ({exc})")
        json.dump(held, open(file, "w"))
        return 0
    held = json.load(open(file))
    for iid, url in pes(registry):
        try:
            call("POST", url + "/api/mqtt/disable")
            before = set(held.get(iid, []))
            gone = 0
            for s in call("GET", url + "/api/sources")["sources"]:
                if s["id"] not in before and str(s.get("name", "")).startswith("mqtt:"):
                    call("DELETE", f"{url}/api/sources/{s['id']}")
                    gone += 1
            print(f"mqtt_sensors: {iid}: bridge disabled, {gone} mqtt: source(s) removed")
        except Exception as exc:  # noqa: BLE001
            print(f"mqtt_sensors: {iid}: cleanup failed ({exc})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
