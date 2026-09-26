# app/chain.py
"""
Blockchain interaction layer for SleepStake on Monad testnet.
Handles Web3 connection, contract caching, read helpers, and EIP-1559 transaction sending.
"""

import os
import json
from pathlib import Path
from typing import Any
import streamlit as st
from web3 import Web3
from eth_account import Account
from eth_utils import function_signature_to_4byte_selector
from dotenv import load_dotenv

# Base paths
APP_DIR = Path(__file__).parent
ROOT_DIR = APP_DIR.parent
ABI_PATH = APP_DIR / "abi" / "SleepStake.json"

# Load local environment variables from .env
load_dotenv(ROOT_DIR / ".env")


def get_config_val(key: str, default: str = "") -> str:
    """Retrieve config from st.secrets first, then os.environ."""
    try:
        if hasattr(st, "secrets") and key in st.secrets:
            return str(st.secrets[key])
    except Exception:
        pass
    return os.environ.get(key, default)


# Configuration constants
DEFAULT_RPC_URL = get_config_val("RPC_URL", "https://testnet-rpc.monad.xyz")
FALLBACK_RPC_URL = "https://rpc.ankr.com/monad_testnet"
CHAIN_ID = int(get_config_val("CHAIN_ID", "10143"))
EXPLORER_BASE = "https://testnet.monadvision.com"


@st.cache_resource
def load_abi() -> list:
    """Load contract ABI from app/abi/SleepStake.json."""
    with open(ABI_PATH, "r") as f:
        return json.load(f)


@st.cache_resource
def get_web3(rpc_url: str = DEFAULT_RPC_URL) -> Web3:
    """Instantiate and cache Web3 provider."""
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    return w3


@st.cache_resource
def get_contract(contract_address: str, rpc_url: str = DEFAULT_RPC_URL):
    """Instantiate and cache contract instance."""
    w3 = get_web3(rpc_url)
    abi = load_abi()
    checksum = Web3.to_checksum_address(contract_address)
    return w3.eth.contract(address=checksum, abi=abi)


def get_address_from_key(private_key: str) -> str:
    """Derive public address from a private key without ever logging the key."""
    if not private_key:
        return ""
    key = private_key.strip()
    if not key.startswith("0x"):
        key = "0x" + key
    try:
        acc = Account.from_key(key)
        return acc.address
    except Exception:
        return ""


# Build custom error selector mapping
_ABI = load_abi()
ERROR_SELECTORS: dict[str, str] = {}
for item in _ABI:
    if item.get("type") == "error":
        name = item["name"]
        inputs = ",".join(inp["type"] for inp in item.get("inputs", []))
        sig = f"{name}({inputs})"
        sel = "0x" + function_signature_to_4byte_selector(sig).hex().lower()
        ERROR_SELECTORS[sel] = name

FRIENDLY_MESSAGES = {
    "AlreadyJoined": "You have already joined this challenge.",
    "AlreadyReported": "Sleep report for this player and night was already submitted.",
    "AlreadySettled": "This challenge has already been settled.",
    "CannotSettleYet": "Cannot settle yet: challenge duration must elapse or all players' reports must be submitted.",
    "ChallengeFull": "Challenge is full (maximum 50 players reached).",
    "ChallengeNotFound": "Challenge ID not found.",
    "IncorrectBuyIn": "Incorrect buy-in sent. You must send the exact buy-in amount.",
    "InvalidAddress": "Invalid address provided.",
    "InvalidBuyIn": "Buy-in must be greater than zero.",
    "InvalidNight": "Invalid night index.",
    "InvalidNights": "Duration must be between 1 and 30 nights.",
    "InvalidSleepTimes": "Sleep end time must be after sleep start time.",
    "JoinDeadlinePassed": "The deadline to join this challenge has passed.",
    "NothingToWithdraw": "No claimable balance available to withdraw.",
    "OnlyOracle": "Unauthorized: Only the designated oracle wallet can submit sleep data.",
    "OnlyOwner": "Unauthorized: Only the contract owner can perform this action.",
    "PlayerNotJoined": "This player has not joined the challenge.",
    "TransferFailed": "Native token transfer failed during withdrawal.",
}


def decode_error(exc: Exception) -> str:
    """Extract a friendly explanation from a Web3 transaction revert."""
    raw = str(exc)
    raw_lower = raw.lower()

    if "insufficient funds" in raw_lower:
        return "Insufficient MON in wallet to cover buy-in and gas fee."

    # Look for known 4-byte custom error selectors in the revert text
    for sel, err_name in ERROR_SELECTORS.items():
        if sel in raw_lower or err_name.lower() in raw_lower:
            return FRIENDLY_MESSAGES.get(err_name, f"Reverted: {err_name}")

    # Fallback to general revert reason if present
    if "execution reverted:" in raw:
        msg = raw.split("execution reverted:")[-1].strip()
        return f"Transaction reverted: {msg}"

    return f"Transaction failed: {raw}"


# --- Cached Read Functions ---

@st.cache_data(ttl=5)
def get_challenge_count(contract_address: str, rpc_url: str = DEFAULT_RPC_URL) -> int:
    contract = get_contract(contract_address, rpc_url)
    return contract.functions.challengeCount().call()


@st.cache_data(ttl=5)
def get_challenge(contract_address: str, challenge_id: int, rpc_url: str = DEFAULT_RPC_URL) -> dict[str, Any]:
    contract = get_contract(contract_address, rpc_url)
    c = contract.functions.getChallenge(challenge_id).call()
    return {
        "creator": c[0],
        "buy_in": c[1],
        "first_night_start": c[2],
        "nights": c[3],
        "join_deadline": c[4],
        "settled": c[5],
        "players": list(c[6]),
        "reports_submitted": c[7],
    }


@st.cache_data(ttl=5)
def get_players(contract_address: str, challenge_id: int, rpc_url: str = DEFAULT_RPC_URL) -> list[str]:
    contract = get_contract(contract_address, rpc_url)
    return list(contract.functions.getPlayers(challenge_id).call())


@st.cache_data(ttl=5)
def get_player_status(
    contract_address: str, challenge_id: int, player_address: str, rpc_url: str = DEFAULT_RPC_URL
) -> tuple[int, list[bool], list[bool]]:
    contract = get_contract(contract_address, rpc_url)
    checksum = Web3.to_checksum_address(player_address)
    res = contract.functions.getPlayerStatus(challenge_id, checksum).call()
    # (nightsPassed, reportedArray, passedArray)
    return (res[0], list(res[1]), list(res[2]))


@st.cache_data(ttl=5)
def get_claimable(contract_address: str, account_address: str, rpc_url: str = DEFAULT_RPC_URL) -> int:
    contract = get_contract(contract_address, rpc_url)
    checksum = Web3.to_checksum_address(account_address)
    return contract.functions.claimable(checksum).call()


@st.cache_data(ttl=5)
def get_balance(account_address: str, rpc_url: str = DEFAULT_RPC_URL) -> int:
    w3 = get_web3(rpc_url)
    checksum = Web3.to_checksum_address(account_address)
    return w3.eth.get_balance(checksum)


@st.cache_data(ttl=5)
def get_oracle(contract_address: str, rpc_url: str = DEFAULT_RPC_URL) -> str:
    contract = get_contract(contract_address, rpc_url)
    return contract.functions.oracle().call()


@st.cache_data(ttl=5)
def get_owner(contract_address: str, rpc_url: str = DEFAULT_RPC_URL) -> str:
    contract = get_contract(contract_address, rpc_url)
    return contract.functions.owner().call()


# --- Transaction Sending ---

def send_tx(
    private_key: str,
    contract_function,
    value_wei: int = 0,
    rpc_url: str = DEFAULT_RPC_URL,
    chain_id: int = CHAIN_ID,
) -> tuple[str, str]:
    """
    Build, estimate gas (+20% safety margin for Monad), sign, and send transaction.
    Raises an exception if reverted. Clears st.cache_data on success.
    Returns (tx_hash_hex, explorer_url).
    """
    key = private_key.strip()
    if not key.startswith("0x"):
        key = "0x" + key

    w3 = get_web3(rpc_url)
    account = Account.from_key(key)
    sender = account.address

    # Nonce from pending pool
    nonce = w3.eth.get_transaction_count(sender, "pending")

    # EIP-1559 gas fee estimation
    latest_block = w3.eth.get_block("latest")
    base_fee = latest_block.get("baseFeePerGas", w3.to_wei(1, "gwei"))
    try:
        max_priority_fee = w3.eth.max_priority_fee
    except Exception:
        max_priority_fee = w3.to_wei(2, "gwei")
    max_fee = base_fee * 2 + max_priority_fee

    tx_params = {
        "from": sender,
        "nonce": nonce,
        "value": value_wei,
        "chainId": chain_id,
        "maxFeePerGas": max_fee,
        "maxPriorityFeePerGas": max_priority_fee,
    }

    # Estimate gas and apply 20% buffer (Monad charges based on gas LIMIT)
    estimated_gas = contract_function.estimate_gas(tx_params)
    gas_limit = int(estimated_gas * 1.2)
    tx_params["gas"] = gas_limit

    # Build transaction
    tx = contract_function.build_transaction(tx_params)

    # Sign using web3 v7 snake_case API (signed.raw_transaction)
    signed = w3.eth.account.sign_transaction(tx, private_key=key)

    # Broadcast transaction
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    tx_hash_hex = "0x" + tx_hash.hex() if not tx_hash.hex().startswith("0x") else tx_hash.hex()

    # Wait for receipt
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.get("status") == 0:
        raise RuntimeError(f"Transaction failed onchain: {tx_hash_hex}")

    # Invalidate cached read calls so the UI immediately updates
    st.cache_data.clear()

    explorer_link = f"{EXPLORER_BASE}/tx/{tx_hash_hex}"
    return tx_hash_hex, explorer_link
