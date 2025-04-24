## DEX

# Basic features
Swap tokens
balance out the AMM

// Core interfaces
interface IUniswapV2Factory
interface IUniswapV2Pair
interface IUniswapV2Router
interface IUniswapV2Callee    // For flash swaps
interface IERC20
interface IWETH               // For ETH wrapping

// Main contracts you'll need to implement:
- UniswapV2Factory.sol       // Creates pairs
- UniswapV2Pair.sol         // Handles swaps and liquidity
- UniswapV2Router.sol       // User-facing contract
- UniswapV2Library.sol      // Helper functions

Advanced Features:
MEV Protection
Gas Optimization
Price Oracle Integration
Multiple Pool Types
Liquidity Mining

