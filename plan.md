# SleepStake: Build Plan

Hackathon: Monad Blitz Berlin, 26 Sept 2026. Code freeze and submission at **17:45**.
Owner: Kai (GitHub: fluyid). A second collaborator may push to the same repo.

This plan is written for an AI coding agent (Antigravity) to execute milestone by milestone.
Stop at the end of every milestone, show what was done, and wait for approval before continuing.

---

## 0. Rules for the agent

1. **Do not run any git commands** (no `git add`, `commit`, `push`, `branch`). Kai runs git himself. At the end of each milestone, suggest a descriptive commit message instead.
2. **Never write private keys, keystore passwords or secrets into any tracked file.** Secrets live only in `.env` (local) and `.streamlit/secrets.toml` (local) or in Streamlit Cloud's secret settings. Both files are gitignored.
3. Add short, plain-language comments to the code. Kai is new to Solidity and web3 and is learning from it.
4. Do not invent statistics or facts for the README or pitch. Leave `TODO: source` placeholders.
5. Keep dependencies minimal. Avoid polling loops that hammer the RPC (rate limits: 50 req/s public RPC).
6. If something in this plan is ambiguous or seems wrong, stop and ask rather than guessing.

---

## 1. What SleepStake is

A "bet on yourself" sleep challenge. Friends or strangers pay a buy-in into a smart contract on Monad. Each night, a player's sleep is reported. If a player hits the sleep goal **every night** of the challenge, they win. Winners split the losers' stakes.

### Rules (enforced by the contract, not the app)
- Each night's **window** is 21:00 to 06:00 local time (9 hours).
- A night **passes** only if the player's sleep started and ended inside that window **and** lasted between **7h30 (27,000 s) and 8h30 (30,600 s)** inclusive.
- To win, a player must pass **every** night of the challenge.
- Settlement:
  - **Nobody wins** or **everyone wins**: everyone gets their buy-in back. No fee.
  - **Some win, some lose**: the losers' stakes form the forfeited pool. A **5% platform fee** is taken from the forfeited pool (not from winners' own stakes). Each winner gets their own buy-in back plus an equal share of the remaining forfeited pool. Any rounding remainder goes to the treasury.

### Trust model (be honest about this in the pitch)
The blockchain cannot see anyone's sleep. An **oracle** (the admin wallet) reports each night's sleep start and end timestamps. The contract then checks the rules. Future work: signed data from a health API (Google Health or similar) instead of an admin.

### Sleep data source
- Today: a `MockHealthProvider` that generates realistic sample nights (some passing, some failing), plus a manual entry form.
- Future: a `GoogleHealthProvider` (or other health API) implementing the same interface. Create only a stub class with a docstring. Do not implement it today.

---

## 2. Stack

| Part | Choice |
|---|---|
| Chain | Monad testnet (chain ID 10143). Mainnet (chain ID 143) switchable via config only. |
| Contracts | Solidity `^0.8.30`, Foundry 1.8+ (already installed; project already initialised from `monad-developers/foundry-monad`) |
| Buy-in currency | Native MON (simplest; no token approvals) |
| App | Python (latest stable available; use the newest version Streamlit Community Cloud offers), Streamlit, web3.py (latest v7+), python-dotenv |
| Hosting | Streamlit Community Cloud from the public GitHub repo |

Network config:
- Testnet RPC: `https://testnet-rpc.monad.xyz` (fallback: `https://rpc.ankr.com/monad_testnet`)
- Explorer: `https://testnet.monadvision.com`
- `foundry.toml` already contains `network = "monad"`, the testnet RPC and `chain_id = 10143`.

---

## 3. Repository layout (target)

```
monad-blitz/
  foundry.toml
  src/SleepStake.sol
  test/SleepStake.t.sol
  script/DeploySleepStake.s.sol
  app/
    streamlit_app.py
    chain.py            # web3 connection, contract loading, tx helpers
    health.py           # HealthProvider interface, MockHealthProvider, GoogleHealthProvider stub
    abi/SleepStake.json # ABI copied from out/ after compile
  requirements.txt      # at repo root, for Streamlit Cloud
  .env.example          # variable NAMES only, no values
  .streamlit/secrets.toml.example
  .gitignore
  README.md
  plan.md
```

Remove the template's `Counter` contract, test and script once `SleepStake` is in place.

---

## Milestone 1: Repo hygiene (target: 10 min)

1. Create/extend `.gitignore` with at least:
   ```
   .env
   .streamlit/secrets.toml
   out/
   cache/
   broadcast/
   __pycache__/
   .venv/
   ```
2. Create `.env.example` and `.streamlit/secrets.toml.example` listing variable names only:
   `RPC_URL`, `CHAIN_ID`, `CONTRACT_ADDRESS`, `ORACLE_PRIVATE_KEY`, `PLAYER_KAI_KEY`, `PLAYER_ALICE_KEY`, `PLAYER_BOB_KEY`.
3. Stub `README.md` (title, one-line description, "setup coming").

**Done when:** `.gitignore` covers secrets and build output; no secret values exist anywhere in the repo.
**Suggested commit:** `Add gitignore, env templates and README stub for SleepStake`

---

## Milestone 2: Smart contract (target: 45 min)

File: `src/SleepStake.sol`

### Constants
- `WINDOW_LENGTH = 9 hours`
- `MIN_SLEEP = 27000` (7h30), `MAX_SLEEP = 30600` (8h30)
- `FEE_BPS = 500` (5%), `BPS = 10000`
- `MAX_NIGHTS = 30`

### State
- `owner` (treasury, set in constructor), `oracle` (set in constructor, changeable by owner)
- `Challenge` struct:
  - `creator`, `buyIn` (wei), `firstNightStart` (unix timestamp of 21:00 local on night 0; computed by the app), `nights`, `joinDeadline`, `settled`, `players` (address[]), `reportsSubmitted`
- Per challenge per player: `joined`, `nightsPassed`, `reported[night]`, `passed[night]`
- `claimable[address]` for the pull-payment pattern, including the treasury's fee

### Functions
- `createChallenge(uint256 buyIn, uint64 firstNightStart, uint8 nights, uint64 joinDeadline) returns (uint256 id)`
  - `buyIn > 0`, `1 <= nights <= MAX_NIGHTS`
  - Past `firstNightStart` is allowed so the demo can replay previous nights. Add a comment that production would require `joinDeadline <= firstNightStart`.
- `join(uint256 id) payable`
  - `msg.value == buyIn`, before `joinDeadline`, not already joined, not settled
- `submitSleep(uint256 id, address player, uint8 night, uint64 sleepStart, uint64 sleepEnd)` (only oracle)
  - player joined, `night < nights`, not already reported for that night, not settled, `sleepEnd > sleepStart`
  - `windowStart = firstNightStart + night * 1 days`, `windowEnd = windowStart + WINDOW_LENGTH`
  - passes if `sleepStart >= windowStart && sleepEnd <= windowEnd && duration in [MIN_SLEEP, MAX_SLEEP]`
  - A failing night is **recorded, not reverted**, so the demo can show failures. Emit an event with the result and the reason code (e.g. `OUTSIDE_WINDOW`, `TOO_SHORT`, `TOO_LONG`).
- `settle(uint256 id)`
  - allowed if not settled **and** (`block.timestamp >= firstNightStart + nights * 1 days` **or** every player has every night reported)
  - Compute winners (`nightsPassed == nights`) and apply the settlement rules from section 1 by crediting `claimable`. Rounding remainder to treasury.
- `withdraw()`: sends `claimable[msg.sender]`, zeroing it **before** the transfer (checks-effects-interactions). Use `call` and require success.
- `setOracle(address)` (only owner)
- View helpers for the app: `getChallenge(id)`, `getPlayers(id)`, `getPlayerStatus(id, player)` returning nights passed and per-night reported/passed arrays, `challengeCount()`.

### Events
`ChallengeCreated`, `Joined`, `SleepReported(id, player, night, passed, reason, duration)`, `Settled(id, winners, feeTaken)`, `Withdrawn`.

### Security notes to follow
- Custom errors instead of long revert strings (cheaper gas).
- No loops over unbounded arrays except `settle`, which is bounded by player count; cap players per challenge at 50.
- No `tx.origin`. No `block.timestamp` for anything except the settle time check.
- Do not send ETH/MON inside loops; use `claimable` + `withdraw`.

**Done when:** `forge build` succeeds with no errors from `src/`.
**Suggested commit:** `Add SleepStake contract with onchain sleep rule checks and pooled payouts`

---

## Milestone 3: Tests (target: 30 min)

File: `test/SleepStake.t.sol`. Run `forge test -vv`. Cover at minimum:

1. Happy path: 3 players, 2 nights; 2 win, 1 loses. Check fee = 5% of one buy-in, winner payouts, treasury gets fee plus dust.
2. Boundaries: exactly 7h30 passes, 7h29m59s fails, exactly 8h30 passes, 8h30m01s fails.
3. Window: start at 20:59 fails, end at 06:01 fails, start 00:30 end 08:15 fails (ends after 06:00), start 22:00 end 06:00 passes.
4. Nobody wins: full refunds, no fee.
5. Everyone wins: full refunds, no fee.
6. Reverts: wrong buy-in, double join, join after deadline, non-oracle submit, double report, double settle, settle too early with missing reports, withdraw with nothing claimable.
7. Withdraw sends the correct balance and cannot be repeated.

**Done when:** all tests pass.
**Suggested commit:** `Add SleepStake tests for rules, settlement math and access control`

---

## Milestone 4: Deploy script (target: 15 min)

File: `script/DeploySleepStake.s.sol`. Constructor sets the deployer as both owner and oracle.

Kai runs (keystore already exists as `monad-deployer`):
```
forge script script/DeploySleepStake.s.sol --account monad-deployer --broadcast
```
Then copies the ABI:
```
jq '.abi' out/SleepStake.sol/SleepStake.json > app/abi/SleepStake.json
```
(If `jq` is missing: `brew install jq`.)

For local practice without tokens: `anvil` in one terminal, then the same script with `--rpc-url http://127.0.0.1:8545` and an anvil test key.

**Done when:** contract address is printed and visible on the explorer.
**Suggested commit:** `Add deploy script and export SleepStake ABI for the app`

---

## Milestone 5: Streamlit app (target: 1h45)

### `app/health.py`
- `SleepRecord` dataclass: `night`, `sleep_start`, `sleep_end` (unix seconds).
- `HealthProvider` abstract base class with `get_sleep(player_name, first_night_start, nights) -> list[SleepRecord]`.
- `MockHealthProvider`: deterministic per player (seeded) so the demo is repeatable. Kai and Alice pass every night; Bob fails one night (too short).
- `GoogleHealthProvider`: stub raising `NotImplementedError`, docstring explaining the future integration.

### `app/chain.py`
- Load config from `st.secrets` if present, otherwise `.env`.
- Connect with web3.py; show a clear error if the RPC is unreachable or the chain ID is wrong.
- Load the contract from `abi/SleepStake.json` and `CONTRACT_ADDRESS`.
- `send_tx(account_key, fn)`: build, sign, send, wait for the receipt. Return tx hash and explorer link.
- Cache read calls with `st.cache_data(ttl=5)` to avoid spamming the RPC.

### `app/streamlit_app.py` (pages via sidebar radio or tabs)
1. **Header**: app name, network badge (testnet/mainnet), contract address with explorer link.
2. **Create challenge**: buy-in (MON), number of nights, start date (converted to 21:00 Europe/Berlin as unix time), join deadline. Signed by the selected demo wallet.
3. **Join**: pick demo player (Kai / Alice / Bob), pick challenge, join button. Show balance before/after.
4. **Oracle panel**: pick challenge; "Fetch from health provider" (mock) fills in each player's nights; "Submit to chain" sends each report. Also a manual entry form for one night.
5. **Leaderboard**: per player, a row of night icons (pass / fail / pending) and total pool.
6. **Settle and withdraw**: settle button, then per-player withdraw buttons showing claimable amounts.

Every transaction shows its tx hash as an explorer link. Friendly error messages for the common failures (not joined, already reported, wrong buy-in, insufficient funds).

### `requirements.txt` (repo root)
`streamlit`, `web3`, `python-dotenv` (latest versions; pin after first successful run with `pip freeze`).

**Done when:** full flow works against the deployed testnet contract: create, 3 joins, reports, settle, withdrawals.
**Suggested commit:** `Add Streamlit app with demo wallets, mock health provider and oracle panel`

---

## Milestone 6: Hosting on Streamlit Community Cloud (target: 20 min)

1. Kai pushes the repo to GitHub (public).
2. On share.streamlit.io: New app, repo `fluyid/<repo>`, branch `main`, main file `app/streamlit_app.py`, newest Python available.
3. Paste secrets (RPC_URL, CHAIN_ID, CONTRACT_ADDRESS, oracle and demo player keys) into the app's **Secrets** settings. Never commit them.
4. Fund the three demo player wallets with a small amount of testnet MON each.

**Done when:** the public URL completes the full flow.

---

## Milestone 7: README and demo prep (target: 30 min)

README sections: problem, how it works (with the rules), trust model and future work (health API oracle, real wallet login), architecture diagram (Mermaid), how to run locally, contract address, live demo link.

Pitch facts about sleep deprivation: leave `TODO: source` placeholders. Kai and Claude will add sourced numbers. Do not invent any.

3-minute demo script:
1. 20 s: problem (one sentence plus one sourced stat).
2. 2 min: live flow. Create challenge, three players join, oracle reports (Bob fails one night, show the reason), settle, winners withdraw, show fee.
3. 30 s: why Monad (fast finality makes nightly check-ins and instant payouts feel instant) and what's next.

Record a backup screen recording of the full flow in case the Wi-Fi fails.

**Suggested commit:** `Add README with rules, trust model, architecture and run instructions`

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| No testnet MON yet | Build and test on `anvil`; ask a Monad team member for tokens early |
| Secret keys leaked in the public repo | `.gitignore` first; check `git status` before every commit |
| RPC rate limits during the demo | Cached reads; fallback RPC in config |
| Demo nights are in the past | Contract allows past `firstNightStart` for replay; explain in pitch |
| Oracle trust questions from judges | State it openly; health API signing is the roadmap |
| Friend cannot build after cloning | `forge-std` is a git submodule: clone with `--recurse-submodules` or run `forge install` |
| Running out of time | Cut order: manual entry form, then leaderboard icons, then create page (pre-create one challenge via script) |
