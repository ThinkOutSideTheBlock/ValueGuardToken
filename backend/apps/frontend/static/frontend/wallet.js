const wallet = {
    async connect() {
        if (typeof window.ethereum === 'undefined') {
            alert('MetaMask is not installed!');
            return null;
        }
        try {
            const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
            return accounts[0];
        } catch (error) {
            console.error("User rejected wallet connection:", error);
            return null;
        }
    },

    getAddress() {
        if (window.ethereum && window.ethereum.selectedAddress) {
            return window.ethereum.selectedAddress;
        }
        return null;
    },

    async signMessage(message) {
        const address = this.getAddress();
        if (!address) {
            throw new Error("Wallet not connected.");
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