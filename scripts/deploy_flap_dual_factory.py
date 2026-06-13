from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from eth_account import Account
from web3 import Web3

from common import (
    BSC_CHAIN_ID,
    DEFAULT_BSC_RPC_URL,
    ETHERSCAN_V2_API_URL,
    SOLC_LONG_VERSION,
    ensure_solc,
    get_private_key,
    load_dotenv,
    write_json,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_KEY = "contracts/FlapDualFeatureVaultFactory.sol"
SOURCE_PATH = ROOT / SOURCE_KEY
SOLC_VERSION = "0.8.24"
OPTIMIZER = {"enabled": True, "runs": 200}
DEPLOYMENT_DIR = ROOT / "deployments" / "bsc-mainnet"
DEPLOYMENT_FILE = DEPLOYMENT_DIR / "FlapDualFeatureVaultFactory.json"
ARTIFACT_DIR = ROOT / "artifacts" / "flap-dual-feature"

MARKET = "WorldCupPredictionMarket"
VAULT = "FlapDualFeatureVault"
FACTORY = "FlapDualFeatureVaultFactory"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def standard_json_input() -> dict[str, Any]:
    return {
        "language": "Solidity",
        "sources": {SOURCE_KEY: {"content": SOURCE_PATH.read_text(encoding="utf-8")}},
        "settings": {
            "optimizer": OPTIMIZER,
            "outputSelection": {
                "*": {
                    "*": [
                        "abi",
                        "evm.bytecode.object",
                        "evm.deployedBytecode.object",
                        "metadata",
                    ]
                }
            },
        },
    }


def compile_all() -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    from solcx import compile_standard, set_solc_version

    ensure_solc()
    set_solc_version(SOLC_VERSION)
    compiler_input = standard_json_input()
    compiled = compile_standard(compiler_input, allow_paths=str(ROOT))
    contracts = compiled["contracts"][SOURCE_KEY]

    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    write_json(ARTIFACT_DIR / "compiler-input.json", compiler_input)
    write_json(ARTIFACT_DIR / "compiled.json", compiled)

    for name in (MARKET, VAULT, FACTORY):
        contract = contracts[name]
        deployed = contract["evm"]["deployedBytecode"]["object"]
        bytecode = contract["evm"]["bytecode"]["object"]
        print(
            f"{name}: deployment {(len(bytecode)) // 2} bytes, runtime {(len(deployed)) // 2} bytes"
        )
        if len(deployed) // 2 > 24576:
            fail(f"{name} runtime bytecode exceeds EVM 24KB limit")

    return compiled, contracts


def deploy_contract(
    w3: Web3,
    account: Any,
    name: str,
    abi: list[dict[str, Any]],
    bytecode: str,
    args: tuple[Any, ...] = (),
) -> dict[str, Any]:
    contract = w3.eth.contract(abi=abi, bytecode="0x" + bytecode)
    constructor = contract.constructor(*args)
    gas_estimate = constructor.estimate_gas({"from": account.address})
    gas = int(gas_estimate * 120 // 100)
    gas_price = w3.eth.gas_price
    max_cost = gas * gas_price
    balance = w3.eth.get_balance(account.address)

    print(f"{name}: estimated gas {gas_estimate}; using gas limit {gas}")
    print(f"{name}: max deploy cost {Web3.from_wei(max_cost, 'ether')} BNB")
    if balance < max_cost:
        fail(f"Deployer balance is too low for {name}")

    tx = constructor.build_transaction(
        {
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "gas": gas,
            "gasPrice": gas_price,
            "chainId": BSC_CHAIN_ID,
        }
    )
    signed = account.sign_transaction(tx)
    raw_tx = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    print(f"{name}: tx sent {tx_hash.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300, poll_latency=5)
    if receipt.status != 1:
        fail(f"{name} deployment reverted: {tx_hash.hex()}")

    constructor_data = constructor.data_in_transaction
    full_bytecode = "0x" + bytecode
    constructor_args = constructor_data[len(full_bytecode) :]
    if constructor_args.startswith("0x"):
        constructor_args = constructor_args[2:]

    print(f"{name}: deployed {receipt.contractAddress}")
    return {
        "address": receipt.contractAddress,
        "constructorArgs": constructor_args,
        "gasUsed": receipt.gasUsed,
        "transactionHash": tx_hash.hex(),
    }


def post_form(fields: dict[str, str]) -> dict[str, Any]:
    chain_id = fields.pop("chainid", str(BSC_CHAIN_ID))
    url = f"{ETHERSCAN_V2_API_URL}?chainid={urllib.parse.quote(chain_id)}"
    body = urllib.parse.urlencode(fields).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def is_success_text(value: str) -> bool:
    lowered = value.lower()
    return "pass - verified" in lowered or "already verified" in lowered


def verify_contract(
    address: str,
    contract_name: str,
    constructor_args: str,
    api_key: str,
) -> dict[str, Any]:
    compiler_input = json.dumps(standard_json_input(), separators=(",", ":"))
    submit_fields = {
        "apikey": api_key,
        "chainid": str(BSC_CHAIN_ID),
        "module": "contract",
        "action": "verifysourcecode",
        "contractaddress": address,
        "sourceCode": compiler_input,
        "codeformat": "solidity-standard-json-input",
        "contractname": f"{SOURCE_KEY}:{contract_name}",
        "compilerversion": SOLC_LONG_VERSION,
        "optimizationUsed": "1",
        "runs": "200",
        "constructorArguements": constructor_args,
        "licenseType": "3",
    }
    submit = post_form(submit_fields)
    print(f"{contract_name}: verify submit {submit.get('message')} - {submit.get('result')}")
    result = str(submit.get("result", ""))
    if is_success_text(result):
        return submit
    if submit.get("status") != "1":
        fail(f"{contract_name}: verification rejected: {submit}")

    check_fields = {
        "apikey": api_key,
        "chainid": str(BSC_CHAIN_ID),
        "module": "contract",
        "action": "checkverifystatus",
        "guid": result,
    }

    for _ in range(24):
        time.sleep(10)
        check = post_form(check_fields)
        status_result = str(check.get("result", ""))
        print(f"{contract_name}: verify check {check.get('message')} - {status_result}")
        if check.get("status") == "1" or is_success_text(status_result):
            return check
        if "pending" not in status_result.lower() and "queue" not in status_result.lower():
            fail(f"{contract_name}: verification failed: {check}")

    fail(f"{contract_name}: timed out waiting for verification")


def main() -> None:
    load_dotenv()
    key_name, private_key = get_private_key()
    if not private_key:
        fail("Missing DEPLOYER_PRIVATE_KEY, BSC_PRIVATE_KEY, or PRIVATE_KEY in environment/.env")

    api_key = (os.getenv("ETHERSCAN_API_KEY") or os.getenv("BSCSCAN_API_KEY") or "").strip()
    if not api_key:
        fail("Missing ETHERSCAN_API_KEY or BSCSCAN_API_KEY in environment/.env")

    rpc_url = os.getenv("BSC_RPC_URL", DEFAULT_BSC_RPC_URL).strip()
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        fail(f"Cannot connect to BSC RPC: {rpc_url}")
    chain_id = w3.eth.chain_id
    if chain_id != BSC_CHAIN_ID:
        fail(f"RPC chain id is {chain_id}; expected {BSC_CHAIN_ID}")

    account = Account.from_key(private_key)
    print(f"Deployer: {account.address} via {key_name}")
    print(f"Balance: {Web3.from_wei(w3.eth.get_balance(account.address), 'ether')} BNB")

    _, contracts = compile_all()

    market = contracts[MARKET]
    vault = contracts[VAULT]
    factory = contracts[FACTORY]

    market_deployment = deploy_contract(
        w3,
        account,
        MARKET,
        market["abi"],
        market["evm"]["bytecode"]["object"],
    )
    vault_deployment = deploy_contract(
        w3,
        account,
        VAULT,
        vault["abi"],
        vault["evm"]["bytecode"]["object"],
    )
    factory_deployment = deploy_contract(
        w3,
        account,
        FACTORY,
        factory["abi"],
        factory["evm"]["bytecode"]["object"],
        (
            Web3.to_checksum_address(vault_deployment["address"]),
            Web3.to_checksum_address(market_deployment["address"]),
        ),
    )

    deployment = {
        "deployedAt": datetime.now(timezone.utc).isoformat(),
        "deployer": account.address,
        "network": "bsc-mainnet",
        "chainId": BSC_CHAIN_ID,
        "source": SOURCE_KEY,
        "compiler": SOLC_LONG_VERSION,
        "optimizer": OPTIMIZER,
        "contracts": {
            MARKET: {
                **market_deployment,
                "abi": market["abi"],
            },
            VAULT: {
                **vault_deployment,
                "abi": vault["abi"],
            },
            FACTORY: {
                **factory_deployment,
                "abi": factory["abi"],
            },
        },
    }
    write_json(DEPLOYMENT_FILE, deployment)
    write_json(
        DEPLOYMENT_DIR / f"FlapDualFeatureVaultFactory-{factory_deployment['address'].lower()}.json",
        deployment,
    )

    verification = {}
    for name, info in deployment["contracts"].items():
        verification[name] = verify_contract(
            info["address"],
            name,
            info["constructorArgs"],
            api_key,
        )
        print(f"{name}: verified https://bscscan.com/address/{info['address']}#code")
    write_json(Path(str(DEPLOYMENT_FILE) + ".verification.json"), verification)

    print(f"Factory: {factory_deployment['address']}")
    print(f"Vault implementation: {vault_deployment['address']}")
    print(f"Prediction market implementation: {market_deployment['address']}")
    print(f"Deployment info: {DEPLOYMENT_FILE}")


if __name__ == "__main__":
    main()
