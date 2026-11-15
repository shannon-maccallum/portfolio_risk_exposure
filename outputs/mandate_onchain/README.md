# Mandate: theme funds whose rules are enforced on-chain

Built for Monad Blitz. Deployed on Monad Testnet (chain ID 10143).

**The idea.** Every fund tells you what it holds. Mandate funds prove what they're exposed to. You pick a theme ("Want AI, Avoid Oil"), the app builds a basket, and one click launches a fund token (e.g. `$AIXO`) whose rules are written into the contract and can never be changed:

- **At launch and on every basket change**, the basket is checked against the Exposure Oracle. Adding XOM is rejected with `Oil: High (XOM)`, and the rejection is recorded on-chain, not hidden.
- **Enforce (anyone can call).** A company's business mix changes over time. If a holding drifts past a rule (say a new filing puts MSFT's oil exposure at High), anyone can call `enforce()`. The contract sells it, reinvests in the remaining holdings, and pays the caller 0.5% of the value sold. Strangers are paid to keep the fund honest; no manager or compliance team needed.
- **Rule receipts.** Every check is counted on-chain: checks passed, breaches caught, and the last rejection reason.

Price per token = total value of the basket ÷ tokens outstanding (the same math as an ETF's NAV). The first deposit buys tokens at $10.

## Why Monad

Checking every fund on every price update, and letting anyone trigger enforcement, means many small transactions. On Monad (400 ms blocks, sub-second finality, low fees) that is cheap enough to run continuously. Each fund is a lightweight clone of one template, so a launch costs about 0.07 MON: cheap enough for every user to have their own fund.

## What is real and what is simulated

| Piece | Status |
|---|---|
| Exposure scores | Real. Share of revenue or earnings tied to each theme, from each company's latest 10-K or quarterly report. See `exposure_10k.csv` for every numerator, denominator and source. |
| Prices | Real closing prices: NVDA, AMD, MSFT, AVGO on Nov 10, 2026; GOOGL on Nov 6; XOM, CVX on Nov 12. The oracle owner can repost them any time. |
| Stocks | Simulated test tokens, bought and sold at the oracle price by a mock exchange. In production this plugs into tokenized stocks. |
| Test dollars | Free from the app's faucet. |
| Oracle | One wallet posts the data. In production this would be several independent signers. |
| The drift in the Enforce demo | Simulated: we post a made-up new oil score for MSFT to show the mechanism. |

## Exposure data (from filings)

| Ticker | AI | Oil | Measure |
|---|---|---|---|
| NVDA | 89.7% High | 0 | Data Center / total revenue, FY2026 |
| AMD | 47.9% High | 0 | Data Center / total revenue, FY2025 |
| MSFT | 41.5% High | 0 | Intelligent Cloud / total revenue, FY2026 |
| AVGO | 31.3% Medium | 0 | AI semiconductor / total revenue, FY2025 |
| GOOGL | 15.5% Medium | 0 | Google Cloud / total revenue, Q4 2025 |
| XOM | 0 | 88.6% High | (Upstream + Energy Products) / segment earnings, FY2025 |
| CVX | 0 | 100% High | (Upstream + Downstream) / segment earnings, Q4 2025 |

Tiers are computed on-chain from the score: High ≥ 40%, Medium ≥ 15%, Low > 0.

## Contracts (`src/`)

| File | What it does |
|---|---|
| `Platform.sol` | Deploys everything below in one transaction |
| `ExposureOracle.sol` | Stores each stock's price and theme scores; derives tiers |
| `MockExchange.sol` | Creates test dollars and simulated stocks; swaps them at oracle prices; faucet |
| `MockToken.sol` | The test token used for dollars and stocks |
| `FundFactory.sol` | Launches a new fund (a cheap clone) with its basket, rules and name |
| `ThemeFund.sol` | The fund token: deposit, cash out, NAV, rule checks, basket changes, enforce, receipts |

## Deployed addresses (Monad Testnet)

Filled in after deployment. Explorer: https://testnet.monadvision.com

| Contract | Address |
|---|---|
| Platform | [0xB09569b01b65a13A91728cdB16358FbCEF131C46](https://testnet.monadvision.com/address/0xB09569b01b65a13A91728cdB16358FbCEF131C46) |
| ExposureOracle | _pending_ |
| MockExchange | _pending_ |
| FundFactory | _pending_ |
| $AIXO fund | _pending_ |

## The app

The website is in `/docs` at the root of this branch (plain HTML and JavaScript, no build step). It needs MetaMask on Monad Testnet. To run it locally:

```bash
cd docs
python3 -m http.server 8080
# open http://localhost:8080
```

## Run the tests

Needs [Foundry](https://getfoundry.sh) and Node.js. From this folder:

```bash
npm install
git clone --depth 1 --branch v1.9.4 https://github.com/foundry-rs/forge-std lib/forge-std
forge test
```

24 tests cover the money math (deposits, cash-outs, price per token as prices move, worked out by hand in the test comments), every rule rejection message, enforcement and bounties, and the access controls. About 97% of contract lines are covered (`forge coverage --ir-minimum`).

After changing a contract, refresh the website's copy of the contract interfaces:

```bash
forge build && python3 script/export_abis.py
```

## Gas (measured on a local chain)

Monad charges for the gas limit you set, so the app sets it at 15% above the estimate.

| Action | Gas | ≈ MON at 102 gwei |
|---|---|---|
| Deploy platform | 10.2M | 1.05 |
| Post oracle data | 0.57M | 0.06 |
| Launch a fund | 0.69M | 0.07 |
| Deposit | 0.38M | 0.04 |
| Enforce (with a sale) | 0.31M | 0.03 |

## Known limits

- Exposure is measured on the fund's target weights, not on live weights that drift with prices.
- The enforcer's bounty comes out of the fund, so investors pay for enforcement.
- Anyone can call `enforce()` when nothing is wrong. It pays nothing, but it does add to the "checks passed" count.
- Revenue-share scores are a label-based starting point. The returns-based regression engine is the next data source for the oracle.
