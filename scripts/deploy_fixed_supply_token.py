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
SOURCE_KEY = "contracts/FixedSupplyToken.sol"
SOURCE_PATH = ROOT / SOURCE_KEY
CONTRACT_NAME = "FixedSupplyToken"
OPTIMIZER = {"enabled": False, "runs": 200}
DEPLOYMENT_DIR = ROOT / "deployments" / "bsc-mainnet"
DEPLOYMENT_FILE = DEPLOYMENT_DIR / f"{CONTRACT_NAME}.json"
ARTIFACT_DIR = ROOT / "artifacts" / CONTRACT_NAME

TOKEN_NAME = os.getenv("TOKEN_NAME", "1")
TOKEN_SYMBOL = os.getenv("TOKEN_SYMBOL", "1")
TOKEN_SUPPLY = int(os.getenv("TOKEN_SUPPLY", "100"))
TOKEN_DECIMALS = 18


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


def compile_contract() -> tuple[dict[str, Any], list[dict[str, Any]], str]:
    from solcx import compile_standard, set_solc_version

    ensure_solc()
    set_solc_version("0.8.24")
    compiler_input = standard_json_input()
    compiled = compile_standard(compiler_input, allow_paths=str(ROOT))
    contract = compiled["contracts"][SOURCE_KEY][CONTRACT_NAME]
    bytecode = contract["evm"]["bytecode"]["object"]
    deployed = contract["evm"]["deployedBytecode"]["object"]

    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    write_json(ARTIFACT_DIR / "compiler-input.json", compiler_input)
    write_json(ARTIFACT_DIR / "compiled.json", compiled)

    print(f"Deployment bytecode: {len(bytecode) // 2} bytes")
    print(f"Runtime bytecode: {len(deployed) // 2} bytes")
    return compiled, contract["abi"], bytecode


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


def verify_contract(address: str, constructor_args: str, api_key: str) -> dict[str, Any]:
    compiler_input = json.dumps(standard_json_input(), separators=(",", ":"))
    submit_fields = {
        "apikey": api_key,
        "chainid": str(BSC_CHAIN_ID),
        "module": "contract",
        "action": "verifysourcecode",
        "contractaddress": address,
        "sourceCode": compiler_input,
        "codeformat": "solidity-standard-json-input",
        "contractname": f"{SOURCE_KEY}:{CONTRACT_NAME}",
        "compilerversion": SOLC_LONG_VERSION,
        "optimizationUsed": "0",
        "runs": "200",
        "constructorArguements": constructor_args,
        "licenseType": "3",
    }
    submit = post_form(submit_fields)
    print(f"Verify submit: {submit.get('message')} - {submit.get('result')}")
    result = str(submit.get("result", ""))
    if is_success_text(result):
        return submit
    if submit.get("status") != "1":
        fail(f"Verification rejected: {submit}")

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
        print(f"Verify check: {check.get('message')} - {status_result}")
        if check.get("status") == "1" or is_success_text(status_result):
            return check
        if "pending" not in status_result.lower() and "queue" not in status_result.lower():
            fail(f"Verification failed: {check}")

    fail("Timed out waiting for verification")


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
    if w3.eth.chain_id != BSC_CHAIN_ID:
        fail(f"RPC chain id is {w3.eth.chain_id}; expected {BSC_CHAIN_ID}")

    account = Account.from_key(private_key)
    receiver = Web3.to_checksum_address(os.getenv("TOKEN_RECEIVER", account.address).strip())
    initial_supply = TOKEN_SUPPLY * (10**TOKEN_DECIMALS)

    print(f"Deployer: {account.address} via {key_name}")
    print(f"Receiver: {receiver}")
    print(f"Token: name={TOKEN_NAME!r}, symbol={TOKEN_SYMBOL!r}, supply={TOKEN_SUPPLY}")
    print(f"Balance: {Web3.from_wei(w3.eth.get_balance(account.address), 'ether')} BNB")

    _, abi, bytecode = compile_contract()
    contract = w3.eth.contract(abi=abi, bytecode="0x" + bytecode)
    constructor = contract.constructor(TOKEN_NAME, TOKEN_SYMBOL, initial_supply, receiver)

    gas_estimate = constructor.estimate_gas({"from": account.address})
    gas = int(gas_estimate * 120 // 100)
    gas_price = w3.eth.gas_price
    max_cost = gas * gas_price
    balance = w3.eth.get_balance(account.address)
    print(f"Estimated gas: {gas_estimate}; using gas limit {gas}")
    print(f"Gas price: {Web3.from_wei(gas_price, 'gwei')} gwei")
    print(f"Max deploy cost: {Web3.from_wei(max_cost, 'ether')} BNB")
    if balance < max_cost:
        fail("Deployer balance is too low for the estimated deployment cost")

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
    print(f"Deployment tx sent: {tx_hash.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300, poll_latency=5)
    if receipt.status != 1:
        fail(f"Deployment transaction reverted: {tx_hash.hex()}")

    constructor_data = constructor.data_in_transaction
    full_bytecode = "0x" + bytecode
    constructor_args = constructor_data[len(full_bytecode) :]
    if constructor_args.startswith("0x"):
        constructor_args = constructor_args[2:]

    deployment = {
        "address": receipt.contractAddress,
        "abi": abi,
        "blockNumber": receipt.blockNumber,
        "chainId": BSC_CHAIN_ID,
        "contractName": CONTRACT_NAME,
        "constructorArgs": constructor_args,
        "deployedAt": datetime.now(timezone.utc).isoformat(),
        "deployer": account.address,
        "gasUsed": receipt.gasUsed,
        "network": "bsc-mainnet",
        "optimizer": OPTIMIZER,
        "receiver": receiver,
        "solcVersion": SOLC_LONG_VERSION,
        "tokenDecimals": TOKEN_DECIMALS,
        "tokenName": TOKEN_NAME,
        "tokenSupply": str(initial_supply),
        "tokenSymbol": TOKEN_SYMBOL,
        "transactionHash": tx_hash.hex(),
    }
    write_json(DEPLOYMENT_FILE, deployment)
    write_json(
        DEPLOYMENT_DIR / f"{CONTRACT_NAME}-{receipt.contractAddress.lower()}.json",
        deployment,
    )
    print(f"Deployed {CONTRACT_NAME}: {receipt.contractAddress}")

    verification = verify_contract(receipt.contractAddress, constructor_args, api_key)
    write_json(Path(str(DEPLOYMENT_FILE) + ".verification.json"), verification)
    write_json(
        DEPLOYMENT_DIR / f"{CONTRACT_NAME}-{receipt.contractAddress.lower()}.json.verification.json",
        verification,
    )
    print(f"Verified: https://bscscan.com/address/{receipt.contractAddress}#code")
    print(f"Deployment info: {DEPLOYMENT_FILE}")


if __name__ == "__main__":
    main()
