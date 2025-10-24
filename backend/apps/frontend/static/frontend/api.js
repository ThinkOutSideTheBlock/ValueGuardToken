const api = {
    BASE_URL: '/api/v1',

    storeTokens(accessToken, refreshToken) {
        localStorage.setItem('accessToken', accessToken);
        localStorage.setItem('refreshToken', refreshToken);
    },

    getAccessToken: () => localStorage.getItem('accessToken'),
    getRefreshToken: () => localStorage.getItem('refreshToken'),
    clearTokens: () => {
        localStorage.removeItem('accessToken');
        localStorage.removeItem('refreshToken');
    },

    async login() {
        try {
            const address = await wallet.connect();
            if (!address) return false;

            // 1. Request nonce
            const nonceResponse = await fetch(`${this.BASE_URL}/users/auth/nonce/`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ wallet_address: address }),
            });
            const { message } = await nonceResponse.json();

            // 2. Sign message
            const signature = await wallet.signMessage(message);

            // 3. Verify signature and get tokens
            const verifyResponse = await fetch(`${this.BASE_URL}/users/auth/verify/`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ wallet_address: address, signature: signature }),
            });
            const data = await verifyResponse.json();

            if (verifyResponse.ok) {
                this.storeTokens(data.access, data.refresh);
                return true;
            }
            return false;
        } catch (error) {
            console.error("Login process failed:", error);
            return false;
        }
    },

    async refreshToken() {
        const refreshToken = this.getRefreshToken();
        if (!refreshToken) return false;

        try {
            const response = await fetch(`${this.BASE_URL}/users/auth/token/refresh/`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ refresh: refreshToken }),
            });
            const data = await response.json();
            if (response.ok) {
                localStorage.setItem('accessToken', data.access);
                return true;
            }
            this.clearTokens();
            return false;
        } catch (error) {
            this.clearTokens();
            return false;
        }
    },

    async fetchWithAuth(url, options = {}) {
        let accessToken = this.getAccessToken();
        if (!accessToken) {
            throw new Error("User not authenticated.");
        }

        const headers = {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${accessToken}`,
            ...options.headers,
        };

        let response = await fetch(url, { ...options, headers });

        if (response.status === 401) {
            console.log("Access token expired. Refreshing...");
            const refreshed = await this.refreshToken();
            if (refreshed) {
                headers['Authorization'] = `Bearer ${this.getAccessToken()}`;
                response = await fetch(url, { ...options, headers }); // Retry the request
            } else {
                alert("Session expired. Please connect your wallet again.");
                this.clearTokens();
                // Optionally redirect to home or force re-login
                throw new Error("Session expired.");
            }
        }
        return response;
    }
};