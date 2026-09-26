// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title SleepStake
 * @notice A "bet on yourself" sleep challenge where players lock a buy-in,
 * sleep within a nightly window for a target duration, and winners split the losers' stakes.
 */
contract SleepStake {
    // --- Constants ---

    // Each night's allowed window is 9 hours long (e.g., 21:00 to 06:00).
    uint64 public constant WINDOW_LENGTH = 9 hours;

    // Minimum sleep duration: 7 hours 30 minutes (27,000 seconds).
    uint64 public constant MIN_SLEEP = 27000;

    // Maximum sleep duration: 8 hours 30 minutes (30,600 seconds).
    uint64 public constant MAX_SLEEP = 30600;

    // Platform fee taken from the forfeited pool (500 basis points = 5%).
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS = 10000;

    // Maximum duration of any challenge is 30 nights.
    uint8 public constant MAX_NIGHTS = 30;

    // Maximum players allowed in one challenge to prevent gas issues during settlement loops.
    uint256 public constant MAX_PLAYERS = 50;

    // --- Enums ---

    // Result reasons for sleep verification.
    enum SleepReason {
        NONE, // Sleep met all requirements (passed)
        OUTSIDE_WINDOW, // Sleep started before window or ended after window
        TOO_SHORT, // Sleep lasted less than 7h30m
        TOO_LONG // Sleep lasted more than 8h30m
    }

    // --- Structs ---

    struct Challenge {
        address creator; // Who created the challenge
        uint256 buyIn; // Entry fee required per player (in wei)
        uint64 firstNightStart; // Unix timestamp for night 0 window start (21:00 local)
        uint8 nights; // Total number of nights in the challenge
        uint64 joinDeadline; // Timestamp after which players can no longer join
        bool settled; // True once the challenge has been settled
        address[] players; // List of all joined player addresses
        uint32 reportsSubmitted; // Total sleep reports submitted across all players
    }

    // --- State Variables ---

    // The treasury address that receives platform fees and rounding dust (the deployer).
    address public owner;

    // The trusted oracle wallet authorized to submit sleep reports.
    address public oracle;

    // Array of all challenges created.
    Challenge[] public challenges;

    // Tracks if an address has joined a challenge: challengeId => player => joined.
    mapping(uint256 => mapping(address => bool)) public isPlayer;

    // Number of nights successfully passed: challengeId => player => nightsPassed.
    mapping(uint256 => mapping(address => uint8)) public playerNightsPassed;

    // Tracks whether a report has been submitted: challengeId => player => nightIndex => reported.
    mapping(uint256 => mapping(address => mapping(uint8 => bool))) public playerReported;

    // Tracks if a reported night passed: challengeId => player => nightIndex => passed.
    mapping(uint256 => mapping(address => mapping(uint8 => bool))) public playerPassed;

    // Pull-payment balances: users and treasury withdraw from here.
    mapping(address => uint256) public claimable;

    // --- Custom Errors ---
    // Custom errors save gas compared to require strings.

    error OnlyOwner();
    error OnlyOracle();
    error InvalidAddress();
    error InvalidBuyIn();
    error InvalidNights();
    error ChallengeNotFound(uint256 id);
    error AlreadySettled();
    error JoinDeadlinePassed();
    error IncorrectBuyIn();
    error AlreadyJoined();
    error ChallengeFull();
    error PlayerNotJoined();
    error InvalidNight();
    error AlreadyReported();
    error InvalidSleepTimes();
    error CannotSettleYet();
    error NothingToWithdraw();
    error TransferFailed();

    // --- Events ---

    event ChallengeCreated(
        uint256 indexed id,
        address indexed creator,
        uint256 buyIn,
        uint64 firstNightStart,
        uint8 nights,
        uint64 joinDeadline
    );
    event Joined(uint256 indexed id, address indexed player);
    event SleepReported(
        uint256 indexed id, address indexed player, uint8 night, bool passed, SleepReason reason, uint64 duration
    );
    event Settled(uint256 indexed id, address[] winners, uint256 feeTaken);
    event Withdrawn(address indexed player, uint256 amount);
    event OracleSet(address indexed newOracle);

    // --- Constructor ---

    /**
     * @notice Initializes the contract with an oracle address.
     * @param _oracle The address authorized to report sleep data.
     * The deployer becomes the owner (treasury).
     */
    constructor(address _oracle) {
        if (_oracle == address(0)) revert InvalidAddress();
        owner = msg.sender;
        oracle = _oracle;
    }

    // --- External Functions ---

    /**
     * @notice Creates a new sleep challenge.
     * @param buyIn Amount of native token (in wei) required to join.
     * @param firstNightStart Unix timestamp of 21:00 on night 0.
     *        Note: For hackathon demo replay, past start times are allowed.
     *        In production, require(joinDeadline <= firstNightStart).
     * @param nights Number of nights the challenge lasts (1 to MAX_NIGHTS).
     * @param joinDeadline Timestamp when joining closes.
     * @return id The ID of the newly created challenge.
     */
    function createChallenge(uint256 buyIn, uint64 firstNightStart, uint8 nights, uint64 joinDeadline)
        external
        returns (uint256 id)
    {
        if (buyIn == 0) revert InvalidBuyIn();
        if (nights == 0 || nights > MAX_NIGHTS) revert InvalidNights();

        id = challenges.length;

        Challenge storage newChallenge = challenges.push();
        newChallenge.creator = msg.sender;
        newChallenge.buyIn = buyIn;
        newChallenge.firstNightStart = firstNightStart;
        newChallenge.nights = nights;
        newChallenge.joinDeadline = joinDeadline;
        newChallenge.settled = false;
        newChallenge.reportsSubmitted = 0;

        emit ChallengeCreated(id, msg.sender, buyIn, firstNightStart, nights, joinDeadline);
    }

    /**
     * @notice Join an existing challenge by paying the exact buy-in.
     * @param id The challenge ID to join.
     */
    function join(uint256 id) external payable {
        if (id >= challenges.length) revert ChallengeNotFound(id);
        Challenge storage challenge = challenges[id];

        if (challenge.settled) revert AlreadySettled();
        if (block.timestamp >= challenge.joinDeadline) revert JoinDeadlinePassed();
        if (msg.value != challenge.buyIn) revert IncorrectBuyIn();
        if (isPlayer[id][msg.sender]) revert AlreadyJoined();
        if (challenge.players.length >= MAX_PLAYERS) revert ChallengeFull();

        isPlayer[id][msg.sender] = true;
        challenge.players.push(msg.sender);

        emit Joined(id, msg.sender);
    }

    /**
     * @notice Oracle reports sleep times for a specific player and night.
     * @param id Challenge ID.
     * @param player Address of the player.
     * @param night Index of the night (0 to nights - 1).
     * @param sleepStart Unix timestamp when the player fell asleep.
     * @param sleepEnd Unix timestamp when the player woke up.
     */
    function submitSleep(uint256 id, address player, uint8 night, uint64 sleepStart, uint64 sleepEnd) external {
        if (msg.sender != oracle) revert OnlyOracle();
        if (id >= challenges.length) revert ChallengeNotFound(id);

        Challenge storage challenge = challenges[id];
        if (challenge.settled) revert AlreadySettled();
        if (!isPlayer[id][player]) revert PlayerNotJoined();
        if (night >= challenge.nights) revert InvalidNight();
        if (playerReported[id][player][night]) revert AlreadyReported();
        if (sleepEnd <= sleepStart) revert InvalidSleepTimes();

        // Calculate expected 9-hour window for this night
        uint64 windowStart = challenge.firstNightStart + (uint64(night) * 1 days);
        uint64 windowEnd = windowStart + WINDOW_LENGTH;
        uint64 duration = sleepEnd - sleepStart;

        SleepReason reason;
        bool passed;

        // Verify window bounds and sleep duration
        if (sleepStart < windowStart || sleepEnd > windowEnd) {
            reason = SleepReason.OUTSIDE_WINDOW;
            passed = false;
        } else if (duration < MIN_SLEEP) {
            reason = SleepReason.TOO_SHORT;
            passed = false;
        } else if (duration > MAX_SLEEP) {
            reason = SleepReason.TOO_LONG;
            passed = false;
        } else {
            reason = SleepReason.NONE;
            passed = true;
            playerNightsPassed[id][player]++;
        }

        // Record the report
        playerReported[id][player][night] = true;
        playerPassed[id][player][night] = passed;
        challenge.reportsSubmitted++;

        emit SleepReported(id, player, night, passed, reason, duration);
    }

    /**
     * @notice Settles a challenge after time has passed or all nights have been reported.
     * Calculates winners, applies 5% fee on losers' pool, and credits claimable balances.
     * @param id Challenge ID to settle.
     */
    function settle(uint256 id) external {
        if (id >= challenges.length) revert ChallengeNotFound(id);
        Challenge storage challenge = challenges[id];
        if (challenge.settled) revert AlreadySettled();

        // Settle is allowed if the challenge duration has fully elapsed OR all reports are in.
        bool timeEnded = block.timestamp >= uint256(challenge.firstNightStart) + (uint256(challenge.nights) * 1 days);
        bool allReported =
            challenge.players.length > 0 && challenge.reportsSubmitted == (challenge.players.length * challenge.nights);

        if (!timeEnded && !allReported) revert CannotSettleYet();

        // Effect: Mark challenge as settled BEFORE crediting balances
        challenge.settled = true;

        uint256 playerCount = challenge.players.length;
        if (playerCount == 0) {
            emit Settled(id, new address[](0), 0);
            return;
        }

        // Count how many players passed every single night
        uint256 winnerCount = 0;
        for (uint256 i = 0; i < playerCount; i++) {
            if (playerNightsPassed[id][challenge.players[i]] == challenge.nights) {
                winnerCount++;
            }
        }

        uint256 feeTaken = 0;
        address[] memory winners = new address[](winnerCount);

        if (winnerCount == 0 || winnerCount == playerCount) {
            // Case 1: Nobody wins or everyone wins.
            // Everyone gets their full buy-in back. No platform fee is taken.
            for (uint256 i = 0; i < playerCount; i++) {
                address player = challenge.players[i];
                claimable[player] += challenge.buyIn;
                if (winnerCount == playerCount) {
                    winners[i] = player;
                }
            }
        } else {
            // Case 2: Some win and some lose.
            // Populate the winners array.
            uint256 winnerIdx = 0;
            for (uint256 i = 0; i < playerCount; i++) {
                address player = challenge.players[i];
                if (playerNightsPassed[id][player] == challenge.nights) {
                    winners[winnerIdx] = player;
                    winnerIdx++;
                }
            }

            // Losers' stakes form the forfeited pool
            uint256 loserCount = playerCount - winnerCount;
            uint256 forfeitedPool = loserCount * challenge.buyIn;

            // 5% platform fee taken from the forfeited pool (not from winners' stakes)
            feeTaken = (forfeitedPool * FEE_BPS) / BPS;
            uint256 poolAfterFee = forfeitedPool - feeTaken;

            // Equal share of remaining forfeited pool for each winner
            uint256 rewardPerWinner = poolAfterFee / winnerCount;

            // Rounding remainder (dust) goes to treasury
            uint256 dust = poolAfterFee % winnerCount;

            // Credit the treasury: fee + dust
            claimable[owner] += feeTaken + dust;

            // Credit each winner: their original buy-in back + their share of forfeited pool
            uint256 winnerPayout = challenge.buyIn + rewardPerWinner;
            for (uint256 i = 0; i < winnerCount; i++) {
                claimable[winners[i]] += winnerPayout;
            }
        }

        emit Settled(id, winners, feeTaken);
    }

    /**
     * @notice Pull payment: withdraw any claimable balance.
     * Follows Checks-Effects-Interactions to prevent reentrancy attacks.
     */
    function withdraw() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        // Effect: Reset claimable balance to zero before sending
        claimable[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);

        // Interaction: Send native currency
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Updates the oracle address.
     * @param _newOracle The new oracle address.
     */
    function setOracle(address _newOracle) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (_newOracle == address(0)) revert InvalidAddress();
        oracle = _newOracle;
        emit OracleSet(_newOracle);
    }

    // --- View Helpers ---

    /**
     * @notice Returns total number of challenges created.
     */
    function challengeCount() external view returns (uint256) {
        return challenges.length;
    }

    /**
     * @notice Returns complete challenge struct for a given ID.
     */
    function getChallenge(uint256 id) external view returns (Challenge memory) {
        if (id >= challenges.length) revert ChallengeNotFound(id);
        return challenges[id];
    }

    /**
     * @notice Returns the array of players who joined a challenge.
     */
    function getPlayers(uint256 id) external view returns (address[] memory) {
        if (id >= challenges.length) revert ChallengeNotFound(id);
        return challenges[id].players;
    }

    /**
     * @notice Returns player status: nights passed count and boolean arrays for reported/passed.
     */
    function getPlayerStatus(uint256 id, address player)
        external
        view
        returns (uint8 nightsPassed, bool[] memory reported, bool[] memory passed)
    {
        if (id >= challenges.length) revert ChallengeNotFound(id);
        uint8 totalNights = challenges[id].nights;

        reported = new bool[](totalNights);
        passed = new bool[](totalNights);

        for (uint8 i = 0; i < totalNights; i++) {
            reported[i] = playerReported[id][player][i];
            passed[i] = playerPassed[id][player][i];
        }

        return (playerNightsPassed[id][player], reported, passed);
    }
}
