// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct FieldDescriptor {
    string name;
    string fieldType;
    string description;
    uint8 decimals;
}

struct VaultDataSchema {
    string description;
    FieldDescriptor[] fields;
    bool isArray;
}

struct ApproveAction {
    string tokenType;
    string amountFieldName;
}

struct VaultMethodSchema {
    string name;
    string description;
    FieldDescriptor[] inputs;
    FieldDescriptor[] outputs;
    ApproveAction[] approvals;
    bool isInputArray;
    bool isOutputArray;
    bool isWriteMethod;
}

struct VaultUISchema {
    string vaultType;
    string description;
    VaultMethodSchema[] methods;
}

abstract contract VaultBase {
    error UnsupportedChain(uint256 chainId);

    function _getPortal() internal view returns (address portal) {
        uint256 chainId = block.chainid;
        if (chainId == 56) {
            return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        } else if (chainId == 97) {
            return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        }
        revert UnsupportedChain(chainId);
    }

    function _getGuardian() internal view returns (address guardian) {
        uint256 chainId = block.chainid;
        if (chainId == 56) {
            return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        } else if (chainId == 97) {
            return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        }
        revert UnsupportedChain(chainId);
    }

    function description() public view virtual returns (string memory);
}

abstract contract VaultBaseV2 is VaultBase {
    function vaultUISchema() public pure virtual returns (VaultUISchema memory schema);
}

interface IVaultFactory {
    error OnlyVaultPortal();
    error ZeroAddress();

    function newVault(
        address taxToken,
        address quoteToken,
        address creator,
        bytes calldata vaultData
    ) external returns (address vault);

    function isQuoteTokenSupported(address quoteToken) external view returns (bool supported);
}

abstract contract VaultFactoryBaseV2 is IVaultFactory {
    error UnsupportedChain(uint256 chainId);

    function vaultDataSchema() public pure virtual returns (VaultDataSchema memory schema);

    function _getVaultPortal() internal view returns (address vaultPortal) {
        uint256 chainId = block.chainid;
        if (chainId == 56) {
            return 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
        } else if (chainId == 97) {
            return 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        }
        revert UnsupportedChain(chainId);
    }

    function _getGuardian() internal view returns (address guardian) {
        uint256 chainId = block.chainid;
        if (chainId == 56) {
            return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        } else if (chainId == 97) {
            return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        }
        revert UnsupportedChain(chainId);
    }
}

library Clones {
    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(
                ptr,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(
                add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "Clone failed");
    }
}

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

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract WorldCupPredictionMarket {
    uint256 public constant MAX_MATCHES = 128;
    uint256 public constant SEEDED_WORLD_CUP_2026_MATCHES = 104;
    uint8 public constant OUTCOME_HOME = 0;
    uint8 public constant OUTCOME_DRAW = 1;
    uint8 public constant OUTCOME_AWAY = 2;
    uint8 public constant OUTCOME_VOID = 3;

    bool private initialized;

    address public vault;
    address public creator;
    address public predictionToken;
    address public oracle;
    address public guardian;

    uint256 public matchCount;
    bool public scheduleSeeded;

    struct MatchInfo {
        string homeTeam;
        string awayTeam;
        uint64 bettingCloseTime;
        bool resolved;
        uint8 result;
        uint256 totalNetStaked;
        uint256 homeNetStaked;
        uint256 drawNetStaked;
        uint256 awayNetStaked;
        uint256 remainingPayoutPool;
        uint256 remainingWinningStake;
    }

    mapping(uint256 => MatchInfo) private matchesById;
    mapping(uint256 => mapping(uint8 => mapping(address => uint256))) private userNetStake;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event Initialized(
        address indexed vault,
        address indexed creator,
        address indexed predictionToken,
        address oracle,
        address guardian
    );
    event OracleUpdated(address indexed oracle);
    event MatchCreated(
        uint256 indexed matchId,
        string homeTeam,
        string awayTeam,
        uint64 bettingCloseTime
    );
    event MatchUpdated(
        uint256 indexed matchId,
        string homeTeam,
        string awayTeam,
        uint64 bettingCloseTime
    );
    event WorldCup2026ScheduleSeeded(uint256 matchCount);
    event PredictionRecorded(
        uint256 indexed matchId,
        address indexed user,
        uint8 indexed outcome,
        uint256 netAmount
    );
    event MatchResolved(uint256 indexed matchId, uint8 indexed result, uint256 totalNetStaked);
    event MatchVoided(uint256 indexed matchId);
    event PredictionClaimed(uint256 indexed matchId, address indexed user, uint256 amount);

    modifier onlyVault() {
        require(msg.sender == vault, "Not vault");
        _;
    }

    constructor() {
        initialized = true;
    }

    function initialize(
        address vault_,
        address creator_,
        address predictionToken_,
        address oracle_,
        address guardian_
    ) external {
        require(!initialized, "Already initialized");
        require(vault_ != address(0), "Vault zero");
        require(creator_ != address(0), "Creator zero");
        require(predictionToken_ != address(0), "Token zero");
        require(oracle_ != address(0), "Oracle zero");
        require(guardian_ != address(0), "Guardian zero");

        initialized = true;
        vault = vault_;
        creator = creator_;
        predictionToken = predictionToken_;
        oracle = oracle_;
        guardian = guardian_;

        _seedWorldCup2026Schedule();

        emit Initialized(vault_, creator_, predictionToken_, oracle_, guardian_);
    }

    function setOracle(address newOracle) external onlyVault {
        require(newOracle != address(0), "Oracle zero");
        oracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    function createMatch(
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 bettingCloseTime
    ) external onlyVault returns (uint256 matchId) {
        require(bettingCloseTime > block.timestamp, "Close time past");

        matchId = _createMatch(homeTeam, awayTeam, bettingCloseTime, true);
    }

    function updateMatch(
        uint256 matchId,
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 bettingCloseTime
    ) external onlyVault {
        MatchInfo storage m = matchesById[matchId];

        require(matchId != 0 && matchId <= matchCount, "Match not found");
        require(!m.resolved, "Match resolved");
        require(m.totalNetStaked == 0, "Already staked");
        require(bytes(homeTeam).length > 0, "Home empty");
        require(bytes(awayTeam).length > 0, "Away empty");
        require(bettingCloseTime > block.timestamp, "Close time past");

        m.homeTeam = homeTeam;
        m.awayTeam = awayTeam;
        m.bettingCloseTime = bettingCloseTime;

        emit MatchUpdated(matchId, homeTeam, awayTeam, bettingCloseTime);
    }

    function seedWorldCup2026Schedule() external onlyVault {
        _seedWorldCup2026Schedule();
    }

    function _createMatch(
        string memory homeTeam,
        string memory awayTeam,
        uint64 bettingCloseTime,
        bool emitCreated
    ) internal returns (uint256 matchId) {
        require(matchCount < MAX_MATCHES, "Match limit reached");
        require(bytes(homeTeam).length > 0, "Home empty");
        require(bytes(awayTeam).length > 0, "Away empty");

        matchId = ++matchCount;
        MatchInfo storage m = matchesById[matchId];
        m.homeTeam = homeTeam;
        m.awayTeam = awayTeam;
        m.bettingCloseTime = bettingCloseTime;

        if (emitCreated) {
            emit MatchCreated(matchId, homeTeam, awayTeam, bettingCloseTime);
        }
    }

    function _seedMatch(
        string memory homeTeam,
        string memory awayTeam,
        uint64 bettingCloseTime
    ) internal {
        _createMatch(homeTeam, awayTeam, bettingCloseTime, false);
    }

    function _seedWorldCup2026Schedule() internal {
        require(!scheduleSeeded, "Schedule seeded");
        scheduleSeeded = true;

        _seedMatch("Mexico", "South Africa", 1781204400); // Match 1, 2026-06-11T19:00:00Z, First Stage
        _seedMatch("Korea Republic", "Czechia", 1781229600); // Match 2, 2026-06-12T02:00:00Z, First Stage
        _seedMatch("Canada", "Bosnia and Herzegovina", 1781290800); // Match 3, 2026-06-12T19:00:00Z, First Stage
        _seedMatch("USA", "Paraguay", 1781312400); // Match 4, 2026-06-13T01:00:00Z, First Stage
        _seedMatch("Haiti", "Scotland", 1781398800); // Match 5, 2026-06-14T01:00:00Z, First Stage
        _seedMatch("Australia", "Turkiye", 1781409600); // Match 6, 2026-06-14T04:00:00Z, First Stage
        _seedMatch("Brazil", "Morocco", 1781388000); // Match 7, 2026-06-13T22:00:00Z, First Stage
        _seedMatch("Qatar", "Switzerland", 1781377200); // Match 8, 2026-06-13T19:00:00Z, First Stage
        _seedMatch("Cote d'Ivoire", "Ecuador", 1781478000); // Match 9, 2026-06-14T23:00:00Z, First Stage
        _seedMatch("Germany", "Curacao", 1781456400); // Match 10, 2026-06-14T17:00:00Z, First Stage
        _seedMatch("Netherlands", "Japan", 1781467200); // Match 11, 2026-06-14T20:00:00Z, First Stage
        _seedMatch("Sweden", "Tunisia", 1781488800); // Match 12, 2026-06-15T02:00:00Z, First Stage
        _seedMatch("Saudi Arabia", "Uruguay", 1781560800); // Match 13, 2026-06-15T22:00:00Z, First Stage
        _seedMatch("Spain", "Cabo Verde", 1781539200); // Match 14, 2026-06-15T16:00:00Z, First Stage
        _seedMatch("IR Iran", "New Zealand", 1781571600); // Match 15, 2026-06-16T01:00:00Z, First Stage
        _seedMatch("Belgium", "Egypt", 1781550000); // Match 16, 2026-06-15T19:00:00Z, First Stage
        _seedMatch("France", "Senegal", 1781636400); // Match 17, 2026-06-16T19:00:00Z, First Stage
        _seedMatch("Iraq", "Norway", 1781647200); // Match 18, 2026-06-16T22:00:00Z, First Stage
        _seedMatch("Argentina", "Algeria", 1781658000); // Match 19, 2026-06-17T01:00:00Z, First Stage
        _seedMatch("Austria", "Jordan", 1781668800); // Match 20, 2026-06-17T04:00:00Z, First Stage
        _seedMatch("Ghana", "Panama", 1781737200); // Match 21, 2026-06-17T23:00:00Z, First Stage
        _seedMatch("England", "Croatia", 1781726400); // Match 22, 2026-06-17T20:00:00Z, First Stage
        _seedMatch("Portugal", "Congo DR", 1781715600); // Match 23, 2026-06-17T17:00:00Z, First Stage
        _seedMatch("Uzbekistan", "Colombia", 1781748000); // Match 24, 2026-06-18T02:00:00Z, First Stage
        _seedMatch("Czechia", "South Africa", 1781798400); // Match 25, 2026-06-18T16:00:00Z, First Stage
        _seedMatch("Switzerland", "Bosnia and Herzegovina", 1781809200); // Match 26, 2026-06-18T19:00:00Z, First Stage
        _seedMatch("Canada", "Qatar", 1781820000); // Match 27, 2026-06-18T22:00:00Z, First Stage
        _seedMatch("Mexico", "Korea Republic", 1781830800); // Match 28, 2026-06-19T01:00:00Z, First Stage
        _seedMatch("Brazil", "Haiti", 1781915400); // Match 29, 2026-06-20T00:30:00Z, First Stage
        _seedMatch("Scotland", "Morocco", 1781906400); // Match 30, 2026-06-19T22:00:00Z, First Stage
        _seedMatch("Turkiye", "Paraguay", 1781924400); // Match 31, 2026-06-20T03:00:00Z, First Stage
        _seedMatch("USA", "Australia", 1781895600); // Match 32, 2026-06-19T19:00:00Z, First Stage
        _seedMatch("Germany", "Cote d'Ivoire", 1781985600); // Match 33, 2026-06-20T20:00:00Z, First Stage
        _seedMatch("Ecuador", "Curacao", 1782000000); // Match 34, 2026-06-21T00:00:00Z, First Stage
        _seedMatch("Netherlands", "Sweden", 1781974800); // Match 35, 2026-06-20T17:00:00Z, First Stage
        _seedMatch("Tunisia", "Japan", 1782014400); // Match 36, 2026-06-21T04:00:00Z, First Stage
        _seedMatch("Uruguay", "Cabo Verde", 1782079200); // Match 37, 2026-06-21T22:00:00Z, First Stage
        _seedMatch("Spain", "Saudi Arabia", 1782057600); // Match 38, 2026-06-21T16:00:00Z, First Stage
        _seedMatch("Belgium", "IR Iran", 1782068400); // Match 39, 2026-06-21T19:00:00Z, First Stage
        _seedMatch("New Zealand", "Egypt", 1782090000); // Match 40, 2026-06-22T01:00:00Z, First Stage
        _seedMatch("Norway", "Senegal", 1782172800); // Match 41, 2026-06-23T00:00:00Z, First Stage
        _seedMatch("France", "Iraq", 1782162000); // Match 42, 2026-06-22T21:00:00Z, First Stage
        _seedMatch("Argentina", "Austria", 1782147600); // Match 43, 2026-06-22T17:00:00Z, First Stage
        _seedMatch("Jordan", "Algeria", 1782183600); // Match 44, 2026-06-23T03:00:00Z, First Stage
        _seedMatch("England", "Ghana", 1782244800); // Match 45, 2026-06-23T20:00:00Z, First Stage
        _seedMatch("Panama", "Croatia", 1782255600); // Match 46, 2026-06-23T23:00:00Z, First Stage
        _seedMatch("Portugal", "Uzbekistan", 1782234000); // Match 47, 2026-06-23T17:00:00Z, First Stage
        _seedMatch("Colombia", "Congo DR", 1782266400); // Match 48, 2026-06-24T02:00:00Z, First Stage
        _seedMatch("Scotland", "Brazil", 1782338400); // Match 49, 2026-06-24T22:00:00Z, First Stage
        _seedMatch("Morocco", "Haiti", 1782338400); // Match 50, 2026-06-24T22:00:00Z, First Stage
        _seedMatch("Switzerland", "Canada", 1782327600); // Match 51, 2026-06-24T19:00:00Z, First Stage
        _seedMatch("Bosnia and Herzegovina", "Qatar", 1782327600); // Match 52, 2026-06-24T19:00:00Z, First Stage
        _seedMatch("Czechia", "Mexico", 1782349200); // Match 53, 2026-06-25T01:00:00Z, First Stage
        _seedMatch("South Africa", "Korea Republic", 1782349200); // Match 54, 2026-06-25T01:00:00Z, First Stage
        _seedMatch("Curacao", "Cote d'Ivoire", 1782417600); // Match 55, 2026-06-25T20:00:00Z, First Stage
        _seedMatch("Ecuador", "Germany", 1782417600); // Match 56, 2026-06-25T20:00:00Z, First Stage
        _seedMatch("Japan", "Sweden", 1782428400); // Match 57, 2026-06-25T23:00:00Z, First Stage
        _seedMatch("Tunisia", "Netherlands", 1782428400); // Match 58, 2026-06-25T23:00:00Z, First Stage
        _seedMatch("Turkiye", "USA", 1782439200); // Match 59, 2026-06-26T02:00:00Z, First Stage
        _seedMatch("Paraguay", "Australia", 1782439200); // Match 60, 2026-06-26T02:00:00Z, First Stage
        _seedMatch("Norway", "France", 1782500400); // Match 61, 2026-06-26T19:00:00Z, First Stage
        _seedMatch("Senegal", "Iraq", 1782500400); // Match 62, 2026-06-26T19:00:00Z, First Stage
        _seedMatch("Egypt", "IR Iran", 1782529200); // Match 63, 2026-06-27T03:00:00Z, First Stage
        _seedMatch("New Zealand", "Belgium", 1782529200); // Match 64, 2026-06-27T03:00:00Z, First Stage
        _seedMatch("Cabo Verde", "Saudi Arabia", 1782518400); // Match 65, 2026-06-27T00:00:00Z, First Stage
        _seedMatch("Uruguay", "Spain", 1782518400); // Match 66, 2026-06-27T00:00:00Z, First Stage
        _seedMatch("Panama", "England", 1782594000); // Match 67, 2026-06-27T21:00:00Z, First Stage
        _seedMatch("Croatia", "Ghana", 1782594000); // Match 68, 2026-06-27T21:00:00Z, First Stage
        _seedMatch("Algeria", "Austria", 1782612000); // Match 69, 2026-06-28T02:00:00Z, First Stage
        _seedMatch("Jordan", "Argentina", 1782612000); // Match 70, 2026-06-28T02:00:00Z, First Stage
        _seedMatch("Colombia", "Portugal", 1782603000); // Match 71, 2026-06-27T23:30:00Z, First Stage
        _seedMatch("Congo DR", "Uzbekistan", 1782603000); // Match 72, 2026-06-27T23:30:00Z, First Stage
        _seedMatch("2A", "2B", 1782673200); // Match 73, 2026-06-28T19:00:00Z, Round of 32
        _seedMatch("1E", "3 ABCDF", 1782765000); // Match 74, 2026-06-29T20:30:00Z, Round of 32
        _seedMatch("1F", "2C", 1782781200); // Match 75, 2026-06-30T01:00:00Z, Round of 32
        _seedMatch("1C", "2F", 1782752400); // Match 76, 2026-06-29T17:00:00Z, Round of 32
        _seedMatch("1I", "3 CDFGH", 1782853200); // Match 77, 2026-06-30T21:00:00Z, Round of 32
        _seedMatch("2E", "2I", 1782838800); // Match 78, 2026-06-30T17:00:00Z, Round of 32
        _seedMatch("1A", "3 CEFHI", 1782867600); // Match 79, 2026-07-01T01:00:00Z, Round of 32
        _seedMatch("1L", "3 EHIJK", 1782921600); // Match 80, 2026-07-01T16:00:00Z, Round of 32
        _seedMatch("1D", "3 BEFIJ", 1782950400); // Match 81, 2026-07-02T00:00:00Z, Round of 32
        _seedMatch("1G", "3 AEHIJ", 1782936000); // Match 82, 2026-07-01T20:00:00Z, Round of 32
        _seedMatch("2K", "2L", 1783033200); // Match 83, 2026-07-02T23:00:00Z, Round of 32
        _seedMatch("1H", "2J", 1783018800); // Match 84, 2026-07-02T19:00:00Z, Round of 32
        _seedMatch("1B", "3 EFGIJ", 1783047600); // Match 85, 2026-07-03T03:00:00Z, Round of 32
        _seedMatch("1J", "2H", 1783116000); // Match 86, 2026-07-03T22:00:00Z, Round of 32
        _seedMatch("1K", "3 DEIJL", 1783128600); // Match 87, 2026-07-04T01:30:00Z, Round of 32
        _seedMatch("2D", "2G", 1783101600); // Match 88, 2026-07-03T18:00:00Z, Round of 32
        _seedMatch("W74", "W77", 1783198800); // Match 89, 2026-07-04T21:00:00Z, Round of 16
        _seedMatch("W73", "W75", 1783184400); // Match 90, 2026-07-04T17:00:00Z, Round of 16
        _seedMatch("W76", "W78", 1783281600); // Match 91, 2026-07-05T20:00:00Z, Round of 16
        _seedMatch("W79", "W80", 1783296000); // Match 92, 2026-07-06T00:00:00Z, Round of 16
        _seedMatch("W83", "W84", 1783364400); // Match 93, 2026-07-06T19:00:00Z, Round of 16
        _seedMatch("W81", "W82", 1783382400); // Match 94, 2026-07-07T00:00:00Z, Round of 16
        _seedMatch("W86", "W88", 1783440000); // Match 95, 2026-07-07T16:00:00Z, Round of 16
        _seedMatch("W85", "W87", 1783454400); // Match 96, 2026-07-07T20:00:00Z, Round of 16
        _seedMatch("W89", "W90", 1783627200); // Match 97, 2026-07-09T20:00:00Z, Quarter-final
        _seedMatch("W93", "W94", 1783710000); // Match 98, 2026-07-10T19:00:00Z, Quarter-final
        _seedMatch("W91", "W92", 1783803600); // Match 99, 2026-07-11T21:00:00Z, Quarter-final
        _seedMatch("W95", "W96", 1783818000); // Match 100, 2026-07-12T01:00:00Z, Quarter-final
        _seedMatch("W97", "W98", 1784055600); // Match 101, 2026-07-14T19:00:00Z, Semi-final
        _seedMatch("W99", "W100", 1784142000); // Match 102, 2026-07-15T19:00:00Z, Semi-final
        _seedMatch("L101", "L102", 1784408400); // Match 103, 2026-07-18T21:00:00Z, Play-off for third place
        _seedMatch("W101", "W102", 1784487600); // Match 104, 2026-07-19T19:00:00Z, Final

        require(matchCount == SEEDED_WORLD_CUP_2026_MATCHES, "Seed count mismatch");
        emit WorldCup2026ScheduleSeeded(matchCount);
    }

    function recordPrediction(
        address user,
        uint256 matchId,
        uint8 outcome,
        uint256 netAmount
    ) external onlyVault {
        MatchInfo storage m = matchesById[matchId];

        require(matchId != 0 && matchId <= matchCount, "Match not found");
        require(!m.resolved, "Match resolved");
        require(block.timestamp < m.bettingCloseTime, "Betting closed");
        require(outcome <= OUTCOME_AWAY, "Invalid outcome");
        require(user != address(0), "User zero");
        require(netAmount > 0, "Amount zero");

        userNetStake[matchId][outcome][user] += netAmount;
        m.totalNetStaked += netAmount;

        if (outcome == OUTCOME_HOME) {
            m.homeNetStaked += netAmount;
        } else if (outcome == OUTCOME_DRAW) {
            m.drawNetStaked += netAmount;
        } else {
            m.awayNetStaked += netAmount;
        }

        emit PredictionRecorded(matchId, user, outcome, netAmount);
    }

    function resolveMatch(uint256 matchId, uint8 result) external onlyVault {
        MatchInfo storage m = matchesById[matchId];

        require(matchId != 0 && matchId <= matchCount, "Match not found");
        require(!m.resolved, "Already resolved");
        require(block.timestamp >= m.bettingCloseTime, "Betting not closed");
        require(result <= OUTCOME_AWAY, "Invalid result");

        m.resolved = true;
        m.result = result;

        uint256 winningStake = _outcomeStake(m, result);
        if (winningStake > 0) {
            m.remainingPayoutPool = m.totalNetStaked;
            m.remainingWinningStake = winningStake;
        }

        emit MatchResolved(matchId, result, m.totalNetStaked);
    }

    function voidMatch(uint256 matchId) external onlyVault {
        MatchInfo storage m = matchesById[matchId];

        require(matchId != 0 && matchId <= matchCount, "Match not found");
        require(!m.resolved, "Already resolved");

        m.resolved = true;
        m.result = OUTCOME_VOID;

        emit MatchVoided(matchId);
    }

    function claimTo(address user, uint256 matchId) external onlyVault returns (uint256 payout) {
        MatchInfo storage m = matchesById[matchId];

        require(matchId != 0 && matchId <= matchCount, "Match not found");
        require(m.resolved, "Not resolved");
        require(!claimed[matchId][user], "Already claimed");

        claimed[matchId][user] = true;
        payout = _claimable(m, matchId, user);
        require(payout > 0, "Nothing to claim");

        if (m.result <= OUTCOME_AWAY && _outcomeStake(m, m.result) > 0) {
            uint256 winnerStake = userNetStake[matchId][m.result][user];
            m.remainingPayoutPool -= payout;
            m.remainingWinningStake -= winnerStake;
        }

        _safeTransfer(predictionToken, user, payout);

        emit PredictionClaimed(matchId, user, payout);
    }

    function getMatch(
        uint256 matchId
    )
        external
        view
        returns (
            string memory homeTeam,
            string memory awayTeam,
            uint64 bettingCloseTime,
            bool resolved,
            uint8 result,
            uint256 totalNetStaked,
            uint256 homeNetStaked,
            uint256 drawNetStaked,
            uint256 awayNetStaked,
            uint256 remainingPayoutPool,
            uint256 remainingWinningStake
        )
    {
        MatchInfo storage m = matchesById[matchId];
        homeTeam = m.homeTeam;
        awayTeam = m.awayTeam;
        bettingCloseTime = m.bettingCloseTime;
        resolved = m.resolved;
        result = m.result;
        totalNetStaked = m.totalNetStaked;
        homeNetStaked = m.homeNetStaked;
        drawNetStaked = m.drawNetStaked;
        awayNetStaked = m.awayNetStaked;
        remainingPayoutPool = m.remainingPayoutPool;
        remainingWinningStake = m.remainingWinningStake;
    }

    function getUserStake(
        uint256 matchId,
        address user
    ) external view returns (uint256 homeStake, uint256 drawStake, uint256 awayStake) {
        homeStake = userNetStake[matchId][OUTCOME_HOME][user];
        drawStake = userNetStake[matchId][OUTCOME_DRAW][user];
        awayStake = userNetStake[matchId][OUTCOME_AWAY][user];
    }

    function claimable(uint256 matchId, address user) external view returns (uint256) {
        MatchInfo storage m = matchesById[matchId];
        if (matchId == 0 || matchId > matchCount || !m.resolved || claimed[matchId][user]) {
            return 0;
        }
        return _claimable(m, matchId, user);
    }

    function _claimable(
        MatchInfo storage m,
        uint256 matchId,
        address user
    ) internal view returns (uint256) {
        if (m.result <= OUTCOME_AWAY && _outcomeStake(m, m.result) > 0) {
            uint256 winnerStake = userNetStake[matchId][m.result][user];
            if (winnerStake == 0 || m.remainingWinningStake == 0) {
                return 0;
            }
            return (winnerStake * m.remainingPayoutPool) / m.remainingWinningStake;
        }

        return
            userNetStake[matchId][OUTCOME_HOME][user] +
            userNetStake[matchId][OUTCOME_DRAW][user] +
            userNetStake[matchId][OUTCOME_AWAY][user];
    }

    function _outcomeStake(MatchInfo storage m, uint8 outcome) internal view returns (uint256) {
        if (outcome == OUTCOME_HOME) {
            return m.homeNetStaked;
        }
        if (outcome == OUTCOME_DRAW) {
            return m.drawNetStaked;
        }
        if (outcome == OUTCOME_AWAY) {
            return m.awayNetStaked;
        }
        return 0;
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }
}

contract FlapDualFeatureVault is VaultBaseV2, AutomationCompatibleInterface {
    address public constant PANCAKE_ROUTER_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant BUYBACK_BPS = 1000;
    uint256 public constant PREDICTION_BURN_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    uint256 public constant VOTE_DURATION = 12 hours;

    bool private initialized;
    bool private reentrancyLock;

    address public taxToken;
    address public owner;
    address public keeper;
    address public predictionToken;
    address public oracle;
    address public predictionMarketImplementation;
    WorldCupPredictionMarket public predictionMarket;

    IPancakeRouterV2 public router;
    address public WBNB;

    address public buybackToken;
    address[] private buybackPath;

    bool public configLocked;
    bool public automationEnabled;
    uint256 public lastBuybackTime;
    uint256 public totalPredictionFeesBurned;

    address public votingToken;
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

    event Initialized(
        address indexed taxToken,
        address indexed creator,
        address indexed predictionToken,
        address oracle,
        address keeper,
        address predictionMarket
    );
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event KeeperUpdated(address indexed newKeeper);
    event OracleUpdated(address indexed newOracle);
    event VotingTokenUpdated(address indexed token);
    event BuybackTokenCASubmitted(
        uint256 indexed voteId,
        address indexed owner,
        address indexed proposedBuybackToken,
        uint256 startTime,
        uint256 endTime
    );
    event VoteCast(uint256 indexed voteId, address indexed voter, bool support, uint256 amount);
    event BuybackVoteFinalized(
        uint256 indexed voteId,
        address indexed proposedBuybackToken,
        bool passed,
        uint256 yesVotes,
        uint256 noVotes
    );
    event VotingTokensClaimed(uint256 indexed voteId, address indexed voter, uint256 amount);
    event BuybackTokenApproved(address indexed token);
    event BuybackPathUpdated(address[] path);
    event ConfigLocked(address indexed token);
    event AutomationEnabledUpdated(bool enabled);
    event BuybackExecuted(address indexed token, uint256 bnbAmountUsed, uint256 timestamp);
    event PredictionPlaced(
        uint256 indexed matchId,
        address indexed user,
        uint8 indexed outcome,
        uint256 grossAmount,
        uint256 burnedFee,
        uint256 netAmount
    );
    event PredictionClaimed(uint256 indexed matchId, address indexed user, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner || msg.sender == _getGuardian(), "Not owner/guardian");
        _;
    }

    modifier onlyExecutor() {
        require(
            msg.sender == owner || msg.sender == keeper || msg.sender == _getGuardian(),
            "Not executor"
        );
        _;
    }

    modifier onlyOracleOwnerOrGuardian() {
        require(
            msg.sender == oracle || msg.sender == owner || msg.sender == _getGuardian(),
            "Not oracle/owner/guardian"
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
        initialized = true;
    }

    receive() external payable {}

    function initialize(
        address taxToken_,
        address creator_,
        address predictionToken_,
        address oracle_,
        address keeper_,
        address predictionMarketImplementation_
    ) external {
        require(!initialized, "Already initialized");
        require(taxToken_ != address(0), "Tax token zero");
        require(creator_ != address(0), "Creator zero");
        require(predictionMarketImplementation_.code.length > 0, "Market impl not contract");

        initialized = true;
        taxToken = taxToken_;
        owner = creator_;
        keeper = keeper_;
        predictionToken = predictionToken_ == address(0) ? taxToken_ : predictionToken_;
        oracle = oracle_ == address(0) ? creator_ : oracle_;
        predictionMarketImplementation = predictionMarketImplementation_;
        votingToken = taxToken_;
        automationEnabled = true;

        router = IPancakeRouterV2(PANCAKE_ROUTER_V2);
        WBNB = IPancakeRouterV2(PANCAKE_ROUTER_V2).WETH();

        address market = Clones.clone(predictionMarketImplementation_);
        WorldCupPredictionMarket(market).initialize(
            address(this),
            creator_,
            predictionToken,
            oracle,
            _getGuardian()
        );
        predictionMarket = WorldCupPredictionMarket(market);

        emit OwnershipTransferred(address(0), creator_);
        emit VotingTokenUpdated(taxToken_);
        emit Initialized(taxToken_, creator_, predictionToken, oracle, keeper_, market);
    }

    function description() public view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "Dual feature Flap vault: BNB tax revenue funds hourly buyback/burn after community vote; ",
                    "World Cup prediction market burns 10% of each prediction and pays winners pro-rata. ",
                    configLocked ? "Buyback config is locked." : "Buyback config is not locked."
                )
            );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "DualFeatureWorldCupVault";
        schema.description =
            "BNB buyback vault plus World Cup prediction market with 10% prediction burn fee.";
        schema.methods = new VaultMethodSchema[](7);

        schema.methods[0].name = "treasuryBalanceBNB";
        schema.methods[0].description = "Returns the BNB balance held for buybacks.";
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("balance", "uint256", "BNB balance", 18);

        schema.methods[1].name = "predictionMarketAddress";
        schema.methods[1].description = "Returns the prediction market module address.";
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("market", "address", "Prediction market", 0);

        schema.methods[2].name = "createWorldCupMatch";
        schema.methods[2].description = "Creates a World Cup match with home, draw and away outcomes.";
        schema.methods[2].inputs = new FieldDescriptor[](3);
        schema.methods[2].inputs[0] = FieldDescriptor("homeTeam", "string", "Home team name", 0);
        schema.methods[2].inputs[1] = FieldDescriptor("awayTeam", "string", "Away team name", 0);
        schema.methods[2].inputs[2] = FieldDescriptor(
            "bettingCloseTime",
            "time",
            "Prediction close time",
            0
        );
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "placePrediction";
        schema.methods[3].description =
            "Places a prediction. Outcome: 0 home win, 1 draw, 2 away win.";
        schema.methods[3].inputs = new FieldDescriptor[](3);
        schema.methods[3].inputs[0] = FieldDescriptor("matchId", "uint256", "Match id", 0);
        schema.methods[3].inputs[1] = FieldDescriptor("outcome", "uint16", "0 home, 1 draw, 2 away", 0);
        schema.methods[3].inputs[2] = FieldDescriptor("amount", "uint256", "Prediction token amount", 18);
        schema.methods[3].approvals = new ApproveAction[](1);
        schema.methods[3].approvals[0] = ApproveAction("taxToken", "amount");
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "claimPrediction";
        schema.methods[4].description = "Claims winnings or refunds after a match is resolved or voided.";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("matchId", "uint256", "Match id", 0);
        schema.methods[4].isWriteMethod = true;

        schema.methods[5].name = "resolveWorldCupMatch";
        schema.methods[5].description = "Oracle resolves a match. Result: 0 home, 1 draw, 2 away.";
        schema.methods[5].inputs = new FieldDescriptor[](2);
        schema.methods[5].inputs[0] = FieldDescriptor("matchId", "uint256", "Match id", 0);
        schema.methods[5].inputs[1] = FieldDescriptor("result", "uint16", "0 home, 1 draw, 2 away", 0);
        schema.methods[5].isWriteMethod = true;

        schema.methods[6].name = "executeBuyback";
        schema.methods[6].description = "Executes the hourly BNB buyback and burns bought tokens.";
        schema.methods[6].isWriteMethod = true;
    }

    function lpToken() external pure returns (address) {
        return address(0);
    }

    function predictionMarketAddress() external view returns (address) {
        return address(predictionMarket);
    }

    function setKeeper(address newKeeper) external onlyOwnerOrGuardian {
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function setOracle(address newOracle) external onlyOwnerOrGuardian {
        require(newOracle != address(0), "Oracle zero");
        oracle = newOracle;
        predictionMarket.setOracle(newOracle);
        emit OracleUpdated(newOracle);
    }

    function setVotingToken(address tokenCA) external onlyOwnerOrGuardian {
        require(!configLocked, "Config locked");
        require(voteCounter == 0, "Vote already started");
        require(tokenCA != address(0), "Voting token zero");
        require(tokenCA.code.length > 0, "Voting token not contract");

        votingToken = tokenCA;

        emit VotingTokenUpdated(tokenCA);
    }

    function setAutomationEnabled(bool enabled) external onlyOwnerOrGuardian {
        automationEnabled = enabled;
        emit AutomationEnabledUpdated(enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner zero");

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function createWorldCupMatch(
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 bettingCloseTime
    ) external onlyOwnerOrGuardian returns (uint256 matchId) {
        matchId = predictionMarket.createMatch(homeTeam, awayTeam, bettingCloseTime);
    }

    function batchCreateWorldCupMatches(
        string[] calldata homeTeams,
        string[] calldata awayTeams,
        uint64[] calldata bettingCloseTimes
    ) external onlyOwnerOrGuardian {
        require(homeTeams.length == awayTeams.length, "Length mismatch");
        require(homeTeams.length == bettingCloseTimes.length, "Length mismatch");

        for (uint256 i = 0; i < homeTeams.length; i++) {
            predictionMarket.createMatch(homeTeams[i], awayTeams[i], bettingCloseTimes[i]);
        }
    }

    function updateWorldCupMatch(
        uint256 matchId,
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 bettingCloseTime
    ) external onlyOwnerOrGuardian {
        predictionMarket.updateMatch(matchId, homeTeam, awayTeam, bettingCloseTime);
    }

    function batchUpdateWorldCupMatches(
        uint256[] calldata matchIds,
        string[] calldata homeTeams,
        string[] calldata awayTeams,
        uint64[] calldata bettingCloseTimes
    ) external onlyOwnerOrGuardian {
        require(matchIds.length == homeTeams.length, "Length mismatch");
        require(matchIds.length == awayTeams.length, "Length mismatch");
        require(matchIds.length == bettingCloseTimes.length, "Length mismatch");

        for (uint256 i = 0; i < matchIds.length; i++) {
            predictionMarket.updateMatch(
                matchIds[i],
                homeTeams[i],
                awayTeams[i],
                bettingCloseTimes[i]
            );
        }
    }

    function placePrediction(
        uint256 matchId,
        uint8 outcome,
        uint256 amount
    ) external nonReentrant {
        require(amount > 0, "Amount zero");

        address token = predictionToken;
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        require(received > 0, "Received zero");

        uint256 burnFee = (received * PREDICTION_BURN_BPS) / BPS_DENOMINATOR;
        if (burnFee > 0) {
            _safeTransfer(token, BURN_ADDRESS, burnFee);
            totalPredictionFeesBurned += burnFee;
        }

        uint256 netTarget = received - burnFee;
        require(netTarget > 0, "Net zero");

        uint256 marketBefore = IERC20(token).balanceOf(address(predictionMarket));
        _safeTransfer(token, address(predictionMarket), netTarget);
        uint256 marketReceived = IERC20(token).balanceOf(address(predictionMarket)) - marketBefore;
        require(marketReceived > 0, "Market received zero");

        predictionMarket.recordPrediction(msg.sender, matchId, outcome, marketReceived);

        emit PredictionPlaced(matchId, msg.sender, outcome, received, burnFee, marketReceived);
    }

    function resolveWorldCupMatch(uint256 matchId, uint8 result) external onlyOracleOwnerOrGuardian {
        predictionMarket.resolveMatch(matchId, result);
    }

    function voidWorldCupMatch(uint256 matchId) external onlyOracleOwnerOrGuardian {
        predictionMarket.voidMatch(matchId);
    }

    function claimPrediction(uint256 matchId) external nonReentrant returns (uint256 payout) {
        payout = predictionMarket.claimTo(msg.sender, matchId);
        emit PredictionClaimed(matchId, msg.sender, payout);
    }

    function submitBuybackTokenCAForVote(address proposedTokenCA) external onlyOwnerOrGuardian {
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

    function castVote(uint256 voteId, bool support, uint256 amount) external nonReentrant {
        TokenVote storage v = votes[voteId];

        require(v.id != 0, "Vote not found");
        require(!v.finalized, "Vote finalized");
        require(block.timestamp < v.endTime, "Vote ended");
        require(amount > 0, "Amount zero");

        VoteReceipt storage receipt = voteReceipts[voteId][msg.sender];

        require(!receipt.hasVoted, "Already voted");

        uint256 beforeBalance = IERC20(v.votingTokenUsed).balanceOf(address(this));
        _safeTransferFrom(v.votingTokenUsed, msg.sender, address(this), amount);
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

    function lockConfig() external onlyOwnerOrGuardian {
        require(!configLocked, "Already locked");
        require(buybackToken != address(0), "Token not approved");
        require(buybackPath.length == 2, "Path not set");
        require(buybackPath[0] == WBNB, "Path must start WBNB");
        require(buybackPath[1] == buybackToken, "Path must end token");

        configLocked = true;

        emit ConfigLocked(buybackToken);
    }

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

    function performUpkeep(bytes calldata) external override onlyExecutor nonReentrant {
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

    function getBuybackPath() external view returns (address[] memory) {
        return _copyBuybackPath();
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

        if (v.id == 0 || block.timestamp >= v.endTime) {
            return 0;
        }

        return v.endTime - block.timestamp;
    }

    function canClaimVotingTokens(uint256 voteId, address user) external view returns (bool) {
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
    ) external view returns (uint256 amount, bool support, bool hasVoted, bool claimed) {
        VoteReceipt memory receipt = voteReceipts[voteId][user];

        amount = receipt.amount;
        support = receipt.support;
        hasVoted = receipt.hasVoted;
        claimed = receipt.claimed;
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

    function _hasUnfinalizedVote() internal view returns (bool) {
        if (latestVoteId == 0) {
            return false;
        }

        return !votes[latestVoteId].finalized;
    }

    function _executeBuyback() internal {
        require(automationEnabled, "Buyback disabled");
        require(configLocked, "Config not locked");
        require(buybackToken != address(0), "Token not set");
        require(buybackPath.length == 2, "Path not set");
        require(buybackPath[0] == WBNB, "Path must start WBNB");
        require(buybackPath[1] == buybackToken, "Path must end token");

        if (lastBuybackTime != 0) {
            require(block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL, "Too early");
        }

        uint256 treasuryBNB = address(this).balance;
        require(treasuryBNB > 0, "No BNB");

        uint256 buybackBNB = (treasuryBNB * BUYBACK_BPS) / BPS_DENOMINATOR;
        require(buybackBNB > 0, "Buyback zero");

        lastBuybackTime = block.timestamp;

        address[] memory path = _copyBuybackPath();

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: buybackBNB}(
            0,
            path,
            BURN_ADDRESS,
            block.timestamp + 600
        );

        emit BuybackExecuted(buybackToken, buybackBNB, block.timestamp);
    }

    function _copyBuybackPath() internal view returns (address[] memory path) {
        path = new address[](buybackPath.length);

        for (uint256 i = 0; i < buybackPath.length; i++) {
            path[i] = buybackPath[i];
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );

        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }
}

contract FlapDualFeatureVaultFactory is VaultFactoryBaseV2 {
    address public immutable vaultImplementation;
    address public immutable predictionMarketImplementation;

    event VaultCreated(
        address indexed taxToken,
        address indexed creator,
        address indexed vault,
        address predictionMarket,
        address predictionToken,
        address oracle,
        address keeper
    );

    constructor(address vaultImplementation_, address predictionMarketImplementation_) {
        if (vaultImplementation_ == address(0) || predictionMarketImplementation_ == address(0)) {
            revert ZeroAddress();
        }
        require(vaultImplementation_.code.length > 0, "Vault impl not contract");
        require(predictionMarketImplementation_.code.length > 0, "Market impl not contract");

        vaultImplementation = vaultImplementation_;
        predictionMarketImplementation = predictionMarketImplementation_;
    }

    function newVault(
        address taxToken,
        address quoteToken,
        address creator,
        bytes calldata vaultData
    ) external override returns (address vault) {
        if (msg.sender != _getVaultPortal()) {
            revert OnlyVaultPortal();
        }
        if (taxToken == address(0) || creator == address(0)) {
            revert ZeroAddress();
        }
        require(isQuoteTokenSupported(quoteToken), "Quote unsupported");

        (address predictionToken, address oracle, address keeper) = _decodeVaultData(vaultData);

        vault = Clones.clone(vaultImplementation);
        FlapDualFeatureVault(payable(vault)).initialize(
            taxToken,
            creator,
            predictionToken,
            oracle,
            keeper,
            predictionMarketImplementation
        );

        address market = FlapDualFeatureVault(payable(vault)).predictionMarketAddress();
        address resolvedPredictionToken = FlapDualFeatureVault(payable(vault)).predictionToken();
        address resolvedOracle = FlapDualFeatureVault(payable(vault)).oracle();

        emit VaultCreated(
            taxToken,
            creator,
            vault,
            market,
            resolvedPredictionToken,
            resolvedOracle,
            keeper
        );
    }

    function isQuoteTokenSupported(address quoteToken) public pure override returns (bool supported) {
        return quoteToken == address(0);
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Creates a dual feature vault. Use zero address for predictionToken to use the launched tax token; use zero address for oracle to use the creator wallet.";
        schema.fields = new FieldDescriptor[](3);
        schema.fields[0] = FieldDescriptor(
            "predictionToken",
            "address",
            "ERC20 token used for World Cup predictions; zero uses the launched tax token",
            0
        );
        schema.fields[1] = FieldDescriptor(
            "oracle",
            "address",
            "Address allowed to resolve match results; zero uses creator",
            0
        );
        schema.fields[2] = FieldDescriptor(
            "keeper",
            "address",
            "Address allowed to execute buybacks; zero disables keeper until set",
            0
        );
        schema.isArray = false;
    }

    function _decodeVaultData(
        bytes calldata vaultData
    ) internal pure returns (address predictionToken, address oracle, address keeper) {
        if (vaultData.length == 0) {
            return (address(0), address(0), address(0));
        }

        return abi.decode(vaultData, (address, address, address));
    }
}
