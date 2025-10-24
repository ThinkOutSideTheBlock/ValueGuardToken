document.addEventListener('DOMContentLoaded', () => {
    const heartbeatForm = document.getElementById('heartbeat-form');
    const heartbeatStatus = document.getElementById('heartbeat-status');

    heartbeatForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const seconds = document.getElementById('heartbeat-seconds').value;
        heartbeatStatus.textContent = 'Submitting...';

        try {
            const response = await api.fetchWithAuth('/api/v1/protocol/admin/set-heartbeat/', {
                method: 'POST',
                body: JSON.stringify({ heartbeatSeconds: parseInt(seconds) }),
            });

            // --- IMPROVEMENT: Check response content type before parsing ---
            const contentType = response.headers.get("content-type");
            if (response.ok && contentType && contentType.indexOf("application/json") !== -1) {
                // If the response is JSON, you can parse it (though this endpoint might not return a body)
                heartbeatStatus.textContent = `Success! Heartbeat set to ${seconds} seconds.`;
            } else if (response.ok) {
                // Handle successful but non-JSON responses (e.g., 204 No Content)
                heartbeatStatus.textContent = `Success! Heartbeat set to ${seconds} seconds. (Status: ${response.status})`;
            }
            else {
                // If we get here, it's likely an HTML error page
                const errorText = await response.text(); // Read the response as text
                console.error("Server returned non-JSON response:", errorText);
                heartbeatStatus.textContent = `Error: Server returned an unexpected response (Status: ${response.status}). Check console for details.`;
            }
        } catch (error) {
            heartbeatStatus.textContent = `Failed to submit: ${error.message}`;
        }
    });

    const updateAdminDashboardData = async () => {
        console.log("Updating admin dashboard data...");
        // TODO: Implement data fetching for admin dashboard from smart contracts
        document.getElementById('admin-total-users').textContent = "123"; // Mock
        document.getElementById('admin-total-nav').textContent = "$1,234,567.89"; // Mock

        // Mock Asset Dashboard
        const assetList = document.getElementById('asset-dashboard-list');
        assetList.innerHTML = `
            <div class="value-item"><span>Gold:</span> <span>$500,000 (+2.5%)</span></div>
            <div class="value-item"><span>Oil:</span> <span>$300,000 (-1.0%)</span></div>
        `;
    };

    if (!api.getAccessToken()) {
        alert("Please connect wallet on the main page first.");
        window.location.href = "/";
    } else {
        updateAdminDashboardData();
        setInterval(updateAdminDashboardData, 10000);
    }
});