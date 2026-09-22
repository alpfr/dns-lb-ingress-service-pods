/**
 * EKS Microservice Live Telemetry & API Explorer Engine
 */

document.addEventListener('DOMContentLoaded', () => {
    // DOM Elements
    const pingMetric = document.getElementById('ping-metric');
    const refreshBtn = document.getElementById('refresh-btn');
    const autoRefreshCheck = document.getElementById('auto-refresh-check');
    const activeEndpointUrl = document.getElementById('active-endpoint-url');
    const responseStatus = document.getElementById('response-status');
    const jsonOutput = document.getElementById('json-output');
    const pillButtons = document.querySelectorAll('.pill-btn');

    // Telemetry display fields
    const podNameEl = document.getElementById('pod-name');
    const podIpEl = document.getElementById('pod-ip');
    const nodeNameEl = document.getElementById('node-name');
    const azEl = document.getElementById('availability-zone');
    const appVersionEl = document.getElementById('app-version');
    const clientIpEl = document.getElementById('client-ip');
    const forwardedProtoEl = document.getElementById('forwarded-proto');
    const forwardedPortEl = document.getElementById('forwarded-port');
    const amznTraceIdEl = document.getElementById('amzn-trace-id');
    const requestHostEl = document.getElementById('request-host');
    const uptimeEl = document.getElementById('uptime-display');
    const memoryRssEl = document.getElementById('memory-rss');
    const pythonVersionEl = document.getElementById('python-version');
    const requestCounterEl = document.getElementById('request-counter');
    const chipCluster = document.getElementById('chip-cluster');
    const chipNamespace = document.getElementById('chip-namespace');

    let activeEndpoint = '/api/info';
    let pollInterval = null;

    /**
     * Fetch live telemetry from /api/info and update dashboard metrics
     */
    async function fetchTelemetry() {
        const startTime = performance.now();
        refreshBtn.classList.add('loading');

        try {
            const response = await fetch('/api/info', {
                headers: { 'Accept': 'application/json' },
                cache: 'no-store'
            });
            const rtt = Math.round(performance.now() - startTime);

            if (response.ok) {
                const data = await response.json();
                updateDashboard(data, rtt);
            }
        } catch (err) {
            console.error('Failed to fetch telemetry:', err);
            pingMetric.textContent = 'Err';
            pingMetric.style.color = '#ff5252';
        } finally {
            refreshBtn.classList.remove('loading');
        }
    }

    /**
     * Update DOM elements with fresh telemetry
     */
    function updateDashboard(data, rtt) {
        // Latency
        if (pingMetric) {
            pingMetric.textContent = `${rtt} ms`;
            pingMetric.style.color = rtt < 100 ? '#00e676' : (rtt < 300 ? '#ffb300' : '#ff5252');
        }

        // Pod & Node
        if (data.pod) {
            if (podNameEl) podNameEl.textContent = data.pod.name || 'Unknown';
            if (podIpEl) podIpEl.textContent = data.pod.ip || 'Unknown';
            if (nodeNameEl) nodeNameEl.textContent = data.pod.node || 'Unknown';
            if (azEl) azEl.textContent = data.pod.zone || 'us-east-1';
            if (chipNamespace && data.pod.namespace) chipNamespace.textContent = data.pod.namespace;
        }

        // Cluster & Version
        if (data.cluster && chipCluster) chipCluster.textContent = data.cluster.name || 'demo-eks';
        if (data.version && appVersionEl) appVersionEl.textContent = `v${data.version}`;

        // Ingress & Client
        if (data.ingress) {
            if (clientIpEl) clientIpEl.textContent = data.ingress.client_ip || 'Unknown';
            if (forwardedProtoEl) forwardedProtoEl.textContent = data.ingress.protocol || 'HTTP/HTTPS';
            if (forwardedPortEl) forwardedPortEl.textContent = data.ingress.port || '80/443';
            if (requestHostEl) requestHostEl.textContent = data.ingress.host || window.location.host;
            if (amznTraceIdEl) {
                const trace = data.ingress.amzn_trace_id || 'Direct Route (No ALB Trace)';
                amznTraceIdEl.textContent = trace;
                amznTraceIdEl.title = trace;
            }
        }

        // Runtime Stats
        if (data.runtime) {
            if (uptimeEl) uptimeEl.textContent = data.runtime.uptime_formatted || `${data.runtime.uptime_seconds}s`;
            if (memoryRssEl) memoryRssEl.textContent = data.runtime.memory_rss || '-- MB';
            if (pythonVersionEl) pythonVersionEl.textContent = data.runtime.python_version || 'Python 3.13';
            if (requestCounterEl) requestCounterEl.textContent = `#${data.runtime.total_requests || 0}`;
        }

        // If the active endpoint in console is /api/info, update it too
        if (activeEndpoint === '/api/info') {
            displayJsonOutput(data, 200);
        }
    }

    /**
     * Fetch and display endpoint data in the API Explorer
     */
    async function inspectEndpoint(endpoint) {
        activeEndpoint = endpoint;
        if (activeEndpointUrl) activeEndpointUrl.textContent = endpoint;
        if (jsonOutput) jsonOutput.textContent = 'Fetching...';

        try {
            const res = await fetch(endpoint, { cache: 'no-store' });
            const statusText = `HTTP ${res.status} ${res.statusText || 'OK'}`;
            if (responseStatus) {
                responseStatus.textContent = statusText;
                responseStatus.style.color = res.ok ? '#00e676' : '#ff5252';
            }

            const contentType = res.headers.get('content-type') || '';
            if (contentType.includes('application/json')) {
                const json = await res.json();
                displayJsonOutput(json, res.status);
            } else {
                const text = await res.text();
                displayTextOutput(text, res.status);
            }
        } catch (err) {
            if (responseStatus) {
                responseStatus.textContent = 'Connection Error';
                responseStatus.style.color = '#ff5252';
            }
            if (jsonOutput) jsonOutput.textContent = `Error reaching endpoint: ${err.message}`;
        }
    }

    function displayJsonOutput(json, status) {
        if (jsonOutput) {
            jsonOutput.innerHTML = `<code>${syntaxHighlight(JSON.stringify(json, null, 2))}</code>`;
        }
    }

    function displayTextOutput(text, status) {
        if (jsonOutput) {
            jsonOutput.innerHTML = `<code>${escapeHtml(text)}</code>`;
        }
    }

    function escapeHtml(str) {
        return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function syntaxHighlight(jsonStr) {
        jsonStr = escapeHtml(jsonStr);
        return jsonStr.replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g, match => {
            let cls = 'style="color: #00e5ff"'; // number
            if (/^"/.test(match)) {
                if (/:$/.test(match)) {
                    cls = 'style="color: #94a3b8; font-weight: 600"'; // key
                } else {
                    cls = 'style="color: #00e676"'; // string
                }
            } else if (/true|false/.test(match)) {
                cls = 'style="color: #b388ff; font-weight: 700"'; // boolean
            } else if (/null/.test(match)) {
                cls = 'style="color: #ff5252"'; // null
            }
            return `<span ${cls}>${match}</span>`;
        });
    }

    // Event Listeners
    if (refreshBtn) {
        refreshBtn.addEventListener('click', () => {
            fetchTelemetry();
            if (activeEndpoint !== '/api/info') {
                inspectEndpoint(activeEndpoint);
            }
        });
    }

    pillButtons.forEach(btn => {
        btn.addEventListener('click', () => {
            pillButtons.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            const targetEndpoint = btn.getAttribute('data-endpoint');
            inspectEndpoint(targetEndpoint);
        });
    });

    function setupAutoRefresh() {
        if (pollInterval) clearInterval(pollInterval);
        if (autoRefreshCheck && autoRefreshCheck.checked) {
            pollInterval = setInterval(() => {
                fetchTelemetry();
            }, 3000);
        }
    }

    if (autoRefreshCheck) {
        autoRefreshCheck.addEventListener('change', setupAutoRefresh);
    }

    // Initial Load
    fetchTelemetry();
    setupAutoRefresh();
});
