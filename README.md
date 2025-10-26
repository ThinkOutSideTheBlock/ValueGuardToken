# 🛡️ ValueGuard Token (VGT)

### **A blockchain-based token designed to protect users’ purchasing power by backing its value with a diversified basket of real-world assets.**  

---

## 🧭 Overview

**ValueGuard Token (VGT)** is an ERC-20 compatible asset designed to maintain stable purchasing power over time by tracking the **real-world value of a diversified portfolio** of inflation-resistant assets such as gold, silver, oil, bonds, and commodity indices.  

Unlike stablecoins pegged to fiat currencies, **VGT is not pegged** and its value **floats dynamically** based on the **Net Asset Value (NAV)** of the underlying asset basket. Each token represents a proportional claim on the total portfolio, functioning similarly to a share in a managed investment fund.

This approach offers a **decentralized, transparent, and AI-assisted solution** to inflation protection.

---

## 💡 Problem Statement

Traditional stablecoins (e.g., USDT, USDC) are pegged to fiat currencies that themselves **lose value due to inflation**.  
Existing inflation hedged instruments, such as ETFs or managed funds, are **centralized**, **restricted by geography**, and **inaccessible to many global users**.

**VGT** addresses this by providing:
- An **onchain inflation resistant store of value**
- **Decentralized, AI-driven portfolio rebalancing**
- **Transparent asset valuation** through oracles
- A seamless experience for Web3 users seeking **long term purchasing power stability**

---

## 🚀 Key Features

- 🧮 **NAV based pricing** — token value determined by total portfolio value / circulating supply  
- 💹 **Diversified asset backing** — exposure to gold, oil, silver, bonds, and commodities  
- 🧠 **AI-driven dynamic rebalancing** using fetch.ai's uAgents and ASI:One LLM  
- 🔮 **Real-time market data** via **Pyth Network oracle**  
- 💰 **Vault based minting mechanism** using stablecoins (e.g., USDT)   
- 🔐 **Decentralized transparency** — fully auditable smart contracts and oracle feeds  

---

## 🏗️ Architecture

### System Components
| Layer | Description |
|-------|--------------|
| **1. Smart Contract (On-chain)** | Implements ERC-20 logic, tracks total supply, NAV per token, and handles minting/burning. Maintains onchain parameters for asset weighting. |
| **2. Vault Contract** | Receives user deposits (stablecoins), mints new tokens, and holds liquidity reserves. A small fraction is allocated for protocol managed yield generation. |
| **3. Oracle Integration (Pyth Network)** | Provides real time asset prices for gold, oil, silver, government bonds, and other commodities. |
| **4. AI Agent Layer** | Built using **fetch.ai's uAgent** and **Agentverse AI Agent Platform** and powered by **ASI:One (LLM)**. Includes: <br> - **Agent 1:** Fetches live price data from Pyth Oracle. <br> - **Agent 2:** Processes the data using a structured economic reasoning model to optimize asset weights. |

### AI Workflow
1. A scheduled or triggered prompt is sent to **ASI:One**.  
2. **Agent 1** retrieves up to date market data via the **Pyth Oracle**.  
3. **Agent 2** analyzes asset correlations and inflation trends using an internal economic knowledge graph.  
4. The agent suggests an optimal new asset weighting strategy.  
5. The updated parameters are transmitted to the **smart contract**, recalculating NAV and rebalancing the virtual basket.  

This creates a **self adjusting, inflation resistant asset** governed by transparent data and AI reasoning.

---

## 🧰 Tech Stack and Dependencies

| Category | Technology / Partner |
|-----------|----------------------|
| **Blockchain** | Ethereum (EVM-compatible), Solidity |
| **AI / Agents** | fetch.ai's uAgent, ASI:One (LLM)|
| **Oracles** | Pyth Network |
| **Smart Contract Dev** | Hardhat|

---

## ⚙️ How It Works

### Step-by-Step Flow
1. **Deposit Stablecoins:**  
   Users lock USDT (or another stablecoin) into the VGT **Vault Contract**.  

2. **Mint Tokens:**  
   Based on the current NAV per token, the contract mints the equivalent amount of VGT to the user’s wallet.  

3. **Asset Price Update:**  
   AI **Agent 1** fetches real time data from **Pyth** for all tracked assets.  

4. **AI Rebalancing:**  
   **Agent 2**, powered by **ASI One** and **SingularityNET's meTTa knowledge graphs**, analyzes the data to adjust the weighting of each asset class in the virtual basket.  

5. **NAV Recalculation:**  
   The contract updates its `navPerToken()` value using the new weightings and asset prices.  

6. **Token Behavior:**  
   - Token price rises when the asset basket appreciates.  
   - Token price declines if the basket loses value.  
   - No peg; pure market reflective pricing.  

7. **Redemption:**  
   Users will be able to redeem VGT tokens for stablecoins at the current NAV.

---

## 🛣️ Future Work / Roadmap

- [ ] Expand asset basket to include additional commodities and ETFs  
- [ ] Integrate decentralized governance (DAO based rebalancing approvals)  
- [ ] Connect VGT to Chainlink's proof of reserve    
- [ ] Explore real onchain asset tokenization partnerships (RWAs)  

**The list may get updated as we progress**  

---

## 📜 License

MIT License © 2025  

---

## 🌐 Connect

- 🌍 **Project Repository:** [https://github.com/ThinkOutSideTheBlock/ValueGuardToken](#)
- 🧠 **Powered by:** fetch.ai's uAgent, ASI:One LLM, SingularityNET's meTTA, Pyth Network, and other ETHGlobal ETHonline 2025 Partners tech stacks  
