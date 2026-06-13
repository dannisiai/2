from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from common import (
    BSC_CHAIN_ID,
    DEPLOYMENT_FILE,
    ETHERSCAN_V2_API_URL,
    FQ_CONTRACT_NAME,
    SOLC_LONG_VERSION,
    deployment_file_for_address,
    load_dotenv,
    standard_json_input,
    write_json,
)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


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


def main() -> None:
    load_dotenv()

    api_key = (os.getenv("ETHERSCAN_API_KEY") or os.getenv("BSCSCAN_API_KEY") or "").strip()
    if not api_key:
        fail("Missing ETHERSCAN_API_KEY or BSCSCAN_API_KEY in environment/.env")

    if not DEPLOYMENT_FILE.exists():
        fail(f"Missing deployment file: {DEPLOYMENT_FILE}. Run scripts/deploy_bsc.py first.")

    deployment = json.loads(DEPLOYMENT_FILE.read_text(encoding="utf-8"))
    address = deployment["address"]
    verification_files = [
        Path(str(DEPLOYMENT_FILE) + ".verification.json"),
        Path(str(deployment_file_for_address(address)) + ".verification.json"),
    ]
    compiler_input = json.dumps(standard_json_input(), separators=(",", ":"))

    submit_fields = {
        "apikey": api_key,
        "chainid": str(BSC_CHAIN_ID),
        "module": "contract",
        "action": "verifysourcecode",
        "contractaddress": address,
        "sourceCode": compiler_input,
        "codeformat": "solidity-standard-json-input",
        "contractname": FQ_CONTRACT_NAME,
        "compilerversion": SOLC_LONG_VERSION,
        "optimizationUsed": "0",
        "runs": "200",
        "constructorArguements": "",
        "licenseType": "3",
    }

    submit = post_form(submit_fields)
    print(f"BscScan submit status: {submit.get('message')} - {submit.get('result')}")

    result = str(submit.get("result", ""))
    if is_success_text(result):
        for verification_file in verification_files:
            write_json(verification_file, submit)
        print(f"Verified: https://bscscan.com/address/{address}#code")
        return

    if submit.get("status") != "1":
        fail(f"BscScan rejected verification request: {submit}")

    guid = result
    check_fields = {
        "apikey": api_key,
        "chainid": str(BSC_CHAIN_ID),
        "module": "contract",
        "action": "checkverifystatus",
        "guid": guid,
    }

    for _ in range(24):
        time.sleep(10)
        check = post_form(check_fields)
        status_result = str(check.get("result", ""))
        print(f"BscScan check: {check.get('message')} - {status_result}")
        if check.get("status") == "1" or is_success_text(status_result):
            for verification_file in verification_files:
                write_json(verification_file, check)
            print(f"Verified: https://bscscan.com/address/{address}#code")
            return
        if "pending" not in status_result.lower() and "queue" not in status_result.lower():
            fail(f"BscScan verification failed: {check}")

    fail("Timed out waiting for BscScan verification")


if __name__ == "__main__":
    main()
