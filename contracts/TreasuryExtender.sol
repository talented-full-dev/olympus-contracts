pragma solidity ^0.8.10;

// interfaces
import "./interfaces/IERC20.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IAllocator.sol";
import "./interfaces/ITreasuryExtender.sol";

// types
import "./types/OlympusAccessControlledV2.sol";

// libraries
import "./libraries/SafeERC20.sol";

error TreasuryExtender_AllocatorOffline();
error TreasuryExtender_AllocatorActivated();
error TreasuryExtender_AllocatorRegistered(uint256 id);
error TreasuryExtender_OnlyAllocator(uint256 id, address sender);
error TreasuryExtender_MaxAllocation(uint256 allocated, uint256 limit);

/**
 * @title Treasury Extender
 * @notice
 *  This contract serves as an accounting and management contract which
 *  will interact with the Olympus Treasury to fund Allocators.
 *
 *  Accounting:
 *  Each time an allocator is funded with `requestFundsFromTreasury` the
 *  `totalValueAllocated` is incremented, which can be done because it is
 *  always denominated in the same unit.
 *
 *  For each Allocator we record 5 distinct values grouped into 3 fields,
 *  together grouped as AllocatorData:
 *
 *  AllocatorLimits { allocated, loss } - This is the maximum amount
 *  an Allocator should have allocated at any point, and also the maximum
 *  loss an allocator should experience without automatically shutting down.
 *
 *  AllocatorPerformance { gain, loss } - This is the current gain (total - allocated)
 *  and the loss the Allocator sustained over its time of operation.
 *
 *  AllocatorHoldings { allocated } - This is the amount of tokens an Allocator
 *  has currently been allocated by the Extender.
 *
 *  Important: The above is only tracked in the 1 underlying token,
 *  (see BaseAllocator.sol) while rewards are retrievable by the standard
 *  ERC20 functions. The point is that we only exactly track that which
 *  exits the Treasury.
 */
contract TreasuryExtender is OlympusAccessControlledV2, ITreasuryExtender {
    using SafeERC20 for IERC20;

    // The Olympus Treasury.
    ITreasury immutable treasury;

    // Enumerable Allocators according to their Id.
    IAllocator[] public allocators;

    // Get an AllocatorData for an Allocator
    mapping(IAllocator => AllocatorData) public allocatorData;

    // The total value allocated according to `treasury.tokenValue`
    // (see Treasury.sol)
    uint256 private totalValueAllocated;

    constructor(address treasuryAddress, address authorityAddress)
        OlympusAccessControlledV2(IOlympusAuthority(authorityAddress))
    {
        treasury = ITreasury(treasuryAddress);
        allocators.push(IAllocator(address(0)));
    }

    //// "MODIFIERS"

    function _allocatorActivated(AllocatorStatus status) internal pure {
        if (AllocatorStatus.ACTIVATED != status) revert TreasuryExtender_AllocatorOffline();
    }

    function _allocatorOffline(AllocatorStatus status) internal pure {
        if (AllocatorStatus.OFFLINE != status) revert TreasuryExtender_AllocatorActivated();
    }

    function _onlyAllocator(uint256 id, address sender) internal view {
        if (IAllocator(sender) != allocators[id]) revert TreasuryExtender_OnlyAllocator(id, sender);
    }

    //// FUNCTIONS

    /**
     * @notice
     *  Registers an Allocator. Sets the Allocators id and prepares storage slots for writing.
     *  Does not activate the Allocator.
     * @dev
     *  Calls `setId` from `IAllocator` with the index of the Allocator in `allocators`
     * @param newAllocatorAddress the Allocator to be registered
     */
    function registerAllocator(address newAllocatorAddress) external override {
        // reads
        IAllocator allocator = IAllocator(newAllocatorAddress);
        uint256 id = allocator.id();

        // checks
        _onlyGuardian();
        if (id != 0) revert TreasuryExtender_AllocatorRegistered(id);

        // effects
        allocators.push(allocator);

        // interactions
        allocator.setId(allocators.length - 1);

        // events
        emit NewAllocatorRegistered(newAllocatorAddress, allocator.getToken(), allocator.id());
    }

    /**
     * @notice
     *  Sets an Allocators limits.
     *  Also see `_seeAllocatorLimits`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called while the Allocator is offline.
     *  Can only be called by the Guardian.
     * @param allocatorAddress the address of the Allocator to set AllocatorLimits for
     * @param limits the AllocatorLimits to set
     */
    function setAllocatorLimits(address allocatorAddress, AllocatorLimits memory limits) external override {
        // reads
        IAllocator allocator = IAllocator(allocatorAddress);

        // interactions
        _setAllocatorLimits(allocator, limits);
    }

    /**
     * @notice
     *  Sets an Allocators limits.
     *  Also see `_seeAllocatorLimits`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called while the Allocator is offline.
     *  Can only be called by the Guardian.
     * @param id the id of the Allocator to set AllocatorLimits for
     * @param limits the AllocatorLimits to set
     */
    function setAllocatorLimits(uint256 id, AllocatorLimits memory limits) external override {
        // reads
        IAllocator allocator = allocators[id];

        // interactions
        _setAllocatorLimits(allocator, limits);
    }

    /**
     * @notice
     *  Reports an Allocators status to the Extender.
     *  Updates Extender state accordingly.
     * @dev
     *  Can only be called while the Allocator is activated or migrating.
     *  The idea is that first the Allocator updates its own state, then
     *  it reports this state to the Extender, which then updates its own state.
     *
     *  There is 3 different combinations the Allocator may report:
     *
     *  (gain + loss) == 0, the Allocator will NEVER report this state
     *  gain > loss, gain is reported and gain + totalValueAllocated is incremented but allocated not.
     *  loss > gain, loss is reported, allocated, totalValueAllocated is decremented and loss incremented
     *  loss == gain, (loss + gain) > 0, migration case, set gain & loss to 1 and zero out allocated
     *
     *  note when migrating the next Allocator should report his state to the Extender, in say an `_activate` call.
     *
     * @param id the id of the Allocator reporting its state
     * @param gain the gain the Allocator has made in allocated token
     * @param loss the loss the Allocator has sustained in allocated token
     */
    function report(
        uint256 id,
        uint128 gain,
        uint128 loss
    ) external override {
        // reads
        IAllocator allocator = allocators[id];
        AllocatorPerformance memory perf = allocatorData[allocator].performance;
        AllocatorStatus status = allocator.status();

        // checks
        // above could send in any id with gain == 0 and loss == 0, but he could only fake
        // address(0) in that case, otherwise, all allocators need to be registered by guardian
        _onlyAllocator(id, msg.sender);
        if (status == AllocatorStatus.OFFLINE) revert TreasuryExtender_AllocatorOffline();

        // effect
        perf.gain += gain;
        perf.loss += loss;

        allocatorData[allocator].performance = perf;

        if (gain > 0) {
            if (loss > 0) {
                loss = uint128(allocatorData[allocator].holdings.allocated);
            } else {
                totalValueAllocated += treasury.tokenValue(allocator.getToken(), gain);
            }
        }

        if (loss != 0) {
            allocatorData[allocator].holdings.allocated -= loss;
            totalValueAllocated -= treasury.tokenValue(allocator.getToken(), loss);
        }

        if (gain > loss) emit AllocatorReportedGain(id, gain);
        else {
            if (gain != loss) emit AllocatorReportedLoss(id, loss);
            else emit AllocatorReportedMigration(id);
        }
    }

    /**
     * @notice
     *  Requests funds from the Olympus Treasury to fund an Allocator.
     *  Also see `_requestFundsFromTreasury`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called while the Allocator is activated.
     *  Can only be called by the Guardian.
     * @param id the id of the Allocator to request funds for
     * @param amount the amount of token to withdraw, the token is known in the Allocator
     */
    function requestFundsFromTreasury(uint256 id, uint256 amount) external override {
        _requestFundsFromTreasury(allocators[id], amount);
    }

    /**
     * @notice
     *  Requests funds from the Olympus Treasury to fund an Allocator.
     *  Also see `_returnFundsToTreasury`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called while the Allocator is activated.
     *  Can only be called by the Guardian.
     * @param allocatorAddress the address of the Allocator to returns funds from
     * @param amount the amount of token to withdraw, the token is known in the Allocator
     */
    function requestFundsFromTreasury(address allocatorAddress, uint256 amount) external override {
        _requestFundsFromTreasury(IAllocator(allocatorAddress), amount);
    }

    /**
     * @notice
     *  Returns funds from an Allocator to the Treasury.
     *  Also see `_returnFundsToTreasury`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called by the Guardian.
     * @param id the id of the Allocator to returns funds from
     * @param amount the amount of token to withdraw, the token is known in the Allocator
     */
    function returnFundsToTreasury(uint256 id, uint256 amount) external override {
        _returnFundsToTreasury(allocators[id], amount);
    }

    /**
     * @notice
     *  Returns funds from an Allocator to the Treasury.
     *  Also see `_returnFundsToTreasury`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called by the Guardian.
     * @param allocatorAddress the address of the Allocator to returns funds from
     * @param amount the amount of token to withdraw, the token is known in the Allocator
     */
    function returnFundsToTreasury(address allocatorAddress, uint256 amount) external override {
        _returnFundsToTreasury(IAllocator(allocatorAddress), amount);
    }

    /**
     * @notice
     *  Returns rewards from an Allocator to the Treasury.
     *  Also see `_returnRewardsToTreasury`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called by the Guardian.
     * @param id the id of the Allocator to returns rewards from
     * @param token the address of the reward token to withdraw
     * @param amount the amount of the reward token to withdraw
     */
    function returnRewardsToTreasury(
        uint256 id,
        address token,
        uint256 amount
    ) external {
        _returnRewardsToTreasury(allocators[id], IERC20(token), amount);
    }

    /**
     * @notice
     *  Returns rewards from an Allocator to the Treasury.
     *  Also see `_returnRewardsToTreasury`.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called by the Guardian.
     * @param allocatorAddress the address of the Allocator to returns rewards from
     * @param token the address of the reward token to withdraw
     * @param amount the amount of the reward token to withdraw
     */
    function returnRewardsToTreasury(
        address allocatorAddress,
        address token,
        uint256 amount
    ) external {
        _returnRewardsToTreasury(IAllocator(allocatorAddress), IERC20(token), amount);
    }

    /**
     * @notice
     *  Get an Allocators address by it's ID.
     * @dev
     *  Our first Allocator is at index 1, 0 is a placeholder.
     * @param id the id of the allocator's address to find
     * @return allocatorAddress the allocator's address
     */
    function getAllocatorByID(uint256 id) external view override returns (address allocatorAddress) {
        allocatorAddress = address(allocators[id]);
    }

    /**
     * @notice
     *  Get the `totalValueAllocated` to Allocators by the Treasury.
     * @dev
     *  For each individual incrementation, the value allocated is calculated by the
     *  `tokenValue` function of the treasury, which returns the OHM valuation of the asset.
     *  Thus, totalValueAllocated could also be called "totalOHMValueAllocated", the name is for simplicity.
     * @return the TotalValueAllocated
     */
    function getTotalValueAllocated() external view override returns (uint256) {
        return totalValueAllocated;
    }

    /**
     * @notice
     *  Get an Allocators limits.
     * @dev
     *  For an explanation of AllocatorLimits, see `_setAllocatorLimits`
     * @return the Allocator's limits
     */
    function getAllocatorLimits(uint256 id) external view override returns (AllocatorLimits memory) {
        return allocatorData[allocators[id]].limits;
    }

    /**
     * @notice
     *  Get an Allocators performance.
     * @dev
     *  An Allocator's performance is the amount of `gain` and `loss` it has sustained in its
     *  lifetime. `gain` is the amount of allocated tokens (underlying) acquired, while
     *  `loss` is the amount lost. `gain` and `loss` are incremented separately.
     *  Thus, overall performance can be gauged as gain - loss
     * @return the Allocator's performance
     */
    function getAllocatorPerformance(uint256 id) external view override returns (AllocatorPerformance memory) {
        return allocatorData[allocators[id]].performance;
    }

    /**
     * @notice
     *  Get an Allocators amount allocated.
     * @dev
     *  This is simply the amount of `token` which was allocated to the allocator.
     * @return the Allocator's amount allocated
     */
    function getAllocatorAllocated(uint256 id) external view override returns (uint256) {
        return allocatorData[allocators[id]].holdings.allocated;
    }

    /**
     * @notice
     *  Sets an Allocators AllocatorLimits.
     *  AllocatorLimits is part of AllocatorData, variable meanings follow:
     *  allocated - The maximum amount a Guardian may allocate this Allocator from Treasury.
     *  loss - The maximum loss amount this Allocator can take.
     * @dev
     *  Can only be called while the Allocator is offline.
     * @param allocator the Allocator to set AllocatorLimits for
     * @param limits the AllocatorLimits to set
     */
    function _setAllocatorLimits(IAllocator allocator, AllocatorLimits memory limits) internal {
        // checks
        _onlyGuardian();
        _allocatorOffline(allocator.status());

        // effects
        allocatorData[allocator].limits = limits;

        // events
        emit AllocatorLimitsChanged(allocator.id(), limits.allocated, limits.loss);
    }

    /**
     * @notice
     *  Requests funds from the Olympus Treasury to fund an Allocator.
     * @dev
     *  Can only be called while the Allocator is activated.
     *  Can only be called by the Guardian.
     *
     *  This function is going to allocate an `amount` of tokens to the Allocator and
     *  properly record this in storage. This done so that at any point, we know exactly
     *  how much was initially allocated and also how much value is allocated in total.
     *
     *  The related functions are `getAllocatorAllocated` and `getTotalValueAllocated`.
     *
     *  To note is also the `_allocatorBelowLimit` check.
     * @param allocator the address of the allocator to fund
     * @param amount the amount of token to withdraw, the token is known in the Allocator
     */
    function _requestFundsFromTreasury(IAllocator allocator, uint256 amount) internal {
        // reads
        AllocatorData memory data = allocatorData[allocator];
        address tokenAllocated = allocator.getToken();
        uint256 value = treasury.tokenValue(tokenAllocated, amount);

        // checks
        _onlyGuardian();
        _allocatorActivated(allocator.status());
        _allocatorBelowLimit(data, amount);

        // interaction (withdrawing)
        treasury.manage(tokenAllocated, amount);

        // effects
        totalValueAllocated += value;
        allocatorData[allocator].holdings.allocated += amount;

        // interaction (depositing)
        IERC20(tokenAllocated).safeTransfer(address(allocator), amount);

        // events
        emit AllocatorFunded(allocator.id(), amount, value);
    }

    /**
     * @notice
     *  Returns funds from an Allocator to the Treasury.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called by the Guardian.
     *
     *  This function is going to withdraw `amount` of allocated token from an Allocator
     *  back to the Treasury. Prior to calling this function, `deallocate` should be called,
     *  in order to prepare the funds for withdrawal.
     *
     *  The maximum amount which can be withdrawn is `gain` + `allocated`.
     *  `allocated` is decremented first after which `gain` is decremented in the case
     *  that `allocated` is not sufficient. The `totalValueAllocated` is also decremented.
     * @param allocator the address of the allocator to return funds from
     * @param amount the amount of token to withdraw, the token is known in the Allocator
     */
    function _returnFundsToTreasury(IAllocator allocator, uint256 amount) internal {
        // reads
        uint256 allocated = allocatorData[allocator].holdings.allocated;
        uint128 gain = allocatorData[allocator].performance.gain;

        if (amount > allocated) {
            amount -= allocated;
            if (amount > gain) {
                amount = allocated + gain;
                gain = 0;
            } else {
                // yes, amount should never > gain, we have safemath
                gain -= uint128(amount);
                amount += allocated;
            }
            allocated = 0;
        } else {
            allocated -= amount;
        }

        address tokenAllocated = allocator.getToken();
        uint256 value = treasury.tokenValue(tokenAllocated, amount);

        // checks
        _onlyGuardian();
        _allowTreasuryWithdrawal(IERC20(tokenAllocated));

        // interaction (withdrawing)
        IERC20(tokenAllocated).safeTransferFrom(address(allocator), address(this), amount);

        // effects
        totalValueAllocated -= value;
        allocatorData[allocator].holdings.allocated = allocated;
        if (allocated == 0) allocatorData[allocator].performance.gain = gain;

        // interaction (depositing)
        assert(treasury.deposit(amount, tokenAllocated, value) == 0);

        // events
        emit AllocatorWithdrawal(allocator.id(), amount, value);
    }

    /**
     * @notice
     *  Returns rewards from an Allocator to the Treasury.
     * @dev
     *  External hook: Logic is handled in the internal function.
     *  Can only be called by the Guardian.
     *
     *  The assumption is that the reward tokens being withdrawn are going to be
     *  either deposited into the contract OR harvested into allocated (underlying).
     *
     *  For this reason we don't need anything other than `balanceOf`.
     * @param allocator the Allocator to returns rewards from
     * @param token the reward token to withdraw
     * @param amount the amount of the reward token to withdraw
     */
    function _returnRewardsToTreasury(
        IAllocator allocator,
        IERC20 token,
        uint256 amount
    ) internal {
        // reads
        uint256 balance = token.balanceOf(address(allocator));
        amount = (balance < amount) ? balance : amount;
        uint256 value = treasury.tokenValue(address(token), amount);

        // checks
        _onlyGuardian();
        _allowTreasuryWithdrawal(token);

        // interactions
        token.safeTransferFrom(address(allocator), address(this), amount);
        assert(treasury.deposit(amount, address(token), value) == 0);

        // events
        emit AllocatorRewardsWithdrawal(allocator.id(), amount, value);
    }

    /**
     * @notice
     *  Approve treasury for withdrawing if token has not been approved.
     * @param token Token to approve.
     */
    function _allowTreasuryWithdrawal(IERC20 token) internal {
        if (token.allowance(address(this), address(treasury)) == 0) token.approve(address(treasury), type(uint256).max);
    }

    /**
     * @notice
     *  Check if token is below limit for allocation and if not approve it.
     * @param data allocator data to check limits and amount allocated
     * @param amount amount of tokens to allocate
     */
    function _allocatorBelowLimit(AllocatorData memory data, uint256 amount) internal pure {
        uint256 newAllocated = data.holdings.allocated + amount;
        if (newAllocated > data.limits.allocated)
            revert TreasuryExtender_MaxAllocation(newAllocated, data.limits.allocated);
    }
}
