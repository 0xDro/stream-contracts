// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {ShareMath} from "./lib/ShareMath.sol";
import {Vault} from "./lib/Vault.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {SafeMath} from "lib/openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract StreamVault is ReentrancyGuard, ERC20 {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using ShareMath for Vault.DepositReceipt;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/
    /// @notice Stores the user's pending deposit for the round
    mapping(address => Vault.DepositReceipt) public depositReceipts;

    /// @notice On every round's close, the pricePerShare value of an rTHETA token is stored
    /// This is used to determine the number of shares to be returned
    /// to a user with their DepositReceipt.depositAmount
    mapping(uint256 => uint256) public roundPricePerShare;

    /// @notice Stores pending user withdrawals
    mapping(address => Vault.Withdrawal) public withdrawals;

    /// @notice Vault's parameters like cap, decimals
    Vault.VaultParams public vaultParams;

    /// @notice Vault's lifecycle state like round and locked amounts
    Vault.VaultState public vaultState;

    /// @notice WETH9 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    address public immutable WETH;

    /************************************************
     *  EVENTS
     ***********************************************/
    event Deposit(address indexed account, uint256 amount, uint256 round);

    event InitiateWithdraw(
        address indexed account,
        uint256 shares,
        uint256 round
    );
    event Withdraw(address indexed account, uint256 amount, uint256 shares);

    event Redeem(address indexed account, uint256 share, uint256 round);

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     */
    constructor(
        address _weth,
        string memory _tokenName,
        string memory _tokenSymbol
    ) ReentrancyGuard() ERC20(_tokenName, _tokenSymbol) {
        require(_weth != address(0), "!_weth");
        WETH = _weth;
    }

    /************************************************
     *  DEPOSITS
     ***********************************************/

    function depositETH() external payable nonReentrant {
        require(vaultParams.asset == WETH, "!WETH");
        require(msg.value > 0, "!value");

        _depositFor(msg.value, msg.sender);

        IWETH(WETH).deposit{value: msg.value}();
    }

    /**
     * @notice Deposits the `asset` from msg.sender.
     * @param amount is the amount of `asset` to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "!amount");

        _depositFor(amount, msg.sender);

        // An approve() by the msg.sender is required beforehand
        IERC20(vaultParams.asset).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
    }

    /**
     * @notice Deposits the `asset` from msg.sender added to `creditor`'s deposit.
     * @notice Used for vault -> vault deposits on the user's behalf
     * @param amount is the amount of `asset` to deposit
     * @param creditor is the address that can claim/withdraw deposited amount
     */
    function depositFor(
        uint256 amount,
        address creditor
    ) external nonReentrant {
        require(amount > 0, "!amount");
        require(creditor != address(0));

        _depositFor(amount, creditor);

        // An approve() by the msg.sender is required beforehand
        IERC20(vaultParams.asset).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
    }

    /**
     * @notice Mints the vault shares to the creditor
     * @param amount is the amount of `asset` deposited
     * @param creditor is the address to receieve the deposit
     */
    function _depositFor(uint256 amount, address creditor) private {
        uint256 currentRound = vaultState.round;
        uint256 totalWithDepositedAmount = totalBalance().add(amount);

        require(totalWithDepositedAmount <= vaultParams.cap, "Exceed cap");
        require(
            totalWithDepositedAmount >= vaultParams.minimumSupply,
            "Insufficient balance"
        );

        emit Deposit(creditor, amount, currentRound);

        Vault.DepositReceipt memory depositReceipt = depositReceipts[creditor];

        // If we have an unprocessed pending deposit from the previous rounds, we have to process it.
        uint256 unredeemedShares = depositReceipt.getSharesFromReceipt(
            currentRound,
            roundPricePerShare[depositReceipt.round],
            vaultParams.decimals
        );

        uint256 depositAmount = amount;

        // If we have a pending deposit in the current round, we add on to the pending deposit
        if (currentRound == depositReceipt.round) {
            uint256 newAmount = uint256(depositReceipt.amount).add(amount);
            depositAmount = newAmount;
        }

        ShareMath.assertUint104(depositAmount);

        depositReceipts[creditor] = Vault.DepositReceipt({
            round: uint16(currentRound),
            amount: uint104(depositAmount),
            unredeemedShares: uint128(unredeemedShares)
        });

        uint256 newTotalPending = uint256(vaultState.totalPending).add(amount);
        ShareMath.assertUint128(newTotalPending);

        vaultState.totalPending = uint128(newTotalPending);
    }

    /************************************************
     *  WITHDRAWALS
     ***********************************************/

    /**
     * @notice Initiates a withdrawal that can be processed once the round completes
     * @param numShares is the number of shares to withdraw
     */
    function _initiateWithdraw(uint256 numShares) internal {
        require(numShares > 0, "!numShares");

        // We do a max redeem before initiating a withdrawal
        // But we check if they must first have unredeemed shares
        if (
            depositReceipts[msg.sender].amount > 0 ||
            depositReceipts[msg.sender].unredeemedShares > 0
        ) {
            _redeem(0, true);
        }

        // This caches the `round` variable used in shareBalances
        uint256 currentRound = vaultState.round;
        Vault.Withdrawal storage withdrawal = withdrawals[msg.sender];

        bool withdrawalIsSameRound = withdrawal.round == currentRound;

        emit InitiateWithdraw(msg.sender, numShares, currentRound);

        uint256 existingShares = uint256(withdrawal.shares);

        uint256 withdrawalShares;
        if (withdrawalIsSameRound) {
            withdrawalShares = existingShares.add(numShares);
        } else {
            require(existingShares == 0, "Existing withdraw");
            withdrawalShares = numShares;
            withdrawals[msg.sender].round = uint16(currentRound);
        }

        ShareMath.assertUint128(withdrawalShares);
        withdrawals[msg.sender].shares = uint128(withdrawalShares);

        _transfer(msg.sender, address(this), numShares);
    }

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     * @return withdrawAmount the current withdrawal amount
     */
    function _completeWithdraw() internal returns (uint256) {
        Vault.Withdrawal storage withdrawal = withdrawals[msg.sender];

        uint256 withdrawalShares = withdrawal.shares;
        uint256 withdrawalRound = withdrawal.round;

        // This checks if there is a withdrawal
        require(withdrawalShares > 0, "Not initiated");

        require(withdrawalRound < vaultState.round, "Round not closed");

        // We leave the round number as non-zero to save on gas for subsequent writes
        withdrawals[msg.sender].shares = 0;
        vaultState.queuedWithdrawShares = uint128(
            uint256(vaultState.queuedWithdrawShares).sub(withdrawalShares)
        );

        uint256 withdrawAmount = ShareMath.sharesToAsset(
            withdrawalShares,
            roundPricePerShare[withdrawalRound],
            vaultParams.decimals
        );

        emit Withdraw(msg.sender, withdrawAmount, withdrawalShares);

        _burn(address(this), withdrawalShares);

        require(withdrawAmount > 0, "!withdrawAmount");
        transferAsset(msg.sender, withdrawAmount);

        return withdrawAmount;
    }

    /************************************************
     *  REDEMPTIONS
     ***********************************************/

    /**
     * @notice Redeems shares that are owed to the account
     * @param numShares is the number of shares to redeem
     */
    function redeem(uint256 numShares) external nonReentrant {
        require(numShares > 0, "!numShares");
        _redeem(numShares, false);
    }

    /**
     * @notice Redeems the entire unredeemedShares balance that is owed to the account
     */
    function maxRedeem() external nonReentrant {
        _redeem(0, true);
    }

    /**
     * @notice Redeems shares that are owed to the account
     * @param numShares is the number of shares to redeem, could be 0 when isMax=true
     * @param isMax is flag for when callers do a max redemption
     */
    function _redeem(uint256 numShares, bool isMax) internal {
        Vault.DepositReceipt memory depositReceipt = depositReceipts[
            msg.sender
        ];

        // This handles the null case when depositReceipt.round = 0
        // Because we start with round = 1 at `initialize`
        uint256 currentRound = vaultState.round;

        uint256 unredeemedShares = depositReceipt.getSharesFromReceipt(
            currentRound,
            roundPricePerShare[depositReceipt.round],
            vaultParams.decimals
        );

        numShares = isMax ? unredeemedShares : numShares;
        if (numShares == 0) {
            return;
        }
        require(numShares <= unredeemedShares, "Exceeds available");

        // If we have a depositReceipt on the same round, BUT we have some unredeemed shares
        // we debit from the unredeemedShares, but leave the amount field intact
        // If the round has past, with no new deposits, we just zero it out for new deposits.
        if (depositReceipt.round < currentRound) {
            depositReceipts[msg.sender].amount = 0;
        }

        ShareMath.assertUint128(numShares);
        depositReceipts[msg.sender].unredeemedShares = uint128(
            unredeemedShares.sub(numShares)
        );

        emit Redeem(msg.sender, numShares, depositReceipt.round);

        _transfer(address(this), msg.sender, numShares);
    }

    /**
     * @notice Returns the vault's total balance, including the amounts locked into a short position
     * @return total balance of the vault, including the amounts locked in third party protocols
     */
    function totalBalance() public view returns (uint256) {
        return
            uint256(vaultState.lockedAmount).add(
                IERC20(vaultParams.asset).balanceOf(address(this))
            );
    }

    /**
     * @notice Helper function to make either an ETH transfer or ERC20 transfer
     * @param recipient is the receiving address
     * @param amount is the transfer amount
     */
    function transferAsset(address recipient, uint256 amount) internal {
        address asset = vaultParams.asset;
        if (asset == WETH) {
            IWETH(WETH).withdraw(amount);
            (bool success, ) = recipient.call{value: amount}("");
            require(success, "Transfer failed");
            return;
        }
        IERC20(asset).safeTransfer(recipient, amount);
    }
}
