from __future__ import annotations

from common import (
    ARTIFACT_DIR,
    CONTRACT_NAME,
    FQ_CONTRACT_NAME,
    SOLC_LONG_VERSION,
    compile_contract,
    standard_json_input,
    write_json,
)


def main() -> None:
    compiled, abi, bytecode = compile_contract()

    write_json(ARTIFACT_DIR / f"{CONTRACT_NAME}.compiler-input.json", standard_json_input())
    write_json(ARTIFACT_DIR / f"{CONTRACT_NAME}.compiled.json", compiled)
    write_json(
        ARTIFACT_DIR / f"{CONTRACT_NAME}.abi.json",
        {"contract": FQ_CONTRACT_NAME, "abi": abi},
    )

    print(f"Compiled {FQ_CONTRACT_NAME}")
    print(f"Compiler: {SOLC_LONG_VERSION}")
    print(f"Deployment bytecode: {(len(bytecode) - 2) // 2} bytes")
    print(f"Artifacts: {ARTIFACT_DIR}")


if __name__ == "__main__":
    main()
