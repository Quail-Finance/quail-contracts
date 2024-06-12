// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
//0x98046Bd286715D3B0BC227Dd7a956b83D8978603
//0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344
//0xE4860D3973802C7C42450D7b9741921C7711D039

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IERC20Rebasing.sol";
import "./IBlast.sol";
import "./IBlastPoints.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
contract QuailFinance is Initializable, OwnableUpgradeable {
    IEntropy private entropy;
    address private entropyProvider;
    address public admin;
    using ECDSA for bytes32;
    bytes32 public merkleRoot; // The Merkle Root representing all valid claims
    uint256 private nextPotId = 1; // Start pot IDs at 1
    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);
    uint256 public totalRevenue;
    uint256 public potCreationFee;
    uint256 public totalYielDeposited;
    IERC20 public usdbToken; // USDC token interface
    address payable public recipient;
    mapping(address => bool) public userCreated;
    mapping(address => uint256) public hasClaimed;
    mapping(uint256 => Pot) public pots;
    // Additional mapping to track earned yield per user
    mapping(address => uint256) private userYield;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasJoinedPot;
    /*
    * Represents the structure of a pot within Quail Finance.
    * Each pot allows participants to deposit USDB tokens, which are then rotated or distributed based on the pot's configuration.
    * 
    * Fields:
    * - amount: The fixed amount of USDB tokens required from each participant to join the pot. This ensures uniform contributions from all participants.
    * - rotationCycleInSeconds: The duration in seconds between each rotation.
    * - lastRotationTime: Timestamp of the last rotation, used to calculate the next eligible rotation time.
    * - interestNumerator and interestDenominator: Parts of the fractional interest rate for risk calculations. 
    *   The actual interest rate is derived from interestNumerator / interestDenominator.
    * - numParticipants: The total number of participants allowed in the pot. This limit is set at pot creation.
    * - currentRound: Tracks the current round of the pot, incrementing after each rotation. It represents the progression through the pot's lifecycle.
    * - potCreator: The address of the user who created the pot, who may have special privileges, such as initiating rotations.
    * - participants: A dynamic array of addresses representing participants who have joined the pot.
    *
    * The `rotationCycleInSeconds` determines the frequency of rotations, enabling dynamic adjustment of the pot's rotation schedule. The `currentRound` is incremented after each rotation, serving as a counter for the total number of rotations, which is essential for calculating and distributing the pot's funds, including the handling of the risk pool towards the end of the pot's lifecycle.
    */
    struct Pot {
        string name;
        uint256 amount;
        uint256 totalDepositedAmount;
        uint256 riskPoolBalance;
        uint256 useRiskPoolBalance;
        uint256 rotationCycleInSeconds;
        uint256 lastRotationTime;
        uint256 interestNumerator;
        uint256 interestDenominator;
        uint256 numParticipants;
        uint256 currentRound;
        uint64 sequenceNumber;
        address potCreator;
        address[] participants;
        address[] winners;
        mapping(address => uint256) amountWon; // Mapping to store amount won by each winner
        mapping(address => bool) hasWon;
    }

    // Events
    event PotCreated(uint256 potId, string name, address creator, uint256 amount, uint256 rotationCycleInSeconds, uint256 _interestDenominator, uint256 _interestNumerator, uint256 _numParticipants, uint64 sequenceNumber, bytes32 userCommitment);
    event ParticipantJoined(uint256 potId, string name, address participant, uint256 amount, uint256 rotationCycleInSeconds, uint256 _interestDenominator, uint256 _interestNumerator, uint256 _numParticipants);
    event ParticipantRemoved(uint256 potId, address participant);
    event RotationCompleted(uint256 potId, address winner, uint256 round, uint64 sequenceNumber,bytes32 userCommitment, uint256 usedRiskPoolBalance, uint256 amount);
    event RewardClaimed(uint256 potId, address winner, uint256 amount);
    event UserCreated(address user);

    IERC20Rebasing public constant USDB = IERC20Rebasing(0x4300000000000000000000000000000000000003);
    function initialize(address _entropy) public initializer {
    // constructor(address _entropy, address _entropyProvider, address adminSigner) Ownable(msg.sender){
        __Ownable_init(msg.sender);
        USDB.configure(YieldMode.CLAIMABLE); //configure claimable yield for USDB
        usdbToken = IERC20(0x4300000000000000000000000000000000000003);
        // To do change operator address while going to mainnet
        IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800).configurePointsOperator(0xE4860D3973802C7C42450D7b9741921C7711D039);
        //0x98046Bd286715D3B0BC227Dd7a956b83D8978603
        //0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344
        //0xE4860D3973802C7C42450D7b9741921C7711D039
        entropy = IEntropy(_entropy);
        entropyProvider = 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506;
        admin = 0xE4860D3973802C7C42450D7b9741921C7711D039;
        potCreationFee = 1000000000000000;
	}
    /*
    * Create a new Quail Pot
    * Allows users to create a new pot within Quail Finance, specifying parameters such as pot name, rotation cycle duration,
    * interest rates, number of participants, and initial deposit amount. The creator must deposit an initial usdb for pot creation.
    * Upon successful creation, emits a PotCreated event containing details of the newly created pot.
    * Parameters:
    * - _name: The name or identifier for the pot.
    * - userCommitment: Commitment generated by the admin for entropy.
    * - _rotationCycleInSeconds: The duration in seconds between each rotation.
    * - _interestDenominator: The denominator for the fractional interest rate.
    * - _interestNumerator: The numerator for the fractional interest rate.
    * - _numParticipants: The total number of participants allowed in the pot.
    * - _amount: The initial deposit amount required from the creator.
    * Modifiers:
    *Payable: Requires the sender to attach a fee for entropy generation to the Pyth network.
    */
    function createPot(string memory _name, bytes32 userCommitment, uint256 _rotationCycleInSeconds, uint256 _interestDenominator, uint256 _interestNumerator, uint256 _numParticipants, uint256 _amount) public payable {
        uint256 fee = entropy.getFee(entropyProvider);
        require(msg.value == fee+potCreationFee, "Insufficient fee");

        require(_rotationCycleInSeconds > 0, "Rotation cycle must be positive");
        require(_interestDenominator > 0, "Interest denominator must be positive");
        require(_interestNumerator <= _interestDenominator, "Numerator must be less than or equal to denominator");
        require(_amount > 0, "Deposit amount must be greater than zero");
        uint256 potId = nextPotId++;
        require(usdbToken.transferFrom(msg.sender, address(this), _amount), "Creator should deposit the initial amount");
        uint64 sequenceNumber = entropy.request{value: fee}(
            entropyProvider,
            userCommitment,
            false
        );
        // Assign values individually
        Pot storage newPot = pots[potId];
        newPot.name = _name;
        newPot.amount = _amount;
        newPot.riskPoolBalance = 0;
        newPot.sequenceNumber = sequenceNumber;
        newPot.potCreator = msg.sender;
        newPot.rotationCycleInSeconds = _rotationCycleInSeconds;
        newPot.interestNumerator = _interestNumerator;
        newPot.interestDenominator = _interestDenominator;
        newPot.lastRotationTime = block.timestamp;
        newPot.numParticipants = _numParticipants;
        newPot.currentRound = 1;
        newPot.totalDepositedAmount = _amount;
        newPot.participants.push(msg.sender);
        hasJoinedPot[potId][newPot.currentRound][msg.sender] = true;
        emit PotCreated(potId, _name, msg.sender, _amount, _rotationCycleInSeconds, _interestNumerator, _interestDenominator,_numParticipants,sequenceNumber,userCommitment);
        emit ParticipantJoined(potId, _name, msg.sender, _amount, _rotationCycleInSeconds, _interestNumerator, _interestDenominator, _numParticipants);
    }

    /*
    * Join a Quail Pot
    * Allows users to join an existing pot within Quail Finance by providing a valid signature and nonce for authentication.
    * Participants must transfer the required amount of USDB tokens to the pot's contract address upon joining.
    * If the participant has not yet won in the pot, they are added to the list of participants.
    * Emits a ParticipantJoined event upon successful participation.
    * Parameters:
    * - _potId: The ID of the pot to join.
    * - signature: Signature for authentication of the join request.
    * - nonce: Nonce used for generating the message hash for signature verification.
    */
    function joinPot(uint256 _potId, bytes memory signature, uint256 nonce) external {
        Pot storage pot = pots[_potId];
        require(pot.participants.length < pot.numParticipants, "Pot is full");
        require(!hasJoinedPot[_potId][pot.currentRound][msg.sender], "You have already joined this pot in the current round");
        bytes32 messageHash = keccak256(abi.encodePacked(_potId, msg.sender, pot.currentRound, nonce));
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);
        require(admin == ethSignedMessageHash.recover(signature), "Signature verification failed");
        hasJoinedPot[_potId][pot.currentRound][msg.sender] = true;
        pot.totalDepositedAmount +=pot.amount;
        // Transfer usdb to the contract
        require(usdbToken.transferFrom(msg.sender, address(this), pot.amount), "Transfer failed");
        if (!pot.hasWon[msg.sender]){
            pot.participants.push(msg.sender);
        }
        emit ParticipantJoined(_potId, pot.name, msg.sender, pot.amount, pot.rotationCycleInSeconds, pot.interestNumerator, pot.interestDenominator, pot.numParticipants);
    }

    /*
    * Rotate liquidity turn-by-turn
    * Allows the pot creator / public to rotate liquidity within the pot, determining the winner of the current round.
    * The rotation occurs at intervals specified by the rotation cycle duration.
    * The pot creator must provide valid random numbers (userRandom and providerRandom) generated from Pyth's entropy.
    * The winner is chosen randomly among the participants using the generated random number.
    * The winner receives the pot's funds after deducting the risk pool and revenue amount.
    * If the winner is not the last participant, their position in the participants' list is swapped with the last participant.
    * Emits a RotationCompleted event upon successful rotation.
    *
    * Parameters:
    * - _potId: The ID of the pot to rotate liquidity.
    * - userRandom: Random number generated by the admin for entropy.
    * - providerRandom: Random number provided by the entropy provider (Pyth).
    */
    function rotateLiquidity(uint256 _potId, bytes32 userCommitment, bytes32 userRandom, bytes32 providerRandom) external payable  {
        Pot storage pot = pots[_potId];
        require(pot.totalDepositedAmount > 0, "Total deposited amount must be greater than zero"); // Ensure total deposited amount is greater than zero
        // this is temporary fix
        // require(block.timestamp >= pot.lastRotationTime + pot.rotationCycleInSeconds || pot.numParticipants == pot.participants.length+pot.winners.length, "Next rotation not yet due");
        require(block.timestamp >= pot.lastRotationTime + pot.rotationCycleInSeconds, "Next rotation not yet due");
        bytes32 randomNumber = entropy.reveal(entropyProvider, pot.sequenceNumber, userRandom, providerRandom);
        uint256 winnerIndex = uint256(randomNumber) % pot.participants.length;
        address winner = pot.participants[winnerIndex];
        pot.winners.push(winner);
        // Transfer usdb to the winner. This will deduct the risk percentage amount set by the creator
        uint256 amountAfterRevenue = deductRevenue(pot.totalDepositedAmount);
        // To-do check risk pool integration
        uint256 riskPoolBalance = calculateRiskPoolBalance(_potId,amountAfterRevenue);
        uint256 currentlyUsingRiskPoolBalance = pot.useRiskPoolBalance;
        uint256 totalWinningAmount = (amountAfterRevenue-riskPoolBalance)+currentlyUsingRiskPoolBalance;
        pot.amountWon[winner] = totalWinningAmount;
        pot.riskPoolBalance += riskPoolBalance;
        pot.useRiskPoolBalance = 0;
        pot.hasWon[winner] = true;
        pot.lastRotationTime = block.timestamp;
        uint256 fee = entropy.getFee(entropyProvider);
        require(msg.value == fee, "Insufficient fee");
        uint64 sequenceNumber = entropy.request{value: fee}(
            entropyProvider,
            userCommitment,
            false
        );
        pot.sequenceNumber = sequenceNumber;
        emit RotationCompleted(_potId, winner, pot.currentRound, sequenceNumber,userCommitment,currentlyUsingRiskPoolBalance,totalWinningAmount);
         // Increment round only if there are participants left
        if (pot.participants.length > 0) {
            pot.currentRound++;
        }
        pot.totalDepositedAmount = 0;
        delete pot.participants;
    }
    /*
    * Use Risk Pool
    * Allows the pot creator or an authorized signer to use funds from the risk pool to supplement the winner's prize amount.
    * Parameters:
    * - _potId: The ID of the pot where the risk pool funds will be used.
    * - _amount: The amount of USDB tokens to be used from the risk pool.
    * - signature: Signature for authentication of the risk pool usage request.
    * - nonce: Nonce used for generating the message hash for signature verification.
    */
    function useRiskPool(uint256 _potId, uint256 _amount, bytes memory signature, uint256 nonce) public {
        Pot storage pot = pots[_potId];
        bytes32 messageHash = keccak256(abi.encodePacked(_potId, msg.sender, _amount, nonce));
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);
        require(admin == ethSignedMessageHash.recover(signature), "Signature verification failed");
        require(pot.riskPoolBalance >= _amount, "amount should be less than or equal to risk pool balance");
        pot.useRiskPoolBalance = _amount;
        pot.riskPoolBalance  -= _amount;
    }

    function withdrawFromPot(uint256 _potId, uint256 _index, bool _isWinner) public{
        Pot storage pot = pots[_potId];
        require(hasJoinedPot[_potId][pot.currentRound][msg.sender], "You have not joined this pot");
        require((_isWinner && _index < pot.winners.length) || (!_isWinner && _index < pot.participants.length), "Invalid index for participants");
        if (_isWinner) {
            if (_index != pot.winners.length - 1) {
                pot.winners[_index] = pot.winners[pot.winners.length - 1];
            }
            pot.winners.pop();
        } else {
            if (_index != pot.participants.length - 1) {
                pot.participants[_index] = pot.participants[pot.participants.length - 1];
            }
            pot.participants.pop();
        }
        // to do audit 
        require(usdbToken.transfer(msg.sender, pot.amount), "Transfer failed");
        hasJoinedPot[_potId][pot.currentRound][msg.sender] = false;
        emit ParticipantRemoved(_potId, msg.sender);
    }
    function claimReward(uint256 _potId) external {
        Pot storage pot = pots[_potId];
        require(pot.amountWon[msg.sender] > 0, "No reward to claim");

        // Transfer the amount won to the winner
        uint256 amountToClaim = pot.amountWon[msg.sender];
        // Clear the amount won for the winner
        pot.amountWon[msg.sender] = 0;
        require(usdbToken.transfer(msg.sender, amountToClaim), "Transfer failed");
        emit RewardClaimed(_potId,msg.sender,amountToClaim);
    }

    // Function to calculate interest for a given amount
    function calculateRiskPoolBalance(uint256 _potId, uint256 _amount) public view returns (uint256) {
        Pot storage pot = pots[_potId];
        return _amount * pot.interestNumerator / pot.interestDenominator;
    }

    function deductRevenue(uint256 _amount) private returns (uint256 netAmount) {
        uint256 revenue = _amount / 100;
        netAmount = _amount - revenue;
        totalRevenue += revenue;
        return (netAmount);
    }

    function withdrawRevenue(bool _isUsdb) external onlyOwner {
        // Transfer the revenueAmount to the owner's address or a specified wallet
        if (_isUsdb){
            uint256 revenueAmount = totalRevenue;
            require(revenueAmount > 0, "No revenue to withdraw");
            totalRevenue = 0; // Reset totalRevenue to zero
            require(usdbToken.transfer(msg.sender, revenueAmount), "Transfer failed");
        }
        else {
            payable(msg.sender).transfer(address(this).balance);
        }
    }

    function sendEther() external payable {
        require(!userCreated[msg.sender], "You have already deposited");
        require(msg.value == 0.005 ether, "Please deposit exactly 0.005 ETH");
        recipient.transfer(msg.value);
        userCreated[msg.sender] = true;
        emit UserCreated(msg.sender);
    }

    function setRecipient(address payable _recipient) external onlyOwner {
        recipient = _recipient;
    }
    function configureGas() external onlyOwner{
        BLAST.configureClaimableGas();
    }
    // Function to claim gas
    function claimMyContractsGas() external onlyOwner{
        BLAST.claimAllGas(address(this), msg.sender);
    }

    // function claimAllYield() external onlyOwner {
	// 	BLAST.claim(recipient, USDB.getClaimableAmount(address(this)));
    // }

    function setMerkleRoot(bytes32 _merkleRoot, uint256 _amount) external onlyOwner payable{
        merkleRoot = _merkleRoot;
        payable(msg.sender).transfer(_amount);
        totalYielDeposited += _amount;
    }

    function changeAdminSigner(address newAdmin) external onlyOwner{
        admin = newAdmin;
    }

    function updatePotCreationFee(uint256 _amount) external onlyOwner{
        potCreationFee = _amount;
    }

    function claimFunds(uint256 claimAmount, bytes32[] calldata merkleProof) external {
        // Verify the Merkle Proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, claimAmount));
        require(MerkleProof.verify(merkleProof, merkleRoot, leaf), "Invalid proof.");
        uint256 alreadyClaimed = hasClaimed[msg.sender];
        require(alreadyClaimed < claimAmount, "No funds left to claim or already claimed.");
        uint256 claimableAmount = claimAmount - alreadyClaimed;
        require(totalYielDeposited >= claimableAmount, "No funds in the vault");
        // Update the claimed amount
        hasClaimed[msg.sender] = claimAmount;
        totalYielDeposited -= claimableAmount;
        // Handle the fund transfer logic here
        require(usdbToken.transfer(msg.sender, claimableAmount), "Yield transfer failed");
    }

    function getEthSignedMessageHash(bytes32 _messageHash)
        public
        pure
        returns (bytes32)
    {
        /*
        Signature is produced by signing a keccak256 hash with the following format:
        "\x19Ethereum Signed Message\n" + len(msg) + msg
        */
        return keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", _messageHash)
        );
    }

    function getEntropyFee() public view returns (uint256 fee) {
        fee = entropy.getFee(entropyProvider);
    }

     function getParticipantIndex(uint256 _potId, address participant) public view returns (uint256) {
        Pot storage pot = pots[_potId];
        for (uint256 i = 0; i < pot.participants.length; i++) {
            if (pot.participants[i] == participant) {
                return i;
            }
        }
        revert("Participant not found");
    }
    function getRiskPoolBalance(uint256 potId) public view returns (uint256 riskPoolBalance) {
        Pot storage pot = pots[potId];
        riskPoolBalance =  pot.riskPoolBalance;
        return riskPoolBalance;
    }
}
