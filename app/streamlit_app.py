# app/streamlit_app.py
"""
SleepStake Web App - Built for Monad Blitz Hackathon.
Interactive UI for joining challenges, submitting oracle sleep reports,
tracking the live leaderboard, and settling/withdrawing rewards.
"""

import time
from datetime import datetime
from zoneinfo import ZoneInfo
import streamlit as st
from web3 import Web3

# Streamlit adds this file's own folder (app/) to Python's import path,
# so we import sibling modules by their plain names, not as app.chain.
from chain import (
    get_config_val,
    get_web3,
    get_contract,
    get_address_from_key,
    get_challenge_count,
    get_challenge,
    get_players,
    get_player_status,
    get_claimable,
    get_balance,
    get_owner,
    get_oracle,
    send_tx,
    decode_error,
    DEFAULT_RPC_URL,
    CHAIN_ID,
    EXPLORER_BASE,
)
from health import MockHealthProvider, BERLIN_TZ

# Page configuration
st.set_page_config(
    page_title="SleepStake | Monad",
    page_icon="🌙",
    layout="wide",
    initial_sidebar_state="expanded",
)

# Custom styling
st.markdown(
    """
    <style>
    .badge {
        display: inline-block;
        padding: 4px 10px;
        font-size: 13px;
        font-weight: 600;
        border-radius: 12px;
        background-color: #7B3FE4;
        color: white;
        margin-left: 8px;
    }
    .metric-card {
        background-color: #1e1e2f;
        padding: 15px;
        border-radius: 10px;
        border: 1px solid #33334d;
        margin-bottom: 10px;
    }
    </style>
    """,
    unsafe_allow_html=True,
)

# Load configuration values
contract_addr = get_config_val("CONTRACT_ADDRESS", "").strip()
# No default password: the repo is public, so a default would be a known password.
oracle_panel_pw = get_config_val("ORACLE_PANEL_PASSWORD", "").strip()
oracle_key = get_config_val("ORACLE_PRIVATE_KEY", "").strip()
kai_key = get_config_val("PLAYER_KAI_KEY", "").strip()
alice_key = get_config_val("PLAYER_ALICE_KEY", "").strip()
bob_key = get_config_val("PLAYER_BOB_KEY", "").strip()

# Derive player wallets
DEMO_WALLETS = {
    "Kai": {"key": kai_key, "addr": get_address_from_key(kai_key)},
    "Alice": {"key": alice_key, "addr": get_address_from_key(alice_key)},
    "Bob": {"key": bob_key, "addr": get_address_from_key(bob_key)},
}

# --- HEADER SECTION ---
col_head1, col_head2 = st.columns([3, 1])
with col_head1:
    st.title("🌙 SleepStake")
    st.caption("A 'bet on yourself' sleep challenge on Monad. Sleep well, pass nightly goals, and split the losers' stakes.")
with col_head2:
    st.markdown("<br>", unsafe_allow_html=True)
    st.markdown(f'<span class="badge">Monad Testnet ({CHAIN_ID})</span>', unsafe_allow_html=True)

if not contract_addr:
    st.error("⚠️ CONTRACT_ADDRESS is not set in `.env` or Streamlit secrets. Please deploy the contract and update `.env`.")
    st.stop()

st.markdown(
    f"**Contract Address:** [`{contract_addr}`]({EXPLORER_BASE}/address/{contract_addr})"
)

# Connect to Web3 and verify chain
try:
    w3 = get_web3()
    if not w3.is_connected():
        st.error(f"Cannot connect to Monad RPC at `{DEFAULT_RPC_URL}`. Please check network.")
        st.stop()
except Exception as e:
    st.error(f"Failed to connect to RPC: {e}")
    st.stop()

# Load challenge count
try:
    total_challenges = get_challenge_count(contract_addr)
except Exception as e:
    st.error(f"Error querying contract: {e}. Ensure CONTRACT_ADDRESS is correct on Monad testnet.")
    st.stop()

if total_challenges == 0:
    st.warning("No challenges exist on this contract yet. Use the `cast send createChallenge...` command from Milestone 4 to create the demo challenge.")
    st.stop()

# Challenge Selector (default to latest)
challenge_options = list(range(total_challenges))
selected_id = st.sidebar.selectbox(
    "Select Challenge",
    challenge_options,
    index=total_challenges - 1,
    format_func=lambda cid: f"Challenge #{cid}",
)

# Fetch selected challenge details
challenge = get_challenge(contract_addr, selected_id)
buy_in_mon = Web3.from_wei(challenge["buy_in"], "ether")
first_night_dt = datetime.fromtimestamp(challenge["first_night_start"], tz=BERLIN_TZ)
deadline_dt = datetime.fromtimestamp(challenge["join_deadline"], tz=BERLIN_TZ)
is_settled = challenge["settled"]

# Challenge Overview Metrics
st.sidebar.markdown("---")
st.sidebar.markdown(f"### Challenge #{selected_id} Info")
st.sidebar.markdown(f"**Buy-in:** {buy_in_mon} MON")
st.sidebar.markdown(f"**Duration:** {challenge['nights']} nights")
st.sidebar.markdown(f"**First Night 21:00:** {first_night_dt.strftime('%d %b %Y %H:%M %Z')}")
st.sidebar.markdown(f"**Join Deadline:** {deadline_dt.strftime('%d %b %Y %H:%M %Z')}")
st.sidebar.markdown(f"**Status:** {'🔒 Settled' if is_settled else '🟢 Active'}")
st.sidebar.markdown(f"**Players Joined:** {len(challenge['players'])} / 50")

# Navigation Tabs
tab_join, tab_oracle, tab_leaderboard, tab_settle = st.tabs([
    "🤝 Join Challenge",
    "🔮 Oracle Panel",
    "📊 Leaderboard",
    "🏆 Settle & Withdraw",
])


# ==============================================================================
# TAB 1: JOIN CHALLENGE
# ==============================================================================
with tab_join:
    st.subheader("Join the Sleep Challenge")
    st.write(f"Pay the required buy-in of **{buy_in_mon} MON** before the deadline to lock your spot.")

    selected_player = st.selectbox("Select Player Wallet", list(DEMO_WALLETS.keys()))
    player_info = DEMO_WALLETS[selected_player]
    player_addr = player_info["addr"]
    player_key = player_info["key"]

    if not player_key or not player_addr:
        st.warning(f"Private key for {selected_player} is not configured in `.env`.")
    else:
        balance_wei = get_balance(player_addr)
        balance_mon = Web3.from_wei(balance_wei, "ether")

        col1, col2 = st.columns(2)
        with col1:
            st.info(f"**Address:** [`{player_addr}`]({EXPLORER_BASE}/address/{player_addr})")
        with col2:
            st.info(f"**Balance:** {balance_mon:.4f} MON")

        joined_players = [p.lower() for p in challenge["players"]]
        has_joined = player_addr.lower() in joined_players

        if is_settled:
            st.warning("This challenge is already settled. No new players can join.")
        elif time.time() >= challenge["join_deadline"]:
            st.warning("The join deadline has passed for this challenge.")
        elif has_joined:
            st.success(f"✅ {selected_player} has already joined Challenge #{selected_id}!")
        else:
            if balance_wei < challenge["buy_in"]:
                st.error(f"Insufficient balance ({balance_mon:.4f} MON). You need at least {buy_in_mon} MON + gas.")
            else:
                if st.button(f"Join Challenge as {selected_player} ({buy_in_mon} MON)", type="primary"):
                    with st.spinner(f"Joining Challenge #{selected_id}..."):
                        try:
                            contract = get_contract(contract_addr)
                            fn = contract.functions.join(selected_id)
                            tx_hash, tx_link = send_tx(player_key, fn, value_wei=challenge["buy_in"])
                            st.success(f"🎉 Successfully joined Challenge #{selected_id}!")
                            st.markdown(f"**Transaction:** [View on MonadVision]({tx_link})")
                            st.rerun()
                        except Exception as e:
                            st.error(decode_error(e))


# ==============================================================================
# TAB 2: ORACLE PANEL
# ==============================================================================
with tab_oracle:
    st.subheader("Oracle Reporting Panel")
    st.caption("The oracle wallet reports verified sleep intervals. A password gates access on the public demo.")

    password_input = st.text_input("Enter Oracle Password", type="password")

    if not oracle_panel_pw:
        st.error("ORACLE_PANEL_PASSWORD is not configured, so the oracle panel stays locked.")
    elif password_input != oracle_panel_pw:
        st.info("🔒 Enter the correct oracle password from `.env` to unlock sleep data submission.")
    elif not oracle_key:
        st.error("ORACLE_PRIVATE_KEY is missing in `.env`.")
    else:
        oracle_addr = get_address_from_key(oracle_key)
        oracle_bal = Web3.from_wei(get_balance(oracle_addr), "ether")

        st.markdown(
            f"**Oracle Wallet:** [`{oracle_addr}`]({EXPLORER_BASE}/address/{oracle_addr}) | "
            f"**Balance:** {oracle_bal:.4f} MON"
        )

        players = challenge["players"]
        if not players:
            st.warning("No players have joined this challenge yet. Have players join first.")
        else:
            mock = MockHealthProvider()
            reports_to_submit = []

            st.write("### Verified Sleep Sessions (Mock Health Provider)")
            table_data = []

            for p_addr in players:
                # Find matching demo name if available
                matched_name = p_addr
                for name, d in DEMO_WALLETS.items():
                    if d["addr"].lower() == p_addr.lower():
                        matched_name = name
                        break

                # Query status from chain
                _, reported_arr, passed_arr = get_player_status(contract_addr, selected_id, p_addr)

                records = mock.get_sleep(matched_name, challenge["first_night_start"], challenge["nights"])
                for r in records:
                    window_start = challenge["first_night_start"] + r.night * 86400
                    exp_passed, exp_reason = r.evaluate_against_window(window_start)

                    start_dt = datetime.fromtimestamp(r.sleep_start, tz=BERLIN_TZ)
                    end_dt = datetime.fromtimestamp(r.sleep_end, tz=BERLIN_TZ)

                    is_reported = reported_arr[r.night] if r.night < len(reported_arr) else False
                    onchain_status = "✅ Submitted" if is_reported else "⏳ Pending"

                    table_data.append({
                        "Player": matched_name,
                        "Night": f"Night {r.night}",
                        "Sleep Start": start_dt.strftime("%H:%M (%d %b)"),
                        "Sleep End": end_dt.strftime("%H:%M (%d %b)"),
                        "Duration": r.duration_formatted,
                        "Rule Evaluation": f"{'PASS' if exp_passed else 'FAIL (' + exp_reason + ')'}",
                        "Onchain Status": onchain_status,
                    })

                    if not is_reported and not is_settled:
                        reports_to_submit.append((p_addr, matched_name, r))

            st.dataframe(table_data)

            if is_settled:
                st.info("This challenge is already settled. No further reports can be submitted.")
            elif not reports_to_submit:
                st.success("All sleep reports have already been submitted to the blockchain!")
            else:
                st.write(f"**{len(reports_to_submit)} pending reports ready to submit.**")
                if st.button("🚀 Submit All Pending Reports to Chain", type="primary"):
                    progress_bar = st.progress(0)
                    status_text = st.empty()
                    contract = get_contract(contract_addr)

                    for i, (p_addr, p_name, r) in enumerate(reports_to_submit):
                        status_text.text(f"Submitting Night {r.night} for {p_name}...")
                        try:
                            fn = contract.functions.submitSleep(
                                selected_id,
                                Web3.to_checksum_address(p_addr),
                                r.night,
                                r.sleep_start,
                                r.sleep_end,
                            )
                            tx_hash, tx_link = send_tx(oracle_key, fn)
                            st.write(f"Night {r.night} for {p_name}: [Tx {tx_hash[:10]}...]({tx_link})")
                        except Exception as e:
                            st.error(f"Error submitting report for {p_name}: {decode_error(e)}")
                        progress_bar.progress((i + 1) / len(reports_to_submit))

                    status_text.text("Finished submitting reports!")
                    st.success("All pending reports submitted!")
                    time.sleep(1)
                    st.rerun()


# ==============================================================================
# TAB 3: LEADERBOARD
# ==============================================================================
with tab_leaderboard:
    st.subheader("Live Challenge Leaderboard")
    total_pool_mon = len(challenge["players"]) * buy_in_mon
    st.metric(label="Total Stake Pool", value=f"{total_pool_mon:.2f} MON", delta=f"{len(challenge['players'])} players")

    players = challenge["players"]
    if not players:
        st.info(f"No players have joined Challenge #{selected_id} yet.")
    else:
        lb_rows = []
        for p_addr in players:
            name_label = p_addr[:8] + "..." + p_addr[-6:]
            for name, d in DEMO_WALLETS.items():
                if d["addr"].lower() == p_addr.lower():
                    name_label = f"{name} ({d['addr'][:6]}...)"
                    break

            nights_passed, reported_arr, passed_arr = get_player_status(contract_addr, selected_id, p_addr)

            # Build night outcome icons
            night_badges = []
            for n in range(challenge["nights"]):
                rep = reported_arr[n] if n < len(reported_arr) else False
                pas = passed_arr[n] if n < len(passed_arr) else False
                if not rep:
                    night_badges.append(f"N{n}: ⏳ Pending")
                elif pas:
                    night_badges.append(f"N{n}: ✅ Pass")
                else:
                    night_badges.append(f"N{n}: ❌ Fail")

            # Final status
            if nights_passed == challenge["nights"]:
                standing = "🏆 Goal Met"
            elif any(rep and not pas for rep, pas in zip(reported_arr, passed_arr)):
                standing = "❌ Knocked Out"
            else:
                standing = "🏃 In Progress"

            lb_rows.append({
                "Player": name_label,
                "Night Results": " | ".join(night_badges),
                "Nights Passed": f"{nights_passed} / {challenge['nights']}",
                "Standing": standing,
            })

        st.dataframe(lb_rows)


# ==============================================================================
# TAB 4: SETTLE & WITHDRAW
# ==============================================================================
with tab_settle:
    st.subheader("Settlement & Payouts")

    contract = get_contract(contract_addr)
    owner_addr = get_owner(contract_addr)
    players = challenge["players"]

    # Calculate status and eligibility
    all_reports_in = (
        len(players) > 0 and challenge["reports_submitted"] == len(players) * challenge["nights"]
    )
    time_expired = time.time() >= (challenge["first_night_start"] + challenge["nights"] * 86400)
    can_settle = not is_settled and (all_reports_in or time_expired)

    col_s1, col_s2 = st.columns(2)
    with col_s1:
        st.write(f"**Settlement State:** {'Settled' if is_settled else 'Unsettled'}")
        st.write(f"**All Reports Submitted:** {'Yes' if all_reports_in else 'No'}")
    with col_s2:
        st.write(f"**Challenge Duration Elapsed:** {'Yes' if time_expired else 'No'}")

    if not is_settled:
        if can_settle:
            st.success("✅ Settlement conditions met! Anyone can trigger settlement.")
            # Use Kai's key or oracle key as caller
            settle_key = kai_key or oracle_key
            if st.button("⚖️ Settle Challenge Now", type="primary"):
                with st.spinner("Settling challenge onchain..."):
                    try:
                        fn = contract.functions.settle(selected_id)
                        tx_hash, tx_link = send_tx(settle_key, fn)
                        st.success("🎉 Challenge settled successfully!")
                        st.markdown(f"**Transaction:** [View on MonadVision]({tx_link})")
                        st.rerun()
                    except Exception as e:
                        st.error(decode_error(e))
        else:
            st.info("Settlement unlocks once either all sleep reports are submitted or the full challenge time has elapsed.")
    else:
        st.success("🏆 Challenge has been settled! Rewards are credited to claimable balances.")

        # Breakdown of payout calculation
        if len(players) > 0:
            winners = []
            losers = []
            for p_addr in players:
                np, _, _ = get_player_status(contract_addr, selected_id, p_addr)
                if np == challenge["nights"]:
                    winners.append(p_addr)
                else:
                    losers.append(p_addr)

            st.write("### 📐 Settlement Math Breakdown")
            col_m1, col_m2, col_m3 = st.columns(3)
            with col_m1:
                st.metric("Winners", f"{len(winners)} / {len(players)}")
            with col_m2:
                forfeited_wei = len(losers) * challenge["buy_in"]
                st.metric("Forfeited Pool", f"{Web3.from_wei(forfeited_wei, 'ether'):.4f} MON")
            with col_m3:
                fee_wei = (forfeited_wei * 500) // 10000 if len(winners) > 0 and len(losers) > 0 else 0
                st.metric("Platform Fee (5%)", f"{Web3.from_wei(fee_wei, 'ether'):.4f} MON")

            if len(winners) == 0 or len(winners) == len(players):
                st.info("Rule: Nobody wins or everyone wins → Everyone receives 100% refund of their buy-in with zero platform fee.")
            else:
                share_wei = (forfeited_wei - fee_wei) // len(winners)
                winner_payout = Web3.from_wei(challenge["buy_in"] + share_wei, "ether")
                st.info(
                    f"Each of the {len(winners)} winner(s) receives their **{buy_in_mon} MON buy-in** "
                    f"plus an equal share of the remaining forfeited pool (**{Web3.from_wei(share_wei, 'ether'):.4f} MON**), "
                    f"totaling **{winner_payout:.4f} MON** per winner."
                )

    # Claimable Balances and Withdrawal
    st.write("### 💰 Claimable Balances & Withdrawals")
    for name, d in DEMO_WALLETS.items():
        if d["addr"]:
            c_wei = get_claimable(contract_addr, d["addr"])
            c_mon = Web3.from_wei(c_wei, "ether")
            col_w1, col_w2 = st.columns([3, 1])
            with col_w1:
                st.write(f"**{name}** (`{d['addr'][:8]}...`): **{c_mon:.4f} MON** claimable")
            with col_w2:
                if c_wei > 0:
                    if st.button(f"Withdraw ({name})", key=f"withdraw_{name}"):
                        with st.spinner(f"Withdrawing {c_mon:.4f} MON for {name}..."):
                            try:
                                fn = contract.functions.withdraw()
                                tx_hash, tx_link = send_tx(d["key"], fn)
                                st.success(f"Withdrawn! [View Tx]({tx_link})")
                                st.rerun()
                            except Exception as e:
                                st.error(decode_error(e))

    # Treasury Claimable
    treasury_claimable = get_claimable(contract_addr, owner_addr)
    st.write(f"**Treasury Fee Balance:** {Web3.from_wei(treasury_claimable, 'ether'):.4f} MON")
