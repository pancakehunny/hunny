// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "../Constants.sol";
import "../library/uniswap/FixedPoint.sol";
import "../library/uniswap/UniswapV2Library.sol";
import "../library/uniswap/UniswapV2OracleLibrary.sol";


// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract HunnyOracle is Ownable {
    using FixedPoint for *;

    uint public constant PERIOD = 1 hours;

    bool public initialized;

    address public hunnyToken;
    IUniswapV2Pair pair;
    address public token0;
    address public token1;

    uint    public price0CumulativeLast;
    uint    public price1CumulativeLast;
    uint32  public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    constructor(address hunny) public {
        hunnyToken = hunny;
    }

    function initialize() internal {
        IUniswapV2Pair _pair = IUniswapV2Pair(UniswapV2Library.pairFor(Constants.PANCAKE_FACTORY, hunnyToken, Constants.WBNB));

        pair = _pair;

        token0 = _pair.token0();
        token1 = _pair.token1();

        price0CumulativeLast = _pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)

        // get the blockTimestampLast
        (,, blockTimestampLast) = _pair.getReserves();

        initialized = true;
    }

    function update() external {
        if (!initialized) {
            initialize();
        }

        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
        UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // ensure that at least one full period has passed since the last update
        if (timeElapsed >= PERIOD) {
            // overflow is desired, casting never truncates
            // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
            price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
            price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

            price0CumulativeLast = price0Cumulative;
            price1CumulativeLast = price1Cumulative;
            blockTimestampLast = blockTimestamp;
        }
    }

    function capture() public view returns(uint224) {
        IUniswapV2Pair _pair = IUniswapV2Pair(UniswapV2Library.pairFor(Constants.PANCAKE_FACTORY, hunnyToken, Constants.WBNB));
        if (_pair.token0() == hunnyToken) {
            return price0Average.mul(1).decode144();
        } else {
            return price1Average.mul(1).decode144();
        }
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address token, uint amountIn) external view returns (uint amountOut) {
        if (token == token0) {
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, 'HunnyOracle: INVALID_TOKEN');
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }
}