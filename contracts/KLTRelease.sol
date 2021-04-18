pragma solidity ^0.5.16;

import "./Comp.sol";

library SafeMath {

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}



contract KLendRelease {

    using SafeMath for uint256;
    
    address public _token;

    address public _owner;

    address public _recipient;

    uint256 public _start_time;

    uint256 public _total_time;

    uint256 public _total_value;

    uint256 public _withdraw_value;

    event Withdrawn(address indexed user, uint256 amount);

    constructor (address token,uint256 totalValue,uint256 totalTime,uint256 startTime) public {
        require(token!=address(0));
        _owner = msg.sender;
        _token = token;
        _total_value = totalValue;
        _total_time = totalTime;
        _start_time = startTime;
    }

    function setRecipient(address recipient) public {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _recipient = recipient;
    }

    function isStart() public view returns(bool) {
        return block.timestamp > _start_time;
    }
    
    function setStartTime(uint256 _startTime) public {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _start_time = _startTime;
    }

    function earned() public view returns (uint256) {
        if(_total_time <= 0 || block.timestamp < _start_time) {
            return 0;
        }
        uint256 time = block.timestamp.sub(_start_time);
        uint256 time_rate = _total_value.div(_total_time);
        uint256 total_reward = time_rate.mul(time);
        uint256 reward = total_reward.sub(_withdraw_value);
        
        if(reward > _total_value.sub(_withdraw_value)){
            reward = _total_value.sub(_withdraw_value);
        }
        return reward;
    }

    function withdraw() public {
        require(_recipient == msg.sender, "Ownable: caller is not the recipient");
        require(block.timestamp > _start_time, "not start");
        uint256 reward = earned();
        require(reward>0,"no reward");
        Comp comp = Comp(_token);
        uint256 balance = comp.balanceOf(address(this));
        if(reward>balance){
            reward = balance;
        }
        comp.transfer(msg.sender,reward);
        _withdraw_value = _withdraw_value.add(reward);
        emit Withdrawn(msg.sender, reward);
    }

    function transfer(address addr,uint256 amount) public {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        Comp comp = Comp(_token);
        comp.transfer(addr,amount);
    }

    function delegate(address delegatee) public {
        require(_recipient == msg.sender || _owner == msg.sender, "Ownable: caller is not the recipient");
        require(delegatee != address(0), "delegatee can not empty");
        Comp comp = Comp(_token);
        uint256 balance = comp.balanceOf(address(this));
        if(balance > 0){
            comp.delegate(delegatee);
        }
    }
}