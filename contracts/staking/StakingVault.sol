// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import { UD60x18 } from "@prb/math/src/UD60x18.sol";

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IOptimisticVotes } from "@interfaces/IOptimisticVotes.sol";
import { IRewardTokenRegistry } from "@interfaces/IRewardTokenRegistry.sol";

import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { UnstakingManager } from "@staking/UnstakingManager.sol";
import { Versioned } from "@utils/Versioned.sol";

import {
    MAX_REWARD_HALF_LIFE,
    MAX_REWARD_TOKENS,
    MAX_UNSTAKING_DELAY,
    MIN_REWARD_HALF_LIFE
} from "../utils/Constants.sol";

uint256 constant LN_2 = 0.693147180559945309e18; // D18{1} ln(2e18)

uint256 constant SCALAR = 1e18; // D18
bytes32 constant OPTIMISTIC_DELEGATION_TYPEHASH =//abi.encode(TYPEHASH, delegatee, nonce, expiry) “Delegate optimistic votes to Bob, nonce = 1, expiry = tomorrow”
    keccak256("OptimisticDelegation(address delegatee,uint256 nonce,uint256 expiry)");

/**
 * @title StakingVault
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice StakingVault is a transferrable vault of an underlying token that uses the ERC4626 interface.
 *         It earns the holder a claimable stream of multi rewards and enables them to vote in (external) governance.
 *         Unstaking is gated by a delay, implemented by an UnstakingManager.
 *
 * @dev StakingVault also supports native asset() rewards alongside other reward tokens, but are handled independently.
 *      All reward tokens must be registered in the RewardTokenRegistry. Reward tokens must remain registered in the
 *      RewardTokenRegistry in order to continue accruing rewards. Users can claim any ERC20 where rewards have accrued.
 *
 * @dev New versions MUST always be backwards-compatible for the sake of all ReserveOptimisticGovernors using it.
 */
contract StakingVault is
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    AccessControlEnumerableUpgradeable,
    Versioned,
    UUPSUpgradeable,
    IOptimisticVotes
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using Checkpoints for Checkpoints.Trace208;

    ReserveOptimisticGovernanceVersionRegistry public versionRegistry;

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

        return _calculateHandVout(rewardsBalance, elapsed);//👉it calculates how much reward should be released after 2 seconds//rewardsBalance = 100 tokens elapsed = 2 seconds  = 19 tokens
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        accrueRewards(caller, receiver)
    {
        totalDeposited += assets;
        nativeBalanceLastKnown += assets;

        super._deposit(caller, receiver, assets, shares);
    }
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
        returns (address[] memory)
    {
        return rewardTokens.values();
        //👉 Returns all reward token addresses   Example: [DAI, USDC, WETH]
    }

    /**
     * Reward Accrual Logic
     */
    /// @param rewardHalfLife {s}
    function setRewardRatio(uint256 rewardHalfLife) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRewardRatio(rewardHalfLife);
    }

    /// @param _rewardHalfLife {s}
    function _setRewardRatio(uint256 _rewardHalfLife) internal accrueRewards(msg.sender, msg.sender) {
        require(
            _rewardHalfLife <= MAX_REWARD_HALF_LIFE && _rewardHalfLife >= MIN_REWARD_HALF_LIFE,
            Vault__InvalidRewardsHalfLife()
        );

        // D18{1/s} = D18{1} / {s}
        rewardRatio = LN_2 / _rewardHalfLife;

        emit RewardRatioSet(rewardRatio, _rewardHalfLife);
    }

    function poke() external accrueRewards(msg.sender, msg.sender) { }

    modifier accrueRewards(address _caller, address _receiver) {
        _accrueRewards(_caller, _receiver);
        _;
    }

    function _accrueRewards(address _caller, address _receiver) internal {
        address[] memory _rewardTokens = rewardTokens.values();
        uint256 _rewardTokensLength = _rewardTokens.length;

        for (uint256 i; i < _rewardTokensLength; i++) {
            address rewardToken = _rewardTokens[i];

            if (!rewardTokenRegistry.isRegistered(rewardToken)) {
                rewardTrackers[rewardToken].payoutLastPaid = block.timestamp;
                continue;
            }

            _accrueRewards(rewardToken);
            _accrueUser(_receiver, rewardToken);

            // If a deposit/withdraw operation gets called for another user we should
            // accrue for both of them to avoid potential issues
            // This is important for accruing for "from" and "to" in a transfer.
            if (_receiver != _caller) {
                _accrueUser(_caller, rewardToken);
            }
        }

        /**
         * Native asset() rewards are special cased
         */

        totalDeposited += _currentAccountedNativeRewards();
        nativeBalanceLastKnown = IERC20(asset()).balanceOf(address(this));
        nativeRewardsLastPaid = block.timestamp;
    }

    function _accrueRewards(address _rewardToken) internal {
        RewardInfo storage rewardInfo = rewardTrackers[_rewardToken];

        uint256 balanceLastKnown = rewardInfo.balanceLastKnown;
        rewardInfo.balanceLastKnown = IERC20(_rewardToken).balanceOf(address(this)) + rewardInfo.totalClaimed;

        uint256 elapsed = block.timestamp - rewardInfo.payoutLastPaid;
        uint256 unaccountedBalance = balanceLastKnown - rewardInfo.balanceAccounted;
        uint256 tokensToHandout = _calculateHandout(unaccountedBalance, elapsed);

        if (tokensToHandout != 0) {
            // D18+decimals{reward/share} = D18 * {reward} * decimals / {share}
            uint256 deltaIndex = Math.mulDiv(tokensToHandout, SCALAR * uint256(10 ** decimals()), totalSupply());

            // D18+decimals{reward/share} += D18+decimals{reward/share}
            rewardInfo.rewardIndex += deltaIndex;
            rewardInfo.balanceAccounted += tokensToHandout;
        }

        rewardInfo.payoutLastPaid = block.timestamp;
    }

    function _accrueUser(address _user, address _rewardToken) internal {
        if (_user == address(0)) {
            return;
        }

        RewardInfo memory rewardInfo = rewardTrackers[_rewardToken];
        UserRewardInfo storage userRewardTracker = userRewardTrackers[_rewardToken][_user];

        // D18+decimals{reward/share}
        uint256 deltaIndex = rewardInfo.rewardIndex - userRewardTracker.lastRewardIndex;

        if (deltaIndex != 0) {
            // Accumulate rewards by multiplying user tokens by index and adding on unclaimed
            // {reward} = {share} * D18+decimals{reward/share} / decimals / D18
            uint256 supplierDelta = Math.mulDiv(balanceOf(_user), deltaIndex, uint256(10 ** decimals()) * SCALAR);

            // {reward} += {reward}
            userRewardTracker.accruedRewards += supplierDelta;
            userRewardTracker.lastRewardIndex = rewardInfo.rewardIndex;
        }
    }

    /**
     * @dev Uses global `rewardRatio`
     */
    function _calculateHandout(uint256 balanceAvailable, uint256 elapsed)//👉 Calculates how much reward should be released from the reward pool based on time decay (exponential curve).
        internal
        view
        returns (uint256 tokensToHandout)
    {
        // The checks are in order of likelihood to save gas
        if (balanceAvailable == 0 || elapsed == 0 || totalSupply() == 0) {
            return 0;
        }
//handoutPercentage = 1e18 - (1e18 - rewardRatio)^elapsed

        uint256 handoutPercentage = 1e18 - UD60x18.wrap(1e18 - rewardRatio).powu(elapsed).unwrap() - 1; // 100 tokens locked  ,,Step 1 :10% released:10 released 90 locked
    
        // {reward|asset} = {reward|asset} * D18{1} / D18 
        tokensToHandout = Math.mulDiv(balanceAvailable, handoutPercentage, 1e18);//tokensToHandout = 100 × 19%   = 19 tokens
    }

    /**
     * Overrides
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
        accrueRewards(from, to)
    {
        super._update(from, to, value);
        _moveOptimisticDelegateVotes(optimisticDelegatees[from], optimisticDelegatees[to], value);
    }

    function nonces(address _owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(_owner);
    }

    function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /**
     * ERC5805 Clock
     */
    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @dev Upgrade to latest non-deprecated version only
     */
    function _authorizeUpgrade(address stakingVaultImpl) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 versionHash = keccak256(abi.encodePacked(Versioned(stakingVaultImpl).version()));

        // RoleRegistry SHOULD maintain fresh latest versions

        (bytes32 latestVersionHash,,, bool deprecated) = versionRegistry.getLatestVersion();
        require(!deprecated, Vault__VersionDeprecated(versionHash));
        require(versionHash == latestVersionHash, Vault__NotLatestStakingVault(stakingVaultImpl));

        (address latestStakingVaultImpl,,) = versionRegistry.getImplementationsForVersion(versionHash);
        require(latestStakingVaultImpl == stakingVaultImpl, Vault__NotLatestStakingVault(stakingVaultImpl));
    }

    function _delegateOptimistic(address account, address delegatee) internal {
        address oldDelegate = optimisticDelegatees[account];
        optimisticDelegatees[account] = delegatee;

        emit OptimisticDelegateChanged(account, oldDelegate, delegatee);
        _moveOptimisticDelegateVotes(oldDelegate, delegatee, balanceOf(account));
    }

    function _moveOptimisticDelegateVotes(address from, address to, uint256 amount) internal {
        if (from == to || amount == 0) {
            return;
        }

        if (from != address(0)) {
            Checkpoints.Trace208 storage fromCheckpoints = optimisticDelegateCheckpoints[from];
            uint256 oldValue = fromCheckpoints.latest();
            uint256 newValue = oldValue - amount;
            fromCheckpoints.push(clock(), SafeCast.toUint208(newValue));
            emit OptimisticDelegateVotesChanged(from, oldValue, newValue);
        }

        if (to != address(0)) {
            Checkpoints.Trace208 storage toCheckpoints = optimisticDelegateCheckpoints[to];
            uint256 oldValue = toCheckpoints.latest();
            uint256 newValue = oldValue + amount;
            toCheckpoints.push(clock(), SafeCast.toUint208(newValue));
            emit OptimisticDelegateVotesChanged(to, oldValue, newValue);
        }
    }
}
