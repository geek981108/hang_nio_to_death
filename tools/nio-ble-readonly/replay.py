"""Bounded offline BLE notification replay; no radio, credentials or writes."""
import argparse
import json
import math
import sys

from decoder import DecodeError, Reassembler


class ReplayError(ValueError):
    def __init__(self, line, reason):
        # Reasons are controlled strings, never input lines or packet bytes.
        super().__init__(f"line {line}: {reason}")
        self.line = line
        self.reason = reason


def read_events(stream):
    """JSONL with a hard line limit before parsing, including the final line."""
    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON field")
            result[key] = value
        return result

    line = 0
    while True:
        raw = stream.readline(70001)
        if not raw:
            return
        line += 1
        if len(raw) > 70000:
            raise ReplayError(line, "event exceeds line limit")
        try:
            yield json.loads(raw, object_pairs_hook=unique_fields)
        except (ValueError, RecursionError):
            raise ReplayError(line, "invalid JSON event") from None


def replay(events, *, decode_packet=None):
    """Replay one connection at a time, failing at the first ambiguous event.

    Optional decode_packet(generation, Envelope) supplies an independent decoder
    in memory. The CLI performs framing only. No callback result verifies peer
    authentication; only vehicle field results are retained, never packet bytes.
    """
    reader = None
    used = set()
    last_time = None
    packets = []
    connections = 0
    line = 0
    for line, event in enumerate(events, 1):
        if line > 100000:
            raise ReplayError(line, "event count limit exceeded")
        if not isinstance(event, dict):
            raise ReplayError(line, "event must be an object")
        kind = event.get("event")
        required = {"event", "generation", "timestamp"}
        if kind == "notification":
            required.add("hex")
        elif kind not in ("connect", "disconnect"):
            raise ReplayError(line, "unsupported event type")
        if set(event) != required:
            raise ReplayError(line, "unexpected or missing event fields")
        generation = event["generation"]
        timestamp = event["timestamp"]
        if not isinstance(generation, str) or not 1 <= len(generation) <= 128:
            raise ReplayError(line, "invalid connection generation")
        if type(timestamp) not in (int, float):
            raise ReplayError(line, "invalid timestamp")
        try:
            valid_time = math.isfinite(timestamp) and timestamp >= 0
        except OverflowError:
            valid_time = False
        if not valid_time or (last_time is not None and timestamp < last_time):
            raise ReplayError(line, "invalid timestamp order")
        last_time = timestamp
        if kind == "connect":
            if reader is not None:
                raise ReplayError(line, "previous connection has not disconnected")
            if generation in used:
                raise ReplayError(line, "connection generation reused")
            used.add(generation)
            connections += 1
            reader = Reassembler(generation)
            continue
        if reader is None or reader.generation != generation:
            raise ReplayError(line, "event does not belong to active connection")
        if kind == "disconnect":
            incomplete = bool(reader.buffer)
            reader.close()
            reader = None
            if incomplete:
                raise ReplayError(line, "disconnect discarded an incomplete frame")
            continue
        encoded = event["hex"]
        if (not isinstance(encoded, str) or not encoded or len(encoded) > 65542
                or len(encoded) % 2
                or any(c not in "0123456789abcdefABCDEF" for c in encoded)):
            raise ReplayError(line, "invalid notification hex")
        try:
            packet = reader.feed(bytes.fromhex(encoded), generation=generation,
                                 timestamp=timestamp)
        except DecodeError as error:
            # Reassembler emits fixed diagnostics without input bytes.
            raise ReplayError(line, "notification reassembly failed: " + str(error)) from None
        if packet is None:
            continue
        result = {"line": line, "connection": connections,
                  "timestamp": timestamp, "category": packet.category,
                  "payload_bytes": len(packet.payload)}
        if decode_packet is not None:
            try:
                decoded = decode_packet(generation, packet)
                result["vehicle"] = decoded["vehicle"]
            except Exception:
                # Callback errors can include session material; do not echo them.
                raise ReplayError(line, "packet decoding failed") from None
        packets.append(result)
    if reader is not None and reader.buffer:
        raise ReplayError(line + 1, "recording ends with an incomplete frame")
    return {"mode": "decoded" if decode_packet else "framing_only",
            "authentication_verified": False, "vehicle_verified": False,
            "connections": connections, "connection_open_at_end": reader is not None,
            "packets": packets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", help="JSONL file; '-' reads stdin")
    args = parser.parse_args()
    try:
        if args.recording == "-":
            report = replay(read_events(sys.stdin))
        else:
            with open(args.recording, encoding="utf-8") as stream:
                report = replay(read_events(stream))
    except ReplayError as error:
        print(json.dumps({"ok": False, "line": error.line, "error": error.reason}))
        return 2
    except (OSError, UnicodeError):
        print(json.dumps({"ok": False, "error": "cannot read recording"}))
        return 2
    print(json.dumps({"ok": True, **report}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
