//SPDX-License-Identifier:MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface Treasury {
    function isEligibleStakerForVoting(address holder)
        external
        view
        returns (bool, uint256);
}

contract SafuBetsDao is ReentrancyGuard, AccessControl {
    bytes32 public constant MEMBER = keccak256("MEMBER");
    uint256 public immutable votingPeriod = 1 days;
    uint256 public proposalCount;
    uint256 public memberCount;
    uint256 public minHolding;
    uint256 public TVL;
    uint256 public rewardRate = 80;
    // owner of the contract
    address public admin;
    // sbetToken token
    ERC20 public sbetToken;
    // SBET treasury contract
    address public treasury;
    // checks if user is already a staker in SafuBets DAO
    mapping (address => bool) public isEligibleStaker;
    // staked AMount in the DAO of a user
    mapping(address => uint256) public stakedAmnt;

    struct Proposal {
        uint256 id;
        uint256 livePeriod;
        uint256 voteInFavor;
        uint256 voteAgainst;
        uint256 totalSBETDeposited;
        string title;
        string desc;
        string proposalLink;
        bool isCompleted;
        address proposer;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(address => uint256) private members;
    mapping(address => uint256[]) private votes;
    mapping(uint256 => mapping(address => uint256)) public deposits;

    event ProposalCreated(uint256 proposalId, address proposer);
    event Voted(address voter, uint256 _votes, bool Infavour, bool isStaker);
    event DepositRedeemed(
        address voter,
        uint256 proposalId,
        uint256 refundAmnt
    );

    modifier onlyMembers(string memory message) {
        require(hasRole(MEMBER, msg.sender), message);
        _;
    }

    constructor(ERC20 _sbetToken, uint256 _minHolding, address _treasury) {
        admin = msg.sender;
        sbetToken = _sbetToken;
        minHolding = _minHolding * 1e18;
        treasury = _treasury;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Ownable: caller is not the owner");
        _;
    }

    function updateTreasury(address _newTreasury) external onlyAdmin{
        require(_newTreasury != address(0), "can't set to zero address");
        treasury = _newTreasury;
    }

    function createProposal(
        string memory title,
        string memory desc,
        string memory _proposalLink
    ) external onlyMembers("Only Members can create proposals") {
        uint256 proposalId = proposalCount;
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.title = title;
        proposal.desc = desc;
        proposal.proposalLink = _proposalLink;
        proposal.totalSBETDeposited = 0;
        proposal.proposer = payable(msg.sender);
        proposal.livePeriod = block.timestamp + votingPeriod;
        proposal.isCompleted = false;
        proposalCount++;
        emit ProposalCreated(proposalId, msg.sender);
    }

    function getAllProposals() public view returns (Proposal[] memory) {
        Proposal[] memory allProposals = new Proposal[](proposalCount);
        for (uint256 i = 0; i < proposalCount; i++) {
            allProposals[i] = proposals[i];
        }
        return allProposals;
    }

    function getProposal(uint256 proposalId)
        public
        view
        returns (Proposal memory)
    {
        return proposals[proposalId];
    }

    function getVotes() public view returns (uint256[] memory) {
        return votes[msg.sender];
    }

    function isMember() public view returns (bool) {
        return members[msg.sender] > 0;
    }

    function vote(
        uint256 proposalId,
        uint256 _tokenAmnt,
        bool inFavour,
        bool isStaker
    ) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.isCompleted || proposal.livePeriod <= block.timestamp) {
            proposal.isCompleted = true;
            revert("Time period for this proposal is ended");
        }

        for (uint256 i = 0; i < votes[msg.sender].length; i++) {
            if (proposal.id == votes[msg.sender][i]) {
                revert("You can only vote once");
            }
        }

        if (isStaker) {
            (isEligibleStaker[msg.sender], stakedAmnt[msg.sender]) = Treasury(treasury).isEligibleStakerForVoting(
                msg.sender
            );
            uint256 voteAmnt = stakedAmnt[msg.sender] + _tokenAmnt;
            if(isEligibleStaker[msg.sender]) {
              if (inFavour) proposal.voteInFavor += voteAmnt;
              else proposal.voteAgainst += voteAmnt;
            } else {
              revert();
            }
        } else {
            require(
                _tokenAmnt >= minHolding,
                "Only sbetToken holders with balance more than the min required balance tokens can vote!"
            );
            require(
                sbetToken.balanceOf(msg.sender) >= _tokenAmnt,
                "Not enough balance!"
            );

            sbetToken.transferFrom(msg.sender, address(this), _tokenAmnt);

            proposal.totalSBETDeposited += _tokenAmnt;
            TVL += _tokenAmnt;

            if (inFavour) proposal.voteInFavor += _tokenAmnt;
            else proposal.voteAgainst += _tokenAmnt;
        }

        deposits[proposalId][msg.sender] += _tokenAmnt;

        votes[msg.sender].push(proposalId);

        emit Voted(msg.sender, _tokenAmnt, inFavour, isStaker);
    }

    function redeemLockedFunds(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(
            proposal.isCompleted || proposal.livePeriod <= block.timestamp,
            "Voting has not ended yet!"
        );

        uint256 depositAmnt = deposits[proposalId][msg.sender];
        uint256 rewardAmnt = (depositAmnt * rewardRate * proposal.livePeriod) /
            (100 * 365 * 86400);
        uint256 refundAmnt = depositAmnt + rewardAmnt;
        require(
            refundAmnt > 0 && sbetToken.balanceOf(address(this)) >= refundAmnt,
            "Not enough balance!"
        );

        deposits[proposalId][msg.sender] -= depositAmnt;

        sbetToken.transfer(msg.sender, refundAmnt);

        emit DepositRedeemed(msg.sender, proposalId, refundAmnt);
    }

    function addMembers(address _member) external onlyAdmin {
        memberCount++;
        _setupRole(MEMBER, _member);
    }

    // Withdraw function for the contract owner to withdraw accumulated ERC20 tokens
    function withdrawOtherTokens(ERC20 token) external onlyAdmin {
        uint256 withdrawableBal;
        if(token == sbetToken) {
            withdrawableBal = token.balanceOf(address(this)) - (TVL + TVL * rewardRate / 100);
        } else {
            withdrawableBal = token.balanceOf(address(this));
        }
        // Ensure that the contract has enough token balance
        require(withdrawableBal >= 0, "Insufficient BUSD balance");
        // Transfer the tokens to the contract owner
        require(token.transfer(msg.sender, withdrawableBal), "Transfer failed");
    }
}
