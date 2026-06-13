from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from solcx import compile_standard, get_installed_solc_versions, install_solc, set_solc_version


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_NAME = "AutoBNBBuybackBurnTreasury"
SOURCE_KEY = f"contracts/{CONTRACT_NAME}.sol"
CONTRACT_PATH = ROOT / SOURCE_KEY
FQ_CONTRACT_NAME = f"{SOURCE_KEY}:{CONTRACT_NAME}"

SOLC_VERSION = "0.8.24"
SOLC_LONG_VERSION = "v0.8.24+commit.e11b9ed9"
OPTIMIZER = {"enabled": False, "runs": 200}

BSC_CHAIN_ID = 56
DEFAULT_BSC_RPC_URL = "https://bsc-dataseed.bnbchain.org"
ETHERSCAN_V2_API_URL = "https://api.etherscan.io/v2/api"
PANCAKE_ROUTER_V2 = "0x10ED43C718714eb63d5aA57B78B54704E256024E"

ARTIFACT_DIR = ROOT / "artifacts"
DEPLOYMENT_DIR = ROOT / "deployments" / "bsc-mainnet"
DEPLOYMENT_FILE = DEPLOYMENT_DIR / f"{CONTRACT_NAME}.json"


def deployment_file_for_address(address: str) -> Path:
    normalized = address.lower()
    return DEPLOYMENT_DIR / f"{CONTRACT_NAME}-{normalized}.json"


def load_dotenv() -> None:
    env_path = ROOT / ".env"
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def get_private_key() -> tuple[str | None, str | None]:
    for name in ("DEPLOYER_PRIVATE_KEY", "BSC_PRIVATE_KEY", "PRIVATE_KEY"):
        value = os.getenv(name)
        if value:
            value = value.strip()
            if value in {"0x", "0xYOUR_PRIVATE_KEY_WITHOUT_FUNDS_YOU_CANNOT_DEPLOY"}:
                continue
            if not value.startswith("0x"):
                value = "0x" + value
            return name, value
    return None, None


def standard_json_input() -> dict[str, Any]:
    source = CONTRACT_PATH.read_text(encoding="utf-8")
    return {
        "language": "Solidity",
        "sources": {SOURCE_KEY: {"content": source}},
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


def ensure_solc() -> None:
    installed = {str(version) for version in get_installed_solc_versions()}
    if SOLC_VERSION not in installed:
        print(f"Installing solc {SOLC_VERSION}...")
        install_solc(SOLC_VERSION)
    set_solc_version(SOLC_VERSION)


def compile_contract() -> tuple[dict[str, Any], list[dict[str, Any]], str]:
    ensure_solc()
    compiler_input = standard_json_input()
    compiled = compile_standard(compiler_input, allow_paths=str(ROOT))
    contract = compiled["contracts"][SOURCE_KEY][CONTRACT_NAME]
    abi = contract["abi"]
    bytecode = contract["evm"]["bytecode"]["object"]
    if not bytecode:
        raise RuntimeError("Compiler produced empty deployment bytecode")
    return compiled, abi, "0x" + bytecode


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
