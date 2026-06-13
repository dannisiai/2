from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

from eth_account import Account
from web3 import Web3

from common import (
    BSC_CHAIN_ID,
    CONTRACT_NAME,
    DEFAULT_BSC_RPC_URL,
    DEPLOYMENT_FILE,
    OPTIMIZER,
    PANCAKE_ROUTER_V2,
    SOLC_LONG_VERSION,
    compile_contract,
    deployment_file_for_address,
    get_private_key,
    load_dotenv,
    write_json,
)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    load_dotenv()

    key_name, private_key = get_private_key()
    if not private_key:
        fail("Missing DEPLOYER_PRIVATE_KEY, BSC_PRIVATE_KEY, or PRIVATE_KEY in environment/.env")

    rpc_url = os.getenv("BSC_RPC_URL", DEFAULT_BSC_RPC_URL).strip()
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        fail(f"Cannot connect to BSC RPC: {rpc_url}")

    chain_id = w3.eth.chain_id
    if chain_id != BSC_CHAIN_ID:
        fail(f"RPC chain id is {chain_id}; expected BSC mainnet chain id {BSC_CHAIN_ID}")

    router = Web3.to_checksum_address(PANCAKE_ROUTER_V2)
    if len(w3.eth.get_code(router)) == 0:
        fail(f"PancakeSwap V2 router has no code at {router} on this RPC")

    account = Account.from_key(private_key)
    balance = w3.eth.get_balance(account.address)
    print(f"Deployer: {account.address} via {key_name}")
    print(f"Balance: {Web3.from_wei(balance, 'ether')} BNB")

    _, abi, bytecode = compile_contract()
    contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    gas_estimate = contract.constructor().estimate_gas({"from": account.address})
    gas = int(gas_estimate * 120 // 100)
    gas_price = w3.eth.gas_price
    max_cost = gas * gas_price
    print(f"Estimated gas: {gas_estimate}; using gas limit {gas}")
    print(f"Gas price: {Web3.from_wei(gas_price, 'gwei')} gwei")
    print(f"Max deploy cost: {Web3.from_wei(max_cost, 'ether')} BNB")

    if balance < max_cost:
        fail("Deployer balance is too low for the estimated deployment cost")

    tx = contract.constructor().build_transaction(
        {
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "gas": gas,
            "gasPrice": gas_price,
            "chainId": chain_id,
        }
    )

    signed = account.sign_transaction(tx)
    raw_tx = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    tx_hash_hex = tx_hash.hex()
    print(f"Deployment tx sent: {tx_hash_hex}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300, poll_latency=5)
    if receipt.status != 1:
        fail(f"Deployment transaction reverted: {tx_hash_hex}")

    deployment = {
        "address": receipt.contractAddress,
        "abi": abi,
        "blockNumber": receipt.blockNumber,
        "chainId": chain_id,
        "contractName": CONTRACT_NAME,
        "deployedAt": datetime.now(timezone.utc).isoformat(),
        "deployer": account.address,
        "effectiveGasPrice": str(getattr(receipt, "effectiveGasPrice", gas_price)),
        "gasUsed": receipt.gasUsed,
        "network": "bsc-mainnet",
        "optimizer": OPTIMIZER,
        "solcVersion": SOLC_LONG_VERSION,
        "transactionHash": tx_hash_hex,
    }
    address_deployment_file = deployment_file_for_address(receipt.contractAddress)
    write_json(address_deployment_file, deployment)
    write_json(DEPLOYMENT_FILE, deployment)

    print(f"Deployed {CONTRACT_NAME}: {receipt.contractAddress}")
    print(f"Address deployment info: {address_deployment_file}")
    print(f"Deployment info: {DEPLOYMENT_FILE}")


if __name__ == "__main__":
    main()
