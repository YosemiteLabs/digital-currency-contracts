pragma solidity ^0.4.18;

/*
    Copyright 2017, Yosemite X Inc.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/// @title SnapshotableToken Contract
/// @author Bezalel Lim <bezalel@yosemitex.com>
/// @dev The token distribution at the requested block number can be snapshotable.
///   The token balances of all accounts at snapshotted block number are reserved and can be referenced at any time.
///   This snapshot feature will allow SnapshotableToken-based tokens to be simply cloneable and upgradable without
///   affecting the original token distribution.
/// @dev SnapshotableToken is inspired by MiniMe token(https://github.com/Giveth/minime), but instead of making all the snapshots for
///   every block number at which any token transfer transaction occurs, only the requested snapshots are made.
///   So this is more efficient implementation less-bloating smart contract storage.
/// @dev SnapshotableToken is ERC20/ERC223 compliant which allows more efficient and secure token transfer to smart contracts.
///   https://github.com/ethereum/EIPs/issues/20
///   https://github.com/ethereum/EIPs/issues/223

/// @dev The token controller contract must implement these functions
contract TokenController {
    /// @notice Called when `_owner` sends ether to the SnapshotableToken contract
    /// @param _owner The address that sent the ether to create tokens
    /// @return True if the ether is accepted, false if it throws
    function proxyPayment(address _owner) public payable returns(bool);

    /// @notice Notifies the controller about a token transfer allowing the
    ///  controller to react if desired
    /// @param _from The origin of the transfer
    /// @param _to The destination of the transfer
    /// @param _value The amount of the transfer
    /// @return False if the controller does not authorize the transfer
    function onTransfer(address _from, address _to, uint _value) public returns(bool);

    /// @notice Notifies the controller about an approval allowing the
    ///  controller to react if desired
    /// @param _owner The address that calls `approve()`
    /// @param _spender The spender in the `approve()` call
    /// @param _value The amount in the `approve()` call
    /// @return False if the controller does not authorize the approval
    function onApprove(address _owner, address _spender, uint _value) public returns(bool);
}

contract Controlled {

    address public controller;

    event ControllerChanged(address indexed previousController, address indexed newController);

    /// @notice The address of the controller is the only address that can call
    ///  a function with this modifier
    modifier onlyController { require(msg.sender == controller); _; }

    function Controlled() public { controller = msg.sender; }

    /// @notice Changes the controller of the contract
    /// @param _newController The new controller of the contract
    function changeController(address _newController) public onlyController {
        ControllerChanged(controller, _newController);
        controller = _newController;
    }
}

/// @dev interface for ERC223 token receiver contract
contract IERC223TokenReceiver {
    /// @dev A function to handle token transfers that is called from token contract when token holder is sending tokens.
    /// @param _from The token sender
    /// @param _value The amount of incoming tokens
    /// @param _data attached custom data similar to data in Ether transactions. works like fallback function for
    ///     Ether transactions and returns nothing.
    function tokenFallback(address _from, uint _value, bytes _data) public;
}

/// @dev The actual token contract, the default controller is the msg.sender
///  that deploys the contract, so usually this token will be deployed by a
///  token controller contract, which Giveth will call a "Campaign"
contract SnapshotableToken is Controlled {

    string public name;                //The Token's name
    uint8 public decimals;             //Number of decimals of the smallest unit
    string public symbol;              //An identifier: e.g. ASX
    string public version = 'SST_0.1'; //An arbitrary versioning scheme

    /// @dev `Checkpoint` is the structure that attaches a block number to a
    ///  given value, the block number attached is the one that last changed the value
    struct Checkpoint {
        // `blockNum` is the block number that the value was generated from
        uint128 blockNum;
        // `value` is the amount of tokens at a specific block number
        uint128 value;
    }

    ////////////////
    // Events
    ////////////////
    event Snapshot(uint256 indexed _blockNumber, uint256 indexed _data);
    //    event Transfer(address indexed _from, address indexed _to, uint256 _value) // ERC20 TODO check backward compatibility
    event Transfer(address indexed _from, address indexed _to, uint256 _value, bytes _data); // ERC223
    event Approval(address indexed _owner, address indexed _spender, uint256 _value); // ERC20
    event ClaimedTokens(address indexed _token, address indexed _controller, uint _value);
    event NewCloneToken(address indexed _cloneToken, uint _snapshotBlock);

    // `parentToken` is the Token address that was cloned to produce this token;
    //  it will be 0x0 for a token that was not cloned
    address public parentToken;

    // `parentSnapshotBlock` is the block number from the Parent Token that was
    //  used to determine the initial distribution of the Clone Token
    uint256 public parentSnapshotBlock;

    // `creationBlock` is the block number that the Clone Token was created
    uint256 public creationBlock;

    // `snapshotBlocks` is the history of the block numbers at which snapshots are made,
    // the last snapshot block number is snapshotBlocks[snapshotBlocks.length - 1]
    uint128[] public snapshotBlocks;
    uint128 lastSnapshotBlock;

    // `balances` is the map that tracks the snapshotted balances of each address
    //  balances[0] : snapshotted amounts of total supply
    mapping (address => Checkpoint[]) balances;

    // 'snapshotForLastCheckpoint' is the map holding last snapshot block numbers used to create/update the last
    // checkpoint balance of each account
    // snapshotForLastCheckpoint[0] for total supply snapshot
    mapping (address => uint128) snapshotForLastCheckpoint;

    // `allowed` tracks any extra transfer rights as in all ERC20 tokens
    mapping (address => mapping (address => uint256)) allowed;

//    // Tracks the history of the `totalSupply` of the token
//    Checkpoint[] totalSupplyHistory;

    // Flag that determines if the token is transferable or not.
    bool public transfersEnabled;

    // The factory used to create new clone tokens
    SnapshotableTokenFactory public tokenFactory;

    modifier whenTransferEnabled() {
        require(transfersEnabled);
        _;
    }

    ////////////////
    // Constructor
    ////////////////

    /// @notice Constructor to create a SnapshotableToken
    /// @param _tokenFactory The address of the SnapshotableTokenFactory contract that
    ///  will create the Clone token contracts, the token factory needs to be deployed first
    /// @param _parentToken Address of the parent token, set to 0x0 if it is a new token
    /// @param _parentSnapshotBlock Block number of the parent token that will determine
    ///   the initial distribution of the clone token, set to 0 if it is a new token
    /// @param _tokenName Name of the new token
    /// @param _decimalUnits Number of decimals of the new token
    /// @param _tokenSymbol Token Symbol for the new token
    /// @param _transfersEnabled If true, tokens will be able to be transferred
    function SnapshotableToken(
        address _tokenFactory,
        address _parentToken,
        uint256 _parentSnapshotBlock,
        string _tokenName,
        uint8 _decimalUnits,
        string _tokenSymbol,
        bool _transfersEnabled
    ) public {
        tokenFactory = SnapshotableTokenFactory(_tokenFactory);
        name = _tokenName;                                 // Set the name
        decimals = _decimalUnits;                          // Set the decimals
        symbol = _tokenSymbol;                             // Set the symbol
        if (_parentToken != 0) {
            require(SnapshotableToken(_parentToken).isSnapshotBlock(_parentSnapshotBlock));
        }
        parentToken = _parentToken;
        parentSnapshotBlock = _parentSnapshotBlock;
        lastSnapshotBlock = 0;
        transfersEnabled = _transfersEnabled;
        creationBlock = block.number;
    }

    /// @notice snapshot token distribution at current block number
    /// @return true if snapshot is successful
    function snapshot() public returns (bool success) {
        uint128 blockNum = uint128(block.number);
        require(lastSnapshotBlock < blockNum);
        snapshotBlocks[snapshotBlocks.length++] = blockNum; // appends last entry
        lastSnapshotBlock = blockNum;
        return true;
    }

    ///////////////////
    // ERC20 / ERC223 Methods
    ///////////////////

    /// @notice Send `_value` tokens to `_to` from `msg.sender`
    /// @dev ERC20 transfer function
    /// @param _to The address of the recipient
    /// @param _value The amount of tokens to be transferred
    /// @return Whether the transfer was successful or not
    function transfer(address _to, uint256 _value) whenTransferEnabled public returns (bool success) {
        return transferFromTo(msg.sender, _to, _value, "");
    }

    /// @notice Send `_value` tokens to `_to` from `msg.sender`
    /// @dev ERC223 transfer function
    /// @param _to The address of the recipient
    /// @param _value The amount of tokens to be transferred
    /// @param _data custom data can be attached to this token transaction and it will stay in blockchain forever.
    ///              _data can be empty.
    /// @return Whether the transfer was successful or not
    function transfer(address _to, uint _value, bytes _data) whenTransferEnabled public returns (bool success) {
        return transferFromTo(msg.sender, _to, _value, _data);
    }

    /// @notice Send `_value` tokens to `_to` from `_from` on the condition it
    ///  is approved by `_from`
    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _value The amount of tokens to be transferred
    /// @return True if the transfer was successful
    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {

        // The controller of this contract can move tokens around at will,
        //  this is important to recognize! Confirm that you trust the
        //  controller of this contract, which in most situations should be
        //  another open source smart contract or 0x0
        if (msg.sender != controller) {
            require(transfersEnabled);

            // The standard ERC 20 transferFrom functionality
            if (allowed[_from][msg.sender] < _value) return false;
            allowed[_from][msg.sender] -= _value;
        }
        return transferFromTo(_from, _to, _value, "");
    }

    /// @param _owner The address that's balance is being requested
    /// @return The balance of `_owner` at the current block
    function balanceOf(address _owner) public view returns (uint256 balance) {
        return balanceOfAtCheckpoint(_owner, block.number);
    }

    /// @notice `msg.sender` approves `_spender` to spend `_value` tokens on
    ///  its behalf. This is a modified version of the ERC20 approve function
    ///  to be a little bit safer
    /// @param _spender The address of the account able to transfer the tokens
    /// @param _value The amount of tokens to be approved for transfer
    /// @return True if the approval was successful
    function approve(address _spender, uint256 _value) whenTransferEnabled public returns (bool success) {
        require((_spender != 0));

        // To change the approve amount you first have to reduce the addresses`
        //  allowance to zero by calling `approve(_spender,0)` if it is not
        //  already 0 to mitigate the race condition described here:
        //  https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
        require((_value == 0) || (allowed[msg.sender][_spender] == 0));

        // Alerts the token controller of the approve function call
        if (isContract(controller)) {
            require(TokenController(controller).onApprove(msg.sender, _spender, _value));
        }

        allowed[msg.sender][_spender] = _value;
        Approval(msg.sender, _spender, _value);
        return true;
    }

    /// @dev This function makes it easy to read the `allowed[]` map
    /// @param _owner The address of the account that owns the token
    /// @param _spender The address of the account able to transfer the tokens
    /// @return Amount of remaining tokens of _owner that _spender is allowed
    ///  to spend
    function allowance(address _owner, address _spender) public view returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }

    /// @dev This function makes it easy to get the total number of tokens
    /// @return The total number of tokens
    function totalSupply() public view returns (uint256) {
        return totalSupplyAtCheckpoint(block.number);
    }

    /// @dev This is the actual transfer function in the token contract, it can only be called by other functions in this contract.
    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _value The amount of tokens to be transferred
    /// @param _data custom data being stored in Transfer event log
    /// @return True if the transfer was successful
    function transferFromTo(address _from, address _to, uint256 _value, bytes _data) internal returns (bool) {

        require((parentSnapshotBlock < block.number) && (_value != 0));

        // Do not allow transfer from/to 0x0 or the token contract itself
        require((_from != 0) && (_to != 0) && (_to != address(this)));

        // If the amount being transfered is more than the balance of the
        //  account the transfer returns false
        var previousBalanceFrom = balanceOfAtCheckpoint(_from, block.number); // guarantees that previousBalanceFrom is in unsigned 128bit range
        if (previousBalanceFrom < _value) { // guarantees that _value is in unsigned 128bit range
            return false;
        }

        // Alerts the token controller of the transfer
        if (isContract(controller)) {
            require(TokenController(controller).onTransfer(_from, _to, _value));
        }

        // First update the balance checkpoints with the new value for the address sending the tokens
        updateBalanceAtNow(_from, previousBalanceFrom - _value); // previousBalanceFrom - _value : positive 128 bit integer and no overflow

        // Then update the balance array with the new value for the address
        //  receiving the tokens
        var previousBalanceTo = balanceOfAtCheckpoint(_to, block.number); // guarantees that previousBalanceTo is in unsigned 128bit range
        uint256 newBalanceTo = add256(previousBalanceTo, _value); // can be overflowed over 128 bit
        updateBalanceAtNow(_to, newBalanceTo); // but, 128bit overflow is checked in `updateBalanceAtNow`

        if (isContract(_to)) {
            IERC223TokenReceiver receiver = IERC223TokenReceiver(_to);
            receiver.tokenFallback(_from, _value, _data); // if not a ERC223 receiver, throw
        }

        // An event to make the transfer easy to find on the blockchain
        //Transfer(_from, _to, _value); // ERC20 event log
        Transfer(_from, _to, _value, _data); // ERC223 event log
        return true;
    }

    /// @param _blockNum The block number to be checked if it is snapshotted block number
    /// @return true if the '_blockNumber' is one of the snapshotted block number
    function isSnapshotBlock(uint256 _blockNum) public view returns (bool) {
        if (snapshotBlocks.length == 0) return false;

        uint128 _block = cast128(_blockNum);

        if (_block == lastSnapshotBlock) { return true; }
        if (_block > lastSnapshotBlock || _block < snapshotBlocks[0]) {
            return false;
        }

        // Binary search of the value in the array
        uint256 min = 0;
        uint256 max = snapshotBlocks.length - 1;
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (snapshotBlocks[mid] <= _block) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return snapshotBlocks[min] == _block;
    }

    /// @notice Queries the balance of `_owner` at a specific snapshotted block number
    /// @param _owner The address from which the balance will be retrieved
    /// @param _snapshotBlockNumber The snapshotted block number at which the balance is queried
    /// @return The balance at `_snapshotBlockNumber`
    function balanceOfAtSnapshot(address _owner, uint256 _snapshotBlockNumber) public view returns (uint256) {
        require(isSnapshotBlock(_snapshotBlockNumber));
        return balanceOfAtCheckpoint(_owner, _snapshotBlockNumber);
    }

    ////////////////
    // Query balance and totalSupply in History
    ////////////////

    /// @notice Queries the checkpoint balance of `_owner` at a specific `_blockNumber`.
    ///   Only the snapshotted block numbers and recent block numbers after last snapshot are guaranteed to return correct value.
    ///   If requested `_blockNumber`
    /// @param _owner The address from which the balance will be retrieved
    /// @param _blockNum The block number when the balance is queried
    /// @return The balance at `_blockNumber`
    function balanceOfAtCheckpoint(address _owner, uint256 _blockNum) public view returns (uint256) {

        uint128 _block = cast128(_blockNum);

        // These next few lines are used when the balance of the token is
        //  requested before a check point was ever created for this token, it
        //  requires that the `parentToken.balanceOfAtCheckpoint` be queried at the
        //  genesis block for that token as this contains initial balance of
        //  this token
        if ((balances[_owner].length == 0) || (balances[_owner][0].blockNum > _block)) {
            if (parentToken != 0) {
                return SnapshotableToken(parentToken).balanceOfAtCheckpoint(_owner, min256(_blockNum, parentSnapshotBlock));
            } else {
                // Has no parent
                return 0;
            }

            // This will return the expected balance during normal situations
        } else {
            return getValueAtCheckpoint(balances[_owner], _blockNum);
        }
    }

    /// @notice Queries the total-supply value at a specific snapshotted block number
    /// @param _snapshotBlockNumber The snapshotted block number at which the total supply is queried
    /// @return The balance at `_snapshotBlockNumber`
    function totalSupplyAtSnapshot(uint256 _snapshotBlockNumber) public view returns (uint256) {
        require(isSnapshotBlock(_snapshotBlockNumber));
        return balanceOfAtCheckpoint(0, _snapshotBlockNumber);
    }

    /// @notice Queries the checkpoint total-supply value at a specific `_blockNumber`.
    ///   Only the snapshotted block numbers and recent block numbers after last snapshot are guaranteed to return correct value.
    /// @param _blockNumber The block number when the totalSupply is queried
    /// @return The total amount of tokens at `_blockNumber`
    function totalSupplyAtCheckpoint(uint256 _blockNumber) public view returns (uint256) {
        return balanceOfAtCheckpoint(0, _blockNumber);
    }

    ////////////////
    // Clone Token Method
    ////////////////

    /// @notice Creates a new clone token with the initial distribution being
    ///  this token at `_snapshotBlock`
    /// @param _cloneTokenName Name of the clone token
    /// @param _cloneDecimalUnits Number of decimals of the smallest unit
    /// @param _cloneTokenSymbol Symbol of the clone token
    /// @param _snapshotBlock Block when the distribution of the parent token is
    ///  copied to set the initial distribution of the new clone token;
    ///  if the block is zero than the actual block, the current block is used
    /// @param _transfersEnabled True if transfers are allowed in the clone
    /// @return The address of the new SnapshotableToken Contract
    function createCloneToken(
        string _cloneTokenName,
        uint8 _cloneDecimalUnits,
        string _cloneTokenSymbol,
        uint256 _snapshotBlock,
        bool _transfersEnabled
    ) public returns(address) {
        if (_snapshotBlock == 0) _snapshotBlock = block.number;
        SnapshotableToken cloneToken = tokenFactory.createCloneToken(
            this,
            _snapshotBlock,
            _cloneTokenName,
            _cloneDecimalUnits,
            _cloneTokenSymbol,
            _transfersEnabled
        );

        cloneToken.changeController(msg.sender);

        // An event to make the token easy to find on the blockchain
        NewCloneToken(address(cloneToken), _snapshotBlock);
        return address(cloneToken);
    }

    ////////////////
    // Generate and destroy tokens
    ////////////////

    /// @notice Generates `_value` tokens that are assigned to `_owner`
    /// @param _owner The address that will be assigned the new tokens
    /// @param _value The quantity of tokens generated
    /// @return True if the tokens are generated correctly
    function generateTokens(address _owner, uint256 _value) public onlyController returns (bool) {
        require(_owner != 0);
        uint256 curTotalSupply = totalSupply();
        uint256 newTotalSupply = add256(curTotalSupply, _value);
        uint256 previousBalanceTo = balanceOf(_owner);
        uint256 newBalance = add256(previousBalanceTo, _value);
        updateBalanceAtNow(0, newTotalSupply); // update total supply
        updateBalanceAtNow(_owner, newBalance);
        Transfer(0, _owner, _value, "");
        return true;
    }


    /// @notice Burns `_value` tokens from `_owner`
    /// @param _owner The address that will lose the tokens
    /// @param _value The quantity of tokens to burn
    /// @return True if the tokens are burned correctly
    function destroyTokens(address _owner, uint _value) public onlyController returns (bool) {
        require(_owner != 0);
        uint256 curTotalSupply = totalSupply();
        uint256 newTotalSupply = sub256(curTotalSupply, _value);
        uint256 previousBalanceFrom = balanceOf(_owner);
        uint256 newBalance = sub256(previousBalanceFrom, _value);
        updateBalanceAtNow(0, newTotalSupply); // update total supply
        updateBalanceAtNow(_owner, newBalance);
        Transfer(_owner, 0, _value, "");
        return true;
    }

    ////////////////
    // Enable tokens transfers
    ////////////////
    


    /// @notice Enables token holders to transfer their tokens freely if true
    /// @param _transfersEnabled True if transfers are allowed in the clone
    function enableTransfers(bool _transfersEnabled) public onlyController {
        transfersEnabled = _transfersEnabled;
    }

    ////////////////
    // Internal helper functions to query and set a value in a snapshot array
    ////////////////

    /// @dev `getValueAtCheckpoint` retrieves the number of tokens at a given block number
    ///   Only the snapshotted block numbers and recent block numbers after last snapshot are guaranteed to return correct value.
    /// @param checkpoints The history of values being queried
    /// @param _blockNum The block number to retrieve the value at
    /// @return The number of tokens being queried
    function getValueAtCheckpoint(Checkpoint[] storage checkpoints, uint256 _blockNum) view internal returns (uint256) {
        if (checkpoints.length == 0) return 0;

        uint128 _block = cast128(_blockNum);

        // Shortcut for the actual value
        if (_block >= checkpoints[checkpoints.length - 1].blockNum) {
            return checkpoints[checkpoints.length - 1].value;
        }
        if (_block < checkpoints[0].blockNum) {
            return 0;
        }

        // Binary search of the value in the array
        uint256 min = 0;
        uint256 max = checkpoints.length - 1;
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (checkpoints[mid].blockNum <= _block) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return checkpoints[min].value;
    }

    /// @dev `updateBalanceAtNow` used to update the `balances` map.
    /// @param _owner The owner account address whose balance value is being updated
    /// @param _value The new number of tokens
    function updateBalanceAtNow(address _owner, uint256 _value) internal {
        uint128 value = cast128(_value);
        Checkpoint[] storage checkpoints = balances[_owner];
        if ((checkpoints.length == 0) || (snapshotForLastCheckpoint[_owner] < lastSnapshotBlock)) {
            // new checkpoint array entry (new snapshot was made since last balance update)
            Checkpoint storage newCheckPoint = checkpoints[checkpoints.length++];
            newCheckPoint.blockNum =  uint128(block.number);
            newCheckPoint.value = value;
            snapshotForLastCheckpoint[_owner] = lastSnapshotBlock;
        } else {
            // overwrite last checkpoint
            Checkpoint storage oldCheckPoint = checkpoints[checkpoints.length - 1];
            oldCheckPoint.blockNum =  uint128(block.number);
            oldCheckPoint.value = value;
        }
    }

    /// @dev Internal function to determine if an address is a contract
    /// @param _addr The address being queried
    /// @return True if `_addr` is a contract
    function isContract(address _addr) view internal returns (bool) {
        uint size;
        if (_addr == 0) return false;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /// @notice The fallback function: If the contract's controller has not been
    ///  set to 0, then the `proxyPayment` method is called which relays the
    ///  ether and creates tokens as described in the token controller contract
    function () public payable {
        require(isContract(controller));
        require(TokenController(controller).proxyPayment.value(msg.value)(msg.sender));
    }

    //////////
    // Safety Methods
    //////////

    /// @notice This method can be used by the controller to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token) public onlyController {
        if (_token == 0x0) {
            controller.transfer(this.balance);
            return;
        }

        SnapshotableToken token = SnapshotableToken(_token);
        uint balance = token.balanceOf(this);
        token.transfer(controller, balance);
        ClaimedTokens(_token, controller, balance);
    }


    //////////
    // Safe Math Methods
    //////////
    function add256(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assert((z = x + y) >= x);
    }

    function sub256(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assert((z = x - y) <= x);
    }

    function cast128(uint256 x) internal pure returns (uint128 z) {
        assert((z = uint128(x)) == x);
    }

    /// @dev Helper function to return a min between the two uints
    function min256(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return x <= y ? x : y;
    }
}


////////////////
// SnapshotableTokenFactory
////////////////

/// @dev This contract is used to generate clone contracts from a contract.
///  In solidity this is the way to create a contract from a contract of the
///  same class
contract SnapshotableTokenFactory {

    /// @notice Update the DApp by creating a new token with new functionalities
    ///  the msg.sender becomes the controller of this clone token
    /// @param _parentToken Address of the token being cloned
    /// @param _snapshotBlock Block of the parent token that will
    ///  determine the initial distribution of the clone token
    /// @param _tokenName Name of the new token
    /// @param _decimalUnits Number of decimals of the new token
    /// @param _tokenSymbol Token Symbol for the new token
    /// @param _transfersEnabled If true, tokens will be able to be transferred
    /// @return The address of the new token contract
    function createCloneToken(
        address _parentToken,
        uint _snapshotBlock,
        string _tokenName,
        uint8 _decimalUnits,
        string _tokenSymbol,
        bool _transfersEnabled
    ) public returns (SnapshotableToken) {
        SnapshotableToken newToken = new SnapshotableToken(
            this,
            _parentToken,
            _snapshotBlock,
            _tokenName,
            _decimalUnits,
            _tokenSymbol,
            _transfersEnabled
        );

        newToken.changeController(msg.sender);
        return newToken;
    }
}