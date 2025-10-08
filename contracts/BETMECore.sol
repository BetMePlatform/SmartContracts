// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./BETMEStaking.sol";

contract BETMECore is Ownable, ReentrancyGuard {
    // Constants and configurable parameters
    uint256 public feePercentage; // 2.5% = 25/1000 (configurable)
    uint256 public stakingShare; // 60% of fees (configurable)
    uint256 public constant BASIS_POINTS = 1000;
    uint256 public minBetAmount; // Minimum bet amount (configurable)

    // Bet status enum
    enum BetStatus {
        Created,        // Pending acceptance from counterparty
        Canceled,       // Canceled by creator
        Declined,       // Declined by counterparty
        Expired,        // Counterparty did not accept before deadline
        Accepted,       // Accepted by counterparty, awaiting judge settlement
        Completed,      // Judge took action (draw | win)
        JudgeExpired    // Judge did not take action within timeframe
    }

    // Winner enum
    enum Winner {
        None,
        Creator,
        CounterParty,
        Draw
    }

    // Optimized Bet struct
    struct Bet {
        uint256 amount;
        address creator;
        address counterParty;
        address judge;
        uint256 betAcceptingDeadline;
        uint256 judgeDecisionDeadline;
        uint256 judgeReward;
        string details;
        BetStatus status;
        Winner winner;
        bool creatorClaimed;
        bool counterPartyClaimed;
        bool judgeClaimed;
    }

    // State variables
    BETMEStaking public stakingContract;
    mapping(uint256 => Bet) public bets;
    uint256 public nextBetId;
    uint256 public totalEscrowed;
    uint256 public totalJudgeRewards;

    // Events
    event BetCreated(uint256 indexed betId, address creator, address counterParty);
    event BetAccepted(uint256 indexed betId, address counterParty);
    event BetCancelled(uint256 indexed betId);
    event BetDeclined(uint256 indexed betId);
    event BetExpired(uint256 indexed betId);
    event BetJudgeExpired(uint256 indexed betId);
    event BetJudged(uint256 indexed betId, Winner winner);
    event BetClaimed(uint256 indexed betId, address claimer, uint256 amount);
    event JudgeRewardClaimed(uint256 indexed betId, address judge, uint256 amount);
    event JudgeRewardRefunded(uint256 indexed betId, address recipient, uint256 amount);
    event MinBetAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event FeePercentageUpdated(uint256 oldFee, uint256 newFee);

    constructor(address payable _stakingContract) Ownable(msg.sender) {
        stakingContract = BETMEStaking(_stakingContract);
        
        // Set default values
        feePercentage = 25; // 2.5%
        stakingShare = 60; // 60% of fees
        minBetAmount = 0.01 ether; // Minimum bet amount
    }

    // Update fee percentage (only owner)
    function updateFeePercentage(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= 150, "Fee cannot exceed 15%"); // Safety check: max 15%
        emit FeePercentageUpdated(feePercentage, _newFeePercentage);
        feePercentage = _newFeePercentage;
    }

    // Update minimum bet amount (only owner)
    function updateMinBetAmount(uint256 _newMinAmount) external onlyOwner {
        require(_newMinAmount > 0, "Min amount must be greater than 0");
        emit MinBetAmountUpdated(minBetAmount, _newMinAmount);
        minBetAmount = _newMinAmount;
    }

    // ========================================
    // PRECISE FEE CALCULATION HELPERS
    // ========================================

    function calculatePlatformFee(uint256 betAmount) public view returns (uint256) {
        return (betAmount * feePercentage + BASIS_POINTS - 1) / BASIS_POINTS;
    }

    function calculateFeeDistribution(uint256 totalFee) public view returns (uint256 stakingFee, uint256 ownerFee) {
        stakingFee = (totalFee * stakingShare) / 100;
        ownerFee = totalFee - stakingFee;
    }

    function calculateCreatorCost(uint256 betAmount, uint256 judgeReward) public view returns (
        uint256 totalCost,
        uint256 platformFee,
        uint256 creatorJudgeShare
    ) {
        platformFee = calculatePlatformFee(betAmount);
        creatorJudgeShare = judgeReward / 2;
        totalCost = betAmount + platformFee + creatorJudgeShare;
    }

    function calculateCounterpartyCost(uint256 betAmount, uint256 judgeReward) public view returns (
        uint256 totalCost,
        uint256 platformFee,
        uint256 counterpartyJudgeShare
    ) {
        platformFee = calculatePlatformFee(betAmount);
        counterpartyJudgeShare = judgeReward - (judgeReward / 2);
        totalCost = betAmount + platformFee + counterpartyJudgeShare;
    }

    // ========================================
    // CORE BETTING FUNCTIONS
    // ========================================

    function createBet(
        uint256 _betAmount,
        address _counterParty,
        address _judge,
        uint256 _betAcceptingDeadline,
        uint256 _judgeDecisionDeadline,
        uint256 _judgeReward,
        string calldata _details
    ) external payable nonReentrant {
        require(_counterParty != address(0) && _counterParty != msg.sender, "Invalid counterparty");
        require(_judge != address(0) && _judge != msg.sender && _judge != _counterParty, "Invalid judge");
        require(_betAcceptingDeadline > block.timestamp, "Invalid end time");
        require(_judgeDecisionDeadline > _betAcceptingDeadline, "Decision deadline must be after end time");
        require(bytes(_details).length <= 256, "Max 256 bytes");
        require(_betAmount >= minBetAmount, "Amount below minimum");

        // Calculate required payment based on desired bet amount
        (uint256 totalRequired, uint256 platformFee, uint256 creatorJudgeShare) = 
            calculateCreatorCost(_betAmount, _judgeReward);
        require(msg.value >= totalRequired, "Insufficient payment");

        // Refund excess (if any)
        if (msg.value > totalRequired) {
            payable(msg.sender).transfer(msg.value - totalRequired);
        }

        // Distribute platform fees
        _distributeFees(platformFee);

        // Create bet with exact specified amount
        uint256 betId = nextBetId++;
        bets[betId] = Bet({
            amount: _betAmount,
            creator: msg.sender,
            counterParty: _counterParty,
            judge: _judge,
            betAcceptingDeadline: _betAcceptingDeadline,
            judgeDecisionDeadline: _judgeDecisionDeadline,
            judgeReward: _judgeReward,
            details: _details,
            status: BetStatus.Created,
            winner: Winner.None,
            creatorClaimed: false,
            counterPartyClaimed: false,
            judgeClaimed: false
        });

        // Update escrowed amounts
        totalEscrowed += _betAmount;
        totalJudgeRewards += creatorJudgeShare;

        emit BetCreated(betId, msg.sender, _counterParty);
    }

    function acceptBet(uint256 _betId) external payable nonReentrant {
        Bet storage bet = bets[_betId];
        require(bet.status == BetStatus.Created, "Invalid status");
        require(msg.sender == bet.counterParty, "Not counterparty");
        require(block.timestamp <= bet.betAcceptingDeadline, "Acceptance period expired");

        // Calculate required amounts
        (uint256 requiredTotal, uint256 platformFee, uint256 counterpartyJudgeShare) = 
            calculateCounterpartyCost(bet.amount, bet.judgeReward);
        require(msg.value >= requiredTotal, "Insufficient payment");

        // Refund excess
        if (msg.value > requiredTotal) {
            payable(msg.sender).transfer(msg.value - requiredTotal);
        }

        // Distribute platform fees
        _distributeFees(platformFee);

        bet.status = BetStatus.Accepted;
        
        // Update escrowed amounts
        totalEscrowed += bet.amount;
        totalJudgeRewards += counterpartyJudgeShare;

        emit BetAccepted(_betId, msg.sender);
    }

    function judgeBet(uint256 _betId, Winner _winner, uint256 deadline) external nonReentrant {
        require(block.timestamp <= deadline, "Deadline expired");
        
        Bet storage bet = bets[_betId];
        require(msg.sender == bet.judge, "Not judge");
        require(bet.status == BetStatus.Accepted, "Invalid status");
        require(block.timestamp <= bet.judgeDecisionDeadline, "Decision window closed");
        require(_winner == Winner.Creator || _winner == Winner.CounterParty || _winner == Winner.Draw, "Invalid winner");

        bet.winner = _winner;
        bet.status = BetStatus.Completed;
        emit BetJudged(_betId, _winner);
    }

    // ========================================
    // CLAIM FUNCTIONS
    // ========================================

    function claim(uint256 _betId) external nonReentrant {
        Bet storage bet = bets[_betId];
        require(
            msg.sender == bet.creator || 
            msg.sender == bet.counterParty || 
            msg.sender == bet.judge, 
            "Not participant"
        );

        // Handle expired states
        _handleExpiredStates(bet, _betId);

        // Calculate payout based on bet status and claimant
        (uint256 payout, uint256 judgeRewardRefund) = _calculateClaimAmount(bet, msg.sender);

        // Process the claim and transfer funds
        _processClaim(bet, msg.sender, payout, judgeRewardRefund, _betId);
    }

    function _handleExpiredStates(Bet storage bet, uint256 betId) internal {
        // Handle expired acceptance deadline
        if (bet.status == BetStatus.Created && block.timestamp > bet.betAcceptingDeadline) {
            bet.status = BetStatus.Expired;
            emit BetExpired(betId);
        }

        // Handle expired judge decisions
        if (bet.status == BetStatus.Accepted && block.timestamp > bet.judgeDecisionDeadline) {
            bet.status = BetStatus.JudgeExpired;
            emit BetJudgeExpired(betId);
        }
    }

    function _calculateClaimAmount(
        Bet storage bet, 
        address claimant
    ) internal view returns (uint256 payout, uint256 judgeRewardRefund) {
        if (bet.status == BetStatus.Created) {
            revert("Cannot claim from created bet");
        }
        else if (bet.status == BetStatus.Canceled || 
                 bet.status == BetStatus.Declined || 
                 bet.status == BetStatus.Expired) {
            // Only creator can claim in these states
            require(claimant == bet.creator, "Only creator can claim");
            payout = bet.amount;
            judgeRewardRefund = bet.judgeReward / 2; // Creator gets back exactly what they paid
        }
        else if (bet.status == BetStatus.Accepted) {
            revert("Cannot claim from accepted bet");
        }
        else if (bet.status == BetStatus.JudgeExpired) {
            // Both parties can claim their bet amount + their judge reward contribution
            require(
                claimant == bet.creator || claimant == bet.counterParty,
                "Only participants can claim from judge expired bet"
            );
            payout = bet.amount;
            if (claimant == bet.creator) {
                judgeRewardRefund = bet.judgeReward / 2; // Creator gets back what they paid
            } else {
                judgeRewardRefund = bet.judgeReward - (bet.judgeReward / 2); // Counterparty gets back what they paid
            }
        }
        else if (bet.status == BetStatus.Completed) {
            if (claimant == bet.judge) {
                // Judge claims their reward
                require(!bet.judgeClaimed, "Judge already claimed");
                require(bet.judgeReward > 0, "No judge reward");
                payout = bet.judgeReward;
            } else {
                // Participants claim based on winner
                payout = _calculateParticipantPayout(bet, claimant);
            }
        }
        else {
            revert("Invalid bet status");
        }
    }

    function _calculateParticipantPayout(
        Bet storage bet,
        address claimant
    ) internal view returns (uint256) {
        if (bet.winner == Winner.Draw) {
            // Both parties can claim their bet amount
            return bet.amount;
        } else if ((bet.winner == Winner.Creator && claimant == bet.creator) ||
                  (bet.winner == Winner.CounterParty && claimant == bet.counterParty)) {
            // Winner gets double the bet amount
            return bet.amount * 2;
        }
        // Loser gets nothing
        return 0;
    }

    function _processClaim(
        Bet storage bet,
        address claimant,
        uint256 payout,
        uint256 judgeRewardRefund,
        uint256 betId
    ) internal {
        if (claimant == bet.judge) {
            // Process judge claim
            require(address(this).balance >= payout, "Insufficient contract balance");
            bet.judgeClaimed = true;
            totalJudgeRewards -= payout;
        } else {
            // Process participant claim
            _processParticipantClaim(bet, claimant, payout, judgeRewardRefund);
        }

        // Transfer funds
        (bool success, ) = claimant.call{value: payout}("");
        require(success, "Transfer failed");

        // Emit events
        _emitClaimEvents(bet, betId, claimant, payout, judgeRewardRefund);
    }

    function _processParticipantClaim(
        Bet storage bet,
        address claimant,
        uint256 payout,
        uint256 judgeRewardRefund
    ) internal {
        if (claimant == bet.creator) {
            require(!bet.creatorClaimed, "Creator already claimed");
            bet.creatorClaimed = true;
        } else {
            require(!bet.counterPartyClaimed, "Counterparty already claimed");
            bet.counterPartyClaimed = true;
        }

        // Update escrowed amounts
        if (payout > 0) {
            totalEscrowed -= payout;
        }
        if (judgeRewardRefund > 0) {
            totalJudgeRewards -= judgeRewardRefund;
            payout += judgeRewardRefund;
        }
    }

    function _emitClaimEvents(
        Bet storage bet,
        uint256 betId,
        address claimant,
        uint256 payout,
        uint256 judgeRewardRefund
    ) internal {
        if (claimant == bet.judge) {
            emit JudgeRewardClaimed(betId, claimant, payout);
        } else {
            emit BetClaimed(betId, claimant, payout - judgeRewardRefund);
            if (judgeRewardRefund > 0) {
                emit JudgeRewardRefunded(betId, claimant, judgeRewardRefund);
            }
        }
    }

    function cancelBet(uint256 _betId) external nonReentrant {
        Bet storage bet = bets[_betId];
        require(msg.sender == bet.creator, "Not creator");
        require(bet.status == BetStatus.Created, "Cannot cancel");

        bet.status = BetStatus.Canceled;
        emit BetCancelled(_betId);
    }

    function declineBet(uint256 _betId) external nonReentrant {
        Bet storage bet = bets[_betId];
        require(msg.sender == bet.counterParty, "Not counterparty");
        require(bet.status == BetStatus.Created, "Cannot decline");

        bet.status = BetStatus.Declined;
        emit BetDeclined(_betId);
    }

    // ========================================
    // INTERNAL FUNCTIONS
    // ========================================

    function _distributeFees(uint256 totalFee) internal {
        (uint256 stakingFee, uint256 ownerFee) = calculateFeeDistribution(totalFee);

        (bool sSuccess, ) = address(stakingContract).call{value: stakingFee}("");
        (bool oSuccess, ) = owner().call{value: ownerFee}("");
        require(sSuccess && oSuccess, "Fee distribution failed");
    }

    // ========================================
    // VIEW FUNCTIONS
    // ========================================

    // Added for frontend
    function getRequiredAcceptAmount(uint256 _betId) external view returns (uint256) {
        require(_betId < nextBetId, "Bet does not exist");
        Bet storage bet = bets[_betId];
        (uint256 totalCost,,) = calculateCounterpartyCost(bet.amount, bet.judgeReward);
        return totalCost;
    }

    function getBetBasicInfo(uint256 _betId) external view returns (
        uint256 amount,
        address creator,
        address counterParty,
        uint256 betAcceptingDeadline,
        BetStatus status,
        bool expired
    ) {
        require(_betId < nextBetId, "Bet does not exist");
        Bet storage bet = bets[_betId];
        
        return (
            bet.amount,
            bet.creator,
            bet.counterParty,
            bet.betAcceptingDeadline,
            bet.status,
            block.timestamp > bet.betAcceptingDeadline
        );
    }

    // Get user's active bets (created or participating)
    function getUserActiveBets(address user) external view returns (uint256[] memory betIds) {
        uint256 count = 0;
        
        // First pass: count active bets
        for (uint256 i = 0; i < nextBetId; i++) {
            Bet storage bet = bets[i];
            if ((bet.creator == user || bet.counterParty == user) && 
                (bet.status == BetStatus.Created || bet.status == BetStatus.Accepted)) {
                count++;
            }
        }
        
        betIds = new uint256[](count);
        uint256 index = 0;
        
        // Second pass: populate array
        for (uint256 i = 0; i < nextBetId; i++) {
            Bet storage bet = bets[i];
            if ((bet.creator == user || bet.counterParty == user) && 
                (bet.status == BetStatus.Created || bet.status == BetStatus.Accepted)) {
                betIds[index] = i;
                index++;
            }
        }
    }

    // Get judge's claimable rewards
    function getJudgeClaimableRewards(address judge) external view returns (
        uint256[] memory betIds,
        uint256[] memory rewardAmounts
    ) {
        uint256 count = 0;
        
        // First pass: count claimable rewards
        for (uint256 i = 0; i < nextBetId; i++) {
            Bet storage bet = bets[i];
            if (bet.judge == judge && 
                bet.status == BetStatus.Completed && 
                !bet.judgeClaimed &&
                bet.judgeReward > 0) {
                count++;
            }
        }
        
        betIds = new uint256[](count);
        rewardAmounts = new uint256[](count);
        uint256 index = 0;
        
        // Second pass: populate arrays
        for (uint256 i = 0; i < nextBetId; i++) {
            Bet storage bet = bets[i];
            if (bet.judge == judge && 
                bet.status == BetStatus.Completed && 
                !bet.judgeClaimed &&
                bet.judgeReward > 0) {
                betIds[index] = i;
                rewardAmounts[index] = bet.judgeReward;
                index++;
            }
        }
    }

    // Get judge's pending decisions
    function getJudgePendingBets(address judge) external view returns (uint256[] memory betIds) {
        uint256 count = 0;
        
        // First pass: count pending judge bets
        for (uint256 i = 0; i < nextBetId; i++) {
            Bet storage bet = bets[i];
            if (bet.judge == judge && 
                bet.status == BetStatus.Accepted && 
                block.timestamp <= bet.judgeDecisionDeadline) {
                count++;
            }
        }
        
        betIds = new uint256[](count);
        uint256 index = 0;
        
        // Second pass: populate array
        for (uint256 i = 0; i < nextBetId; i++) {
            Bet storage bet = bets[i];
            if (bet.judge == judge && 
                bet.status == BetStatus.Accepted && 
                block.timestamp <= bet.judgeDecisionDeadline) {
                betIds[index] = i;
                index++;
            }
        }
    }

    // Get full bet details (public access)
    function getFullBetDetails(uint256 _betId) 
        external 
        view 
        returns (
            uint256 amount,
            address creator,
            address counterParty,
            address judge,
            uint256 betAcceptingDeadline,
            uint256 judgeDecisionDeadline,
            uint256 judgeReward,
            string memory details,
            BetStatus status,
            Winner winner,
            bool creatorClaimed,
            bool counterPartyClaimed,
            bool judgeClaimed
        ) 
    {
        require(_betId < nextBetId, "Bet does not exist");
        Bet storage bet = bets[_betId];
        
        return (
            bet.amount,
            bet.creator,
            bet.counterParty,
            bet.judge,
            bet.betAcceptingDeadline,
            bet.judgeDecisionDeadline,
            bet.judgeReward,
            bet.details,
            bet.status,
            bet.winner,
            bet.creatorClaimed,
            bet.counterPartyClaimed,
            bet.judgeClaimed
        );
    }
}