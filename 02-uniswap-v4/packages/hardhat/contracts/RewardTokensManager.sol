// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Permit2Forwarder } from "@uniswap/v4-periphery/src/base/Permit2Forwarder.sol";

contract RewardTokensManager is Ownable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant FEE_TIER = 3000; // 0.3% fee
    int24 public constant TICK_SPACING = 60;
    IHooks public constant HOOKS = IHooks(address(0)); // no custom hooks

    event PoolCreated(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    error InvalidAmount();
    error InvalidTickRange();
    error PoolNotCreated();
    error TickRangeDoesNotCoverAssignmentPrice();
    error MintFailed();

    IPoolManager poolManager;
    IPositionManager positionManager;
    address pnpToken;
    address fnbToken;
    PoolKey poolKey;
    bytes32 poolId;
    mapping(bytes32 => bool) public createdPools;

    constructor(address _poolManager, address _positionManager, address _pnpToken, address _fnbToken) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        pnpToken = _pnpToken;
        fnbToken = _fnbToken;

        // sort tokens into currency0 / currency1 (lower address first)
        (address currency0, address currency1) = _pnpToken < _fnbToken ? (_pnpToken, _fnbToken) : (_fnbToken, _pnpToken);

        poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: HOOKS
        });
    }

    // 1 FNBT = R0.10 and 1 PNPT = R0.01, so spot is 10 PNPT per FNBT
    function getTargetTick() public view returns (int24) {
        address currency0 = Currency.unwrap(poolKey.currency0);
        uint160 sqrtPriceX96 = currency0 == fnbToken
            ? sqrtRatioX96(10, 1)
            : sqrtRatioX96(1, 10);
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function sqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        return uint160(Math.sqrt((amount1 << 192) / amount0));
    }

    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(poolKey.toId());
    }

    function getCanonicalCurrencies() public view returns (address currency0, address currency1) {
        return (Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
    }

    // only the deployer should bootstrap the pool once
    function createPool(uint160 sqrtPriceX96) public onlyOwner returns (bytes32) {
        poolManager.initialize(poolKey, sqrtPriceX96);
        poolId = PoolId.unwrap(poolKey.toId());
        createdPools[poolId] = true;

        emit PoolCreated(
            poolId,
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            FEE_TIER,
            TICK_SPACING,
            address(HOOKS),
            sqrtPriceX96
        );

        return poolId;
    }

    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 mintedPoolId) {
        // validate amounts and tick constraints
        if (amount0Desired == 0 || amount1Desired == 0) revert InvalidAmount();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0) revert InvalidTickRange();

        // range must include the assignment spot tick
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper < targetTick) revert TickRangeDoesNotCoverAssignmentPrice();

        // pool must exist before we mint
        mintedPoolId = PoolId.unwrap(poolKey.toId());
        if (!createdPools[mintedPoolId]) revert PoolNotCreated();

        // work out liquidity from current price and desired amounts
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(mintedPoolId));

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);

        // pull tokens from the caller
        IERC20(currency0Addr).safeTransferFrom(msg.sender, address(this), amount0Desired);
        IERC20(currency1Addr).safeTransferFrom(msg.sender, address(this), amount1Desired);

        // let PositionManager pull via Permit2
        address permit2Addr = address(Permit2Forwarder(payable(address(positionManager))).permit2());
        IERC20(currency0Addr).forceApprove(permit2Addr, type(uint256).max);
        IERC20(currency1Addr).forceApprove(permit2Addr, type(uint256).max);

        // min through PositionManager
        positionId = positionManager.nextTokenId();

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            uint128(amount0Desired),
            uint128(amount1Desired),
            msg.sender,
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        // make sure something actually got minted
        uint128 mintedLiquidity = positionManager.getPositionLiquidity(positionId);
        if (mintedLiquidity == 0) revert MintFailed();

        // send back any leftover tokens, then emit
        uint256 leftover0 = IERC20(currency0Addr).balanceOf(address(this));
        if (leftover0 > 0) {
            IERC20(currency0Addr).safeTransfer(msg.sender, leftover0);
        }
        uint256 leftover1 = IERC20(currency1Addr).balanceOf(address(this));
        if (leftover1 > 0) {
            IERC20(currency1Addr).safeTransfer(msg.sender, leftover1);
        }

        emit LiquidityMinted(mintedPoolId, positionId, msg.sender, tickLower, tickUpper, mintedLiquidity);
    }
}
