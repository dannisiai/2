from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

from eth_account import Account
from web3 import Web3

from common import BSC_CHAIN_ID, DEFAULT_BSC_RPC_URL, get_private_key, load_dotenv


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_PATH = ROOT / "artifacts" / "flap-dual-feature" / "compiled.json"

MINIMAL_VAULT_ABI: list[dict[str, Any]] = [
    {
        "inputs": [],
        "name": "owner",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "keeper",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "buybackToken",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "configLocked",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "automationEnabled",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "lastBuybackTime",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "bytes"}],
        "name": "checkUpkeep",
        "outputs": [
            {"name": "upkeepNeeded", "type": "bool"},
            {"name": "performData", "type": "bytes"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "executeBuyback",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, default=str))


def connect_web3(rpc_url: str) -> Web3 | None:
    for attempt in range(1, 6):
        w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
        try:
            if w3.is_connected() and w3.eth.chain_id == BSC_CHAIN_ID:
                return w3
        except Exception:
            pass
        if attempt < 5:
            time.sleep(8)
    return None


def load_vault_abi() -> list[dict[str, Any]]:
    if not ARTIFACT_PATH.exists():
        return MINIMAL_VAULT_ABI

    compiled = json.loads(ARTIFACT_PATH.read_text(encoding="utf-8"))
    return compiled["contracts"]["contracts/FlapDualFeatureVaultFactory.sol"][
        "FlapDualFeatureVault"
    ]["abi"]


def main() -> int:
    load_dotenv()

    vault_address = Web3.to_checksum_address(
        os.getenv("BUYBACK_VAULT_ADDRESS", "0x7563CaD223b6cCfFe34A2649FeFf794A1B86D54F")
    )

    key_name, private_key = get_private_key()
    if not private_key:
        emit({"status": "error", "reason": "missing private key"})
        return 1

    rpc_url = (os.getenv("BSC_RPC_URL") or DEFAULT_BSC_RPC_URL).strip()
    w3 = connect_web3(rpc_url)
    if w3 is None:
        emit({"status": "error", "reason": f"cannot connect to BSC RPC after retries: {rpc_url}"})
        return 1

    account = Account.from_key(private_key)
    vault = w3.eth.contract(address=vault_address, abi=load_vault_abi())

    owner = Web3.to_checksum_address(vault.functions.owner().call())
    keeper = vault.functions.keeper().call()
    signer = Web3.to_checksum_address(account.address)
    if signer != owner and Web3.to_checksum_address(keeper) != signer:
        emit(
            {
                "status": "skip",
                "reason": "signer is not owner or keeper",
                "signer": signer,
                "owner": owner,
                "keeper": keeper,
            }
        )
        return 0

    check_upkeep = vault.functions.checkUpkeep(b"").call()
    state = {
        "signer": signer,
        "keyName": key_name,
        "vault": vault_address,
        "signerBnbWei": w3.eth.get_balance(signer),
        "vaultBnbWei": w3.eth.get_balance(vault_address),
        "buybackToken": vault.functions.buybackToken().call(),
        "configLocked": vault.functions.configLocked().call(),
        "automationEnabled": vault.functions.automationEnabled().call(),
        "lastBuybackTime": vault.functions.lastBuybackTime().call(),
        "checkUpkeep": check_upkeep,
    }

    if not check_upkeep[0]:
        emit({"status": "skip", "reason": "checkUpkeep false", "state": state})
        return 0

    fn = vault.functions.executeBuyback()
    try:
        gas_estimate = fn.estimate_gas({"from": signer})
    except Exception as exc:
        emit(
            {
                "status": "skip",
                "reason": "executeBuyback gas estimate failed",
                "error": str(exc),
                "state": state,
            }
        )
        return 0

    gas_price = w3.eth.gas_price
    gas_limit = int(gas_estimate * 130 // 100) + 30_000
    max_cost = gas_limit * gas_price
    if state["signerBnbWei"] < max_cost:
        emit(
            {
                "status": "skip",
                "reason": "insufficient signer BNB for gas",
                "gasEstimate": gas_estimate,
                "gasLimit": gas_limit,
                "gasPrice": gas_price,
                "maxCostWei": max_cost,
                "state": state,
            }
        )
        return 0

    tx = fn.build_transaction(
        {
            "from": signer,
            "nonce": w3.eth.get_transaction_count(signer, "pending"),
            "gas": gas_limit,
            "gasPrice": gas_price,
            "chainId": BSC_CHAIN_ID,
        }
    )
    signed = account.sign_transaction(tx)
    raw_tx = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300, poll_latency=3)

    if receipt.status != 1:
        emit(
            {
                "status": "error",
                "reason": "executeBuyback transaction reverted",
                "tx": "0x" + tx_hash.hex(),
                "state": state,
            }
        )
        return 1

    emit(
        {
            "status": "executed",
            "tx": "0x" + tx_hash.hex(),
            "gasUsed": receipt.gasUsed,
            "before": state,
            "after": {
                "signerBnbWei": w3.eth.get_balance(signer),
                "vaultBnbWei": w3.eth.get_balance(vault_address),
                "lastBuybackTime": vault.functions.lastBuybackTime().call(),
                "checkUpkeep": vault.functions.checkUpkeep(b"").call(),
            },
        }
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
