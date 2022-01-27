// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

contract Saving{ 

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
    struct LockIds{
        address custodian;
        address ward;
    }

    constructor() payable {}

    mapping(address => Custodian ) public custodians;
    /*
    * for easy identification of wards and thier custodians 
    *   wardAdress => Custodians adresses
    */
    mapping(address => mapping(address => bool )) public wards;
    /**
        * Where all the custody expirations are stored 
        * for oracle keepers to call on expiry 
     */
    mapping( uint => LockIds[])  public custodyExpiration;

    event wardCreated(address indexed custodian, address indexed ward, uint expiry);
    event custodyExpired(address indexed custodian, address indexed ward, string expiry);
    event deposit(address indexed account, string accountType, uint amount);
    event withdraw(address indexed account, string accountType, uint amount);

    modifier onlyOnExpiration(address _ward){
        require(block.timestamp >= custodians[msg.sender].wards[_ward].expiry, 'Release date of custody not reached or passed yet' ); 
        _;
    }

    modifier onlyOnLock(address _ward){
        require(custodians[msg.sender].wards[_ward].locked, 'The wards account must be under lock to be released');
        _;
    }
    modifier wardAmountNotEmpty(address _ward){
        require(custodians[msg.sender].wards[_ward].amount > 0, 'There is nothing to send to the ward');
        _;
    }
    modifier onlyCustodian() {
        require(custodians[msg.sender].wardCount != 0, 'You must be a custodian to take this action');
        _;
    }

    modifier wardExists(address _ward)
    {
        // if(custodians[msg.sender].wardCount != 0)
        //     require(custodians[msg.sender].wards[_ward].amount == 0, 'This ward exist under this custodian already');
        // _;
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

    ///@dev This creates a ward which is then locked add appropraite updated. 
    function createWard(
        address payable _ward, 
        uint _expiry, 
        address[] memory _subCustodians, 
        uint _subCustodianApprovalCount
    ) public payable wardExists(_ward) noValue()
    {
        // Create a new ward
         Ward memory newWard = Ward({
             amount: msg.value,
             locked: true,
             expiry: _expiry, 
             subCustodians: _subCustodians, 
             subCustodianApprovalCount: _subCustodianApprovalCount

         });
       
        // if custodian exists and has an existing ward
        if(custodians[msg.sender].wardCount > 0){
            custodians[msg.sender].wards[_ward] = newWard;
            custodians[msg.sender].lockedAmount += newWard.amount;
            ++custodians[msg.sender].wardCount; 

        }else{
            // Custodian does not exists 
            Custodian storage _custodian = custodians[msg.sender];
            _custodian.amount = 0;
            _custodian.wardCount = 1;
            _custodian.lockedAmount = newWard.amount;
            _custodian.wards[_ward] = newWard; 
        }

        wards[_ward][msg.sender] = true;        

        emit wardCreated(msg.sender, _ward, _expiry);
    }

    function depositIntoWard(address _ward) payable public  noValue(){
        require(wards[_ward][msg.sender]== true, 'You do not have this address as a ward');
        custodians[msg.sender].wards[_ward].amount += msg.value;
        emit deposit(_ward, 'ward', msg.value);
    }

    function getBalanceAsCus(address _ward) public view returns(uint256){
        require(wards[_ward][msg.sender], 'This is address is not your ward');
        return custodians[msg.sender].wards[_ward].amount;
    }

    function getBalanceAsWard(address _custodian) public view returns(uint256){
        require(wards[msg.sender][_custodian], 'This address is not one of your Custodians');
        return custodians[_custodian].wards[msg.sender].amount;
    }

    //@dev function that is hit by a keeper to Release the fund to the ward at the expiry 
    //@dev time specified at lock, also a certian percent should be sent to a wallet for housekeeping, 1%
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

}