// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
//0xed697E3f843c196c8c008813D970f24f6DcEB13a
//0x70fcD38091e4a56C9568934B52F59cBCadc48c30
//0x
// Transparent proxy contract for QuailFinance
contract QuailFinanceProxy is TransparentUpgradeableProxy {
    constructor(address _logic, address admin, bytes memory _data) 
        TransparentUpgradeableProxy(_logic, admin, _data) 
    {
    }
}