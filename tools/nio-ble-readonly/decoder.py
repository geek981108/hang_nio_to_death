"""Offline analysis only. No Bluetooth, network, keys, or vehicle commands.

Envelope bytes and authenticated plaintext are deliberately separate inputs.
This module does NOT establish authentication. Optional NT2 decryption requires
caller-supplied session material; no extraction or key discovery is implemented.
"""
from dataclasses import dataclass
import math


class DecodeError(ValueError):
    pass


@dataclass(frozen=True)
class Envelope:
    category: int
    payload: bytes


def decode_envelope(raw: bytes) -> Envelope:
    if len(raw) < 5 or raw[0] != 4:
        raise DecodeError("invalid or incomplete envelope header")
    # HexExtKt.l uses Java BigInteger(byte[]), i.e. signed big endian.
    length = int.from_bytes(raw[2:4], "big", signed=True)
    if length <= 0 or length != len(raw) - 4:
        raise DecodeError("envelope length mismatch")
    return Envelope(raw[1], raw[4:])


class Reassembler:
    """One instance per connection generation. Reject ambiguity; never resync by guessing.

    Caller supplies monotonically increasing timestamps. A stale generation cannot
    feed this instance. Bounds and reset-on-error are deliberate defensive behavior,
    not a claim that the Android implementation has identical failure handling.
    """
    def __init__(self, generation: str, timeout: float = 30.0):
        if not generation or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("invalid reassembly context")
        self.generation = generation
        self.timeout = timeout
        self.last_time = None
        self.closed = False
        self.reset()

    def reset(self):
        self.buffer = b""
        self.expected = 0
        self.started = None

    def close(self):
        """Invalidate this connection, discard fragments and reject late callbacks."""
        self.reset()
        self.closed = True

    def feed(self, chunk: bytes, *, generation: str, timestamp: float):
        if self.closed:
            raise DecodeError("connection is closed; create a new reassembler")
        if generation != self.generation:
            raise DecodeError("stale connection generation")
        if not math.isfinite(timestamp) or (
            self.last_time is not None and timestamp < self.last_time
        ):
            self.reset()
            raise DecodeError("invalid timestamp order")
        self.last_time = timestamp
        if not chunk:
            self.reset()
            raise DecodeError("empty fragment")
        if self.buffer and timestamp - self.started > self.timeout:
            self.reset()
            raise DecodeError("fragment window expired; current fragment discarded")
        if not self.buffer:
            if len(chunk) < 5 or chunk[0] != 4:
                raise DecodeError("first fragment must contain header and payload")
            length = int.from_bytes(chunk[2:4], "big", signed=True)
            if length <= 0:
                raise DecodeError("invalid signed payload length")
            self.expected = length + 4
            self.started = timestamp
        if len(self.buffer) + len(chunk) > self.expected:
            self.reset()
            raise DecodeError("overlong or coalesced fragments")
        self.buffer += chunk
        if len(self.buffer) != self.expected:
            return None
        packet = self.buffer
        self.reset()
        return decode_envelope(packet)


def parse_ltv(payload: bytes):
    """L counts type + value, not its own byte; signed-byte L in recovered code."""
    result = []
    offset = 0
    while offset < len(payload):
        length = payload[offset]
        if not 2 <= length <= 127 or offset + length + 1 > len(payload):
            raise DecodeError(f"invalid LTV at offset {offset}")
        result.append((payload[offset + 1], payload[offset + 2:offset + length + 1]))
        offset += length + 1
    return result


def signed_byte(value):
    return value if value < 128 else value - 256


def decode_veh_data(raw: bytes):
    if len(raw) != 19:
        raise DecodeError("VehData version requires exactly 19 bytes")
    fields = (
        "vehState", "comfEna", "cenLockUnlockSts", "doorAjarFrntLeSts",
        "doorAjarFrntRiSts", "doorAjarReLeSts", "doorAjarReRiSts",
        "hoodAjarSts", "trAjarSts", "findMeStatus", "winFrntLePosn",
        "winFrntRiPosn", "winReLePosn", "winReRiPosn", "sunroofPosnStsApp",
    )
    literal = {name: signed_byte(raw[i]) for i, name in enumerate(fields)}
    literal["comfEna"] = raw[1] != 0
    literal["findMeStatus"] = raw[9] != 0
    literal["bmsCustomerUsageSoc"] = signed_byte(raw[15]) * 0.5
    literal["bmsChrgState"] = signed_byte(raw[16])
    literal["vcuRemainingRng"] = int.from_bytes(raw[17:19], "big", signed=True)
    warnings = []
    if raw[15] >= 128:
        warnings.append("SOC_SIGNEDNESS_UNRESOLVED: recovered constructor yields negative SOC")
    if raw[17] >= 128:
        warnings.append("NEGATIVE_RANGE_LITERAL: physical interpretation unverified")
    # No unsigned correction or replacement with zero. Keep source literal separate.
    return {"source_literal": literal, "warnings": warnings,
            "semantics": "recovered_default_method_only_not_live_verified"}


def decode_nt2_vehicle_plaintext(payload: bytes):
    """Input MUST be post-authentication, post-decryption NT2 vehicle plaintext.

    This entry point cannot establish provenance; callers must not pass encrypted
    envelope.payload and claim that decoding proves authentication.
    """
    entries = parse_ltv(payload)
    known = {}
    unknown_types = []
    for tag, value in entries:
        if tag in (1, 0x80):
            if tag in known:
                raise DecodeError("duplicate discriminator or vehicle status")
            known[tag] = value
        else:
            unknown_types.append(tag)
    if known.get(1) != b"\x01":
        raise DecodeError("not an unambiguous NT2 asynchronous notification")
    if 0x80 not in known:
        raise DecodeError("vehicle status LTV missing")
    return {"stage": "nt2_vehicle_plaintext_provenance_not_verified",
            "vehicle": decode_veh_data(known[0x80]),
            "uninterpreted_ltv_types": unknown_types}


def decode_nt2_encrypted_vehicle(envelope: Envelope, *, session_key: bytes,
                                 session_iv: bytes):
    """Offline NT2 B1 decoder for an already established legitimate session.

    CBC is not an authenticity check. This API neither establishes key provenance
    nor proves that a peer authenticated. Never log session_key/session_iv.
    """
    if envelope.category != 0xB1:
        raise DecodeError("only NT2 vehicle-data category is supported")
    if len(session_key) not in (16, 24, 32) or len(session_iv) != 16:
        raise DecodeError("invalid AES session material lengths")
    if not envelope.payload or len(envelope.payload) % 16:
        raise DecodeError("invalid CBC ciphertext length")
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    try:
        decryptor = Cipher(algorithms.AES(session_key), modes.CBC(session_iv)).decryptor()
        padded = decryptor.update(envelope.payload) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        plaintext = unpadder.update(padded) + unpadder.finalize()
    except ValueError:
        raise DecodeError("CBC decryption or padding failed") from None
    result = decode_nt2_vehicle_plaintext(plaintext)
    result["stage"] = "nt2_ciphertext_decoded_with_caller_session_material"
    result["authentication_verified_by_decoder"] = False
    return result
