// SPDX-License-Identifier: MIT

pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18, ud, MAX_WHOLE_UD60x18} from "prb-math/UD60x18.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {ISwapCall} from "./interfaces/ISwapCall.sol";

interface IFactory {
    function feeTo() external view returns (address);
}

contract Pair is ERC20 {
    using SafeERC20 for IERC20;

    error Pair__Forbidden();
    error Pair__AlreadyInitialized();
    error Pair__InsufficientLiquidityMinted();
    error Pair__Overflow();
    error Pair__SameToken();
    error Pair__InvalidZeroAddress();
    error Pair__Locked();
    error Pair__InsufficientLiquidityBurned();
    error Pair__InvalidFlashLoanReceiver();
    error Pair__RepayFailed();
    error Pair__ReservesReversed();
    error Pair__InvalidSwapAmount();
    error Pair__InsufficientLiquidity();
    error Pair__InvalidInputAmount();

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant PRECISION = 1000;
    uint256 constant FEE = 997;
    uint256 constant FEES = 3;

    uint256 private reserve0;
    uint256 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 private kLast; // reserve0 * reserve1, as of the last liquidity event

    address public immutable factory;
    IERC20 public token0;
    IERC20 public token1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Sync(uint256 reserve0, uint256 reserve1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    uint256 private unlocked = 1;

    modifier lock() {
        if (unlocked != 1) revert Pair__Locked();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor(address _token0, address _token1) ERC20("SwapCoinPair", "SCP") {
        if (_token0 == _token1) revert Pair__SameToken();
        if (
            IERC20(_token0) == IERC20(address(0)) ||
            IERC20(_token1) == IERC20(address(0))
        ) revert Pair__InvalidZeroAddress();
        factory = msg.sender;
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory) revert Pair__Forbidden();
        if (token0 != IERC20(address(0)) || token1 != IERC20(address(0)))
            revert Pair__AlreadyInitialized();
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    function mint() external lock returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            liquidity =
                Math.sqrt((ud(amount0) * ud(amount1)).unwrap()) -
                MINIMUM_LIQUIDITY;
            _mint(address(0xDEAD), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens to 0xDEAD
        } else {
            liquidity = Math.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }

        if (liquidity <= 0) revert Pair__InsufficientLiquidityMinted();

        _mint(msg.sender, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) kLast = reserve0 * reserve1;

        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(
        address to
    ) external lock returns (uint256 amount0, uint256 amount1) {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 && amount1 == 0)
            revert Pair__InsufficientLiquidityBurned();
        _burn(address(this), liquidity);
        SafeERC20.safeTransfer(IERC20(_token0), to, amount0);
        SafeERC20.safeTransfer(IERC20(_token1), to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = ud(reserve0).mul(ud(reserve1)).unwrap();
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external lock returns (bool) {
        uint256 fee = flashFee(token, amount); // using the EIP 3156
        uint256 futureBalance = IERC20(token).balanceOf(address(this)) + fee;

        IERC20(token).transfer(address(receiver), amount);

        if (
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) ==
            keccak256("ERC3156FlashBorrower.onFlashLoan")
        ) {
            revert Pair__InvalidFlashLoanReceiver();
        }

        if (
            IERC20(token).transferFrom(
                address(receiver),
                address(this),
                amount + fee
            )
        ) {
            revert Pair__RepayFailed();
        }

        address _token0 = address(token0);
        address _token1 = address(token1);
        if (token == _token0 || token == _token1) {
            (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
            uint256 balance0 = IERC20(_token0).balanceOf(address(this));
            uint256 balance1 = IERC20(_token1).balanceOf(address(this));
            if (balance0 * balance1 < _reserve0 * _reserve1)
                revert Pair__ReservesReversed();
            _update(balance0, balance1, _reserve0, _reserve1);
        }
        return true;
    }

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        if (amount0Out < 0 || amount1Out < 0) revert Pair__InvalidSwapAmount();
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        if (amount0Out > _reserve0 && amount1Out > _reserve1)
            revert Pair__InsufficientLiquidity();

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = address(token0);
            address _token1 = address(token1);
            if (amount0Out > 0) IERC20(_token0).safeTransfer(to, amount0Out);
            if (amount1Out > 0) IERC20(_token1).safeTransfer(to, amount1Out);

            if (data.length > 0)
                ISwapCall(msg.sender).swapCall(
                    msg.sender,
                    amount0Out,
                    amount1Out,
                    data
                );
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;
        if (amount0In < 0 || amount1In < 0) revert Pair__InvalidInputAmount();

        {
            uint256 balance0Adjusted = balance0 *
                PRECISION -
                (amount0In * FEES);
            uint256 balance1Adjusted = balance1 *
                PRECISION -
                (amount1In * FEES);
            if (
                balance0Adjusted * balance1Adjusted <
                _reserve0 * _reserve1 * PRECISION ** 2
            ) revert Pair__ReservesReversed();
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function getReserves()
        public
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint256 _reserve0,
        uint256 _reserve1
    ) private {
        if (
            ud(balance0) > MAX_WHOLE_UD60x18 && ud(balance1) > MAX_WHOLE_UD60x18
        ) revert Pair__Overflow();
        uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;
        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            UD60x18 udReserve0 = ud(_reserve0);
            UD60x18 udReserve1 = ud(_reserve1);
            price0CumulativeLast +=
                udReserve1.div(udReserve0).unwrap() *
                timeElapsed;
            price1CumulativeLast +=
                udReserve0.div(udReserve1).unwrap() *
                timeElapsed;
        }
        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = uint32(block.timestamp);

        emit Sync(reserve0, reserve1);
    }

    function skim(address to) external lock {
        address _token0 = address(token0);
        address _token1 = address(token1);
        IERC20(_token0).safeTransfer(
            to,
            IERC20(_token0).balanceOf(address(this)) - reserve0
        );
        IERC20(_token1).safeTransfer(
            to,
            IERC20(_token1).balanceOf(address(this)) - reserve1
        );
    }

    function sync() external lock {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            _reserve0,
            _reserve1
        );
    }

    function flashFee(
        address token,
        uint256 amount
    ) public view returns (uint256 fee) {
        fee = amount - ((amount * FEE) / PRECISION);
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _mintFee(
        uint256 _reserve0,
        uint256 _reserve1
    ) private returns (bool feeOn) {
        address feeTo = IFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (kLast != 0) {
                uint256 rootK = Math.sqrt(reserve0 * _reserve1);
                uint256 rootKLast = Math.sqrt(kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (kLast != 0) {
            kLast = 0;
        }
    }
}
