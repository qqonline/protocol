// SPDX-License-Identifier: MIT
/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: YAMRewards.sol
*
* Docs: https://docs.synthetix.io/
*
*
* MIT License
* ===========
*
* Copyright (c) 2020 Synthetix
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

pragma solidity >=0.6.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";

abstract contract IRewardDistributionRecipient {
    address public rewardDistribution;

    function notifyRewardAmount(uint256 reward) internal virtual;

    modifier onlyRewardDistribution() {
        require(
            msg.sender == rewardDistribution,
            "Caller is not reward distribution"
        );
        _;
    }

    function setRewardDistribution(address _rewardDistribution) public {
        rewardDistribution = _rewardDistribution;
    }
}

contract LPTokenWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public y;

    function setStakeToken(address _y) internal {
        y = IERC20(_y);
    }

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        y.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        y.safeTransfer(msg.sender, amount);
    }
}

contract StakingPool is
    Initializable,
    LPTokenWrapper,
    IRewardDistributionRecipient
{
    string public poolName;
    IERC20 public rewardToken;
    address public orchestrator;
    uint256 public duration;
    bool public manualStartPool;

    uint256 public initReward;
    uint256 public maxReward;
    bool public poolStarted;
    uint256 public startTime;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardDistributed;

    uint256 public fairDistributionTokenLimit;
    uint256 public fairDistributionTimeLimit;
    bool public isFairDistribution;
    address constant uniFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ManualPoolStarted(uint256 startedAt);

    modifier checkHalve() {
        if (block.timestamp >= periodFinish) {
            initReward = initReward.mul(50).div(100);

            rewardRate = initReward.div(duration);
            periodFinish = block.timestamp.add(duration);
            emit RewardAdded(initReward);
        }
        _;
    }

    modifier checkStart() {
        if (manualStartPool) {
            require(poolStarted == true, "Orchestrator hasn't started pool");
        } else {
            require(
                block.timestamp > startTime,
                "Can't use pool before start time"
            );
        }
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // https://uniswap.org/docs/v2/smart-contract-integration/getting-pair-addresses/
    function genUniAddr(address left, address right)
        internal
        pure
        returns (address)
    {
        address first = left < right ? left : right;
        address second = left < right ? right : left;
        address pair = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        uniFactory,
                        keccak256(abi.encodePacked(first, second)),
                        hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                    )
                )
            )
        );
        return pair;
    }

    function initialize(
        string memory poolName_,
        address rewardToken_,
        address pairToken_,
        bool isUniPair,
        address orchestrator_,
        uint256 duration_,
        bool isFairDistribution_,
        uint256 fairDistributionTokenLimit_,
        uint256 fairDistributionTimeLimit_,
        bool manualStartPool_,
        uint256 oracleStartTimeOffset
    ) public initializer {
        poolName = poolName_;
        if (isUniPair) {
            setStakeToken(genUniAddr(rewardToken_, pairToken_));
        } else {
            setStakeToken(pairToken_);
        }
        rewardToken = IERC20(rewardToken_);
        orchestrator = orchestrator_;

        maxReward = rewardToken.balanceOf(address(this));
        duration = duration_;

        isFairDistribution = isFairDistribution_;
        fairDistributionTokenLimit = fairDistributionTokenLimit_;
        fairDistributionTimeLimit = fairDistributionTimeLimit_;
        manualStartPool = manualStartPool_;

        if (!manualStartPool) {
            startTime = block.timestamp + oracleStartTimeOffset;
            notifyRewardAmount(maxReward.mul(50).div(100));
        }
    }

    function startPool() external {
        require(msg.sender == address(orchestrator));
        require(poolStarted == false, "Pool can only be started once");

        poolStarted = true;
        startTime = block.timestamp + 1;
        notifyRewardAmount(maxReward.mul(50).div(100));
        emit ManualPoolStarted(startTime);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(10**18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(10**18)
                .add(rewards[account]);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkHalve
        checkStart
    {
        require(amount > 0, "Cannot stake 0");
        super.stake(amount);
        emit Staked(msg.sender, amount);

        if (isFairDistribution) {
            require(
                balanceOf(msg.sender) <=
                    fairDistributionTokenLimit * uint256(10)**y.decimals() ||
                    block.timestamp >= startTime.add(fairDistributionTimeLimit),
                "Can't stake more than distribution limit"
            );
        }
    }

    function withdraw(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkHalve
        checkStart
    {
        require(amount > 0, "Cannot withdraw 0");
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
        getReward();
    }

    function getReward() public updateReward(msg.sender) checkHalve checkStart {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
            rewardDistributed = rewardDistributed.add(reward);
        }
    }

    function notifyRewardAmount(uint256 reward)
        internal
        override
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(duration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(duration);
        }
        initReward = reward;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(duration);
        emit RewardAdded(reward);
    }
}
