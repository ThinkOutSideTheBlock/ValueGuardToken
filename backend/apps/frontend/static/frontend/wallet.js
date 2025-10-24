const wallet = {
    async connect() {
        if (typeof window.ethereum === 'undefined') {
            alert('MetaMask is not installed!');
            return null;
        }
        try {
            // This method prompts the user to connect.
            const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
            return accounts[0];
        } catch (error) {
            console.error("User rejected wallet connection:", error);
            return null;
        }
    },

    async getAddress() {
        // This method gets the address WITHOUT prompting the user.
        if (!window.ethereum) return null;
        try {
            const accounts = await window.ethereum.request({ method: 'eth_accounts' });
            return accounts.length > 0 ? accounts[0] : null;
        } catch (e) {
            console.error("Could not get accounts:", e);
            return null;
        }
    },

    async signMessage(message, address) {
        if (!address) {
            throw new Error("Address not provided for signing.");
        }
        try {
            const signature = await window.ethereum.request({
                method: 'personal_sign',
                params: [message, address],
            });
            return signature;
        } catch (error) {
            console.error("Message signing failed:", error);
            throw error;
        }
    }
};