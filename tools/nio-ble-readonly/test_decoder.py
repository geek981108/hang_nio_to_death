import unittest
from decoder import (DecodeError, Reassembler, decode_envelope,
                     decode_nt2_vehicle_plaintext, decode_veh_data, parse_ltv,
                     decode_nt2_encrypted_vehicle, Envelope)

# Hand-authored synthetic evidence; NOT captured traffic and NOT encrypted.
VEH = bytes.fromhex("00 01 01 01 01 01 01 01 01 00 00 00 00 00 7f 64 01 01 2c")
PLAINTEXT = bytes.fromhex("02 01 01 14 80") + VEH
FRAME = bytes.fromhex("04 b1 00 18") + PLAINTEXT


class DecoderTests(unittest.TestCase):
    def test_exact_envelope(self):
        decoded = decode_envelope(FRAME)
        self.assertEqual(decoded.category, 0xb1)
        self.assertEqual(decoded.payload, PLAINTEXT)

    def test_each_legal_split_point(self):
        for split in range(5, len(FRAME)):
            reader = Reassembler("session-a")
            self.assertIsNone(reader.feed(FRAME[:split], generation="session-a", timestamp=1))
            result = reader.feed(FRAME[split:], generation="session-a", timestamp=2)
            self.assertEqual(result.payload, PLAINTEXT)

    def test_timeout_discards_fragment_and_recovers(self):
        reader = Reassembler("a")
        reader.feed(FRAME[:7], generation="a", timestamp=0)
        with self.assertRaises(DecodeError):
            reader.feed(FRAME[7:], generation="a", timestamp=31)
        self.assertEqual(reader.feed(FRAME, generation="a", timestamp=32).payload, PLAINTEXT)

    def test_stale_connection_does_not_contaminate_current_buffer(self):
        reader = Reassembler("new")
        reader.feed(FRAME[:7], generation="new", timestamp=0)
        with self.assertRaises(DecodeError):
            reader.feed(FRAME[7:], generation="old", timestamp=1)
        self.assertEqual(reader.feed(FRAME[7:], generation="new", timestamp=2).payload, PLAINTEXT)

    def test_disconnect_invalidates_late_packets(self):
        reader = Reassembler("old")
        reader.feed(FRAME[:7], generation="old", timestamp=0)
        reader.close()
        self.assertEqual(reader.buffer, b"")
        reader.reset()  # Frame reset must not reopen a closed connection.
        for late in (FRAME[7:], FRAME):
            with self.assertRaises(DecodeError):
                reader.feed(late, generation="old", timestamp=1)
        fresh = Reassembler("new")
        self.assertEqual(fresh.feed(FRAME, generation="new", timestamp=2).payload, PLAINTEXT)

    def test_fragment_errors(self):
        for data in (b"", b"\x04\xb1\x00\x18", FRAME + b"\x00", b"\x04\xb1\x80\x00\x01"):
            with self.assertRaises(DecodeError):
                Reassembler("a").feed(data, generation="a", timestamp=0)

    def test_envelope_malformed(self):
        for data in (b"", FRAME[:4], FRAME[:-1], FRAME + b"\x00", b"\x05" + FRAME[1:]):
            with self.assertRaises(DecodeError):
                decode_envelope(data)

    def test_ltv_boundaries(self):
        self.assertEqual(parse_ltv(PLAINTEXT), [(1, b"\x01"), (0x80, VEH)])
        for data in (b"\x01\x80", b"\x80\x80" + bytes(127), PLAINTEXT[:-1], PLAINTEXT + b"\x00"):
            with self.assertRaises(DecodeError):
                parse_ltv(data)

    def test_vehicle_fixture(self):
        result = decode_nt2_vehicle_plaintext(PLAINTEXT)
        values = result["vehicle"]["source_literal"]
        self.assertEqual(values["cenLockUnlockSts"], 1)
        self.assertEqual(values["bmsCustomerUsageSoc"], 50.0)
        self.assertEqual(values["vcuRemainingRng"], 300)
        self.assertEqual(values["sunroofPosnStsApp"], 127)
        self.assertTrue(values["comfEna"])
        self.assertFalse(values["findMeStatus"])

    def test_signedness_not_silently_fixed(self):
        raw = bytearray(VEH)
        raw[15] = 150
        result = decode_veh_data(bytes(raw))
        self.assertEqual(result["source_literal"]["bmsCustomerUsageSoc"], -53.0)
        self.assertTrue(result["warnings"])

    def test_vehicle_length_exact(self):
        for data in (VEH[:-1], VEH + b"\x00"):
            with self.assertRaises(DecodeError):
                decode_veh_data(data)

    def test_unambiguous_notification_required(self):
        for data in (PLAINTEXT[3:], bytes.fromhex("0201001480") + VEH,
                     PLAINTEXT + bytes.fromhex("020101"), PLAINTEXT + bytes.fromhex("1480") + VEH):
            with self.assertRaises(DecodeError):
                decode_nt2_vehicle_plaintext(data)

    def test_unknown_ltv_retained_as_uninterpreted(self):
        result = decode_nt2_vehicle_plaintext(PLAINTEXT + bytes.fromhex("027e01"))
        self.assertEqual(result["uninterpreted_ltv_types"], [126])

    def test_invalid_clock(self):
        reader = Reassembler("a")
        reader.feed(FRAME[:5], generation="a", timestamp=10)
        with self.assertRaises(DecodeError):
            reader.feed(FRAME[5:], generation="a", timestamp=9)

    def test_encrypted_synthetic_notification_with_multiple_fragments(self):
        from cryptography.hazmat.primitives import padding
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        # Public, deterministic test values. Never taken from an account or car.
        key, iv = bytes(range(16)), bytes(range(16, 32))
        padder = padding.PKCS7(128).padder()
        padded = padder.update(PLAINTEXT) + padder.finalize()
        encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        ciphertext = encryptor.update(padded) + encryptor.finalize()
        frame = b"\x04\xb1" + len(ciphertext).to_bytes(2, "big") + ciphertext
        reader = Reassembler("synthetic")
        self.assertIsNone(reader.feed(frame[:7], generation="synthetic", timestamp=0))
        self.assertIsNone(reader.feed(frame[7:20], generation="synthetic", timestamp=1))
        packet = reader.feed(frame[20:], generation="synthetic", timestamp=2)
        result = decode_nt2_encrypted_vehicle(packet, session_key=key, session_iv=iv)
        self.assertEqual(result["vehicle"]["source_literal"]["cenLockUnlockSts"], 1)
        self.assertEqual(result["vehicle"]["source_literal"]["bmsCustomerUsageSoc"], 50)
        self.assertFalse(result["authentication_verified_by_decoder"])

    def test_cipher_input_rejected_without_leaking_material(self):
        key, iv = bytes(range(16)), bytes(range(16, 32))
        for packet, badkey, badiv in (
            (Envelope(0xB3, bytes(16)), key, iv),
            (Envelope(0xB1, bytes(16)), key[:15], iv),
            (Envelope(0xB1, bytes(16)), key, iv[:15]),
            (Envelope(0xB1, bytes(15)), key, iv),
            (Envelope(0xB1, bytes(16)), key, iv),
        ):
            with self.assertRaises(DecodeError) as raised:
                decode_nt2_encrypted_vehicle(packet, session_key=badkey, session_iv=badiv)
            self.assertNotIn(key.hex(), str(raised.exception))

    def test_independent_openssl_synthetic_vector(self):
        # Produced with OpenSSL 4.1.0 enc -aes-128-cbc, default padding.
        # Public fixture key=00..0f, IV=10..1f, plaintext=PLAINTEXT above.
        ciphertext = bytes.fromhex(
            "b2957c733126bfd160abd9379cc977fe"
            "b9a9a15acf2cc3c347498be51d867881")
        result = decode_nt2_encrypted_vehicle(
            Envelope(0xb1, ciphertext), session_key=bytes(range(16)),
            session_iv=bytes(range(16, 32)))
        self.assertEqual(result["vehicle"], decode_veh_data(VEH))
        self.assertFalse(result["authentication_verified_by_decoder"])


if __name__ == "__main__":
    unittest.main()
