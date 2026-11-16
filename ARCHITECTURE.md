# Architecture

## Gig state machine

OPEN -> PAYMENT_CLAIMED -> ACTIVE -> DELIVERED -> COMPLETED
OPEN -> CANCELLED / EXPIRED
PAYMENT_CLAIMED -> OPEN (freelancer rejects, counted publicly) or ACTIVE (freelancer accepts, or anyone binds after the confirm window)
ACTIVE -> EXPIRED (deadline plus review window passed with no dispute)
ACTIVE or DELIVERED -> DISPUTED -> RESOLVED, or REOPENED once if evidence is insufficient, then RESOLVED

## Economics

- Freelancer level from total stake: STARTER 5 GEN (cap 2 per gig), VERIFIED 20 (cap 10), PREMIUM 50 (cap 40).
- Lock per gig: 150% of the covered amount, 120% for freelancers with at least 5 credited completions and no lost disputes.
- CLIENT_WINS pays 100% of the covered amount, SPLIT 50%. A 5% fee on the compensation is paid from the freelancer's lock to the treasury.
- Client posts a 1 GEN deposit to dispute. It is refunded unless the verdict is FREELANCER_WINS.
- Second INSUFFICIENT_EVIDENCE verdict ends the dispute as INCONCLUSIVE: no compensation, lock released, deposit refunded.
- Accounting invariant: contract balance = stakes + claimable + treasury + burned claim deposits + held deposits. All payouts are pull payments through `claim()`.

## Anti-abuse

- Payable methods never revert on bad input. The value is credited to `claimable` and the call returns `REFUNDED:<reason>`, so funds cannot get stuck.
- Reputation credit per freelancer and client pair is capped at 3, and tiny gigs earn no credit.
- Verified and automatic completions are tracked separately.
- Evidence is frozen with a sha256 digest, capped at 3 pieces per side, https only, no embedded credentials.

## Arbiter

Untrusted text is wrapped in `<DATA>` markers with angle brackets neutralised, trusted facts are passed as JSON, the rubric is fixed, and the answer must be JSON with a verdict enum and a reason code enum. Validators re-run the evaluation and compare only the verdict.

## GenVM notes

Header lines are exactly the version line and the Depends line. No comments or docstrings in the contract. Collections are class-level annotations and never assigned in `__init__`. Views return JSON strings.

## Payment confirmation and the timeout trade-off

The contract cannot verify a bank payment. A client claims payment with a reference, and the freelancer either accepts, rejects, or stays silent. Silence for the confirm window binds the gig (`bound_by = timeout`), otherwise a freelancer who took the money could escape by never answering.

That choice has a cost: a client who never paid can bind a gig when the freelancer is offline. To limit it:

- The judge is told whether payment was `FREELANCER_CONFIRMED` or `FREELANCER_SILENT`. For silent gigs a client win needs checkable payment evidence from the client; without it the verdict must be INSUFFICIENT_EVIDENCE, which ends with no compensation.
- The client's payment reference is passed to the judge as untrusted evidence.
- A client whose claim was rejected cannot claim the same gig again.
- On Base the arbiter should apply the same rule. The gig records who bound it (`boundBy`: 1 freelancer, 2 timeout).

## Unconfirmed-payment policy (enforced in the contracts)

For gigs bound by freelancer silence (`bound_by = timeout`, `boundBy = 2`):

- Compensation is capped at 25% of the covered amount (`TIMEOUT_CAP_BPS = 2500`). CLIENT_WINS pays the cap, SPLIT pays the lower of 50% and the cap. The fee is taken on the capped amount.
- Any compensation requires the judge to set `payment_evidence_reviewed = true`. The flag is stored in the final dispute record and, on Base, emitted in the `Resolved` event. It records the judge's responsibility. It is not proof that the payment happened.
- Without the flag, GenLayer downgrades a CLIENT_WINS or SPLIT verdict to INSUFFICIENT_EVIDENCE (reopen, then no payout), and `_settle` itself refuses to pay. On Base `resolveDispute` reverts, so the arbiter must choose FREELANCER_WINS or INSUFFICIENT_EVIDENCE.
- On GenLayer, validators must agree on the flag as well as the verdict for these gigs.
- The cap is a conservative starting policy, not an economically derived number.

Residual risk: a fabricated payment proof can still fool a judge, up to the cap. Freelancers should answer claims promptly.

## URL policy

Both versions use the same rules, checked against `tests/url_vectors.json` (Python test) and a generated Foundry test (`base/test/UrlVectors.t.sol`, regenerate with `python3 scripts/gen_url_tests.py`): empty or https only (lowercase scheme), 12 to 300 bytes, printable ASCII without spaces or backslashes, no userinfo, no brackets, port only 443, host with at least two labels of letters, digits and hyphens, and an alphabetic top-level label of at least two letters (so IP addresses and localhost are rejected).

## Review round 1 changes

- Free-text verdict extraction removed. Only valid JSON with an allowed verdict counts, anything else is INSUFFICIENT_EVIDENCE with reason code UNSPECIFIED.
- GenLayer gained `close_stalled_dispute` (168 units after the evidence deadline): no payout, lock released, deposit returned, outcome STALLED.
- Evidence limit is 3 per side, plus 2 more per side in the reopened round.
- The dispute deposit must be exactly the configured amount.
- Rejected claims no longer lower the reputation score (still shown publicly). Trusted status needs at least 3 client-confirmed completions.
- Base: the arbiter is snapshotted per dispute, so changing it does not affect open disputes. The owner should still be a multisig. Time unit is bounded to 1..86400.
- Late delivery is allowed on purpose. The client can still dispute within the review window, and the late timestamp is visible.
- Handles are lowercase only in both versions; the GenLayer contract lowercases input, the Solidity contract rejects uppercase.
- Tests: 41 offline tests including a randomized stateful run that checks the accounting invariant after every operation.

## Red-team round and defenses

An internal attack pass (script: the attack list sent with the review bundle) found these weaknesses and the fixes applied. All fixes exist in both contracts.

- Free claim spam: anyone could claim payment on any open gig at no cost, and a silent freelancer then got bound. Fix: `claim_payment` needs an exact refundable deposit (1 GEN / 0.001 ETH). It returns on completion, lapse or dispute outcome (to the freelancer if FREELANCER_WINS), and is burned (locked forever in the contract, counted as `burned`) if the freelancer rejects the claim. It goes to neither the owner nor the freelancer, so nobody profits from rejecting a genuine payment.
- Fake-payment payouts on silent gigs: a client could fabricate a payment claim and wait for the freelancer to miss the 24 h window. Fix: on silent-bound gigs a CLIENT_WINS or SPLIT ruling is not paid at once. It becomes PAYOUT_PENDING for 7 days. The freelancer can challenge, which forces a second review round and pays only after that ruling (still capped at 25%, still needing the review flag). If nobody challenges, anyone can finalize after the delay. A challenge is always accepted even if the freelancer used every evidence slot, and it gives both sides two extra evidence slots for the re-review.
- Fake reputation: a freelancer could farm the trusted lock ratio with a few friendly clients. Fix: trusted needs at least 5 completed gigs, 3 of them client-confirmed, 5 distinct clients, 14 days of age and no lost disputes.
- Server-side fetch abuse (GenLayer): evidence links used to be fetched by validators. Fix: the contract and the judge never open links. Links are stored and shown only as references; the judge sees only the text the parties wrote. This removes SSRF, DNS-rebinding and page-borne prompt injection. A separate isolated evidence-fetching service can be designed later.
- Weekly compensation cap: tried and removed. A per-freelancer cap computed from the freelancer's level let a fraudulent freelancer exhaust it with a sock-puppet client (losing only the 5% fee, since the payout returns to their own wallet) so that real victims in the same week got nothing; even honest losses shrank the cap for later clients. The stake and the 150% lock already bound the worst-case loss per freelancer.
- Base arbiter: should be a multisig (for example 2-of-3). The deploy script refuses an EOA arbiter unless ALLOW_EOA_ARBITER=true (testnet only). Arbiter changes are two-step and timelocked: the owner calls proposeArbiter, anyone can applyArbiterChange after 7 days, the owner can cancel, and every step emits an event. Each dispute snapshots its arbiter when it opens.
- Frontend: self-declared handle label, fee-vs-cover notice, new statuses and actions.

Residual risks that remain by design: the contract cannot see bank payments or the delivered files, so a convincing fabricated text can still sway a judge; a multisig arbiter can still be bribed or colluding; a freelancer can still reject a genuine payment, costing the client the claim deposit (visible as rejected_claims on the freelancer profile); handles are not verified; the fee text is not tied to the covered amount. Before real money: compile and run the Solidity CI, run the GenLayer contract on real Studio, and get an external audit.

## Cross-implementation parity

`scripts/gen_parity.py` holds a small reference model of the dispute economics (compensation, 25% cap on silent-payment gigs, fee, deposit routing, reputation counters, reopen then inconclusive) and generates 72 scenarios: covered amount (1 or 10), payment confirmed or silent, every verdict with and without the review flag, two-round sequences, and the delayed-payout flows (finalize after the delay, challenge then freelancer wins, challenge then client wins again, challenge then inconclusive). The model includes the claim deposit routing. The outputs are `tests/parity_scenarios.json`, run against the GenLayer contract by `tests/test_parity.py`, and `base/test/ParityScenarios.t.sol`, run against the Solidity contract by Foundry. Tests fail if the generated files are stale.

Intentional difference, covered by explicit scenarios: when a silent-payment gig gets CLIENT_WINS or SPLIT without the review flag, GenLayer downgrades the verdict to INSUFFICIENT_EVIDENCE (dispute reopens), while Base reverts so the arbiter must submit a different ruling.

Status: the GenLayer contract matches the reference model in all 72 scenarios on the offline stub. The Solidity side has not been compiled or run.

## Freelance adaptation

HireLock reuses the gig state machine, economics and defenses above, with these domain changes:

- The gig carries a `scope` (10 to 600 characters) and an optional brief link. The scope is written by the freelancer, so it is passed to the judge as an untrusted `<DATA side=scope>` block, never as trusted JSON facts.
- The judge compares the submitted work with that scope only. Taste, extras and late change requests outside the scope do not justify a client win.
- Verdicts are CLIENT_WINS, FREELANCER_WINS, SPLIT and INSUFFICIENT_EVIDENCE. Reason codes: NO_DELIVERABLE, WORK_MATCHES_BRIEF, WORK_BELOW_BRIEF, CLIENT_CLAIM_UNSUPPORTED, PARTIAL_OR_OFF_BRIEF, CONFLICTING_EVIDENCE, NO_SUBSTANTIVE_EVIDENCE.
- Evidence keys use side letters `c` (client) and `f` (freelancer).
