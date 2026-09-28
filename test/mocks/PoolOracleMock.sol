// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

/// @dev A Slipstream pool's `slot0` tick and `observe` cumulatives for venue doubles. The tick held `averageTick` over
///      every past window and sits at `spotTick` now; both default to zero, so the reset's pool check passes.
abstract contract PoolOracleMock {
    int24 public spotTick;
    int24 public averageTick;

    function setTicks(int24 spot, int24 average) external {
        spotTick = spot;
        averageTick = average;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (uint160(1) << 96, spotTick, 0, 1, 1, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = -int56(averageTick) * int56(uint56(secondsAgos[i]));
        }
    }
}
