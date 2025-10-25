document.addEventListener('DOMContentLoaded', async () => {
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

    let pieChart = null; // Variable to hold the chart instance

    const createOrUpdatePieChart = (labels, data) => {
        const ctx = document.getElementById('asset-pie-chart').getContext('2d');

        if (pieChart) {
            pieChart.data.labels = labels;
            pieChart.data.datasets[0].data = data;
            pieChart.update();
            return;
        }

        pieChart = new Chart(ctx, {
            type: 'pie',
            data: {
                labels: labels, // e.g., ['Gold', 'Oil', 'USDC']
                datasets: [{
                    label: 'Asset Allocation',
                    data: data, // e.g., [50, 30, 20]
                    backgroundColor: [
                        'rgba(255, 206, 86, 0.7)',  // Gold
                        'rgba(75, 192, 192, 0.7)',   // Teal
                        'rgba(54, 162, 235, 0.7)',  // Blue
                        'rgba(153, 102, 255, 0.7)', // Purple
                    ],
                    borderColor: [
                        'rgba(255, 206, 86, 1)',
                        'rgba(75, 192, 192, 1)',
                        'rgba(54, 162, 235, 1)',
                        'rgba(153, 102, 255, 1)',
                    ],
                    borderWidth: 1
                }]
            },
            options: {
                responsive: true,
                plugins: {
                    legend: {
                        position: 'top',
                        labels: {
                            color: 'white' // Legend text color
                        }
                    },
                }
            }
        });
    };

    const updateAdminDashboardData = async () => {
        console.log("Updating admin dashboard data...");
        // TODO: Implement real data fetching for admin dashboard

        // Mock data
        document.getElementById('admin-total-users').textContent = "123";
        document.getElementById('admin-total-nav').textContent = "$1,234,567.89";

        const assetList = document.getElementById('asset-dashboard-list');
        assetList.innerHTML = `
            <div class="flex justify-between"><span>Gold:</span> <span class="font-mono text-white">$500,000 (+2.5%)</span></div>
            <div class="flex justify-between"><span>Oil:</span> <span class="font-mono text-white">$300,000 (-1.0%)</span></div>
            <div class="flex justify-between"><span>USDC Reserve:</span> <span class="font-mono text-white">$434,567.89</span></div>
        `;

        // --- NEW: Update the pie chart with mock data ---
        const assetLabels = ['Gold', 'Oil', 'USDC Reserve'];
        const assetData = [50, 30, 20]; // Percentages
        createOrUpdatePieChart(assetLabels, assetData);
    };

    const token = api.getAccessToken();
    if (!token) {
        alert("Authentication required. Please connect your wallet on the main page.");
        window.location.href = "/";
    } else {
        await updateAdminDashboardData(); // Use await
        setInterval(updateAdminDashboardData, 10000);
    }


});