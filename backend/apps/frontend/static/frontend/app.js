// This file contains JavaScript code shared across all pages.

document.addEventListener('DOMContentLoaded', () => {
    const connectBtn = document.getElementById('connect-wallet-btn');

    // This function updates the button text based on wallet connection status
    const updateConnectButtonUI = () => {
        const address = wallet.getAddress();
        const token = api.getAccessToken();
        if (address && token) {
            connectBtn.textContent = `${address.substring(0, 6)}...${address.substring(address.length - 4)}`;
        } else {
            connectBtn.textContent = 'Connect Wallet';
            api.clearTokens(); // Ensure storage is clean if disconnected
        }
    };

    // Attach the login logic to the button click
    connectBtn.addEventListener('click', async () => {
        const address = wallet.getAddress();
        const token = api.getAccessToken();

        // If already connected, do nothing (or implement a disconnect logic)
        if (address && token) {
            console.log("Wallet already connected.");
            return;
        }

        const success = await api.login();
        if (success) {
            // A simple and effective way to ensure the page state is correct after login
            // is to just reload the page.
            window.location.reload();
        }
    });

    // Update the button text as soon as the page loads
    updateConnectButtonUI();
});