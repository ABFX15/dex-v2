// SPDX-License-Identifier: MIT

pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18, ud, MAX_WHOLE_UD60x18} from "prb-math/UD60x18.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

interface IFactory {
    function feeTo() external view returns (address);
}

contract Pair is ERC20 {
    error Pair__InsufficientLiquidityMinted();
    error Pair__SameToken();
    error Pair__InvalidZeroAddress();
    error Pair__Locked();
    error Pair__InsufficientLiquidityBurned();
    error Pair__InvalidFlashLoanReceiver();
    error Pair__RepayFailed();
    error Pair__ReservesReversed();

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant PRECISION = 1000;
    uint256 constant FEE = 997;

    uint256 private reserve0;
    uint256 private reserve1;
    uint32 private blockTimestampLast;
    uint256 private kLast; // reserve0 * reserve1, as of the last liquidity event

    address public immutable factory;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Sync(uint256 reserve0, uint256 reserve1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
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

        _update(balance0, balance0);

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
        uint256 amount0 = (liquidity * balance0) / _totalSupply;
        uint256 amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 && amount1 == 0)
            revert Pair__InsufficientLiquidityBurned();
        _burn(address(this), liquidity);
        SafeERC20.safeTransfer(IERC20(_token0), to, amount0);
        SafeERC20.safeTransfer(IERC20(_token1), to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1);
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

        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan")) {
            revert Pair__InvalidFlashLoanReceiver();
        }

        if (IERC20(token).transferFrom(address(receiver), address(this), amount + fee)) {
            revert Pair__RepayFailed();
        }

        address _token0 = address(token0);
        address _token1 = address(token1);
        if (token == _token0 || token == _token1) {
            (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
            uint256 balance0 = IERC20(_token0).balanceOf(address(this));
            uint256 balance1 = IERC20(_token1).balanceOf(address(this));
            if (balance0 * balance1 < _reserve0 * _reserve1) revert Pair__ReservesReversed();
            _update(balance0, balance1);
        }
        return true;
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

    function flashFee(address token, uint256 amount) public view returns (uint256 fee) {
        fee = amount - ((amount * FEE) / PRECISION);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        reserve0 = uint256(balance0);
        reserve1 = uint256(balance1);

        emit Sync(reserve0, reserve1);
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
