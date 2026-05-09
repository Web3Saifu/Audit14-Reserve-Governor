// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28; 

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
//👉 Governance voting interface from OpenZeppelin
//👉 Used for vote delegation and vote snapshots

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//👉 Standard ERC20 token interface
//👉 Used to interact with tokens like USDC, DAI

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
//👉 Safe wrapper around ERC20 operations
//👉 Handles broken ERC20 tokens safely

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
//👉 Used for signature verification/recovery
//👉 Example: Recover signer from signed message

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
//👉 Extra math utilities
//👉 Example: mulDiv() for precision multiplication/division

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
//👉 Safely converts between integer sizes
//👉 Example: uint256 → uint208 without overflow

import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
//👉 Stores historical snapshots over time
//👉 Example:
//👉 Time 100 → 50 votes
//👉 Time 200 → 120 votes

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
//👉 Set structure with unique values
//👉 Example: Prevent duplicate reward tokens

import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
//👉 OpenZeppelin time helper library
//👉 Used for governance timestamp checkpoints

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
//👉 Upgradeable role-based access control
//👉 Example: Admin role management

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
//👉 UUPS proxy upgrade system
//👉 Allows implementation upgrades

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
//👉 Upgradeable ERC20 implementation

import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
//👉 ERC20 permit support
//👉 Allows approvals using signatures instead of transactions

import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
//👉 Governance voting extension for ERC20
//👉 Adds delegation + vote checkpoints

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
//👉 Upgradeable tokenized vault standard
//👉 Users deposit assets and receive vault shares

import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
//👉 Tracks signature nonces
//👉 Prevents replay attacks

import { UD60x18 } from "@prb/math/src/UD60x18.sol";
//👉 PRBMath fixed-point decimal math library
//👉 Used for exponential reward calculations

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
//👉 Interface for deployer contract
//👉 Used during initialization setup

import { IOptimisticVotes } from "@interfaces/IOptimisticVotes.sol";
//👉 Custom optimistic voting interface

import { IRewardTokenRegistry } from "@interfaces/IRewardTokenRegistry.sol";
//👉 Registry interface for approved reward tokens

import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
//👉 Stores approved implementation versions for upgrades

import { UnstakingManager } from "@staking/UnstakingManager.sol";
//👉 Handles delayed unstaking locks
//👉 Example: Wait 7 days before withdrawal claim

import { Versioned } from "@utils/Versioned.sol";
//👉 Provides contract version string utilities

import {
    MAX_REWARD_HALF_LIFE,
    MAX_REWARD_TOKENS,
    MAX_UNSTAKING_DELAY,
    MIN_REWARD_HALF_LIFE
} from "../utils/Constants.sol";
//👉 Global system constants
//👉 Example:
//👉 Max reward tokens limit
//👉 Max unstaking delay
//👉 Reward half-life boundaries

uint256 constant LN_2 = 0.693147180559945309e18;
//👉 Natural log of 2 in 18 decimal precision
//👉 Used for exponential reward decay math

uint256 constant SCALAR = 1e18;
//👉 Fixed-point precision scaler
//👉 1e18 = 100%

bytes32 constant OPTIMISTIC_DELEGATION_TYPEHASH =
    keccak256(
        "OptimisticDelegation(address delegatee,uint256 nonce,uint256 expiry)"
    );
//👉 Unique EIP712 type hash for optimistic delegation signatures
//👉 Prevents signature format mismatch attacks
//👉 Example signed message:
//👉 "Delegate optimistic votes to Bob until tomorrow"

/**
 * @title StakingVault
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 *
 * @notice
 * 👉 ERC4626 staking vault with:
 * 👉 deposits,
 * 👉 rewards,
 * 👉 governance voting,
 * 👉 delayed unstaking,
 * 👉 upgradeability
 *
 * @dev
 * 👉 Users deposit underlying token and receive vault shares
 * 👉 Vault distributes reward tokens over time
 * 👉 Users can delegate governance voting power
 * 👉 Withdrawals may be delayed using UnstakingManager
 *
 * 👉 Supports:
 * 👉 native rewards (same asset token)
 * 👉 external ERC20 reward tokens
 *
 * 👉 Upgrade system requires approved versions from registry
 */

contract StakingVault is
    ERC4626Upgradeable, //👉 ERC4626 vault logic
    ERC20PermitUpgradeable, //👉 Permit signature approvals
    ERC20VotesUpgradeable, //👉 Governance vote tracking
    AccessControlEnumerableUpgradeable, //👉 Admin role system
    Versioned, //👉 Version utilities
    UUPSUpgradeable, //👉 Upgradeability logic
    IOptimisticVotes //👉 Custom optimistic voting interface
{
    using EnumerableSet for EnumerableSet.AddressSet;
    //👉 Adds helper functions to AddressSet
    //👉 Example: add(), remove(), values()

    using Checkpoints for Checkpoints.Trace208;
    //👉 Adds checkpoint helper functions
    //👉 Example: push(), latest(), at()

    ReserveOptimisticGovernanceVersionRegistry
        public
        versionRegistry;
    //👉 Registry storing approved upgrade versions
    //👉 Used to validate safe implementation upgrades
}

    EnumerableSet.AddressSet private rewardTokens;// List of all reward tokens  👉 Example: [USDC, DAI]

    uint256 public rewardRatio; // D18{1}//Controls how fast rewards are released over time    👉 Example: Higher ratio → your 10 USDC reward comes faster

    UnstakingManager public unstakingManager;// Holds your tokens during withdrawal delay 👉 Example: You withdraw 100 → stored here for 7 days

    uint256 public unstakingDelay; // {s} Time you must wait before getting tokens   👉 Example: 7 days lock before claim

    struct RewardInfo { // RewardInfo (per reward token)
        uint256 payoutLastPaid; // {s} Last time rewards were updated     Example: Last update happened 1 hour ago
        uint256 rewardIndex; // D18+decimals{reward/share}   Global reward per share tracker    👉 Example: If it increases → your rewards increase
        uint256 balanceAccounted; // {reward}//   Rewards already distributed to users  👉 Example: 60 out of 100 USDC already allocated
    
        uint256 balanceLastKnown; // {reward}  Last recorded reward balance in vault  👉 Example: Vault had 100 USDC
        uint256 totalClaimed; // {reward}  Total rewards already claimed by users  👉 Example: 40 USDC already claimed
    }

    struct UserRewardInfo {//👤 UserRewardInfo (per user)
        uint256 lastRewardIndex; // D18+decimals{reward/share}  Your last checkpoint  //👉 Example: You joined when index = 5
        uint256 accruedRewards; // {reward}  Rewards you earned but not claimed    👉 Example: You earned 10 USDC
    }

    IRewardTokenRegistry public rewardTokenRegistry;// Checks if a token is allowed as reward  👉 Example: Only approved tokens like USDC can be added

    mapping(address token => RewardInfo rewardInfo) public rewardTrackers;//Stores global reward data for each token (like USDC reward distribution info).
    mapping(address token => bool isDisallowed) public disallowedRewardTokens;//Marks tokens that are permanently banned from being used as rewards.
    mapping(address token => mapping(address user => UserRewardInfo userReward)) public userRewardTrackers;//Stores each user’s earned rewards per token (like your pending USDC rewards).

    mapping(address account => address delegatee) private optimisticDelegatees; //Stores who receives your optimistic (veto) voting powe
    mapping(address delegatee => Checkpoints.Trace208) private optimisticDelegateCheckpoints;//Tracks historical optimistic voting power of each delegate for governance snapshots.

    uint256 private totalDeposited; // {asset}Total tokens deposited by all users in the vault.
    uint256 private nativeBalanceLastKnown; // {asset} Last recorded balance of the main token in the vault.
    uint256 private nativeRewardsLastPaid; // {s}  Last time native token rewards were calculated and updated.

    error Vault__InvalidRewardToken(address rewardToken); //Reverts if an invalid token (like vault token itself) is used as reward.
    error Vault__DisallowedRewardToken(address rewardToken);//Reverts if a banned reward token is used again.
    error Vault__RewardAlreadyRegistered(); //Reverts if trying to add the same reward token twice.
    error Vault__RewardNotRegistered();//Reverts if token is not approved in registry.
    error Vault__MaxRewardTokensReached();//Reverts if reward token limit is exceeded.
    error Vault__InvalidUnstakingDelay();//→ Reverts if unstaking delay is too high.
    error Vault__InvalidRewardsHalfLife(); //Reverts if admin address is zero.
    error Vault__InvalidAdmin(address admin);//Reverts if admin address is zero.
    error Vault__VersionDeprecated(bytes32 versionHash);
    error Vault__NotLatestStakingVault(address stakingVaultImpl);

    event VersionRegistrySet(address versionRegistry);
    event UnstakingDelaySet(uint256 delay);
    event RewardTokenAdded(address rewardToken);
    event RewardTokenRemoved(address rewardToken);
    event RewardTokenRegistrySet(address rewardTokenRegistry);
    event RewardsClaimed(address user, address rewardToken, uint256 amount);
    event RewardRatioSet(uint256 rewardRatio, uint256 halfLife);
    event OptimisticDelegateChanged(
        address indexed delegator, address indexed fromDelegate, address indexed toDelegate
    );
    event OptimisticDelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    constructor() {
        _disableInitializers();
    }

    /// @param _name Name of the vault
    /// @param _symbol Symbol of the vault
    /// @param _underlying Underlying token deposited during staking
    /// @param _initialAdmin Initial admin of the vault
    /// @param _rewardPeriod {s} Half life of the reward handout rate
    /// @param _unstakingDelay {s} Delay after unstaking before user receives their deposit
    function initialize(
        string memory _name,
        string memory _symbol,
        IERC20 _underlying,
        address _initialAdmin,
        uint256 _rewardPeriod,
        uint256 _unstakingDelay
    ) external initializer {
        require(_initialAdmin != address(0), Vault__InvalidAdmin(_initialAdmin));

        __ERC4626_init(_underlying);
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __ERC20Votes_init();
        __AccessControlEnumerable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);

        _setRewardRatio(_rewardPeriod);
        _setUnstakingDelay(_unstakingDelay);

        IReserveOptimisticGovernorDeployer deployer = IReserveOptimisticGovernorDeployer(msg.sender);

        address _rewardTokenRegistry = deployer.rewardTokenRegistry();
        emit RewardTokenRegistrySet(_rewardTokenRegistry);
        rewardTokenRegistry = IRewardTokenRegistry(_rewardTokenRegistry);

        address _versionRegistry = deployer.versionRegistry();
        emit VersionRegistrySet(_versionRegistry);
        versionRegistry = ReserveOptimisticGovernanceVersionRegistry(_versionRegistry);

        unstakingManager = new UnstakingManager(_underlying);

        nativeRewardsLastPaid = block.timestamp;
    }

    /**
     * Deposit & Delegate
     */
    function depositAndDelegate(uint256 assets) external returns (uint256 shares) { //Simple UX → auto delegate to yourself  ,,This function = “Stake + assign two controllers in one step”
        shares = depositAndDelegate(assets, msg.sender, msg.sender);//depositAndDelegate(100, Bob, Charlie)   normal vote → Bob  optimistic vote → Charlie
    }//Alice 100 token deposit করে → vault shares পায় 

    function depositAndDelegate(uint256 assets, address delegatee, address optimisticDelegatee)//Advanced UX → custom delegation
        public
        returns (uint256 shares)
    {
        shares = deposit(assets, msg.sender);

        _delegate(msg.sender, delegatee);
        _delegateOptimistic(msg.sender, optimisticDelegatee);
    }

    function delegateOptimistic(address delegatee) external {
        _delegateOptimistic(msg.sender, delegatee);
    }

    function delegateOptimisticBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)//👉 If time passed → ❌ reject
        external
    {
        if (block.timestamp > expiry) {
            revert IVotes.VotesExpiredSignature(expiry);
        }

        address signer = ECDSA.recover(//ECDSA.recover(hash, v, r, s)
            _hashTypedDataV4(keccak256(abi.encode(OPTIMISTIC_DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s
        );
        _useCheckedNonce(signer, nonce);//👉 Prevents replay (same signature reuse)
        _delegateOptimistic(signer, delegatee);//👉 Bob gets Alice’s 100 optimistic votes
    }

    function optimisticDelegates(address account) external view returns (address) {// optimisticDelegates(Alice)✔️ “Who is Alice’s optimistic delegate?”
        return optimisticDelegatees[account];
    }

    function getOptimisticVotes(address account) external view returns (uint256) {//getOptimisticVotes(Bob) Returns: 100✔️ “How many optimistic votes Bob currently has?”
        return optimisticDelegateCheckpoints[account].latest();
    }

    function numOptimisticCheckpoints(address account) external view returns (uint32) {//numOptimisticCheckpoints(Bob) 👉 Returns: e.g. 3 ✔️ “How many times Bob’s vote balance changed in history?”
        return SafeCast.toUint32(optimisticDelegateCheckpoints[account].length());
    }

    function optimisticCheckpoints(address account, uint32 pos)//👉 Returns the vote snapshot (checkpoint) of a delegate at a specific position.Example: Bob has vote history → this gives Bob’s vote at index pos = 0 (first recorded vote).
        external//Index (pos):   0     1     2,,Votes:       100 → 150 → 120
        view
        returns (Checkpoints.Checkpoint208 memory)//Checkpoint208 = { time: 1000, votes: 150 }
    {
        return optimisticDelegateCheckpoints[account].at(pos);//➡️ “Give me the checkpoint at index pos” ,,It comes from OpenZeppelin’s Checkpoints library.//{ time: T2, votes: 150 }
    }

    function getPastOptimisticVotes(address account, uint256 timepoint) external view returns (uint256) {//👉 Returns how many votes a delegate had at a specific past time (using checkpoint history).
        return optimisticDelegateCheckpoints[account].upperLookupRecent(_validateTimepoint(timepoint));//Time:   10      20      30 ,,Votes: 100 → 150 → 120  //  getPastOptimisticVotes(Bob, 25) ,,Look for last checkpoint ≤ 25,,That is time = 20 ,,Return 
    }

    function totalAssets() public view override returns (uint256) {
        // {qAsset} = {qAsset} + {qAsset}//👉 It means “quantity of asset” (just the amount of tokens).
        return totalDeposited + _currentAccountedNativeRewards();//Users deposited = 100 tokens ,,Rewards accumulated = 10 tokens
    }

    function _currentAccountedNativeRewards() internal view returns (uint256) {//👉 Calculates how many native reward tokens have been generated but not yet added to totalAssets.
        uint256 elapsed = block.timestamp - nativeRewardsLastPaid;//Example: last update = 10 min ago → elapsed = 600s
        uint256 rewardsBalance = nativeBalanceLastKnown - totalDeposited;//Example: contract has 110 tokens, deposits = 100 → rewardsBalance = 10

        return _calculateHandout(rewardsBalance, elapsed);//👉it calculates how much reward should be released after 2 seconds//rewardsBalance = 100 tokens elapsed = 2 seconds  = 19 tokens
    }
    function _deposit( //👉 Internal deposit function used during staking
        address caller, //👉 Who sends the tokens    Example: Alice
        address receiver, //👉 Who receives vault shares    Example: Alice
        uint256 assets, //👉 Amount deposited    Example: 100 USDC
        uint256 shares //👉 Shares minted    Example: 100 vault shares
    )
        internal
        override
        accrueRewards(caller, receiver) //?👉 Update rewards before balances change
    {
        totalDeposited += assets; //👉 Tracks only user deposited principal    Example: 900 → 1000

        nativeBalanceLastKnown += assets; //👉 Tracks total vault balance snapshot    Example: vault balance 900 → 1000

        //👉 Difference:
        //   totalDeposited = only user deposits
        //   nativeBalanceLastKnown = all tokens inside vault

        super._deposit(caller, receiver, assets, shares);
        //👉 ERC4626 deposit flow
        //👉 Transfers tokens into vault and mints shares
        //👉 Example: Alice deposits 100 USDC → receives 100 vault shares
    }//*Done
    /**
     * Withdraw Logic
     */
    function _withdraw( //👉 Handles user withdrawal flow (instant withdraw OR delayed unstaking lock)
        address _caller, //👉 Person calling withdraw   Example: Bob calls withdraw for Alice
        address _receiver, //👉 Final receiver of assets   Example: Alice receives unstaked tokens
        address _owner, //👉 Owner of vault shares   Example: Alice owns 100 shares
        uint256 _assets, //👉 Amount of underlying tokens to withdraw   Example: 100 USDC
        uint256 _shares //👉 Amount of vault shares to burn   Example: burn 100 shares
    )
        internal
        override
        accrueRewards(_owner, _receiver) //👉 First update pending rewards before balances change
    {
        totalDeposited -= _assets; //👉 Reduce total vault deposited amount   Example: 1000 → 900
        nativeBalanceLastKnown -= _assets; //👉 Reduce tracked vault balance   Example: vault balance 1000 → 900

        // nativeBalanceLastKnown update is redundant, final value set at bottom of function

        if (unstakingDelay == 0) { //👉 If no delay → withdraw instantly
            super._withdraw(_caller, _receiver, _owner, _assets, _shares); //👉 Sends tokens immediately to receiver
        } else { //👉 Delayed unstaking mode enabled
            // Since we can't use the builtin `_withdraw`, we need to take care of the entire flow here.

            if (_caller != _owner) { //👉 If someone withdraws on behalf of owner
                _spendAllowance(_owner, _caller, _shares); //👉 Consume allowance approval   Example: Bob uses Alice approval
            }

            // Burn the shares first.
            _burn(_owner, _shares); //👉 Destroy vault shares first   Example: Alice 100 shares → 0

            SafeERC20.forceApprove(IERC20(asset()), address(unstakingManager), _assets);
            //👉 Allow unstakingManager to pull withdrawn assets

            unstakingManager.createLock(_receiver, _assets, block.timestamp + unstakingDelay);
            //👉 Create withdrawal lock   Example: 100 USDC locked for 7 days before claim

            emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
            //👉 Emit withdraw event for tracking/history
        }

        nativeBalanceLastKnown = IERC20(asset()).balanceOf(address(this));
        //👉 Sync final actual vault token balance from ERC20 contract
    }

    /// @param _delay {s} New unstaking delay
    function setUnstakingDelay(uint256 _delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        //👉 Admin function to update withdrawal waiting time

        _setUnstakingDelay(_delay); //👉 Example: admin changes delay from 3 days → 7 days
    }

    /// @param _delay {s} New unstaking delay
    function _setUnstakingDelay(uint256 _delay) internal {
        require(
            _delay <= MAX_UNSTAKING_DELAY,
            Vault__InvalidUnstakingDelay()
        );
        //👉 Prevents extremely large delay values

        unstakingDelay = _delay; //👉 Save new unstaking delay
        emit UnstakingDelaySet(_delay); //👉 Emit configuration update event
    }

    /**
     * Reward Management Logic
     */

    /// @param _rewardToken Reward token to add
    function addRewardToken(address _rewardToken)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            _rewardToken != address(this) &&
            _rewardToken != asset(),
            Vault__InvalidRewardToken(_rewardToken)
        );
        //👉 Prevent vault token or staking asset itself as reward token

        require(
            !disallowedRewardTokens[_rewardToken],
            Vault__DisallowedRewardToken(_rewardToken)
        );
        //👉 Prevent previously banned reward token reuse

        require(
            rewardTokenRegistry.isRegistered(_rewardToken),
            Vault__RewardNotRegistered()
        );
        //👉 Reward token must exist in approved registry

        require(
            rewardTokens.length() < MAX_REWARD_TOKENS,
            Vault__MaxRewardTokensReached()
        );
        //👉 Prevent too many reward tokens   Example: limit = 10

        require(
            rewardTokens.add(_rewardToken),
            Vault__RewardAlreadyRegistered()
        );
        //👉 Prevent duplicate reward token addition

        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];
        //👉 Load reward tracking storage for this token

        rewardInfo.payoutLastPaid = block.timestamp;
        //👉 Start reward accounting from current time

        rewardInfo.balanceLastKnown =
            IERC20(_rewardToken).balanceOf(address(this));
        //👉 Save current vault reward token balance   Example: vault already has 500 DAI

        emit RewardTokenAdded(_rewardToken);
        //👉 Emit reward token added event
    }

    /// @dev To be called in event of bad ERC20; all unaccrued rewards will be lost forever
    /// @param _rewardToken Reward token to remove
    function removeRewardToken(address _rewardToken)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        disallowedRewardTokens[_rewardToken] = true;
        //👉 Permanently blacklist token from future usage

        require(
            rewardTokens.remove(_rewardToken),
            Vault__RewardNotRegistered()
        );
        //👉 Remove token from active reward list

        emit RewardTokenRemoved(_rewardToken);
        //👉 Emit reward token removal event
    }

    /// Allows to claim rewards
    /// Supports claiming accrued rewards for disallowed/removed/unregistered tokens

    /// @param _rewardTokens Array of reward tokens to claim
    /// @return claimableRewards Amount claimed for each rewardToken
    function claimRewards(address[] calldata _rewardTokens)
        external
        accrueRewards(msg.sender, msg.sender) //👉 First update latest pending rewards
        returns (uint256[] memory claimableRewards)
    {
        claimableRewards = new uint256[](_rewardTokens.length);
        //👉 Create output array for returned claimed amounts

        for (uint256 i; i < _rewardTokens.length; i++) {
            //👉 Loop through each requested reward token

            address _rewardToken = _rewardTokens[i];
            //👉 Current reward token   Example: DAI

            RewardInfo storage rewardInfo =
                rewardTrackers[_rewardToken];
            //👉 Global reward tracking storage

            UserRewardInfo storage userRewardTracker =
                userRewardTrackers[_rewardToken][msg.sender];
            //👉 User-specific pending rewards storage

            claimableRewards[i] =
                userRewardTracker.accruedRewards;
            //👉 Load user pending rewards   Example: Alice earned 25 DAI

            if (claimableRewards[i] != 0) {
                //👉 Only transfer if rewards exist

                rewardInfo.totalClaimed += claimableRewards[i];
                //👉 Increase total claimed counter

                userRewardTracker.accruedRewards = 0;
                //👉 Reset user pending rewards after claim

                SafeERC20.safeTransfer(
                    IERC20(_rewardToken),
                    msg.sender,
                    claimableRewards[i]
                );
                //👉 Send reward tokens to user

                emit RewardsClaimed(
                    msg.sender,
                    _rewardToken,
                    claimableRewards[i]
                );
                //👉 Emit reward claim event
            }
        }
    }

/// @return All reward tokens, including ones not registered with the registry anymore
function getAllRewardTokens()
    external
    view
    returns (address[] memory) //👉 Returns dynamic array in memory   Example: [DAI, USDC, WETH]
{
    return rewardTokens.values(); //👉 .values() comes from EnumerableSet library   Converts internal set → normal array
}

/**
 * Reward Accrual Logic
 */

/// @param rewardHalfLife {s}   Example: 7 days
function setRewardRatio(
    uint256 rewardHalfLife //👉 Admin chooses reward release speed   Bigger half-life = slower reward release
)
    external
    onlyRole(DEFAULT_ADMIN_ROLE) //👉 Only admin can change reward release configuration
{
    _setRewardRatio(rewardHalfLife); //👉 Calls internal configuration logic
}

/// @param _rewardHalfLife {s}
function _setRewardRatio(
    uint256 _rewardHalfLife //👉 Time needed for ~50% remaining rewards to unlock   Example: 7 days
)
    internal
    accrueRewards(msg.sender, msg.sender) //👉 First updates pending rewards before changing release speed
{
    require(
        _rewardHalfLife <= MAX_REWARD_HALF_LIFE &&
        _rewardHalfLife >= MIN_REWARD_HALF_LIFE,
        Vault__InvalidRewardsHalfLife()
    );
    //👉 Prevents extremely fast or extremely slow reward release settings

    // D18{1/s} = D18{1} / {s}

    rewardRatio = LN_2 / _rewardHalfLife;
    //👉 Converts half-life → exponential decay speed
    //👉 LN_2 = natural log of 2 used in exponential reward math
    //👉 Smaller half-life = larger ratio = rewards release faster
    //👉 Example:
    //👉 1 day half-life → fast release
    //👉 30 day half-life → slow release

    emit RewardRatioSet(rewardRatio, _rewardHalfLife);
    //👉 Emit event showing new reward release configuration
}
function poke()
    external
    accrueRewards(msg.sender, msg.sender) //👉 Just triggers reward update logic without deposit/withdraw   Example: Bob manually updates rewards
{ }

modifier accrueRewards(//“Already earned but not yet claimed rewards”
    address _caller, //👉 Main user involved in action   Example: Bob
    address _receiver //👉 Receiver affected by action   Example: Alice receives shares
) {
    _accrueRewards(_caller, _receiver);
    //👉 First update all pending rewards before state changes happen
    //👉 Prevents unfair reward accounting after balances change

    _;
    //👉 Continue executing original function logic
}

function _accrueRewards(
    address _caller, //👉 User initiating action   Example: Bob
    address _receiver //👉 User receiving balance update   Example: Alice
)
    internal
{
    address[] memory _rewardTokens = rewardTokens.values();//?
    //👉 Load all reward token addresses into memory   Example: [USDC, DAI]

    uint256 _rewardTokensLength = _rewardTokens.length;
    //👉 Cache array length to save gas during loop

    for (uint256 i; i < _rewardTokensLength; i++) {
        //👉 Loop through every reward token one by one

        address rewardToken = _rewardTokens[i];
        //👉 Current reward token in loop   Example: USDC

        if (!rewardTokenRegistry.isRegistered(rewardToken)) {
            //👉 Skip token if registry no longer approves it

            rewardTrackers[rewardToken].payoutLastPaid = block.timestamp;
            //👉 Update timestamp so old elapsed time does not keep growing forever

            continue;
            //👉 Skip remaining logic for this token
        }

        _accrueRewards(rewardToken);
        //👉 Update global reward accounting for this token
        //👉 Example:
        //👉 Vault had 100 unaccounted USDC rewards
        //👉 Some portion becomes distributable now

        _accrueUser(_receiver, rewardToken);
        //👉 Update receiver’s personal pending rewards before balances change
        //👉 Example:
        //👉 Alice had earned 10 USDC so far
        //👉 Save it before her share balance changes

        // If a deposit/withdraw operation gets called for another user we should
        // accrue for both of them to avoid potential issues
        // This is important for accruing for "from" and "to" in a transfer.

        if (_receiver != _caller) {
            //👉 If two different users are involved, update both users
            //👉 Example:
            //👉 Bob transfers shares to Alice
            //👉 Both balances will change

            _accrueUser(_caller, rewardToken);
            //👉 Update caller’s pending rewards before balance changes
        }
    }

    /**
     * Native asset() rewards are special cased
     */

    totalDeposited += _currentAccountedNativeRewards();
    //👉 Adds newly unlocked native rewards into vault accounting
    //👉 Example:
    //👉 Vault deposited assets = 1000
    //👉 Newly unlocked rewards = 20
    //👉 totalDeposited becomes 1020

    nativeBalanceLastKnown = IERC20(asset()).balanceOf(address(this));
    //👉 Save latest actual vault token balance
    //👉 Example:
    //👉 Contract currently holds 1020 tokens

    nativeRewardsLastPaid = block.timestamp;
    //👉 Save current timestamp as latest reward update time
}

function _accrueRewards(
    address _rewardToken //👉 Reward token being updated   Example: USDC
)
    internal
{
    RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];
    //👉 Load global reward data for this token from storage
    //👉 Example:
    //👉 rewardInfo stores rewardIndex, balanceAccounted, payoutLastPaid etc.

    uint256 balanceLastKnown = rewardInfo.balanceLastKnown;
    //👉 Cache previous known reward balance
    //👉 Example: Previously vault knew about 100 USDC rewards

    rewardInfo.balanceLastKnown =
        IERC20(_rewardToken).balanceOf(address(this)) +
        rewardInfo.totalClaimed;
    //👉 Update latest known total reward balance
    //👉 Adds totalClaimed because claimed rewards already left vault physically
    //👉 but still belong in accounting history
    //👉 Example:
    //👉 Current vault USDC = 70
    //👉 Already claimed = 30
    //👉 Total historical rewards = 100

    uint256 elapsed =
        block.timestamp - rewardInfo.payoutLastPaid;
    //👉 Time passed since last reward update
    //👉 Example:
    //👉 Last update = 1000
    //👉 Current time = 1060
    //👉 elapsed = 60 seconds

    uint256 unaccountedBalance =
        balanceLastKnown - rewardInfo.balanceAccounted;
    //👉 Rewards existing in vault but not yet distributed into rewardIndex
    //👉 Example:
    //👉 Total rewards known = 100
    //👉 Already accounted = 40
    //👉 unaccountedBalance = 60

    uint256 tokensToHandout =
        _calculateHandout(unaccountedBalance, elapsed);
    //👉 Calculates how many rewards unlock during elapsed time
    //👉 Example:
    //👉 60 rewards pending
    //👉 10 rewards unlock after 60 seconds

    if (tokensToHandout != 0) {
        //👉 Only update indexes if some rewards unlocked

        // D18+decimals{reward/share} = D18 * {reward} * decimals / {share}

        uint256 deltaIndex = Math.mulDiv(
            tokensToHandout,
            SCALAR * uint256(10 ** decimals()),
            totalSupply()
        );
        //👉 Calculates extra reward per share
        //👉 Example:
        //👉 10 USDC unlocked
        //👉 Total shares = 100
        //👉 Each share earns 0.1 USDC more

        // D18+decimals{reward/share} += D18+decimals{reward/share}

        rewardInfo.rewardIndex += deltaIndex;
        //👉 Increase global reward-per-share index
        //👉 Future users use this index to calculate earned rewards

        rewardInfo.balanceAccounted += tokensToHandout;
        //👉 Mark unlocked rewards as officially distributed/accounted
        //👉 Example:
        //👉 Previously accounted = 40
        //👉 Newly unlocked = 10
        //👉 New accounted = 50
    }

    rewardInfo.payoutLastPaid = block.timestamp;
    //👉 Save latest reward update timestamp
}

function _accrueUser(
    address _user, //👉 User whose rewards are being updated   Example: Alice
    address _rewardToken //👉 Reward token being calculated   Example: USDC
)
    internal
{
    if (_user == address(0)) {
        return;
        //👉 Skip zero address because it is not a real user
    }

    RewardInfo memory rewardInfo =
        rewardTrackers[_rewardToken];
    //👉 Load global reward data for this token into memory
    //👉 Example:
    //👉 Contains current rewardIndex for USDC rewards

    UserRewardInfo storage userRewardTracker =
        userRewardTrackers[_rewardToken][_user];
    //👉 Load user’s personal reward tracking storage
    //👉 Example:
    //👉 Alice’s lastRewardIndex and accruedRewards

    // D18+decimals{reward/share}

    uint256 deltaIndex =
        rewardInfo.rewardIndex -
        userRewardTracker.lastRewardIndex;
    //👉 Calculates newly added reward-per-share since user’s last update
    //👉 Example:
    //👉 Current rewardIndex = 8
    //👉 Alice lastRewardIndex = 5
    //👉 deltaIndex = 3

    if (deltaIndex != 0) {
        //👉 Continue only if new rewards were added globally

        // Accumulate rewards by multiplying user tokens by index and adding on unclaimed
        // {reward} = {share} * D18+decimals{reward/share} / decimals / D18

        uint256 supplierDelta = Math.mulDiv(
            balanceOf(_user),
            deltaIndex,
            uint256(10 ** decimals()) * SCALAR
        );
        //👉 Calculates newly earned rewards for user
        //👉 Example:
        //👉 Alice has 100 shares
        //👉 Each share earned 0.1 USDC more
        //👉 Alice earns 10 new USDC rewards

        // {reward} += {reward}

        userRewardTracker.accruedRewards += supplierDelta;
        //👉 Add newly earned rewards into pending claimable rewards
        //👉 Example:
        //👉 Previous pending rewards = 5 USDC
        //👉 New rewards = 10 USDC
        //👉 Total pending = 15 USDC

        userRewardTracker.lastRewardIndex =
            rewardInfo.rewardIndex;
        //👉 Save latest global rewardIndex as user checkpoint
        //👉 Prevents counting same rewards again next time
    }
}

/**
 * @dev Uses global `rewardRatio`
 */

function _calculateHandout(
    uint256 balanceAvailable, //👉 Rewards still locked and available for future release   Example: 100 USDC
    uint256 elapsed //👉 Time passed since last reward update in seconds   Example: 2 seconds
)
    internal
    view
    returns (uint256 tokensToHandout) //👉 Amount of rewards unlocked now
{
    // The checks are in order of likelihood to save gas

    if (
        balanceAvailable == 0 ||
        elapsed == 0 ||
        totalSupply() == 0
    ) {
        return 0;
        //👉 No rewards released if:
        //👉 no rewards exist,
        //👉 no time passed,
        //👉 or nobody owns shares
    }

    // handoutPercentage = 1e18 - (1e18 - rewardRatio)^elapsed

    uint256 handoutPercentage =
        1e18 -
        UD60x18
            .wrap(1e18 - rewardRatio)
            .powu(elapsed)
            .unwrap() -
        1;
    //👉 Calculates how much percentage of locked rewards should unlock
    //👉 Uses exponential decay release model
    //👉 Rewards release fast at start, then slower later

    //👉 Example:
    //👉 rewardRatio = 10%
    //👉 Locked rewards = 100 tokens

    //👉 After 1 round:
    //👉 10 released
    //👉 90 remain locked

    //👉 After 2nd round:
    //👉 10% of remaining 90 released
    //👉 9 more released
    //👉 Total released = 19
    //👉 Remaining locked = 81

    //👉 So rewards are NOT released linearly
    //👉 Each round releases percentage of remaining locked rewards

    //👉 1e18 represents 100% in fixed-point precision math
    //👉 Solidity has no decimal support, so:
    //👉 1e18 = 100%
    //👉 0.5e18 = 50%
    //👉 0.1e18 = 10%

    //👉 UD60x18.wrap(...)
    //👉 Converts normal uint into PRBMath fixed-point decimal number
    //👉 Needed because .powu() works with UD60x18 math type

    //👉 .powu(elapsed)
    //👉 Applies repeated exponential decay
    //👉 Example:
    //👉 (90%)^2 = 81%
    //👉 Meaning 81% still remains locked after 2 rounds

    //👉 .unwrap()
    //👉 Converts UD60x18 type back into normal uint256

    //👉 Final "-1"
    //👉 Small rounding adjustment to avoid rounding up
    //👉 Keeps calculations safely rounded down

    // {reward|asset} = {reward|asset} * D18{1} / D18

    tokensToHandout = Math.mulDiv(
        balanceAvailable,
        handoutPercentage,
        1e18
    );
    //👉 Converts percentage into actual token amount
    //👉 Example:
    //👉 balanceAvailable = 100
    //👉 handoutPercentage = 19%
    //👉 tokensToHandout = 19 tokens
}

/**
 * Overrides
 */

function _update(
    address from, //👉 Address losing shares/tokens   Example: Alice
    address to, //👉 Address receiving shares/tokens   Example: Bob
    uint256 value //👉 Amount of shares transferred/minted/burned   Example: 100 shares
)
    internal
    override(ERC20Upgradeable, ERC20VotesUpgradeable)
    accrueRewards(from, to) //👉 First update rewards before balances change
{
    super._update(from, to, value);
    //👉 Executes normal ERC20/ERC4626 token balance update logic
    //👉 Handles transfer, mint, or burn internally
    //👉 Example:
    //👉 Alice sends 100 shares → Bob receives 100 shares

    _moveOptimisticDelegateVotes(
        optimisticDelegatees[from],
        optimisticDelegatees[to],
        value
    );
    //👉 Moves optimistic voting power together with token ownership
    //👉 Example:
    //👉 Alice delegated to Charlie
    //👉 Bob delegated to David
    //👉 100 votes removed from Charlie and added to David
}

function nonces(
    address _owner //👉 User address owning permit signatures   Example: Alice
)
    public
    view
    override(ERC20PermitUpgradeable, NoncesUpgradeable)
    returns (uint256)
{
    return super.nonces(_owner);
    //👉 Returns current nonce for permit signatures
    //👉 Nonce increases after every successful signature use
    //👉 Prevents replay attacks using same signature twice
    //👉 Example:
    //👉 Alice current nonce = 5
    //👉 Next valid signature must use nonce 5
}

function decimals()
    public
    view
    virtual
    override(ERC20Upgradeable, ERC4626Upgradeable)
    returns (uint8)
{
    return super.decimals();
    //👉 Returns token decimal precision
    //👉 Usually returns 18
    //👉 Example:
    //👉 1 token internally stored as 1e18
}

/**
 * ERC5805 Clock
 */

function clock()
    public
    view
    override
    returns (uint48)
{
    return Time.timestamp();
    //👉 Returns current timestamp used for governance checkpoints
    //👉 Uses OpenZeppelin Time library
    //👉 Example:
    //👉 Current unix timestamp = 1710000000
}

function CLOCK_MODE()
    public
    pure
    override
    returns (string memory)
{
    return "mode=timestamp";
    //👉 Tells governance system checkpoints use timestamps instead of block numbers
    //👉 Example:
    //👉 Votes checked using "time" snapshots
}

 /**
 * @dev Upgrade to latest non-deprecated version only
 */

function _authorizeUpgrade(
    address stakingVaultImpl //👉 New implementation contract address for upgrade
)
    internal
    view
    override
    onlyRole(DEFAULT_ADMIN_ROLE) //👉 Only admin can approve upgrades
{
    bytes32 versionHash =
        keccak256(
            abi.encodePacked(
                Versioned(stakingVaultImpl).version()
            )
        );
    //👉 Creates unique hash of new implementation version string
    //👉 Example:
    //👉 "v2.0.0" → hashed into bytes32 identifier

    // RoleRegistry SHOULD maintain fresh latest versions

    (
        bytes32 latestVersionHash,
        ,
        ,
        bool deprecated
    ) = versionRegistry.getLatestVersion();
    //👉 Load latest approved version info from registry

    require(
        !deprecated,
        Vault__VersionDeprecated(versionHash)
    );
    //👉 Reject upgrade if latest version itself is deprecated

    require(
        versionHash == latestVersionHash,
        Vault__NotLatestStakingVault(stakingVaultImpl)
    );
    //👉 Only allows upgrading to officially latest version
    //👉 Prevents upgrading into old/outdated implementation

    (
        address latestStakingVaultImpl,
        ,
        
    ) = versionRegistry.getImplementationsForVersion(versionHash);
    //👉 Load official implementation address for this version

    require(
        latestStakingVaultImpl == stakingVaultImpl,
        Vault__NotLatestStakingVault(stakingVaultImpl)
    );
    //👉 Verifies provided implementation exactly matches registry-approved contract
    //👉 Prevents malicious custom implementations from being upgraded into proxy
}

    function _delegateOptimistic( //👉 Changes optimistic voting delegation
        address account, //👉 User whose votes are being delegated    Example: Alice
        address delegatee //👉 New optimistic delegate    Example: Bob
    )
        internal
    {
        address oldDelegate = optimisticDelegatees[account];
        //👉 Load previous delegate    Example: Charlie was old delegate

        optimisticDelegatees[account] = delegatee;
        //👉 Save new delegate    Example: Alice now delegates optimistic votes to Bob

        emit OptimisticDelegateChanged(account, oldDelegate, delegatee); // @audit  What if Old delegates not exist ?
        //👉 Emit delegation change event
        //👉 Example: Alice changed delegate from Charlie → Bob

        _moveOptimisticDelegateVotes(
            oldDelegate,
            delegatee,
            balanceOf(account)
        );
        //👉 Move voting power from old delegate → new delegate
        //👉 Example:
        //   Alice owns 100 vault shares
        //   Charlie loses 100 optimistic votes
        //   Bob receives 100 optimistic votes
    }

function _moveOptimisticDelegateVotes( //👉 Moves optimistic voting power from one delegate → another delegate
    address from, //👉 Old delegate losing votes   Example: Charlie
    address to, //👉 New delegate receiving votes   Example: Bob
    uint256 amount //👉 Amount of votes being moved   Example: 100 votes
)
    internal
{
    if (from == to || amount == 0) { //👉 Skip if delegate unchanged OR no votes to move   Example: Bob → Bob
        return;
    }

    if (from != address(0)) { //👉 Remove votes from old delegate   address(0) means “no delegate”

        Checkpoints.Trace208 storage fromCheckpoints =
            optimisticDelegateCheckpoints[from];//address  →  Trace208
        //👉 Load Charlie vote-history storage from mapping
        //👉 Trace208 stores historical snapshots like:
        //👉 time 100 => 50 votes
        //👉 time 200 => 300 votes

        uint256 oldValue = fromCheckpoints.latest(); //👉.latest() comes from OpenZeppelin Checkpoints library   Gets newest stored vote amount   Example: 300  //fromCheckpoints.latest() compiler secretly convert করে:Checkpoints.latest(fromCheckpoints)

        uint256 newValue = oldValue - amount; //👉 Remove moved votes   Example: 300 - 100 = 200

        fromCheckpoints.push(
            clock(),
            SafeCast.toUint208(newValue)
        );
        //👉 Save new historical checkpoint into Charlie history
        //👉 Example: current time 300 => 200 votes
        //👉 push(time, votes) adds a new snapshot record

        emit OptimisticDelegateVotesChanged(
            from,
            oldValue,
            newValue
        );
        //👉 Emit event showing Charlie votes changed from 300 → 200
    }

    if (to != address(0)) { //👉 Add votes to new delegate

        Checkpoints.Trace208 storage toCheckpoints =
            optimisticDelegateCheckpoints[to];
        //👉 Load Bob vote-history storage from mapping
        //👉 Example history:
        //👉 time 100 => 20 votes
        //👉 time 200 => 50 votes

        uint256 oldValue = toCheckpoints.latest(); //👉 Get Bob latest stored votes   Example: 50

        uint256 newValue = oldValue + amount; //👉 Add moved votes   Example: 50 + 100 = 150

        toCheckpoints.push(
            clock(),
            SafeCast.toUint208(newValue)
        );
        //👉 Save new checkpoint into Bob history
        //👉 Example: current time 300 => 150 votes

        emit OptimisticDelegateVotesChanged(
            to,
            oldValue,
            newValue
        );
        //👉 Emit event showing Bob votes changed from 50 → 150
    }
}//*Done

