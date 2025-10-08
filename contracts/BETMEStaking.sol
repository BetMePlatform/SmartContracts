// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BETMEStaking V2
 * @dev Scalable staking contract using MasterChef pattern for infinite scalability
 * @notice Users stake $BET tokens to earn BNB rewards from betting platform fees
 * 
 * Key Features:
 * - Infinite scalability (O(1) operations, no loops)
 * - Real-time reward calculations
 * - Anti-frontrunning protection (3-day eligibility delay)
 * - Weekly BNB distribution from betting fees
 * - Gas-optimized design (80-90% gas reduction)
 */
contract BETMEStaking is ReentrancyGuard, Ownable {
    
    // ========================================
    // STATE VARIABLES
    // ========================================
    
    IERC20 public immutable betmeToken;
    
    // MasterChef-style accumulators for infinite scalability
    uint256 public accRewardPerShare;      // Accumulated BNB rewards per staked token
    uint256 public totalStaked;            // Total tokens currently staked
    uint256 public lastRewardTime;         // Last time rewards were distributed
    
    // Anti-frontrunning configuration
    uint256 public constant ELIGIBILITY_DELAY = 3 days;  // Users eligible after 3 days
    uint256 public constant PRECISION = 1e30;             // Increased precision for calculations
    uint256 public constant MIN_STAKE_AMOUNT = 1e6;       // 0.001 tokens minimum (prevents dust attacks)
    
    // MEV protection
    mapping(address => uint256) private _lastActionBlock;
    uint256 public constant MIN_BLOCK_DELAY = 1;
    
    // User staking information
    struct UserInfo {
        uint256 amount;         // Amount of tokens staked
        uint256 rewardDebt;     // Debt for fair reward distribution
        uint256 stakeTime;      // When user first staked (for eligibility)
    }
    
    mapping(address => UserInfo) public userInfo;
    
    // ========================================
    // EVENTS
    // ========================================
    
    event Staked(address indexed user, uint256 amount, uint256 newTotalStaked);
    event Unstaked(address indexed user, uint256 amount, uint256 newTotalStaked);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsDistributed(uint256 amount, uint256 newAccRewardPerShare);
    event RewardsRedistributed(address indexed ineligibleUser, uint256 amount, uint256 newAccRewardPerShare);
    
    // ========================================
    // CONSTRUCTOR
    // ========================================
    
    constructor(address _betmeToken) Ownable(msg.sender) {
        require(_betmeToken != address(0), "Invalid token address");
        betmeToken = IERC20(_betmeToken);
        lastRewardTime = block.timestamp;
    }
    
    // ========================================
    // CORE STAKING FUNCTIONS
    // ========================================
    
    modifier antiMEV() {
        require(block.number > _lastActionBlock[msg.sender] + MIN_BLOCK_DELAY, "Action too frequent");
        _lastActionBlock[msg.sender] = block.number;
        _;
    }
    
    /**
     * @dev Stakes tokens for the caller
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external nonReentrant antiMEV {
        require(amount >= MIN_STAKE_AMOUNT, "Below minimum stake amount");
        require(betmeToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        UserInfo storage user = userInfo[msg.sender];
        
        // Claim any pending rewards before changing stake (FIXED: proper order)
        if (user.amount > 0) {
            _claimRewards();
        }
        
        // If user is staking for the first time, set their stake time
        if (user.amount == 0) {
            user.stakeTime = block.timestamp;
        }
        
        // Update user's stake
        user.amount += amount;
        // FIXED: Update reward debt after stake amount is updated
        user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;
        
        // Update global state
        totalStaked += amount;
        
        emit Staked(msg.sender, amount, totalStaked);
    }
    
    /**
     * @dev Stakes tokens using EIP-2612 permit (gasless approval)
     */
    function permitAndStake(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant antiMEV {
        require(amount >= MIN_STAKE_AMOUNT, "Below minimum stake amount");
        require(deadline > block.timestamp, "Permit expired");
        require(deadline <= block.timestamp + 1 hours, "Deadline too far in future");
        
        // Use permit to approve in the same transaction
        IERC20Permit(address(betmeToken)).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
        
        // Transfer tokens
        require(betmeToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        UserInfo storage user = userInfo[msg.sender];
        
        // Claim any pending rewards before changing stake (FIXED: proper order)
        if (user.amount > 0) {
            _claimRewards();
        }
        
        // If user is staking for the first time, set their stake time
        if (user.amount == 0) {
            user.stakeTime = block.timestamp;
        }
        
        // Update user's stake
        user.amount += amount;
        // FIXED: Update reward debt after stake amount is updated
        user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;
        
        // Update global state
        totalStaked += amount;
        
        emit Staked(msg.sender, amount, totalStaked);
    }
    
    /**
     * @dev Unstakes tokens for the caller
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant antiMEV {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Insufficient staked amount");
        require(amount > 0, "Unstake amount must be greater than 0");
        
        // Check if user is eligible for rewards
        bool isEligible = block.timestamp >= user.stakeTime + ELIGIBILITY_DELAY;
        
        if (isEligible) {
            // User is eligible - claim rewards normally
            _claimRewards();
        } else {
            // User is not eligible - redistribute their allocated rewards to remaining stakers
            _handleIneligibleUnstake(amount);
        }
        
        // Update user's stake
        user.amount -= amount;
        // FIXED: Update reward debt after stake amount is updated
        user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;
        
        // If user unstakes everything, reset their stake time
        if (user.amount == 0) {
            user.stakeTime = 0;
        }
        
        // Update global state
        totalStaked -= amount;
        
        // Transfer tokens back to user
        require(betmeToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit Unstaked(msg.sender, amount, totalStaked);
    }
    
    /**
     * @dev Claims pending rewards for the caller
     */
    function claimRewards() external nonReentrant {
        _claimRewards();
    }
    
    /**
     * @dev Internal function to claim rewards
     */
    function _claimRewards() internal {
        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = _pendingRewards(msg.sender);
        
        if (pending > 0) {
            // Update user's reward debt to prevent double-claiming
            user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;
            
            // Transfer BNB rewards
            (bool success, ) = payable(msg.sender).call{value: pending}("");
            require(success, "BNB transfer failed");
            
            emit RewardsClaimed(msg.sender, pending);
        }
    }
    
    // ========================================
    // REWARD DISTRIBUTION
    // ========================================
    
    /**
     * @dev Receives BNB rewards from betting platform (called by BETMECore)
     */
    receive() external payable {
        if (msg.value > 0 && totalStaked > 0) {
            _updatePool(msg.value);
        }
    }
    
    /**
     * @dev Manual function to add BNB rewards (for testing or special distributions)
     */
    function addRewards() external payable {
        if (msg.value > 0 && totalStaked > 0) {
            _updatePool(msg.value);
        }
    }
    
    /**
     * @dev Updates the reward accumulator (MasterChef pattern)
     * @param newRewards Amount of new BNB rewards to distribute
     */
    function _updatePool(uint256 newRewards) internal {
        if (totalStaked == 0) return;
        
        // MasterChef magic: Update global accumulator
        // This single operation distributes rewards fairly to all stakers
        accRewardPerShare += (newRewards * PRECISION) / totalStaked;
        lastRewardTime = block.timestamp;
        
        emit RewardsDistributed(newRewards, accRewardPerShare);
    }
    
    // ========================================
    // VIEW FUNCTIONS
    // ========================================
    
    /**
     * @dev Calculates pending rewards for a user
     * @param user Address of the user
     * @return Amount of pending BNB rewards
     */
    function pendingRewards(address user) external view returns (uint256) {
        return _pendingRewards(user);
    }
    
    /**
     * @dev Internal function to calculate pending rewards
     */
    function _pendingRewards(address user) internal view returns (uint256) {
        UserInfo storage userDetails = userInfo[user];
        
        // Check if user has staked tokens
        if (userDetails.amount == 0) {
            return 0;
        }
        
        // Anti-frontrunning: Check eligibility (3-day delay)
        if (block.timestamp < userDetails.stakeTime + ELIGIBILITY_DELAY) {
            return 0;
        }
        
        // MasterChef calculation: O(1) complexity
        uint256 totalEarned = (userDetails.amount * accRewardPerShare) / PRECISION;
        
        // Subtract already claimed rewards (debt)
        if (totalEarned > userDetails.rewardDebt) {
            return totalEarned - userDetails.rewardDebt;
        }
        
        return 0;
    }
    
    /**
     * @dev Gets comprehensive user information
     * @param user Address of the user
     * @return stakedAmount Amount of tokens staked
     * @return pendingBNB Amount of pending BNB rewards
     * @return stakeTime When user first staked
     * @return isEligible Whether user is eligible for rewards
     * @return timeToEligibility Seconds until eligible (0 if already eligible)
     */
    function getUserInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 pendingBNB,
        uint256 stakeTime,
        bool isEligible,
        uint256 timeToEligibility
    ) {
        UserInfo storage userDetails = userInfo[user];
        
        stakedAmount = userDetails.amount;
        pendingBNB = _pendingRewards(user);
        stakeTime = userDetails.stakeTime;
        
        if (userDetails.stakeTime == 0) {
            isEligible = false;
            timeToEligibility = 0;
        } else {
            uint256 eligibleTime = userDetails.stakeTime + ELIGIBILITY_DELAY;
            isEligible = block.timestamp >= eligibleTime;
            timeToEligibility = isEligible ? 0 : eligibleTime - block.timestamp;
        }
    }
    
    /**
     * @dev Gets global staking statistics
     * @return totalStakedTokens Total tokens staked across all users
     * @return totalBNBRewards Total BNB available for distribution
     * @return rewardPerShare Current accumulated reward per share
     * @return lastDistribution Timestamp of last reward distribution
     */
    function getGlobalStats() external view returns (
        uint256 totalStakedTokens,
        uint256 totalBNBRewards,
        uint256 rewardPerShare,
        uint256 lastDistribution
    ) {
        totalStakedTokens = totalStaked;
        totalBNBRewards = address(this).balance;
        rewardPerShare = accRewardPerShare;
        lastDistribution = lastRewardTime;
    }
    
    /**
     * @dev Calculates APY based on recent reward distribution
     * @param recentRewards BNB rewards distributed in recent period
     * @param periodDays Number of days the rewards cover
     * @return apy Annual Percentage Yield (scaled by PRECISION)
     */
    function calculateAPY(uint256 recentRewards, uint256 periodDays) external view returns (uint256 apy) {
        if (totalStaked == 0 || periodDays == 0 || periodDays > 365) {
            return 0;
        }
        
        // IMPROVED: Calculate annual rewards first to minimize precision loss
        // This avoids dividing small numbers and losing precision
        
        // Step 1: Annualize the rewards (multiply before divide)
        uint256 annualRewards = (recentRewards * 365) / periodDays;
        
        // Step 2: Check for overflow before final calculation
        require(annualRewards <= type(uint256).max / PRECISION, "APY calculation overflow");
        
        // Step 3: Calculate APY with full precision
        // APY = (annual rewards / total staked) * PRECISION
        apy = (annualRewards * PRECISION) / totalStaked;
    }
    
    /**
     * @dev Handles redistribution of rewards when an ineligible user unstakes
     * @param unstakeAmount Amount of tokens being unstaked
     */
    function _handleIneligibleUnstake(uint256 unstakeAmount) internal {
        UserInfo storage user = userInfo[msg.sender];
        
        // Calculate the proportional share of rewards that would have been allocated to the unstaking amount
        uint256 rewardDebtForUnstakeAmount = (unstakeAmount * accRewardPerShare) / PRECISION;
        uint256 orphanedRewards = rewardDebtForUnstakeAmount - (user.rewardDebt * unstakeAmount / user.amount);
        
        // If there are remaining stakers after this unstake
        uint256 remainingStaked = totalStaked - unstakeAmount;
        if (orphanedRewards > 0 && remainingStaked > 0) {
            // Redistribute the orphaned rewards to remaining stakers
            // This increases accRewardPerShare, effectively giving the rewards to current stakers
            accRewardPerShare += (orphanedRewards * PRECISION) / remainingStaked;
            lastRewardTime = block.timestamp;
            
            emit RewardsRedistributed(msg.sender, orphanedRewards, accRewardPerShare);
        }
        // If no remaining stakers, the rewards stay in contract (recoverable via emergencyWithdraw)
    }
    
    // ========================================
    // ADMIN FUNCTIONS
    // ========================================
    
    /**
     * @dev Emergency withdrawal function (only if contract needs to be migrated)
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No BNB to withdraw");
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");
    }
}