// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
*
* MIT License
* ===========
*
* Copyright (c) 2020 HunnyFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IHunnyMinter.sol";
import "../interfaces/legacy/IStrategyHelper.sol";
import "./VaultController.sol";
import {PoolConstant} from "../library/PoolConstant.sol";


contract VaultBananaToBanana is VaultController, IStrategy {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint;

    /* ========== CONSTANTS ============= */

    IBEP20 private constant BANANA = IBEP20(0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95);
    IMasterChef private constant BANANA_MASTER_CHEF = IMasterChef(0x5c8D727b265DBAfaba67E050f2f739cAeEB4A6F9);
    IStrategyHelper private constant STRATEGY_HELPER = IStrategyHelper(0x486B662A191E29cF767862ACE492c89A6c834fB4);

    uint public constant override pid = 0;
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.CakeStake;

    uint private constant DUST = 1000;

    /* ========== STATE VARIABLES ========== */

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) private _depositedAt;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __VaultController_init(BANANA);

        setMinter(0x15D70a537Fe24883735e5C5Bd62886Ba8aBc56cA);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function balance() public view override returns (uint amount) {
        (amount,) = BANANA_MASTER_CHEF.userInfo(pid, address(this));
    }

    function balanceOf(address account) public view override returns(uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) public view override returns (uint) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    // helper function returns reward in banana + hunny
    function profitOf(address account) public view returns (uint _cake, uint _hunny) {
        uint amount = earned(account);

        if (canMint()) {
            uint performanceFee = _minter.performanceFee(amount);
            // banana amount
            _cake = amount.sub(performanceFee);

            uint bnbValue = STRATEGY_HELPER.tvlInBNB(address(BANANA), performanceFee);
            // hunny amount
            _hunny = _minter.amountHunnyToMint(bnbValue);
        } else {
            _cake = amount;
            _hunny = 0;
        }
    }

    function priceShare() external view override returns(uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        return address(_stakingToken);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint _amount) public override {
        _deposit(_amount, msg.sender);

        if (isWhitelist(msg.sender) == false) {
            _principal[msg.sender] = _principal[msg.sender].add(_amount);
            _depositedAt[msg.sender] = block.timestamp;
        }
    }

    function depositAll() external override {
        deposit(BANANA.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        uint amount = balanceOf(msg.sender);
        uint principal = principalOf(msg.sender);
        uint depositTimestamp = _depositedAt[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        uint bananaHarvested = _withdrawStakingToken(amount);

        uint profit = amount > principal ? amount.sub(principal) : 0;
        uint withdrawalFee = canMint() ? _minter.withdrawalFee(principal, depositTimestamp) : 0;
        uint performanceFee = canMint() ? _minter.performanceFee(profit) : 0;

        if (withdrawalFee.add(performanceFee) > DUST) {
            BANANA.safeApprove(address(_minter), 0);
            BANANA.safeApprove(address(_minter), withdrawalFee.add(performanceFee));
            _minter.mintFor(address(BANANA), withdrawalFee, performanceFee, msg.sender, depositTimestamp);
            if (performanceFee > 0) {
                emit ProfitPaid(msg.sender, profit, performanceFee);
            }
            amount = amount.sub(withdrawalFee).sub(performanceFee);
        }

        BANANA.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);

        _harvest(bananaHarvested);
    }

    function harvest() external override {
        uint bananaHarvested = _withdrawStakingToken(0);
        _harvest(bananaHarvested);
    }

    function withdraw(uint shares) external override onlyWhitelisted {
        uint amount = balance().mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);

        uint bananaHarvested = _withdrawStakingToken(amount);

        BANANA.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, 0);

        _harvest(bananaHarvested);
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint _amount) external {
        uint amount = Math.min(_amount, _principal[msg.sender]);
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        uint bananaHarvested = _withdrawStakingToken(amount);

        uint depositTimestamp = _depositedAt[msg.sender];
        uint withdrawalFee = canMint() ? _minter.withdrawalFee(amount, depositTimestamp) : 0;
        if (withdrawalFee > DUST) {
            BANANA.safeApprove(address(_minter), 0);
            BANANA.safeApprove(address(_minter), withdrawalFee);
            _minter.mintFor(address(BANANA), withdrawalFee, 0, msg.sender, depositTimestamp);
            amount = amount.sub(withdrawalFee);
        }

        BANANA.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);

        _harvest(bananaHarvested);
    }

    function getReward() external override {
        uint amount = earned(msg.sender);
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        uint bananaHarvested = _withdrawStakingToken(amount);

        uint depositTimestamp = _depositedAt[msg.sender];
        uint performanceFee = canMint() ? _minter.performanceFee(amount) : 0;
        if (performanceFee > DUST) {
            BANANA.safeApprove(address(_minter), 0);
            BANANA.safeApprove(address(_minter), performanceFee);
            _minter.mintFor(address(BANANA), 0, performanceFee, msg.sender, depositTimestamp);
            amount = amount.sub(performanceFee);
        }

        BANANA.safeTransfer(msg.sender, amount);
        emit ProfitPaid(msg.sender, amount, performanceFee);

        _harvest(bananaHarvested);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    // safe check banana balance
    function _depositStakingToken(uint amount) private returns(uint bananaHarvested) {
        uint before = BANANA.balanceOf(address(this));

        BANANA.safeApprove(address(BANANA_MASTER_CHEF), 0);
        BANANA.safeApprove(address(BANANA_MASTER_CHEF), amount);
        BANANA_MASTER_CHEF.enterStaking(amount);
        bananaHarvested = BANANA.balanceOf(address(this)).add(amount).sub(before);
    }

    function _withdrawStakingToken(uint amount) private returns(uint bananaHarvested) {
        uint before = BANANA.balanceOf(address(this));
        BANANA_MASTER_CHEF.leaveStaking(amount);
        bananaHarvested = BANANA.balanceOf(address(this)).sub(amount).sub(before);
    }

    function _harvest(uint bananaAmount) private {
        if (bananaAmount > 0) {
            emit Harvested(bananaAmount);
            BANANA.safeApprove(address(BANANA_MASTER_CHEF), 0);
            BANANA.safeApprove(address(BANANA_MASTER_CHEF), bananaAmount);
            BANANA_MASTER_CHEF.enterStaking(bananaAmount);
        }
    }

    function _deposit(uint _amount, address _to) private notPaused {
        uint _pool = balance();
        BANANA.safeTransferFrom(msg.sender, address(this), _amount);
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);

        uint bananaHarvested = _depositStakingToken(_amount);
        emit Deposited(msg.sender, _amount);

        _harvest(bananaHarvested);
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */
    // @dev _stakingToken(BANANA) must not remain balance in this contract. So dev should be able to salvage staking token transferred by mistake.
    function recoverToken(address _token, uint amount) virtual external override onlyOwner {
        require(address(_stakingToken) != _token, "!token");
        IBEP20(_token).safeTransfer(owner(), amount);
        emit Recovered(_token, amount);
    }
}
