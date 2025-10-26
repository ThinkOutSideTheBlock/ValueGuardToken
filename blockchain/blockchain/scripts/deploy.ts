import { ethers } from "hardhat";
import { Contract } from "ethers";

async function main() {
  console.log(" Starting SHIELD Protocol Deployment...\n");

  const [deployer] = await ethers.getSigners();
  console.log(" Deploying from address:", deployer.address);
  console.log(" Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // NETWORK CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════════════
  
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  
  console.log(" Network:", network.name);
  console.log(" Chain ID:", chainId, "\n");

  let PYTH_ADDRESS: string;
  let USDC_ADDRESS: string;
  let PYUSD_ADDRESS: string;
  let GMX_EXCHANGE_ROUTER: string;
  let GMX_ORDER_VAULT: string;
  let GMX_READER: string;
  let GMX_DATASTORE: string;
  let GMX_ORDER_HANDLER: string;
  let NETWORK_TYPE: number;

  if (chainId === 42161) {
    // Arbitrum Mainnet
    console.log(" Detected: Arbitrum Mainnet");
    NETWORK_TYPE = 1;
    PYTH_ADDRESS = "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C";
    USDC_ADDRESS = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"; // Native USDC
    PYUSD_ADDRESS = "0x46850aD61C2B7d64d08c9C754F45254596696984"; 
    GMX_EXCHANGE_ROUTER = "0x7c68C7866A64FA2160F78Eeae77F8b0F06373D61";
    GMX_ORDER_VAULT = "0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5";
    GMX_READER = "0x38d8f1156E7fA9ef1EFeaF88b55C1697074FE2FA";
    GMX_DATASTORE = "0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8";
    GMX_ORDER_HANDLER = "0x95C2D962b8E962105EFB8d1EB0016Ede4A918877";
  } else if (chainId === 43114) {
    // Avalanche Mainnet
    console.log(" Detected: Avalanche Mainnet");
    NETWORK_TYPE = 2;
    PYTH_ADDRESS = "0x4305FB66699C3B2702D4d05CF36551390A4c69C6";
    USDC_ADDRESS = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"; // Native USDC
    PYUSD_ADDRESS = "0x0000000000000000000000000000000000000000"; // Not deployed on Avalanche
    GMX_EXCHANGE_ROUTER = "0x11a71cc9E6F9b0FE7A8Ba7C6b812E8454Facc6EF";
    GMX_ORDER_VAULT = "0xF41F0d0A9A4964D1A98F8Ead2d0a5750dAB15655";
    GMX_READER = "0xc102F4925Bd8A2Ab0AB91D850d2dd6853a8724aF";
    GMX_DATASTORE = "0x0090B2c3abb9d495Da0B9f0d2E60f0827411BCfe";
    GMX_ORDER_HANDLER = "0xCD8A3107A66cBeA3b9D69AfF33EE0254A1393f4E";
  } else {
    // Testnet/Local (No validation)
    console.log("  Detected: Testnet/Local Network - Using placeholder addresses");
    NETWORK_TYPE = 0;
    PYTH_ADDRESS = "0x0000000000000000000000000000000000000001";
    USDC_ADDRESS = "0x0000000000000000000000000000000000000002";
    PYUSD_ADDRESS = "0x0000000000000000000000000000000000000003";
    GMX_EXCHANGE_ROUTER = "0x0000000000000000000000000000000000000004";
    GMX_ORDER_VAULT = "0x0000000000000000000000000000000000000005";
    GMX_READER = "0x0000000000000000000000000000000000000006";
    GMX_DATASTORE = "0x0000000000000000000000000000000000000007";
    GMX_ORDER_HANDLER = "0x0000000000000000000000000000000000000008";
  }

  console.log("\n Configuration:");
  console.log("  Pyth Oracle:", PYTH_ADDRESS);
  console.log("  USDC:", USDC_ADDRESS);
  console.log("  PYUSD:", PYUSD_ADDRESS);
  console.log("  GMX Exchange Router:", GMX_EXCHANGE_ROUTER);
  console.log("  GMX Order Vault:", GMX_ORDER_VAULT);
  console.log("  GMX Reader:", GMX_READER);
  console.log("  GMX DataStore:", GMX_DATASTORE);
  console.log("  GMX Order Handler:", GMX_ORDER_HANDLER, "\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 1: DEPLOY BASKET ORACLE
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log(" [1/6] Deploying BasketOracle...");
  const BasketOracle = await ethers.getContractFactory("BasketOracle");
  const basketOracle = await BasketOracle.deploy(
    PYTH_ADDRESS,
    deployer.address
  );
  await basketOracle.waitForDeployment();
  const basketOracleAddress = await basketOracle.getAddress();
  console.log(" BasketOracle deployed at:", basketOracleAddress);
  
  // Initialize basket with commodity components
  console.log("    Initializing basket components...");
  const initTx = await basketOracle.initializeBasket();
  await initTx.wait();
  console.log("    Basket initialized with 6 commodities (Gold, Oil, EUR/USD, JPY/USD, Wheat, Copper)\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 2: DEPLOY GMXV2 POSITION MANAGER (WRAPPER)
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log(" [2/6] Deploying GMXV2PositionManager...");
  
  // Deploy with placeholder BasketManager (will set later)
  const GMXV2PositionManager = await ethers.getContractFactory("GMXV2PerpWrapper");
  const gmxPositionManager = await GMXV2PositionManager.deploy(
    GMX_EXCHANGE_ROUTER,
    GMX_ORDER_VAULT,
    GMX_READER,
    GMX_DATASTORE,
    GMX_ORDER_HANDLER,
    ethers.ZeroAddress, // Placeholder - will set after BasketManager deployment
    deployer.address,
    NETWORK_TYPE
  );
  await gmxPositionManager.waitForDeployment();
  const gmxPositionManagerAddress = await gmxPositionManager.getAddress();
  console.log(" GMXV2PositionManager deployed at:", gmxPositionManagerAddress, "\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 3: DEPLOY BASKET MANAGER
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log(" [3/6] Deploying BasketManager...");
  const BasketManager = await ethers.getContractFactory("BasketManager");
  const basketManager = await BasketManager.deploy(
    basketOracleAddress,
    ethers.ZeroAddress, // ShieldVault - will set after deployment
    gmxPositionManagerAddress,
    USDC_ADDRESS,
    deployer.address
  );
  await basketManager.waitForDeployment();
  const basketManagerAddress = await basketManager.getAddress();
  console.log(" BasketManager deployed at:", basketManagerAddress);
  
  // Grant GMX Position Manager the BASKET_MANAGER_ROLE
  console.log("    Granting BASKET_MANAGER_ROLE to BasketManager in GMXV2PositionManager...");
  const BASKET_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BASKET_MANAGER_ROLE"));
  const grantRoleTx = await gmxPositionManager.grantRole(BASKET_MANAGER_ROLE, basketManagerAddress);
  await grantRoleTx.wait();
  console.log("    Role granted\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 4: DEPLOY SHIELD VAULT
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("  [4/6] Deploying ShieldVault...");
  const ShieldVault = await ethers.getContractFactory("ShieldVault");
  const shieldVault = await ShieldVault.deploy(
    basketOracleAddress,
    PYTH_ADDRESS,
    deployer.address
  );
  await shieldVault.waitForDeployment();
  const shieldVaultAddress = await shieldVault.getAddress();
  console.log(" ShieldVault deployed at:", shieldVaultAddress);
  
  // Set BasketManager in ShieldVault
  console.log("    Setting BasketManager in ShieldVault...");
  const setBasketManagerTx = await shieldVault.setBasketManager(basketManagerAddress);
  await setBasketManagerTx.wait();
  console.log("    BasketManager set in ShieldVault");
  
  // Set ShieldVault in BasketManager
  console.log("    Setting ShieldVault in BasketManager...");
  const setVaultTx = await basketManager.setShieldVault(shieldVaultAddress);
  await setVaultTx.wait();
  console.log("    ShieldVault set in BasketManager\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 5: DEPLOY TREASURY CONTROLLER
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log(" [5/6] Deploying TreasuryController...");
  const TreasuryController = await ethers.getContractFactory("TreasuryController");
  const treasuryController = await TreasuryController.deploy(
    basketOracleAddress,
    shieldVaultAddress, // SHIELD token address
    deployer.address
  );
  await treasuryController.waitForDeployment();
  const treasuryControllerAddress = await treasuryController.getAddress();
  console.log(" TreasuryController deployed at:", treasuryControllerAddress);
  
  // Set Treasury in ShieldVault
  console.log("    Setting Treasury in ShieldVault...");
  const setTreasuryTx = await shieldVault.setTreasury(treasuryControllerAddress);
  await setTreasuryTx.wait();
  console.log("    Treasury set in ShieldVault");
  
  // Add deployer as trusted signer in BasketOracle (for off-chain NAV submission)
  console.log("    Adding deployer as trusted signer in BasketOracle...");
  const setSignerTx = await basketOracle.setTrustedSigner(deployer.address, true);
  await setSignerTx.wait();
  console.log("    Deployer set as trusted signer\n");

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 6: DEPLOY PYUSD INTEGRATION
  // ═══════════════════════════════════════════════════════════════════════════
  
  let pyusdIntegrationAddress = ethers.ZeroAddress;
  
  if (PYUSD_ADDRESS !== ethers.ZeroAddress && PYUSD_ADDRESS !== "0x0000000000000000000000000000000000000000") {
    console.log(" [6/6] Deploying PYUSDIntegration...");
    const PYUSDIntegration = await ethers.getContractFactory("PYUSDIntegration");
    const pyusdIntegration = await PYUSDIntegration.deploy(
      PYUSD_ADDRESS,
      shieldVaultAddress,
      treasuryControllerAddress,
      basketOracleAddress,
      PYTH_ADDRESS,
      deployer.address,
      deployer.address // Fee recipient
    );
    await pyusdIntegration.waitForDeployment();
    pyusdIntegrationAddress = await pyusdIntegration.getAddress();
    console.log(" PYUSDIntegration deployed at:", pyusdIntegrationAddress, "\n");
  } else {
    console.log("  [6/6] Skipping PYUSDIntegration (PYUSD not available on this network)\n");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DEPLOYMENT SUMMARY
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("═══════════════════════════════════════════════════════════════");
  console.log(" SHIELD PROTOCOL DEPLOYMENT COMPLETE!");
  console.log("═══════════════════════════════════════════════════════════════\n");
  
  console.log(" CONTRACT ADDRESSES:\n");
  console.log("  BasketOracle:          ", basketOracleAddress);
  console.log("  GMXV2PositionManager:  ", gmxPositionManagerAddress);
  console.log("  BasketManager:         ", basketManagerAddress);
  console.log("  ShieldVault (SHIELD):  ", shieldVaultAddress);
  console.log("  TreasuryController:    ", treasuryControllerAddress);
  if (pyusdIntegrationAddress !== ethers.ZeroAddress) {
    console.log("  PYUSDIntegration:      ", pyusdIntegrationAddress);
  }
  
  console.log("\n ROLES & PERMISSIONS:\n");
  console.log("  Admin (All Contracts): ", deployer.address);
  console.log("  Trusted Signer (Oracle):", deployer.address);
  console.log("  BASKET_MANAGER_ROLE:   ", basketManagerAddress, "→ GMXV2PositionManager");
  
  console.log("\n  CONFIGURATION:\n");
  console.log("  Network Type:          ", NETWORK_TYPE === 1 ? "Arbitrum" : NETWORK_TYPE === 2 ? "Avalanche" : "Testnet");
  console.log("  Pyth Oracle:           ", PYTH_ADDRESS);
  console.log("  USDC Address:          ", USDC_ADDRESS);
  console.log("  GMX Integration:       ", GMX_EXCHANGE_ROUTER);
  
  console.log("\n NEXT STEPS:\n");
  console.log("  1. Fund BasketManager with USDC for deposits");
  console.log("  2. Fund TreasuryController with ETH for gas options");
  if (pyusdIntegrationAddress !== ethers.ZeroAddress) {
    console.log("  3. Fund PYUSDIntegration with ETH for PYUSD conversions");
  }
  console.log("  4. Deploy backend service for NAV submission (submitNAV)");
  console.log("  5. Deploy AI agents for rebalancing");
  console.log("  6. Set up Chainlink Keepers for periodic tasks:");
  console.log("     - collectManagementFee() in ShieldVault");
  console.log("     - recordBaseFee() in TreasuryController");
  console.log("     - submitNAV() in BasketOracle (via backend)");
  console.log("  7. Grant MINTER_ROLE and REDEEMER_ROLE to backend hot wallet:");
  console.log("     - executeMintIntent() in ShieldVault");
  console.log("     - executeRedeemIntent() in ShieldVault");
  
  console.log("\n DEPLOYMENT JSON:\n");
  
  const deploymentData = {
    network: network.name,
    chainId: chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      BasketOracle: basketOracleAddress,
      GMXV2PositionManager: gmxPositionManagerAddress,
      BasketManager: basketManagerAddress,
      ShieldVault: shieldVaultAddress,
      TreasuryController: treasuryControllerAddress,
      PYUSDIntegration: pyusdIntegrationAddress !== ethers.ZeroAddress ? pyusdIntegrationAddress : null
    },
    externalAddresses: {
      Pyth: PYTH_ADDRESS,
      USDC: USDC_ADDRESS,
      PYUSD: PYUSD_ADDRESS !== "0x0000000000000000000000000000000000000000" ? PYUSD_ADDRESS : null,
      GMX_ExchangeRouter: GMX_EXCHANGE_ROUTER,
      GMX_OrderVault: GMX_ORDER_VAULT,
      GMX_Reader: GMX_READER,
      GMX_DataStore: GMX_DATASTORE,
      GMX_OrderHandler: GMX_ORDER_HANDLER
    }
  };
  
  console.log(JSON.stringify(deploymentData, null, 2));
  
  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log(" Deployment script completed successfully!");
  console.log("═══════════════════════════════════════════════════════════════\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n Deployment failed:");
    console.error(error);
    process.exit(1);
  });