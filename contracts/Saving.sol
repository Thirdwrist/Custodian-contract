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
    *   7. 
    */

    using SafeMath for uint256;

    struct Ward {
        uint amount;
        bool locked; 
        uint expiry;
        address[] subCustodians;
        uint subCustodianApprovalCount;
    }

    struct Custodian {
        uint amount;
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
        uint256 blockId;
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
    modifier onlyOnExpiration(address _ward){
        require(block.timestamp >= custodians[msg.sender].wards[_ward].expiry, 'Release date of custody not reached or passed yet' ); 
        _;
    }

    modifier wardAmtNotEmpty(address _ward){
        require(custodians[msg.sender].wards[_ward].amount > 0, 'There is nothing to send to the ward');
        _;
    }

    modifier wardExists(address _ward)
    {   
        require(!wards[_ward][msg.sender], 'Ward exists already');
        _;
    }

    modifier wardNotExist(address _ward) {
         require(wards[_ward][msg.sender] !=true, 'Ward does not exist');
         _;
    }

    modifier noValue(){
        require(msg.value > 0, 'You have to deposit eth to this ward');
        _;
    }

    //@dev This creates a ward which is then locked add appropraite updated. 
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
            _expiry > (uint256(86400).mul(7).add(block.timestamp)), 
            'The expiry date must be more than 7 days in the future, if not the funds will be locked forever'
        );

        // expiry reset to the start of the day 
        uint256 _expiryStartOfDay = _setLockDate(_expiry); 

        // create a new ward
         Ward memory newWard = Ward({
             amount: msg.value,
             locked: true,
             expiry: _expiryStartOfDay, 
             subCustodians: _subCustodians, 
             subCustodianApprovalCount: _subCustodianApprovalCount

         });
       
        // existing custodian
        if(custodians[msg.sender].wardCount > 0){
            custodians[msg.sender].wards[_ward] = newWard;
            custodians[msg.sender].lockedAmount += newWard.amount;
            ++custodians[msg.sender].wardCount; 

        }else{
            // new custodian
            Custodian storage _custodian = custodians[msg.sender];
            _custodian.amount = 0;
            _custodian.wardCount = 1;
            _custodian.lockedAmount = newWard.amount;
            _custodian.wards[_ward] = newWard; 
        }

        // add to ExpirationlockedIds
        uint256 lockIdKey = _setLockDate(_expiry);
        LockId memory _lockId = LockId({
            custodian: msg.sender,
            ward: _ward
        });

        // existing lock release date
        if(custodyExpirations[lockIdKey].status == CustodyExpirationStatus.Pending)
        {
            custodyExpirations[lockIdKey].locks.push(_lockId);
        }
        else{

            // new lock release date
            CustodyExpiration storage _expiration = custodyExpirations[lockIdKey];
            _expiration.status = CustodyExpirationStatus.Pending;
            _expiration.locks.push(LockId({
               custodian: msg.sender,
               ward: _ward
            }));
        }

        // matching wards to thier custodians for ease
        wards[_ward][msg.sender] = true;        

        // emit ward created event
        emit wardCreated(msg.sender, _ward,newWard.amount, _expiry);
    }

    function depositIntoWard(address _ward) payable public  noValue(){
        require(wards[_ward][msg.sender]== true, 'You do not have this address as a ward');
        custodians[msg.sender].wards[_ward].amount += msg.value;
        emit deposit(_ward, 'ward', msg.value);
    }
    //@dev This function makes sure that the expiry date is at the begining of the day
    function _setLockDate(uint256 _expiry) private pure returns (uint256 expiry){
        expiry = _expiry.mod(36400);
        expiry = expiry !=0 ? _expiry.sub(expiry): expiry;
    }

    //@dev get the amount locked against ward
    function getBalanceAsCus(address _ward) public view returns(uint256){
        require(wards[_ward][msg.sender], 'This is address is not your ward');
        return custodians[msg.sender].wards[_ward].amount;
    }

    //@dev ward can check the amount locked against his name
    function getBalanceAsWard(address _custodian) public view returns(uint256){
        require(wards[msg.sender][_custodian], 'This address is not one of your Custodians');
        return custodians[_custodian].wards[msg.sender].amount;
    }

    //@dev function that is hit by a keeper to Release the fund to the ward at the expiry 
    //@dev time specified at lock, also a certian percent should be sent to a wallet for housekeeping, (1%)
    function releaseLock()  public {

    }

    function getCusBalance() public view returns(uint){
        return custodians[msg.sender].amount;
    }

    function getCusWardCount() public view returns(uint){
        return custodians[msg.sender].wardCount;
    }

    function getCusLockedAmount() public view returns(uint){
        return custodians[msg.sender].lockedAmount;
    }

    function getContractBalance() public view returns(uint256)
    {
        return address(this).balance;
    }

    function getWardBalance(address _ward) public wardNotExist(_ward) view returns(uint256)
    {
        return custodians[msg.sender].wards[_ward].amount;
    }
    
    function getLockForToday() view public returns(uint)
    {
       uint256 _expiration=  _setLockDate(block.timestamp);
       return custodyExpirations[_expiration].locks.length;
    }

}