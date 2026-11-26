import io
import unittest

from decoder import decode_nt2_encrypted_vehicle
from replay import ReplayError, read_events, replay


# Independent OpenSSL fixture from test_decoder; synthetic public materials only.
CIPHER = bytes.fromhex("b2957c733126bfd160abd9379cc977feb9a9a15acf2cc3c347498be51d867881")
FRAME = b"\x04\xb1\x00\x20" + CIPHER


def event(kind, time, generation="a", data=None):
    value = {"event": kind, "timestamp": time, "generation": generation}
    if data is not None:
        value["hex"] = data.hex()
    return value


class ReplayTests(unittest.TestCase):
    def test_encrypted_recording_reconnect_and_independent_state(self):
        events = [event("connect", 0), event("notification", 1, data=FRAME[:8]),
                  event("notification", 2, data=FRAME[8:]), event("disconnect", 3),
                  event("connect", 4, "b"), event("notification", 5, "b", FRAME)]
        generations = []

        def decode(generation, packet):
            generations.append(generation)
            return decode_nt2_encrypted_vehicle(packet, session_key=bytes(range(16)),
                                                session_iv=bytes(range(16, 32)))

        result = replay(events, decode_packet=decode)
        self.assertEqual(generations, ["a", "b"])
        self.assertEqual(result["connections"], 2)
        self.assertTrue(result["connection_open_at_end"])
        self.assertFalse(result["authentication_verified"])
        for packet in result["packets"]:
            self.assertEqual(packet["vehicle"]["source_literal"]["cenLockUnlockSts"], 1)

    def test_cli_mode_does_not_treat_ciphertext_as_plaintext(self):
        result = replay([event("connect", 0), event("notification", 1, data=FRAME)])
        self.assertEqual(result["mode"], "framing_only")
        self.assertNotIn("vehicle", result["packets"][0])
        self.assertNotIn(CIPHER.hex(), str(result))

    def test_late_notification_and_reused_generation_rejected(self):
        base = [event("connect", 0), event("disconnect", 1)]
        for tail in ([event("notification", 2, data=FRAME)],
                     [event("connect", 2)],
                     [event("connect", 2, "b"), event("notification", 3, data=FRAME)]):
            with self.assertRaises(ReplayError):
                replay(base + tail)

    def test_truncation_at_disconnect_and_end(self):
        base = [event("connect", 0), event("notification", 1, data=FRAME[:9])]
        for tail in ([], [event("disconnect", 2)]):
            with self.assertRaisesRegex(ReplayError, "incomplete frame"):
                replay(base + tail)

    def test_timeout_and_global_clock(self):
        with self.assertRaisesRegex(ReplayError, "reassembly failed"):
            replay([event("connect", 0), event("notification", 1, data=FRAME[:9]),
                    event("notification", 32, data=FRAME[9:])])
        for time in (float("nan"), float("inf"), True, -1, 10**400):
            with self.assertRaises(ReplayError):
                replay([event("connect", time)])
        with self.assertRaisesRegex(ReplayError, "timestamp order"):
            replay([event("connect", 3), event("disconnect", 2)])

    def test_malformed_input_and_sensitive_errors_not_echoed(self):
        for source in ('{"token":"do-not-echo"}\n', 'not json do-not-echo\n',
                       'x' * 70001, '[]\n', '{"event":"connect","event":"disconnect"}\n'):
            with self.assertRaises(ReplayError) as caught:
                replay(read_events(io.StringIO(source)))
            self.assertNotIn("do-not-echo", str(caught.exception))
        def bad_decoder(generation, packet):
            raise ValueError("do-not-echo")
        with self.assertRaisesRegex(ReplayError, "packet decoding failed"):
            replay([event("connect", 0), event("notification", 1, data=FRAME)],
                   decode_packet=bad_decoder)


if __name__ == "__main__":
    unittest.main()
