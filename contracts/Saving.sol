// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
contract Saving{  

    /**
    *TODO
    *   1. Insert release days for locks
    *   2. Inform an address that an amount was locked against its account. 
    *       i. This sends a signed message to this address without a value included in the transaction
    *   3. Move day literal (36400) into constant
    *   4. Add Chainlink oracle 
    *   5. A certain percent should be left after lock release 
    *   6. Store total; amount, wards, custodians and released funds in contract. 
    *   7. Chabge format to pull over push for dispencing funds
    */

    using SafeMath for uint256;

    mapping (address => uint256 ) redemptions;

    struct Ward {
        uint amount;
        bool locked; 
        uint expiry;
        address[] subCustodians;
        uint subCustodianApprovalCount;
    }

    /** @TODO
    *   Remove the amount here, the house will pay for any gas required
    *  also since implementatiion has shifted to pull over push no gas needed to remit to wards
    **/
    
    struct Custodian {
        uint wardCount;
        uint lockedAmount;
        mapping(address => Ward) wards;
    }

    struct LockId{ 
        address custodian;
        address ward;
    }

    struct CustodyExpiration{
        LockId[] locks;
        CustodyExpirationStatus status;
    }

    enum CustodyExpirationStatus {
        Default,
        Pending,
        Executed 
    }

    mapping(address => Custodian ) public custodians;

    //@dev For easy identification of wards and thier custodians
    //@dev wardAdress => Custodians adresses
    mapping(address => mapping(address => bool )) public wards;

    //@dev Where all the custody expirations are stored
    //@dev keys = block.timestamp - (block.timestamp /x/ 86400 );
    //@dev only start of day is used as a key
    mapping( uint256 => CustodyExpiration )  public custodyExpirations;

    /*
        *
        ***** Events ******
        *
     */ 
    event wardCreated(address indexed custodian, address indexed ward, uint256 amount, uint expiry);
    event custodyExpired(address indexed custodian, address indexed ward, uint256 amount, string expiry);
    event deposit(address indexed account, string accountType, uint256 amount);
    event withdraw(address indexed account, string accountType, uint256 amount);

    /*
        *
        ***** Modifiers ******
        *
     */    
    modifier wardExists(address _ward)
    {   
        require(!wards[_ward][msg.sender], 'Ward exists already');
        _;
    }

    modifier noValue(){
        require(msg.value > 0, 'You have to deposit eth to this ward');
        _;
    }

    //@dev This creates a ward which is then locked and appropraitely updated. 
    function createWard(
        address payable _ward, 
        uint256 _expiry, 
        address[] memory _subCustodians, 
        uint _subCustodianApprovalCount
    ) public payable wardExists(_ward) noValue()
    {
        require(
            _subCustodians.length >= _subCustodianApprovalCount, 
            'Custodian approval should be equal or lower than available custodians'
        );
        require(
            _expiry >= 1 weeks, 
            'The expiry date must be more than 7 days in the future, if not the funds will be locked forever'
        );

        // expiry reset to the start of the day 
        uint256 _expiryStartOfDay = _setLockDate(_expiry); 
       
         // new custodian ward
        Custodian storage _custodian = custodians[msg.sender];
        ++_custodian.wardCount;
        _custodian.lockedAmount += msg.value;
        _custodian.wards[_ward] = Ward({
             amount: msg.value,
             locked: true,
             expiry: _expiryStartOfDay, 
             subCustodians: _subCustodians, 
             subCustodianApprovalCount: _subCustodianApprovalCount

         });

        // new lock release date
        CustodyExpiration storage _expiration = custodyExpirations[_expiryStartOfDay];
        _expiration.status = CustodyExpirationStatus.Pending;
        _expiration.locks.push(LockId({
            custodian: msg.sender,
            ward: _ward
        }));

        // matching wards to thier custodians for ease
        wards[_ward][msg.sender] = true;        

        // emit ward created event
        emit wardCreated(msg.sender, _ward,msg.value, _expiry);
    }

    function depositIntoWard(address _ward) payable public  noValue(){
        require(wards[_ward][msg.sender], 'You do not have this address as a ward');
        require(custodians[msg.sender].wards[_ward].locked, 'This ward has to be under lock to recieve deposit');
        require(
          custodians[msg.sender].wards[_ward].expiry >= block.timestamp + 2 days, 
          'Can not deposit two days within lock expiry'
        );
        
        custodians[msg.sender].wards[_ward].amount += msg.value;
        custodians[msg.sender].lockedAmount += msg.value;

        emit deposit(_ward, 'ward', msg.value);
    }
    //@dev This function makes sure that the expiry date is at the begining of the day
    function _setLockDate(uint256 _expiry) private pure returns (uint256 expiry){
        expiry = _expiry.mod(36400);
        expiry = expiry !=0 ? _expiry.sub(expiry): expiry;
    }

    function _releaseLock(address _custodian, address _ward) private {
        Ward storage ward  = custodians[_custodian].wards[_ward];
        redemptions[_ward] += ward.amount;
        ward.locked = false;
        custodians[_custodian].lockedAmount -= ward.amount;
        ward.amount = 0;
    }

    //@dev get the amount locked against ward
    function getBalanceOfWard(address _ward, address _custodian) public view returns(uint256){
        require(wards[_ward][_custodian], 'This match does not exist');
        return custodians[_custodian].wards[_ward].amount;
    }

    function getCustodianWardCount(address _custodian) public view returns(uint){
        require(custodians[_custodian].wardCount > 0, 'This custodian does not exist');
        return custodians[msg.sender].wardCount;
    }

    function getCusLockedAmount(address _custodian) public view returns(uint){
        require(custodians[_custodian].wardCount > 0, 'This custodian does not exist');
        return custodians[msg.sender].lockedAmount;
    }

    function getContractBalance() public view returns(uint256)
    {
        return address(this).balance;
    }
    
    function getLockForToday() view public returns(uint)
    {
       uint256 _expiration=  _setLockDate(block.timestamp);
       return custodyExpirations[_expiration].locks.length;
    }

    //@dev function that is hit by a keeper to Release the fund to the ward at the expiry 
    //@dev time specified at lock, also a certian percent should be sent to a wallet for housekeeping, (1%)
    function releaseLock()  public {

    }

}