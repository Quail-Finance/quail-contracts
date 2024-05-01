require('dotenv').config();
const { ethers } = require("ethers");

const implementationAddress = "0x65E63b7f76b5e3BAC8b74199e846CC86f8536222";
const adminAddress = "0x9A856fcB5d7F33d19BEa7B6B63e61Ed248eeEE56";

// Replace these with the actual addresses you want to use
const entropyAddress = "0x98046Bd286715D3B0BC227Dd7a956b83D8978603";
const entropyProviderAddress = "0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344";
const adminSignerAddress = "0xE4860D3973802C7C42450D7b9741921C7711D039";

const initData = ethers.utils.defaultAbiCoder.encode(
    ["address", "address", "address"],
    [entropyAddress, entropyProviderAddress, adminSignerAddress]
);
// Assuming you're using Hardhat
async function main() {
    const privateKey = process.env.PRIV_KEY;
    if (!privateKey) {
        throw new Error("Private key not found in environment variables");
    }
    const rpcUrl = "https://sepolia.blast.io"; // Sepolia testnet URL
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);

    // Create a wallet from the private key and connect your provider to it
    const wallet = new ethers.Wallet(privateKey, provider);
    const TransparentUpgradeableProxy = await ethers.getContractFactory("TransparentUpgradeableProxy");
    const proxy = await TransparentUpgradeableProxy.deploy(
        implementationAddress,
        adminAddress,
        initData
    );

    console.log("Proxy deployed to:", proxy.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
