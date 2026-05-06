
Stacking :
You deposit tokens → get power
You choose who uses your power
Power moves when tokens move
You must wait to withdraw
You earn rewards while staying
- This contract doesn’t make decisions — it only manages powe




separation:
Alice (slow governance)
Thinks deeply
Decides long-term direction
Votes FOR / AGAINST
protocol upgrade

Bob (fast veto)
Watches for danger
Veto (AGAINST only)Emergency reaction
exploit stop











💰 Deposit & Delegation
depositAndDelegate(assets) → Deposit tokens and delegate both voting powers to yourself.
depositAndDelegate(assets, delegatee, optimisticDelegatee) → Deposit and assign standard + optimistic voting to chosen addresses.
delegateOptimistic(delegatee) → Change who controls your optimistic (veto) voting power.
delegateOptimisticBySig(...) → Delegate optimistic voting using a signed message (no direct transaction needed).
🗳️ Optimistic Voting (Read Functions)
optimisticDelegates(account) → Returns who receives your optimistic votes.
getOptimisticVotes(account) → Returns current optimistic voting power of an account.
numOptimisticCheckpoints(account) → Returns how many vote checkpoints exist for that account.
optimisticCheckpoints(account, pos) → Returns checkpoint data at a specific position.
getPastOptimisticVotes(account, timepoint) → Returns voting power at a past time (used for governance snapshots).
🏦 Vault Accounting
totalAssets() → Returns total assets including deposited tokens + accrued rewards.
_currentAccountedNativeRewards() → Calculates pending rewards for the main asset token.
💸 Deposit / Withdraw (Internal)
_deposit(...) → Handles deposit logic and updates balances + rewards.
_withdraw(...) → Handles withdrawal, either instant or via time-locked unstaking.
⏳ Unstaking Config
setUnstakingDelay(delay) → Admin sets how long withdrawals are locked.
_setUnstakingDelay(delay) → Internal function to validate and apply delay.
🎁 Reward Token Management
addRewardToken(token) → Admin adds a new reward token to distribute.
removeRewardToken(token) → Admin removes a reward token permanently.
claimRewards(tokens[]) → User claims all earned rewards for given tokens.
getAllRewardTokens() → Returns list of all reward tokens ever added.
📈 Reward Configuration
setRewardRatio(halfLife) → Admin updates reward distribution speed.
_setRewardRatio(halfLife) → Internal logic to calculate reward rate.
poke() → Manually trigger reward update without doing anything else.
🔄 Reward Accrual System
_accrueRewards(caller, receiver) → Updates rewards globally and for users.
_accrueRewards(rewardToken) → Updates reward distribution for a specific token.
_accrueUser(user, rewardToken) → Updates a user’s earned rewards.
_calculateHandout(balance, elapsed) → Calculates how much reward to distribute over time.
🔁 Token Transfer Hook
_update(from, to, value) → Updates balances, rewards, and moves voting power on transfer.
🔐 ERC20 / Permit
nonces(owner) → Returns nonce for signature-based actions.
decimals() → Returns token decimals.
⏱️ Governance Clock
clock() → Returns current timestamp (used for vote snapshots).
CLOCK_MODE() → Returns that the system uses timestamps (not blocks).
🔄 Upgradeability
_authorizeUpgrade(newImpl) → Ensures upgrades only go to approved latest versions.
⚡ Optimistic Delegation (Core Logic)
_delegateOptimistic(account, delegatee) → Assigns optimistic voting power to a delegate.
_moveOptimisticDelegateVotes(from, to, amount) → Moves voting power between delegates when balance changes.






































































































 // @audit “If ignorant users delegate to same person → he gets too much power”
  // @audit “What if users don’t delegateOptimistic?”= veto becomes weak fast proposals become dangerous

   // @audit Vault total = 1100 tokens You own 100 shares (~10%)