
document.addEventListener('DOMContentLoaded', () => {

    const tabMint = document.getElementById('tab-mint');
    const tabRedeem = document.getElementById('tab-redeem');
    const panelMint = document.getElementById('panel-mint');
    const panelRedeem = document.getElementById('panel-redeem');
    const mintTokenSelect = document.getElementById('mint-token-select');
    const redeemTokenSelect = document.getElementById('redeem-token-select');
    const mintAmountInput = document.getElementById('mint-amount');
    const redeemAmountInput = document.getElementById('redeem-amount');
    const mintBtn = document.getElementById('mint-action-btn');
    const redeemBtn = document.getElementById('redeem-action-btn');
    const txStatus = document.getElementById('tx-status');

    const basketManagerAddress = "0x1c9fD50dF7a4f066884b58A05D91e4b55005876A";
    const vaultManagerAddress = "0x1c9fD50dF7a4f066884b58A05D91e4b55005876A";


    const basketManagerABI = [
        "function totalSupply() view returns (uint256)",
        "function balanceOf(address) view returns (uint256)",
        // TODO: Add the ABI for the function that returns totalManagedValue (NAV)
        // "function totalManagedValue() view returns (uint256)" 
    ];

    const vaultManagerABI = [
        "function createMintIntent(address depositAsset, uint256 depositAmount) external payable returns (bytes32 intentId)",
        "function createRedeemIntent(uint256 shieldAmount, address outputAsset) external payable returns (bytes32 intentId)"
    ];

    const switchTab = (activeTab) => {
        if (!tabMint || !tabRedeem) return;

        if (activeTab === 'mint') {
            tabMint.classList.add('bg-gray-700', 'text-white');
            tabMint.classList.remove('text-gray-500');
            tabRedeem.classList.remove('bg-gray-700', 'text-white');
            tabRedeem.classList.add('text-gray-500');
            panelMint.classList.remove('hidden');
            panelRedeem.classList.add('hidden');
        } else {
            tabRedeem.classList.add('bg-gray-700', 'text-white');
            tabRedeem.classList.remove('text-gray-500');
            tabMint.classList.remove('bg-gray-700', 'text-white');
            tabMint.classList.add('text-gray-500');
            panelRedeem.classList.remove('hidden');
            panelMint.classList.add('hidden');
        }
    };

    if (tabMint && tabRedeem) {
        tabMint.addEventListener('click', () => switchTab('mint'));
        tabRedeem.addEventListener('click', () => switchTab('redeem'));
        switchTab('mint');
    }

    const djangoDataElement = document.getElementById('django-data');
    if (djangoDataElement) {
        const djangoData = JSON.parse(djangoDataElement.textContent);
        const supportedTokens = djangoData.tokens;



        if (mintTokenSelect && redeemTokenSelect) {
            supportedTokens.forEach(token => {
                mintTokenSelect.innerHTML += `<option value="${token.address}">${token.symbol}</option>`;
                redeemTokenSelect.innerHTML += `<option value="${token.address}">${token.symbol}</option>`;
            });
        }

        const getSignerAndContract = () => {
            if (!wallet.getAddress() || !api.getAccessToken()) {
                alert("Please connect your wallet first.");
                return null;
            }
            const provider = new ethers.providers.Web3Provider(window.ethereum);
            const signer = provider.getSigner();
            const contract = new ethers.Contract(vaultManagerAddress, vaultManagerABI, signer);
            return { signer, contract };
        };
        if (mintBtn) {
            mintBtn.addEventListener('click', async () => {
                const { signer, contract } = getSignerAndContract() || {};
                if (!signer || !contract) return;

                const tokenAddress = mintTokenSelect.value;
                const amount = mintAmountInput.value;
                const token = supportedTokens.find(t => t.address === tokenAddress);

                if (!amount || isNaN(amount) || parseFloat(amount) <= 0) {
                    alert("Please enter a valid amount.");
                    return;
                }

                try {
                    const amountInWei = ethers.utils.parseUnits(amount, token.decimals);
                    txStatus.textContent = "Please approve the transaction in your wallet...";

                    // TODO: Add logic for ERC20 approval if the token is not native ETH
                    // if (token.symbol !== 'ETH') {
                    //    const tokenContract = new ethers.Contract(token.address, erc20Abi, signer);
                    //    const approveTx = await tokenContract.approve(vaultManagerAddress, amountInWei);
                    //    await approveTx.wait();
                    // }

                    const tx = await contract.createMintIntent(tokenAddress, amountInWei, {
                        // Pass value if it's a native ETH transaction
                        value: token.symbol === 'ETH' ? amountInWei : 0,
                        // TODO: You may need to pass an execution fee as `value` for all transactions
                    });

                    txStatus.textContent = `Transaction sent! Waiting for confirmation... (Hash: ${tx.hash.substring(0, 10)}...)`;
                    await tx.wait();
                    txStatus.textContent = "Mint Intent created successfully! Your order is being processed.";
                    mintAmountInput.value = "";
                } catch (error) {
                    console.error("Mint transaction failed:", error);
                    txStatus.textContent = `Error: ${error.reason || error.message}`;
                }
            });
        }
        if (redeemBtn) {
            redeemBtn.addEventListener('click', async () => {
                const { signer, contract } = getSignerAndContract() || {};
                if (!signer || !contract) return;

                const outputTokenAddress = redeemTokenSelect.value;
                const amount = redeemAmountInput.value;

                if (!amount || isNaN(amount) || parseFloat(amount) <= 0) {
                    alert("Please enter a valid amount.");
                    return;
                }

                try {
                    // VGT tokens have 18 decimals
                    const amountInWei = ethers.utils.parseUnits(amount, 18);
                    txStatus.textContent = "Please approve the transaction in your wallet...";

                    // TODO: The user first needs to approve the VaultManager to spend their VGT tokens.
                    // const vgtContract = new ethers.Contract(VGT_TOKEN_ADDRESS, erc20Abi, signer);
                    // const approveTx = await vgtContract.approve(vaultManagerAddress, amountInWei);
                    // await approveTx.wait();

                    const tx = await contract.createRedeemIntent(amountInWei, outputTokenAddress, {
                        // todo
                    });

                    txStatus.textContent = `Transaction sent! Waiting for confirmation... (Hash: ${tx.hash.substring(0, 10)}...)`;
                    await tx.wait();
                    txStatus.textContent = "Redeem Intent created successfully! Your order is being processed.";
                    redeemAmountInput.value = "";
                } catch (error) {
                    console.error("Redeem transaction failed:", error);
                    txStatus.textContent = `Error: ${error.reason || error.message}`;
                }
            });
        }

        const updateDashboardData = async () => {
            const address = await wallet.getAddress();
            const token = api.getAccessToken();

            if (!address || !token) {
                console.log("User not connected, skipping data fetch on main page.");
                return;
            }

            console.log("Updating main dashboard data...");
            // TODO: Replace with real contract addresses and ABIs


            try {
                const provider = new ethers.providers.Web3Provider(window.ethereum);
                const contract = new ethers.Contract(basketManagerAddress, basketManagerABI, provider);

                // TODO: The function for NAV is missing. Using a mock value.
                const nav = ethers.utils.parseEther("1234567.89"); // Mock NAV
                const [totalSupply, userSupply] = await Promise.all([
                    contract.totalSupply(),
                    contract.balanceOf(address)
                ]);

                // Update basket dashboard
                document.getElementById('basket-nav').textContent = `$${parseFloat(ethers.utils.formatEther(nav)).toLocaleString()}`;
                document.getElementById('basket-total-supply').textContent = parseFloat(ethers.utils.formatEther(totalSupply)).toLocaleString();

                // Update user dashboard
                document.getElementById('user-vgt-supply').textContent = parseFloat(ethers.utils.formatEther(userSupply)).toLocaleString();

                // TODO: Implement P&L and User Asset Value calculations
                document.getElementById('basket-pnl-day').textContent = "+1.25%"; // Mock
                document.getElementById('user-asset-value').textContent = "$1,234.56"; // Mock

            } catch (error) {
                console.error("Failed to fetch dashboard data:", error);
            }
        };

        document.addEventListener('walletConnected', () => {
            console.log("Caught 'walletConnected' event. Fetching initial data.");
            updateDashboardData();
        });

        setInterval(updateDashboardData, 10000);
        updateDashboardData();
    } else {
        console.warn("No 'django-data' element found on this page. On-chain actions and data will not be initialized.");
    }
});