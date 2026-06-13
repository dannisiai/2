// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPancakeRouterV2 {
    function WETH() external pure returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}

interface AutomationCompatibleInterface {
    function checkUpkeep(
        bytes calldata checkData
    ) external view returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract AutoBNBBuybackBurnTreasury is AutomationCompatibleInterface {
    address public owner;
    address public keeper;

    address public constant PANCAKE_ROUTER_V2 =
        0x10ED43C718714eb63d5aA57B78B54704E256024E;

    IPancakeRouterV2 public immutable router;
    address public immutable WBNB;

    address public buybackToken;
    address[] private buybackPath;

    bool public configLocked;
    bool public automationEnabled = true;

    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    uint256 public constant BUYBACK_BPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    uint256 public lastBuybackTime;

    // =========================
    // Voting
    // =========================

    address public votingToken;

    uint256 public constant VOTE_DURATION = 12 hours;

    uint256 public voteCounter;
    uint256 public latestVoteId;

    struct TokenVote {
        uint256 id;
        address votingTokenUsed;
        address proposedBuybackToken;
        uint256 startTime;
        uint256 endTime;
        uint256 yesVotes;
        uint256 noVotes;
        bool finalized;
        bool passed;
    }

    struct VoteReceipt {
        uint256 amount;
        bool support;
        bool hasVoted;
        bool claimed;
    }

    mapping(uint256 => TokenVote) public votes;
    mapping(uint256 => mapping(address => VoteReceipt)) public voteReceipts;

    bool private reentrancyLock;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event KeeperUpdated(address indexed newKeeper);

    event VotingTokenUpdated(address indexed token);

    event BuybackTokenCASubmitted(
        uint256 indexed voteId,
        address indexed owner,
        address indexed proposedBuybackToken,
        uint256 startTime,
        uint256 endTime
    );

    event VoteCast(
        uint256 indexed voteId,
        address indexed voter,
        bool support,
        uint256 amount
    );

    event BuybackVoteFinalized(
        uint256 indexed voteId,
        address indexed proposedBuybackToken,
        bool passed,
        uint256 yesVotes,
        uint256 noVotes
    );

    event VotingTokensClaimed(
        uint256 indexed voteId,
        address indexed voter,
        uint256 amount
    );

    event BuybackTokenApproved(address indexed token);
    event BuybackPathUpdated(address[] path);
    event ConfigLocked(address indexed token);
    event AutomationEnabledUpdated(bool enabled);

    event BuybackExecuted(
        address indexed token,
        uint256 bnbAmountUsed,
        uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyExecutor() {
        require(
            msg.sender == owner || msg.sender == keeper,
            "Not executor"
        );
        _;
    }

    modifier nonReentrant() {
        require(!reentrancyLock, "Reentrant");
        reentrancyLock = true;
        _;
        reentrancyLock = false;
    }

    constructor() {
        owner = msg.sender;

        router = IPancakeRouterV2(PANCAKE_ROUTER_V2);
        WBNB = IPancakeRouterV2(PANCAKE_ROUTER_V2).WETH();

        emit OwnershipTransferred(address(0), msg.sender);
    }

    receive() external payable {}

    // =========================
    // Owner settings
    // =========================

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function setVotingToken(address tokenCA) external onlyOwner {
        require(!configLocked, "Config locked");
        require(voteCounter == 0, "Vote already started");
        require(tokenCA != address(0), "Voting token zero");
        require(tokenCA.code.length > 0, "Voting token not contract");

        votingToken = tokenCA;

        emit VotingTokenUpdated(tokenCA);
    }

    function setAutomationEnabled(bool enabled) external onlyOwner {
        automationEnabled = enabled;
        emit AutomationEnabledUpdated(enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner zero");

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // =========================
    // Owner submits buyback token CA for community vote
    // =========================

    function submitBuybackTokenCAForVote(address proposedTokenCA) external onlyOwner {
        require(!configLocked, "Config locked");
        require(votingToken != address(0), "Voting token not set");
        require(buybackToken == address(0), "Buyback token already approved");

        require(proposedTokenCA != address(0), "Token zero");
        require(proposedTokenCA != WBNB, "Cannot buy WBNB");
        require(proposedTokenCA.code.length > 0, "Token not contract");

        require(!_hasUnfinalizedVote(), "Previous vote not finalized");

        voteCounter += 1;
        latestVoteId = voteCounter;

        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + VOTE_DURATION;

        votes[latestVoteId] = TokenVote({
            id: latestVoteId,
            votingTokenUsed: votingToken,
            proposedBuybackToken: proposedTokenCA,
            startTime: startTime,
            endTime: endTime,
            yesVotes: 0,
            noVotes: 0,
            finalized: false,
            passed: false
        });

        emit BuybackTokenCASubmitted(
            latestVoteId,
            msg.sender,
            proposedTokenCA,
            startTime,
            endTime
        );
    }

    // =========================
    // Community voting
    // =========================

    function castVote(
        uint256 voteId,
        bool support,
        uint256 amount
    ) external nonReentrant {
        TokenVote storage v = votes[voteId];

        require(v.id != 0, "Vote not found");
        require(!v.finalized, "Vote finalized");
        require(block.timestamp < v.endTime, "Vote ended");
        require(amount > 0, "Amount zero");

        VoteReceipt storage receipt = voteReceipts[voteId][msg.sender];

        require(!receipt.hasVoted, "Already voted");

        uint256 beforeBalance = IERC20(v.votingTokenUsed).balanceOf(address(this));

        _safeTransferFrom(
            v.votingTokenUsed,
            msg.sender,
            address(this),
            amount
        );

        uint256 afterBalance = IERC20(v.votingTokenUsed).balanceOf(address(this));
        uint256 received = afterBalance - beforeBalance;

        require(received > 0, "Received zero");

        receipt.amount = received;
        receipt.support = support;
        receipt.hasVoted = true;
        receipt.claimed = false;

        if (support) {
            v.yesVotes += received;
        } else {
            v.noVotes += received;
        }

        emit VoteCast(voteId, msg.sender, support, received);
    }

    function finalizeVote(uint256 voteId) external nonReentrant {
        TokenVote storage v = votes[voteId];

        require(v.id != 0, "Vote not found");
        require(!v.finalized, "Already finalized");
        require(block.timestamp >= v.endTime, "Vote not ended");
        require(!configLocked, "Config locked");
        require(buybackToken == address(0), "Buyback token already approved");

        v.finalized = true;

        bool passed = v.yesVotes > v.noVotes && v.yesVotes > 0;

        if (passed) {
            v.passed = true;
            _approveBuybackToken(v.proposedBuybackToken);
        }

        emit BuybackVoteFinalized(
            voteId,
            v.proposedBuybackToken,
            passed,
            v.yesVotes,
            v.noVotes
        );
    }

    function claimVotingTokens(uint256 voteId) external nonReentrant {
        TokenVote storage v = votes[voteId];

        require(v.id != 0, "Vote not found");
        require(block.timestamp >= v.endTime, "Vote not ended");

        VoteReceipt storage receipt = voteReceipts[voteId][msg.sender];

        require(receipt.hasVoted, "Did not vote");
        require(!receipt.claimed, "Already claimed");
        require(receipt.amount > 0, "Nothing to claim");

        uint256 amount = receipt.amount;
        receipt.claimed = true;

        _safeTransfer(v.votingTokenUsed, msg.sender, amount);

        emit VotingTokensClaimed(voteId, msg.sender, amount);
    }

    function _approveBuybackToken(address tokenCA) internal {
        require(!configLocked, "Config locked");
        require(tokenCA != address(0), "Token zero");
        require(tokenCA != WBNB, "Cannot buy WBNB");

        buybackToken = tokenCA;

        delete buybackPath;
        buybackPath.push(WBNB);
        buybackPath.push(tokenCA);

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = tokenCA;

        emit BuybackTokenApproved(tokenCA);
        emit BuybackPathUpdated(path);
    }

    function lockConfig() external onlyOwner {
        require(!configLocked, "Already locked");
        require(buybackToken != address(0), "Token not approved");
        require(buybackPath.length == 2, "Path not set");
        require(buybackPath[0] == WBNB, "Path must start WBNB");
        require(buybackPath[1] == buybackToken, "Path must end token");

        configLocked = true;

        emit ConfigLocked(buybackToken);
    }

    function _hasUnfinalizedVote() internal view returns (bool) {
        if (latestVoteId == 0) {
            return false;
        }

        return !votes[latestVoteId].finalized;
    }

    // =========================
    // Buyback
    // =========================

    function executeBuyback() external onlyExecutor nonReentrant {
        _executeBuyback();
    }

    function checkUpkeep(
        bytes calldata
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        bool timeReady = lastBuybackTime == 0 ||
            block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL;

        bool hasBNB = address(this).balance > 0;
        bool tokenReady = buybackToken != address(0) && buybackPath.length == 2;

        upkeepNeeded =
            automationEnabled &&
            configLocked &&
            timeReady &&
            hasBNB &&
            tokenReady;

        performData = "";
    }

    function performUpkeep(bytes calldata) external override nonReentrant {
        bool timeReady = lastBuybackTime == 0 ||
            block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL;

        bool hasBNB = address(this).balance > 0;
        bool tokenReady = buybackToken != address(0) && buybackPath.length == 2;

        require(automationEnabled, "Automation disabled");
        require(configLocked, "Config not locked");
        require(timeReady, "Too early");
        require(hasBNB, "No BNB");
        require(tokenReady, "Token/path not ready");

        _executeBuyback();
    }

    function _executeBuyback() internal {
        require(automationEnabled, "Buyback disabled");
        require(configLocked, "Config not locked");
        require(buybackToken != address(0), "Token not set");
        require(buybackPath.length == 2, "Path not set");
        require(buybackPath[0] == WBNB, "Path must start WBNB");
        require(buybackPath[1] == buybackToken, "Path must end token");

        if (lastBuybackTime != 0) {
            require(
                block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL,
                "Too early"
            );
        }

        uint256 treasuryBNB = address(this).balance;
        require(treasuryBNB > 0, "No BNB");

        uint256 buybackBNB =
            (treasuryBNB * BUYBACK_BPS) / BPS_DENOMINATOR;

        require(buybackBNB > 0, "Buyback zero");

        lastBuybackTime = block.timestamp;

        address[] memory path = _copyBuybackPath();

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: buybackBNB
        }(
            0,
            path,
            BURN_ADDRESS,
            block.timestamp + 600
        );

        emit BuybackExecuted(
            buybackToken,
            buybackBNB,
            block.timestamp
        );
    }

    // =========================
    // View functions
    // =========================

    function getBuybackPath() external view returns (address[] memory) {
        return _copyBuybackPath();
    }

    function _copyBuybackPath() internal view returns (address[] memory path) {
        path = new address[](buybackPath.length);

        for (uint256 i = 0; i < buybackPath.length; i++) {
            path[i] = buybackPath[i];
        }
    }

    function treasuryBalanceBNB() external view returns (uint256) {
        return address(this).balance;
    }

    function nextBuybackTime() external view returns (uint256) {
        if (lastBuybackTime == 0) {
            return block.timestamp;
        }

        return lastBuybackTime + BUYBACK_INTERVAL;
    }

    function currentVoteInfo()
        external
        view
        returns (
            uint256 voteId,
            address voteToken,
            address proposedBuybackToken,
            uint256 startTime,
            uint256 endTime,
            uint256 yesVotes,
            uint256 noVotes,
            bool finalized,
            bool passed,
            bool active
        )
    {
        TokenVote memory v = votes[latestVoteId];

        voteId = v.id;
        voteToken = v.votingTokenUsed;
        proposedBuybackToken = v.proposedBuybackToken;
        startTime = v.startTime;
        endTime = v.endTime;
        yesVotes = v.yesVotes;
        noVotes = v.noVotes;
        finalized = v.finalized;
        passed = v.passed;
        active = v.id != 0 && !v.finalized && block.timestamp < v.endTime;
    }

    function voteTimeLeft(uint256 voteId) external view returns (uint256) {
        TokenVote memory v = votes[voteId];

        if (v.id == 0) {
            return 0;
        }

        if (block.timestamp >= v.endTime) {
            return 0;
        }

        return v.endTime - block.timestamp;
    }

    function canClaimVotingTokens(
        uint256 voteId,
        address user
    ) external view returns (bool) {
        TokenVote memory v = votes[voteId];
        VoteReceipt memory receipt = voteReceipts[voteId][user];

        return
            v.id != 0 &&
            block.timestamp >= v.endTime &&
            receipt.hasVoted &&
            !receipt.claimed &&
            receipt.amount > 0;
    }

    function getVoteReceipt(
        uint256 voteId,
        address user
    )
        external
        view
        returns (
            uint256 amount,
            bool support,
            bool hasVoted,
            bool claimed
        )
    {
        VoteReceipt memory receipt = voteReceipts[voteId][user];

        amount = receipt.amount;
        support = receipt.support;
        hasVoted = receipt.hasVoted;
        claimed = receipt.claimed;
    }

    // =========================
    // Safe token helpers
    // =========================

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                amount
            )
        );

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferFrom failed"
        );
    }
}
