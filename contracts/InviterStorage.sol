pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

contract InviterStorage {

    address public _owner;

    address public _sysInviter;

    mapping(string => address) public inviters;

    string[] public inviteCodes;

    constructor(address sysInviter) public {
        _owner = msg.sender;
        _sysInviter = sysInviter;
    }

    function setSysInviter(address sysInviter) public {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _sysInviter = sysInviter;
    }

    function setInviter(address inviter, string memory code) public {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        require(bytes(code).length != 0, "code can not empty");

        inviters[code] = inviter;
        inviteCodes.push(code);
    }

    function getInviterAddress(string memory code) public view returns (address) {
        address inviter = inviters[code];
        if(inviter == address(0)) {
            inviter = _sysInviter;
        }
        return inviter;
    }
    
    function getAllInviteCode() public view returns (string[] memory) {
        return inviteCodes;
    }

}