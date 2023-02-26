// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

/**
BNB Chain Mainnet
LINK Token Address: 0x404460c6a5ede2d891e8297795264fde62adbb75
Oracle Address: 0x97a585920a3D0E8922406c5E6D826F76F29ecCd4
JOB ID: c37e674b864a47ccb33096ca007d64e4
**/

/**
 * Request testnet LINK and ETH here: https://faucets.chain.link/
 * Find information on LINK Token Contracts and get the latest ETH and LINK faucets here: https://docs.chain.link/docs/link-token-contracts/
 */

/**
 * THIS IS AN EXAMPLE CONTRACT WHICH USES HARDCODED VALUES FOR CLARITY.
 * THIS EXAMPLE USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */

contract APIConsumer is ChainlinkClient, ConfirmedOwner {
    using Chainlink for Chainlink.Request;

    uint256 public SBETPrice;
    bytes32 private jobId;
    uint256 private fee;

    event RequestVolume(bytes32 indexed requestId, uint256 volume);

    /**
     * @notice Initialize the link token and target oracle
     * BSC Testnet details:
     * Token: 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06
     * Oracle: 0xCC79157eb46F5624204f47AB42b3906cAA40eaB7
     * JobId: ca98366cc7314957b8c012c72f05aeeb
     * Goerli Testnet details:
     * Link Token: 0x326C977E6efc84E512bB9C30f76E30c160eD06FB
     * Oracle: 0xCC79157eb46F5624204f47AB42b3906cAA40eaB7 (Chainlink DevRel)
     * jobId: ca98366cc7314957b8c012c72f05aeeb
     *
     */
    constructor() ConfirmedOwner(msg.sender) {
        setChainlinkToken(0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06);
        setChainlinkOracle(0xCC79157eb46F5624204f47AB42b3906cAA40eaB7);
        jobId = "ca98366cc7314957b8c012c72f05aeeb";
        fee = (1 * LINK_DIVISIBILITY) / 10; // 0,1 * 10**18 (Varies by network and job)
    }

    /**
     * Create a Chainlink request to retrieve API response, find the target
     * data, then multiply by 1000000000000000000 (to remove decimal places from data).
     */
    function getSBETPrice() public returns (bytes32 requestId) {
        Chainlink.Request memory req = buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfill.selector
        );

        // Set the URL to perform the GET request on
        req.add(
            "get",
            // "https://min-api.cryptocompare.com/data/pricemultifull?fsyms=ETH&tsyms=USD"
            "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd"
        );

        // Set the path to find the desired data in the API response, where the response format is:
        // {"RAW":
        //   {"ETH":
        //    {"USD":
        //     {
        //      "VOLUME24HOUR": xxx.xxx,
        //     }
        //    }
        //   }
        //  }
        // request.add("path", "RAW.ETH.USD.VOLUME24HOUR"); // Chainlink nodes prior to 1.0.0 support this format
        req.add("path", "ethereum,usd"); // Chainlink nodes 1.0.0 and later support this format

        // Multiply the result by 1000000000000000000 to remove decimals
        int256 timesAmount = 10 ** 18;
        req.addInt("times", timesAmount);

        // Sends the request
        return sendChainlinkRequest(req, fee);
    }

    /**
     * Receive the response in the form of uint256
     */
    function fulfill(
        bytes32 _requestId,
        uint256 _price
    ) public recordChainlinkFulfillment(_requestId) {
        emit RequestVolume(_requestId, _price);
        SBETPrice = _price;
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }
}

// interface SBETPriceOracle {
//     function getSBETPrice() external view returns (bytes32 requestId);

//     function fulfill(bytes32 _requestId, uint256 _price) external;
// }

contract SafuBetsTreasury is ReentrancyGuard, APIConsumer {
    // The BUSD contract
    ERC20 public BUSD;
    // The SBET contract
    ERC20 public SBET;
    // Oracle address
    // address public oracleAddress;

    mapping(address => bool) public v1Holders;

    // owner of the contract
    address public admin;

    // Total staked amount for SBET
    uint256 public TVL_SBET;

    // Total bond amount for BUSD
    uint256 public TVL_BUSD;

    // SBET price fetched via oracle
    uint256 public priceOfSBET;

    // Max allowed amount for staking SBETs
    uint256 public maxAllowedStake;

    // Max allowed amount for purchasing discount SBETs
    uint256 public maxAllowedPurchase;

    // Map to store the staked amount for each user
    mapping(address => uint256) public stakedAmounts;
    // The bond purchase time for each user
    mapping(address => uint256) public totalBUSDSpent;
    // Map to store vested amount for each bond purchaser
    mapping(address => uint256) public vestedSBETs;
    // Map to store the accumulated rewards for each staker
    mapping(address => uint256) public claimableRewards;
    // Map to store the claimed rewards for each user
    mapping(address => uint256) public rewardsClaimed;
    // Map to store the compounded rewards for each user
    mapping(address => uint256) public compoundedRewards;

    uint256 public vestingPeriod; // in seconds
    mapping(address => uint256) public swapAmounts;
    mapping(address => uint256) public vestingDates;
    mapping(address => uint256) public claimedAmounts;

    // The reward rate for staking BUSD in SBET
    uint256 public rewardRate; // 10 ~ 10%

    // Extra reward rate for V1 Holders
    uint256 public addtionalAPYForV1Holders;

    // The discount rate for BUSD to SBET swap
    uint256 public swapDiscount; // 10 ~ 10%

    event SBETStaked(address staker, uint256 amount);
    event SBETUnstaked(address staker, uint256 amount);
    event RewardCompounded(address staker, uint256 amount);
    event RewardClaimed(address staker, uint256 amount);
    event BondPurchased(address purchaser, uint256 amount);
    event ClaimedVestedSBETs(address purchaser, uint256 amount);

    // The constructor to initialize the contract
    constructor(
        address _BUSD,
        address _SBET,
        uint256 _rewardRate,
        uint256 _additionalAPYForV1Holders,
        uint256 _maxStakeAmnt,
        uint256 _maxPurchaseAmnt,
        uint256 _swapDiscount,
        uint256 _vestingPeriod
    ) {
        require(
            _BUSD != address(0) && _SBET != address(0),
            "Can't set zero addresses"
        );
        require(_rewardRate > 0, "Can't set 0 reward for stakers");
        require(
            _maxStakeAmnt <= 1_000_000 * 1e18 && _maxStakeAmnt > 0,
            "Can't set 0 reward for stakers"
        );
        require(
            _maxPurchaseAmnt <= 100_000 * 1e18 && _maxPurchaseAmnt > 0,
            "Can't set 0 reward for stakers"
        );
        require(
            _vestingPeriod >= 5 days,
            "Minimum of 5 days vesting required!"
        );
        BUSD = ERC20(_BUSD);
        SBET = ERC20(_SBET);
        rewardRate = _rewardRate;
        addtionalAPYForV1Holders = _additionalAPYForV1Holders;
        maxAllowedStake = _maxStakeAmnt * 1e18;
        maxAllowedPurchase = _maxPurchaseAmnt * 1e18;
        swapDiscount = _swapDiscount;
        vestingPeriod = _vestingPeriod;

        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Ownable: caller is not the owner");
        _;
    }

    // @notice - add promoters
    function addV1Holders(address[] memory accounts, bool state)
        external
        onlyOwner
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            v1Holders[accounts[i]] = state;
        }
    }

    function isV1Holder(address holder) external view returns (bool) {
        if (v1Holders[holder]) {
            return true;
        } else {
            return false;
        }
    }

    function isEligibleStakerForVoting(address holder)
        public
        view
        returns (bool, uint256)
    {
        if (stakedAmounts[holder] >= 10000 * 1e18) {
            return (true, stakedAmounts[holder]);
        } else {
            return (false, stakedAmounts[holder]);
        }
    }

    // Stake function to allow users to stake BUSD
    function stake(uint256 amount) external nonReentrant {
        // Ensure that the user has enough SBETs balance
        require(SBET.balanceOf(msg.sender) >= amount, "Insufficient balance");
        // Ensure that the purchaser is not exceeding max buy limit in a single transaction
        require(
            stakedAmounts[msg.sender] + amount <= maxAllowedStake,
            "You are exceeding max stake limit!"
        );
        // Transfer the amount of BUSD from the user to the contract
        require(
            SBET.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        // Update the staked amount for the user
        stakedAmounts[msg.sender] += amount;
        TVL_SBET += amount;

        emit SBETStaked(msg.sender, amount);
    }

    // Unstake function to allow users to unstake BUSD
    function unstake(uint256 amount) external nonReentrant {
        // Ensure that the user has enough staked amount
        require(
            stakedAmounts[msg.sender] >= amount,
            "Insufficient staked amount"
        );
        // Update the staked amount for the user
        stakedAmounts[msg.sender] -= amount;
        TVL_SBET -= amount;
        // Transfer the unstaked amount of BUSD back to the user
        require(SBET.transfer(msg.sender, amount), "Transfer failed");

        emit SBETUnstaked(msg.sender, amount);
    }

    // Compound function to allow users to compound their rewards into existing staking
    function compound() external nonReentrant {
        uint256 compoundAmnt = calculateStakingReward(msg.sender);
        // Ensure that the user has rewards to compound
        require(claimableRewards[msg.sender] > 0, "No rewards to compound");

        // Reset the rewards for the user
        claimableRewards[msg.sender] = 0;
        TVL_SBET += compoundAmnt;
        // Add the compounded rewards to the existing staked amount
        stakedAmounts[msg.sender] += compoundAmnt;
        // Update the compounded rewards for the user
        compoundedRewards[msg.sender] += compoundAmnt;

        emit RewardCompounded(msg.sender, compoundAmnt);
    }

    // calculate rewards for staked amount of BUSD
    function calculateStakingReward(address _staker)
        internal
        returns (uint256)
    {
        require(_staker != address(0), "staker can't be zero address");
        require(stakedAmounts[msg.sender] >= 0, "Incorrect amount!");

        // Calculate the reward amount in SBET

        if (v1Holders[msg.sender]) {
            uint256 rewardAmount = (stakedAmounts[msg.sender] *
                (rewardRate + addtionalAPYForV1Holders)) / (100 * 365 days);
            claimableRewards[msg.sender] = rewardAmount;

            return (rewardAmount);
        } else {
            uint256 rewardAmount = (stakedAmounts[msg.sender] * rewardRate) /
                (100 * 365 days);
            claimableRewards[msg.sender] = rewardAmount;

            return (rewardAmount);
        }
    }

    // ClaimReward function to allow users to claim their rewards in SBET
    function claimReward() external nonReentrant {
        uint256 claimAmnt = calculateStakingReward(msg.sender);

        // Ensure that the user has rewards to claim
        require(claimableRewards[msg.sender] > 0, "No rewards to claim");
        // Ensure that the contract has enough SBET balance
        require(
            SBET.balanceOf(address(this)) >= claimAmnt,
            "Insufficient SBET balance"
        );
        // Reset the rewards for the user
        claimableRewards[msg.sender] = 0;
        // Update the claim rewards for the user
        rewardsClaimed[msg.sender] += claimAmnt;
        // Transfer the reward amount in SBET to the user
        require(SBET.transfer(msg.sender, claimAmnt), "Transfer failed");

        emit RewardClaimed(msg.sender, claimAmnt);
    }

    // function setPriceOfSBET() internal returns (uint256) {
    //     getSBETPrice();

    //     priceOfSBET = SBETPrice;

    //     return(priceOfSBET);
    // }

    // Swap function to allow users to swap BUSD for SBET
    function _purchaseDiscountedSBET(uint256 amountBUSD) external nonReentrant {
        getSBETPrice();
        // setPriceOfSBET();
        // Ensure that the purchaser is not exceeding max buy limit in a single transaction
        require(
            totalBUSDSpent[msg.sender] + amountBUSD <= maxAllowedPurchase,
            "You are exceeding max limit!"
        );
        require(BUSD.allowance(msg.sender, address(this)) >= amountBUSD, "Not enough allowance for tokenA");
        // Ensure that the user has enough BUSD balance
        require(
            BUSD.balanceOf(msg.sender) >= amountBUSD,
            "Insufficient BUSD balance"
        );
        // calculate swapRate
        uint256 outAmntSBET = amountBUSD * 1e18 / SBETPrice;
        // Calculate the discounted amount of SBET
        uint256 discountAmnt = outAmntSBET * swapDiscount / 100;
        uint256 totalOutAmnt = outAmntSBET + discountAmnt;

        totalBUSDSpent[msg.sender] += amountBUSD;
        TVL_BUSD += amountBUSD;

        // Transfer the amount of BUSD from the user to the contract
        require(
            BUSD.transferFrom(msg.sender, address(this), amountBUSD),
            "Transfer failed"
        );
        // log SBET amount allocated to the purchaser
        swapAmounts[msg.sender] += totalOutAmnt;
        vestingDates[msg.sender] = block.timestamp + vestingPeriod;

        emit BondPurchased(msg.sender, totalOutAmnt);
    }

    // Vesting function to allow users to claim their vested SBET
    // function claimVestedSBETs() external nonReentrant {
    //     // Ensure that 24 hours have passed from the time of purchase
    //     require(
    //         block.timestamp >= bondPurchaseTime[msg.sender] + 1 days,
    //         "Can only 24 hours after purchase"
    //     );
    //     // Ensure that the day is within the vesting period
    //     require(vestedSBETs[msg.sender] > 0, "No vested balance available");
    //     // Calculate the vested amount of SBET for the given day
    //     uint256 vestedAmount = vestedSBETs[msg.sender] / vestingPeriod;
    //     // Ensure that the contract has enough SBET balance
    //     require(
    //         SBET.balanceOf(address(this)) >= vestedAmount,
    //         "Insufficient SBET balance"
    //     );

    //     if ((vestedSBETs[msg.sender] - vestedAmount) == 0) {
    //         bondPurchaseTime[msg.sender] = 0;
    //     }

    //     // Deduct the claimed amount from total vested
    //     vestedSBETs[msg.sender] -= vestedAmount;
    //     // Transfer the vested amount of SBET to the user
    //     require(SBET.transfer(msg.sender, vestedAmount), "Transfer failed");

    //     emit ClaimedVestedSBETs(msg.sender, vestedAmount);
    // }

    function claimVested() external nonReentrant {
        uint256 totalVested = 0;
        for (uint256 i = 0; i < swapAmounts[msg.sender]; i++) {
            if (block.timestamp >= vestingDates[msg.sender] + i * vestingPeriod) {
                uint256 vestedAmount = swapAmounts[msg.sender] * (i + 1) / swapAmounts[msg.sender] - claimedAmounts[msg.sender];
                claimedAmounts[msg.sender] += vestedAmount;
                totalVested += vestedAmount;
            }
        }
        require(totalVested > 0, "No vested amount to claim");
        require(BUSD.balanceOf(address(this)) >= totalVested, "Not enough balance in the contract!");
        
        require(BUSD.transfer(msg.sender, totalVested), "TokenB transfer failed");
        
        emit ClaimedVestedSBETs(msg.sender, totalVested);
    }

    // Withdraw function for the contract owner to withdraw accumulated BUSD via bond purchase
    function withdrawBUSD(uint256 amount) external onlyAdmin {
        // Ensure that the contract has enough BUSD balance
        require(
            BUSD.balanceOf(address(this)) >= amount,
            "Insufficient BUSD balance"
        );
        // Transfer the amount of BUSD to the contract owner
        require(BUSD.transfer(msg.sender, amount), "Transfer failed");
    }

    // Withdraw function for the contract owner to withdraw accumulated BUSD via bond purchase
    function withdrawOtherTokens(ERC20 token) external onlyAdmin {
        uint256 withdrawableBal;
        if (token == SBET) {
            withdrawableBal = token.balanceOf(address(this)) - (TVL_SBET + TVL_SBET * rewardRate / 100);
        } else {
            withdrawableBal = token.balanceOf(address(this));
        }
        // Ensure that the contract has enough token balance
        require(withdrawableBal >= 0, "Insufficient BUSD balance");
        // Transfer the tokens to the contract owner
        require(token.transfer(msg.sender, withdrawableBal), "Transfer failed");
    }
}
