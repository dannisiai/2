# BSC deployment

This project deploys and verifies `AutoBNBBuybackBurnTreasury` on BNB Smart Chain mainnet.

## Setup

```powershell
& 'C:\Users\yulin\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
```

Set these values in `.env`:

```text
DEPLOYER_PRIVATE_KEY=0x...
BSC_RPC_URL=https://bsc-dataseed.bnbchain.org
ETHERSCAN_API_KEY=...
```

The deployer wallet must hold enough BNB for gas. Do not commit `.env`.

## Commands

```powershell
.\.venv\Scripts\python.exe scripts\compile_contract.py
.\.venv\Scripts\python.exe scripts\deploy_bsc.py
.\.venv\Scripts\python.exe scripts\verify_bscscan.py
```

The deployment record is written to `deployments/bsc-mainnet/AutoBNBBuybackBurnTreasury.json`.

Verification uses Etherscan API V2 with `chainid=56`, so an Etherscan API key can verify the BSC deployment.

## Cloud buyback automation

The GitHub Actions workflow at `.github/workflows/bsc-f144-buyback.yml` runs
`scripts/execute_buyback_once.py` hourly. The script checks the vault first and
only sends an `executeBuyback()` transaction when `checkUpkeep` is true.

Current vault:

```text
0x7563CaD223b6cCfFe34A2649FeFf794A1B86D54F
```

Current keeper:

```text
0x1620c5fFEe9AFc74BA09Eb982cc034ae3f57a4F8
```

GitHub repository setup:

1. Push this project to a private GitHub repository.
2. Add repository secret `KEEPER_PRIVATE_KEY` from local `.env.keeper`.
3. Optional: add repository secret `BSC_RPC_URL`; otherwise the script uses the
   default BSC RPC.
4. Keep the keeper wallet funded with BNB for gas.

Never commit `.env` or `.env.keeper`.
