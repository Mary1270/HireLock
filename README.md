# HireLock

Freelancer stakes and on-chain dispute arbitration for paid freelance work, built as a GenLayer Intelligent Contract with a static frontend.

Clients pay the freelancer off-chain, the way they already do. The freelancer has locked a GEN stake that backs the gig and has published its scope. If the work is not delivered as agreed, both sides submit evidence and GenLayer validators reach consensus on a verdict by comparing the submitted work with the scope. A winning client is paid from the freelancer's stake.

## Layout

- `contracts/hirelock.py` - the Intelligent Contract (production windows, 1 hour unit)
- `contracts/hirelock_testnet.py` - generated variant with 5 second units for fast live testing
- `scripts/make_testnet.py` - regenerates the testnet variant
- `frontend/index.html` - single-file hash-routed app (genlayer-js, Studio network)
- `tests/` - offline test suite (includes shared URL vectors and parity scenarios) with a small GenLayer stub (no network, no pip)
- `base/` - Solidity version for Base (`src/HireLockBase.sol`, Foundry tests, deploy script)
- `frontend/base.html` - Base frontend (viem), also usable as a Base App / Farcaster mini app
- `frontend/.well-known/farcaster.json` - mini app manifest template (placeholders to fill)
- `ARCHITECTURE.md` - state machine, economics, limits

## Run the tests

    python3 -m unittest discover -s tests -t tests

## Deploy

1. Open GenLayer Studio, create a new file, paste `contracts/hirelock_testnet.py` (use `hirelock.py` for real time windows), deploy with no arguments.
2. Open `frontend/index.html?c=<contract address>` or set the address under Settings.

Production contract on GenLayer Studio (contracts/hirelock.py): 0x0CC01C64e7bBFaA4692639F148dE893089fE92eA. Fast-window test contract (hirelock_testnet.py), used for the live lifecycle tests: 0x7F1C5f2A60aA331691fd8bCF1b771125b690eC73. The offline stub checks logic and accounting. See Honest limits for what was and was not covered live.

## Base version

Same gig flow, with ETH stakes. Differences from the GenLayer version:

- No AI judge. A designated `arbiter` address (set by the owner, ideally a multisig) rules after the evidence window. If it stays silent for 7 days anyone can close the dispute as inconclusive (no payout, deposits returned).
- Gigs bound by freelancer silence cap compensation at 25%, need the arbiter's `paymentEvidenceReviewed` flag, and pay out only after a 7-day window in which the freelancer can challenge. Claiming a payment needs a refundable deposit (see ARCHITECTURE.md).
- Invalid input reverts normally (ETH is returned by the EVM), so no refund-instead-of-revert path.
- Constants are scaled to ETH (min stake 0.005, cover cap 0.002 / 0.01 / 0.04, dispute deposit 0.001). Constructor takes `(arbiter, timeUnit)`; use 3600 for real windows, 5 for fast tests.
- The Foundry tests are meant to run in CI (`.github/workflows/tests.yml`); the Solidity code has not been deployed to a live chain and has not been audited.
- The arbiter should be a multisig contract; the deploy script refuses an EOA unless `ALLOW_EOA_ARBITER=true` (testnet only). Arbiter changes are timelocked 7 days (`proposeArbiter`, `applyArbiterChange`).
- Deploy: `cd base && ARBITER=0x... forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org --account <keystore> --broadcast`, then open `frontend/base.html?c=<address>&n=sepolia`.
- Mini app: host `frontend/` over https, replace `APP_URL` in `base.html` and `.well-known/farcaster.json`, and sign the account association with Base Build. The mini app is untested.

## Honest limits

- The contract cannot see bank payments or open the delivered files. It only weighs the text the parties submit against the published scope.
- Handles (Upwork, Fiverr, GitHub, Telegram or any name) are self-declared labels, not verified.
- Validators are language models and can be wrong. No appeal in v1.
- Compensation is in GEN and covers the covered amount, not necessarily the fee.
- Links are never opened. When the freelancer stays silent, a text-only payment claim was rejected as insufficient in live Studio tests, so the client gets the deposits back but no compensation.
- Live Studio runs covered the confirmed-freelancer and silent-freelancer paths and the accounting balance. The payout delay and freelancer challenge are covered by the offline tests only.

MIT licensed.
