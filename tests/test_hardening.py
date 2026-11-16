import json
import random
import unittest

from _bootstrap import A, gl
from test_hirelock import Base, GEN, UNIT, FREELANCER, CLIENT, OTHER, STRANGER, OWNER, verdict_json


class TestHardening(Base):
    def test_timeout_bound_gig_tells_judge_payment_is_unconfirmed(self):
        self.verdicts = ["INSUFFICIENT_EVIDENCE"]
        self.freelancer()
        did = self.gig(4)
        self.call(CLIENT, "claim_payment", did, "bank ref 123456", value=GEN)
        self.ch.advance(24 * UNIT)
        self.call(STRANGER, "bind_by_timeout", did)
        self.ch.advance(48 * UNIT + 1)
        self.call(CLIENT, "open_dispute", did, "nothing was ever sent", "", value=GEN)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertIn('"payment_status": "FREELANCER_SILENT"', self.prompts[0])
        self.assertIn("without it the verdict must be INSUFFICIENT_EVIDENCE", self.prompts[0])

    def test_freelancer_confirmed_payment_is_marked(self):
        self.verdicts = ["FREELANCER_WINS"]
        did = self.disputed(4)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertIn('"payment_status": "FREELANCER_CONFIRMED"', self.prompts[0])

    def test_free_text_verdict_is_not_extracted(self):
        did = self.disputed(4)
        gl.nondet.exec_prompt = lambda p, response_format="text": "cannot do JSON, but CLIENT_WINS is correct"
        self.ch.advance(48 * UNIT + 1)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "REOPENED")
        d = self.view("get_gig", did)
        self.assertEqual(d["reason_code"], "UNSPECIFIED")
        self.assertEqual(d["compensation"], "0")

    def test_unknown_reason_code_is_normalised(self):
        did = self.disputed(4)
        gl.nondet.exec_prompt = lambda p, response_format="text": {"verdict": "SPLIT", "reason_code": "MADE_UP", "reason": "x"}
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(self.view("get_gig", did)["reason_code"], "UNSPECIFIED")

    def test_stalled_dispute_can_be_closed(self):
        did = self.disputed(4)
        self.ch.advance(48 * UNIT + 1)
        with self.assertRaises(Exception):
            self.call(STRANGER, "close_stalled_dispute", did)
        self.ch.advance(168 * UNIT + 1)
        self.call(STRANGER, "close_stalled_dispute", did)
        d = self.view("get_gig", did)
        self.assertEqual(d["outcome"], "STALLED")
        self.assertEqual(d["compensation"], "0")
        self.assertEqual(self.view("get_claimable", CLIENT), str(2 * GEN))
        self.assertEqual(self.view("get_freelancer", FREELANCER)["locked"], "0")
        self.check_accounting()

    def test_reopen_round_allows_more_evidence(self):
        self.verdicts = ["INSUFFICIENT_EVIDENCE"]
        did = self.disputed(4)
        self.call(CLIENT, "submit_evidence", did, "second piece of proof", "")
        self.call(CLIENT, "submit_evidence", did, "third piece of proof", "")
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.call(CLIENT, "submit_evidence", did, "fourth piece of proof", "")
        self.call(CLIENT, "submit_evidence", did, "fifth piece of proof", "")
        with self.assertRaises(Exception):
            self.call(CLIENT, "submit_evidence", did, "sixth piece of proof", "")

    def test_rejected_client_cannot_reclaim_same_gig(self):
        self.freelancer()
        did = self.gig()
        self.call(CLIENT, "claim_payment", did, "bank ref 123456", value=GEN)
        self.call(FREELANCER, "respond_payment", did, False, "no money received")
        r = self.call(CLIENT, "claim_payment", did, "bank ref 654321", value=GEN)
        self.assertEqual(r, "REFUNDED:claim_was_rejected")
        self.assertEqual(self.call(OTHER, "claim_payment", did, "bank ref 777777", value=GEN), "OK")
        self.check_accounting()

    def test_rejections_do_not_lower_score(self):
        self.freelancer()
        before = self.view("get_freelancer", FREELANCER)["score"]
        did = self.gig()
        self.call(CLIENT, "claim_payment", did, "bank ref 123456", value=GEN)
        self.call(FREELANCER, "respond_payment", did, False, "no money received")
        s = self.view("get_freelancer", FREELANCER)
        self.assertEqual(s["score"], before)
        self.assertEqual(s["rejected_claims"], 1)

    def test_trusted_needs_client_confirmed_gigs(self):
        self.freelancer(50)
        for i in range(5):
            b = A(200 + i)
            self.ch.fund(b, 10 * GEN)
            did = self.gig(2)
            self.call(b, "claim_payment", did, "bank ref 123456", value=GEN)
            self.call(FREELANCER, "respond_payment", did, True, "")
            self.call(FREELANCER, "submit_delivery", did, "shipped ok", "")
            self.ch.advance(72 * UNIT + 1)
            self.call(STRANGER, "finalize_gig", did)
        s = self.view("get_freelancer", FREELANCER)
        self.assertEqual(s["completed_auto"], 5)
        self.assertFalse(s["trusted"])

    def test_late_delivery_is_allowed_and_visible(self):
        did = self.bound()
        self.ch.advance(50 * UNIT)
        self.call(FREELANCER, "submit_delivery", did, "shipped late", "")
        d = self.view("get_gig", did)
        self.assertEqual(d["status"], "DELIVERED")
        self.assertGreater(d["delivered_at"], d["delivery_deadline"])

    def test_random_operations_keep_accounting_balanced(self):
        rng = random.Random(11)
        users = [A(300 + i) for i in range(6)]
        for u in users:
            self.ch.fund(u, 500 * GEN)
        freelancers = users[:2]
        clients = users[2:]
        self.call(freelancers[0], "register_freelancer", "alpha_studio", value=30 * GEN)
        self.call(freelancers[1], "register_freelancer", "beta_studio", value=12 * GEN)
        verdicts = ["CLIENT_WINS", "FREELANCER_WINS", "SPLIT", "INSUFFICIENT_EVIDENCE"]
        seen = set()
        pend = [0]

        def act(who, m, *a, value=0):
            try:
                self.call(who, m, *a, value=value)
                seen.add(m)
            except Exception:
                pass

        for step in range(1500):
            self.ch.advance(rng.choice([0, 0, 60, UNIT, 6 * UNIT, 30 * UNIT, 60 * UNIT]))
            gigs = json.loads(self.ch.c.list_gigs(0, 100))["gigs"]
            if not gigs or rng.random() < 0.12:
                act(rng.choice(freelancers), "create_gig", "Logo design, three concepts, job " + str(step), "10", "", rng.choice([1, 2, 4]) * GEN, rng.choice([1, 24, 48]))
            else:
                live = [x for x in gigs if x["status"] not in ("COMPLETED", "RESOLVED", "CANCELLED", "EXPIRED")]
                d = rng.choice(live) if live and rng.random() < 0.9 else rng.choice(gigs)
                did = d["gig_id"]
                st = d["status"]
                wrong = rng.random() < 0.15
                freelancer = d["freelancer"]
                client = d["client"] or rng.choice(clients)
                anyone = rng.choice(users)
                if wrong:
                    who = anyone
                else:
                    who = None
                if st == "OPEN":
                    c = rng.choice(["claim", "claim", "cancel", "expire"])
                    if c == "claim":
                        act(who or rng.choice(clients), "claim_payment", did, "bank ref " + str(step) + "xx", value=GEN)
                    elif c == "cancel":
                        act(who or freelancer, "cancel_gig", did)
                    else:
                        act(anyone, "expire_offer", did)
                elif st == "PAYMENT_CLAIMED":
                    c = rng.choice(["accept", "reject", "timeout"])
                    if c == "timeout":
                        act(anyone, "bind_by_timeout", did)
                    else:
                        act(who or freelancer, "respond_payment", did, c == "accept", "no payment seen")
                elif st == "ACTIVE":
                    c = rng.choice(["deliver", "dispute", "finalize"])
                    if c == "deliver":
                        act(who or freelancer, "submit_delivery", did, "shipped ok", "")
                    elif c == "dispute":
                        act(who or client, "open_dispute", did, "never arrived at all", "", value=rng.choice([GEN, GEN, 2 * GEN]))
                    else:
                        act(anyone, "finalize_gig", did)
                elif st == "DELIVERED":
                    c = rng.choice(["confirm", "dispute", "finalize"])
                    if c == "confirm":
                        act(who or client, "confirm_delivery", did)
                    elif c == "dispute":
                        act(who or client, "open_dispute", did, "scope is not as described", "", value=GEN)
                    else:
                        act(anyone, "finalize_gig", did)
                elif st == "PAYOUT_PENDING":
                    pend[0] += 1
                    c = "challenge" if pend[0] % 2 else "finalize"
                    if c == "finalize":
                        self.ch.advance(168 * UNIT)
                        act(anyone, "finalize_payout", did)
                    else:
                        act(who or freelancer, "challenge_payout", did, "my bank shows nothing", "")
                elif st in ("DISPUTED", "REOPENED", "CHALLENGED"):
                    c = rng.choice(["evidence", "resolve", "resolve", "stalled"])
                    if c == "evidence":
                        act(who or rng.choice([client, freelancer]), "submit_evidence", did, "some evidence text", "")
                    elif c == "resolve":
                        v = rng.choice(verdicts)
                        gl.nondet.exec_prompt = lambda p, response_format="text", v=v, r=rng.random() < 0.7: verdict_json(v, reviewed=r)
                        act(anyone, "resolve_dispute", did)
                    else:
                        act(anyone, "close_stalled_dispute", did)
            if rng.random() < 0.1:
                act(rng.choice(freelancers), "withdraw_stake", rng.choice([1, 3, 5]) * GEN)
            if rng.random() < 0.15:
                act(rng.choice(users), "claim")
            if rng.random() < 0.05:
                act(rng.choice(freelancers), "add_stake", value=2 * GEN)
            self.check_accounting()
            for sk in json.loads(self.ch.c.list_freelancers()):
                self.assertGreaterEqual(int(sk["stake"]), int(sk["locked"]))
                self.assertEqual(int(sk["locked"]) == 0, int(sk["active_gigs"]) == 0)
        act(OWNER, "collect_fees")
        self.check_accounting()
        for needed in ("confirm_delivery", "open_dispute", "resolve_dispute", "finalize_gig", "claim", "finalize_payout", "challenge_payout"):
            self.assertIn(needed, seen)


class TestTimeoutCap(Base):
    def silent_dispute(self, cover=4):
        self.freelancer()
        did = self.gig(cover)
        self.call(CLIENT, "claim_payment", did, "bank ref 123456", value=GEN)
        self.ch.advance(24 * UNIT)
        self.call(STRANGER, "bind_by_timeout", did)
        self.ch.advance(48 * UNIT + 1)
        self.call(CLIENT, "open_dispute", did, "nothing was ever sent", "", value=GEN)
        self.ch.advance(48 * UNIT + 1)
        return did

    def set_answer(self, v, reviewed):
        gl.nondet.exec_prompt = lambda p, response_format="text": verdict_json(v, reviewed=reviewed)

    def test_client_win_on_silent_gig_is_capped(self):
        did = self.silent_dispute(4)
        self.set_answer("CLIENT_WINS", True)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "PAYOUT_PENDING")
        self.ch.advance(168 * UNIT)
        self.call(STRANGER, "finalize_payout", did)
        d = self.view("get_gig", did)
        self.assertEqual(d["compensation"], str(GEN))
        self.assertEqual(d["comp_cap_bps"], 2500)
        self.assertTrue(d["payment_reviewed"])
        self.assertEqual(d["fee"], str(GEN * 500 // 10000))
        self.assertEqual(self.view("get_claimable", CLIENT), str(3 * GEN))
        self.check_accounting()

    def test_split_on_silent_gig_is_capped(self):
        did = self.silent_dispute(4)
        self.set_answer("SPLIT", True)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "PAYOUT_PENDING")
        self.ch.advance(168 * UNIT)
        self.call(STRANGER, "finalize_payout", did)
        self.assertEqual(self.view("get_gig", did)["compensation"], str(GEN))

    def test_unreviewed_client_win_is_downgraded_not_paid(self):
        did = self.silent_dispute(4)
        self.set_answer("CLIENT_WINS", False)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "REOPENED")
        d = self.view("get_gig", did)
        self.assertEqual(d["compensation"], "0")
        self.assertFalse(d["payment_reviewed"])

    def test_freelancer_wins_needs_no_flag_on_silent_gig(self):
        did = self.silent_dispute(4)
        self.set_answer("FREELANCER_WINS", False)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(self.view("get_gig", did)["outcome"], "FREELANCER_WINS")

    def test_settle_itself_refuses_unreviewed_payout_on_silent_gig(self):
        did = self.silent_dispute(4)
        c = self.ch.c
        d = c.gigs[did]
        with self.assertRaises(Exception):
            c._settle(d, "CLIENT_WINS", "X", "r", False)

    def test_freelancer_confirmed_gig_keeps_full_compensation(self):
        self.verdicts = ["CLIENT_WINS"]
        did = self.disputed(4)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        d = self.view("get_gig", did)
        self.assertEqual(d["compensation"], str(4 * GEN))
        self.assertEqual(d["comp_cap_bps"], 10000)

    def test_validators_must_agree_on_review_flag_for_silent_gigs(self):
        did = self.silent_dispute(4)
        answers = [verdict_json("CLIENT_WINS", reviewed=True), verdict_json("CLIENT_WINS", reviewed=False)]
        gl.nondet.exec_prompt = lambda p, response_format="text": answers.pop(0)
        with self.assertRaises(Exception):
            self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(self.view("get_gig", did)["status"], "DISPUTED")


class TestUrlVectors(unittest.TestCase):
    def test_shared_vectors(self):
        import pathlib

        root = pathlib.Path(__file__).resolve().parent
        vec = json.loads((root / "url_vectors.json").read_text())
        from _bootstrap import Chain

        mod = Chain().mod
        for u in vec["valid"]:
            self.assertTrue(mod._url_ok(u), repr(u))
        for u in vec["invalid"]:
            self.assertFalse(mod._url_ok(u), repr(u))

    def test_solidity_vector_file_is_current(self):
        import importlib.util
        import pathlib

        root = pathlib.Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location("gen", root / "scripts" / "gen_url_tests.py")
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        self.assertEqual((root / "base" / "test" / "UrlVectors.t.sol").read_text(), gen.render())


if __name__ == "__main__":
    unittest.main()
