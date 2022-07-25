// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./StrategyBase.sol";
import "../../../interfaces/IGenericVault.sol";
import "../../../interfaces/IUniV2Router.sol";
import "../../../interfaces/IWETH.sol";

contract AuraBalZaps is Ownable, AuraBalStrategyBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable vault;
    bytes32 private constant BAL_ETH_POOL_ID =
        0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;

    constructor(address _vault) {
        vault = _vault;
    }

    /// @notice Set approvals for the contracts used when swapping & staking
    function setApprovals() external {
        IERC20(BAL_TOKEN).safeApprove(BAL_VAULT, 0);
        IERC20(BAL_TOKEN).safeApprove(BAL_VAULT, type(uint256).max);
        IERC20(WETH_TOKEN).safeApprove(BAL_VAULT, 0);
        IERC20(WETH_TOKEN).safeApprove(BAL_VAULT, type(uint256).max);
        IERC20(BAL_ETH_POOL_TOKEN).safeApprove(vault, 0);
        IERC20(BAL_ETH_POOL_TOKEN).safeApprove(vault, type(uint256).max);
    }

    /// @notice Deposit from BAL and/or WETH
    /// @param _amounts - the amounts of FXS and cvxFXS to deposit respectively
    /// @param _minAmountOut - min amount of LP tokens expected
    /// @param _to - address to stake on behalf of
    function depositFromUnderlyingAssets(
        uint256[2] calldata _amounts,
        uint256 _minAmountOut,
        address _to
    ) external notToZeroAddress(_to) {
        if (_amounts[0] > 0) {
            IERC20(BAL_TOKEN).safeTransferFrom(
                msg.sender,
                address(this),
                _amounts[0]
            );
        }
        if (_amounts[1] > 0) {
            IERC20(WETH_TOKEN).safeTransferFrom(
                msg.sender,
                address(this),
                _amounts[1]
            );
        }
        _addAndDeposit(_amounts, _minAmountOut, _to);
    }

    function _addAndDeposit(
        uint256[2] memory _amounts,
        uint256 _minAmountOut,
        address _to
    ) internal {
        _depositToBalEthPool(_amounts[0], _amounts[1], _minAmountOut);
        IGenericVault(vault).depositAll(_to);
    }

    /// @notice Deposit into the pounder from ETH
    /// @param _minAmountOut - min amount of lp tokens expected
    /// @param _to - address to stake on behalf of
    function depositFromEth(uint256 _minAmountOut, address _to)
        external
        payable
        notToZeroAddress(_to)
    {
        require(msg.value > 0, "cheap");
        _depositFromEth(msg.value, _minAmountOut, _to);
    }

    /// @notice Internal function to deposit ETH to the pounder
    /// @param _amount - amount of ETH
    /// @param _minAmountOut - min amount of lp tokens expected
    /// @param _to - address to stake on behalf of
    function _depositFromEth(
        uint256 _amount,
        uint256 _minAmountOut,
        address _to
    ) internal {
        IWETH(WETH_TOKEN).deposit{value: _amount}();
        _addAndDeposit([_amount, 0], _minAmountOut, _to);
    }

    /// @notice Deposit into the pounder from any token via Uni interface
    /// @notice Use at your own risk
    /// @dev Zap contract needs approval for spending of inputToken
    /// @param _amount - min amount of input token
    /// @param _minAmountOut - min amount of cvxCRV expected
    /// @param _router - address of the router to use. e.g. 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F for Sushi
    /// @param _inputToken - address of the token to swap from, needs to have an ETH pair on router used
    /// @param _to - address to stake on behalf of
    function depositViaUniV2EthPair(
        uint256 _amount,
        uint256 _minAmountOut,
        address _router,
        address _inputToken,
        address _to
    ) external notToZeroAddress(_to) {
        require(_router != address(0));

        IERC20(_inputToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
        address[] memory _path = new address[](2);
        _path[0] = _inputToken;
        _path[1] = WETH_TOKEN;

        IERC20(_inputToken).safeApprove(_router, 0);
        IERC20(_inputToken).safeApprove(_router, _amount);

        IUniV2Router(_router).swapExactTokensForETH(
            _amount,
            1,
            _path,
            address(this),
            block.timestamp + 1
        );
        _depositFromEth(address(this).balance, _minAmountOut, _to);
    }

    /// @notice Retrieves a user's vault shares and withdraw all
    /// @param _amount - amount of shares to retrieve
    function _claimAndWithdraw(uint256 _amount) internal {
        IERC20(vault).safeTransferFrom(msg.sender, address(this), _amount);
        IGenericVault(vault).withdrawAll(address(this));
    }

    /// @notice Claim as either BAL or WETH/ETH
    /// @param _amount - amount to withdraw
    /// @param _assetIndex - asset to withdraw (0: BAL, 1: ETH)
    /// @param _minAmountOut - minimum amount of underlying tokens expected
    /// @param _to - address to send withdrawn underlying to
    /// @param _useWrappedEth - whether to use WETH or unwrap
    function claimFromVaultAsUnderlying(
        uint256 _amount,
        uint256 _assetIndex,
        uint256 _minAmountOut,
        address _to,
        bool _useWrappedEth
    ) public notToZeroAddress(_to) {
        _claimAndWithdraw(_amount);

        IAsset[] memory _assets = new IAsset[](2);
        _assets[0] = IAsset(BAL_TOKEN);
        _assets[1] = IAsset(_useWrappedEth ? WETH_TOKEN : address(0));

        uint256[] memory _amountsOut = new uint256[](2);
        _amountsOut[0] = _assetIndex == 0 ? _minAmountOut : 0;
        _amountsOut[1] = _assetIndex == 1 ? _minAmountOut : 0;

        balVault.exitPool(
            BAL_ETH_POOL_ID,
            address(this),
            payable(_to),
            IBalancerVault.ExitPoolRequest(
                _assets,
                _amountsOut,
                abi.encode(
                    ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
                    IERC20(BAL_ETH_POOL_TOKEN).balanceOf(address(this)),
                    _assetIndex
                ),
                false
            )
        );
    }

    /// @notice Claim to any token via a univ2 router
    /// @notice Use at your own risk
    /// @param _amount - amount of uFXS to unstake
    /// @param _minAmountOut - min amount of output token expected
    /// @param _router - address of the router to use. e.g. 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F for Sushi
    /// @param _outputToken - address of the token to swap to
    /// @param _to - address of the final recipient of the swapped tokens
    function claimFromVaultViaUniV2EthPair(
        uint256 _amount,
        uint256 _minAmountOut,
        address _router,
        address _outputToken,
        address _to
    ) public notToZeroAddress(_to) {
        require(_router != address(0));
        claimFromVaultAsUnderlying(_amount, 1, 0, address(this), true);
        address[] memory _path = new address[](2);
        _path[0] = WETH_TOKEN;
        _path[1] = _outputToken;
        IUniV2Router(_router).swapExactETHForTokens{
            value: address(this).balance
        }(_minAmountOut, _path, _to, block.timestamp + 1);
    }

    modifier notToZeroAddress(address _to) {
        require(_to != address(0), "Invalid address!");
        _;
    }
}
