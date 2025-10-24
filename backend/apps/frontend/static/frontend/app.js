document.addEventListener('DOMContentLoaded', () => {
    const connectBtn = document.getElementById('connect-wallet-btn');

    const updateConnectButtonUI = async () => {
        const refreshToken = api.getRefreshToken();

        // The source of truth for being "logged in" is the presence of a refresh token.
        if (refreshToken) {
            // If we are logged in, try to connect to the wallet to get the address.
            // The user might have already granted permission.
            try {
                const accounts = await window.ethereum.request({ method: 'eth_accounts' });
                if (accounts.length > 0) {
                    const address = accounts[0];
                    connectBtn.textContent = `${address.substring(0, 6)}...${address.substring(address.length - 4)}`;
                } else {
                    // Logged in, but wallet is locked or disconnected.
                    connectBtn.textContent = 'Connect Wallet';
                    api.clearTokens(); // Clear tokens if wallet is disconnected/locked
                }
            } catch (e) {
                console.error("Could not get wallet accounts.", e);
                connectBtn.textContent = 'Connect Wallet';
            }
        } else {
            // Not logged in.
            connectBtn.textContent = 'Connect Wallet';
        }
    };

    connectBtn.addEventListener('click', async () => {
        const refreshToken = api.getRefreshToken();
        if (refreshToken) {
            console.log("Already logged in.");
            return;
        }

        const success = await api.login();
        if (success) {
            await updateConnectButtonUI(); // Update button text
            document.dispatchEvent(new CustomEvent('walletConnected')); // Notify other scripts
        }
    });

    // Initial UI update on page load
    updateConnectButtonUI();
});