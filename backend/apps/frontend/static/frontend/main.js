
document.addEventListener('DOMContentLoaded', () => {
    const updateDashboardData = async () => {
        const address = await wallet.getAddress(); // Use await
        const token = api.getAccessToken();

        if (!address || !token) { // Check both
            console.log("User not connected, skipping data fetch on main page.");
            return;
        }

        console.log("Updating main dashboard data...");
        // TODO: Replace with real contract addresses and ABIs
        const basketManagerAddress = "0x..."; // Replace with your mock contract address
        const basketManagerABI = [
            "function totalSupply() view returns (uint256)",
            "function balanceOf(address) view returns (uint256)",
            // TODO: Add the ABI for the function that returns totalManagedValue (NAV)
            // "function totalManagedValue() view returns (uint256)" 
        ];

        try {
            const provider = new ethers.providers.Web3Provider(window.ethereum);
            const contract = new ethers.Contract(basketManagerAddress, basketManagerABI, provider);

            // TODO: The function for NAV is missing. Using a mock value.
            const nav = ethers.utils.parseEther("1234567.89"); // Mock NAV
            const [totalSupply, userSupply] = await Promise.all([
                contract.totalSupply(),
                contract.balanceOf(address) // Pass the address here
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

    // Periodically update data every 10 seconds if user is connected
    setInterval(updateDashboardData, 10000);

    // Fetch initial data if user is already connected on page load
    updateDashboardData();
});