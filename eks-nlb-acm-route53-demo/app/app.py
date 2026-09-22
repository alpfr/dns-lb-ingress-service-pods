"""
Enterprise Microservice Architecture on AWS EKS
Includes Interactive Web UI Dashboard, Diagnostic APIs, Prometheus Metrics,
and Kubernetes Downward API Integration.
"""

import logging
import os
import resource
import socket
import sys
import time
from flask import Flask, jsonify, render_template, request

START_TIME = time.time()
REQUEST_COUNT = 0

app = Flask(__name__)

# Configure structured logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s"
)
logger = logging.getLogger("eks-microservice")

# Environment & Kubernetes Downward API variables
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "demo-eks")
APP_VERSION = os.getenv("APP_VERSION", "2.0.0")
POD_NAMESPACE = os.getenv("POD_NAMESPACE", "default")
POD_NAME = os.getenv("POD_NAME", socket.gethostname())
POD_IP = os.getenv("POD_IP", "127.0.0.1")
NODE_NAME = os.getenv("NODE_NAME", "eks-auto-node")
ENVIRONMENT = os.getenv("ENVIRONMENT", "production")


def get_memory_rss_mb() -> float:
    """Return Resident Set Size (RSS) memory in Megabytes."""
    try:
        usage = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        # On macOS, ru_maxrss is in bytes; on Linux, it is in kilobytes
        if sys.platform == "darwin":
            return round(usage / (1024 * 1024), 2)
        return round(usage / 1024, 2)
    except Exception:
        return 0.0


def format_uptime(seconds: float) -> str:
    """Format seconds into human-readable uptime string."""
    seconds = int(seconds)
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, secs = divmod(remainder, 60)
    if days > 0:
        return f"{days}d {hours}h {minutes}m {secs}s"
    if hours > 0:
        return f"{hours}h {minutes}m {secs}s"
    if minutes > 0:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def extract_availability_zone(node_name: str) -> str:
    """Infer or derive Availability Zone from node name or region."""
    # EKS Auto Mode or EC2 private DNS often contains internal IP or region
    region = os.getenv("AWS_REGION", os.getenv("AWS_DEFAULT_REGION", "us-east-1"))
    if "us-east-1a" in node_name:
        return "us-east-1a"
    if "us-east-1b" in node_name:
        return "us-east-1b"
    if "us-east-1c" in node_name:
        return "us-east-1c"
    return f"{region} (Multi-AZ)"


@app.before_request
def count_requests():
    global REQUEST_COUNT
    REQUEST_COUNT += 1


@app.get("/")
def home():
    """
    Root endpoint:
    - Serves interactive Glassmorphic UI Dashboard for web browsers.
    - Serves JSON response if 'Accept: application/json' or '?format=json' is specified.
    """
    uptime_sec = time.time() - START_TIME
    client_ip = request.headers.get("X-Forwarded-For", request.remote_addr or "127.0.0.1").split(",")[0].strip()
    forwarded_proto = request.headers.get("X-Forwarded-Proto", request.scheme).upper()
    forwarded_port = request.headers.get("X-Forwarded-Port", "443" if forwarded_proto == "HTTPS" else "80")
    amzn_trace_id = request.headers.get("X-Amzn-Trace-Id", "Direct Connection")
    az = extract_availability_zone(NODE_NAME)

    # Content negotiation
    wants_json = (
        request.args.get("format") == "json"
        or "application/json" in request.headers.get("Accept", "")
    )

    if wants_json:
        return jsonify({
            "message": "Hello from Kubernetes on AWS",
            "pod": POD_NAME,
            "status": "running",
            "version": APP_VERSION,
            "cluster": CLUSTER_NAME,
            "ingress": {
                "class": "alb",
                "target_type": "ip",
                "client_ip": client_ip,
                "protocol": forwarded_proto,
                "amzn_trace_id": amzn_trace_id
            }
        })

    return render_template(
        "dashboard.html",
        cluster_name=CLUSTER_NAME,
        app_version=APP_VERSION,
        pod_name=POD_NAME,
        pod_namespace=POD_NAMESPACE,
        pod_ip=POD_IP,
        node_name=NODE_NAME,
        availability_zone=az,
        client_ip=client_ip,
        forwarded_proto=forwarded_proto,
        forwarded_port=forwarded_port,
        amzn_trace_id=amzn_trace_id,
        request_host=request.host,
        uptime_formatted=format_uptime(uptime_sec),
        memory_rss=f"{get_memory_rss_mb()} MB",
        python_version=f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        request_count=REQUEST_COUNT
    )


@app.get("/healthz")
def health():
    """Kubernetes liveness probe endpoint."""
    uptime_sec = round(time.time() - START_TIME, 2)
    return jsonify({
        "status": "healthy",
        "service": "demo-app",
        "version": APP_VERSION,
        "pod": POD_NAME,
        "uptime_seconds": uptime_sec
    }), 200


@app.get("/ready")
def readiness():
    """Kubernetes readiness probe endpoint."""
    return jsonify({
        "status": "ready",
        "service": "demo-app",
        "version": APP_VERSION,
        "pod": POD_NAME
    }), 200


@app.get("/api/info")
def api_info():
    """Detailed telemetry payload consumed by UI and observability collectors."""
    uptime_sec = round(time.time() - START_TIME, 2)
    client_ip = request.headers.get("X-Forwarded-For", request.remote_addr or "127.0.0.1").split(",")[0].strip()
    forwarded_proto = request.headers.get("X-Forwarded-Proto", request.scheme).upper()
    forwarded_port = request.headers.get("X-Forwarded-Port", "443" if forwarded_proto == "HTTPS" else "80")
    amzn_trace_id = request.headers.get("X-Amzn-Trace-Id", "Direct Connection")
    az = extract_availability_zone(NODE_NAME)

    return jsonify({
        "version": APP_VERSION,
        "status": "running",
        "cluster": {
            "name": CLUSTER_NAME,
            "environment": ENVIRONMENT
        },
        "pod": {
            "name": POD_NAME,
            "namespace": POD_NAMESPACE,
            "ip": POD_IP,
            "node": NODE_NAME,
            "zone": az
        },
        "ingress": {
            "class": "alb",
            "target_type": "ip",
            "client_ip": client_ip,
            "protocol": forwarded_proto,
            "port": forwarded_port,
            "host": request.host,
            "amzn_trace_id": amzn_trace_id
        },
        "runtime": {
            "python_version": f"Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
            "memory_rss": f"{get_memory_rss_mb()} MB",
            "memory_rss_mb": get_memory_rss_mb(),
            "uptime_seconds": uptime_sec,
            "uptime_formatted": format_uptime(uptime_sec),
            "total_requests": REQUEST_COUNT
        }
    })


@app.get("/api/headers")
def api_headers():
    """Inspection endpoint for incoming HTTP and AWS ALB Ingress headers."""
    headers_dict = {key: value for key, value in request.headers.items()}
    return jsonify({
        "pod": POD_NAME,
        "client_ip": request.remote_addr,
        "headers": headers_dict
    })


@app.get("/metrics")
def metrics():
    """Prometheus-compatible plain text metrics exposition."""
    uptime_sec = round(time.time() - START_TIME, 2)
    memory_bytes = int(get_memory_rss_mb() * 1024 * 1024)

    lines = [
        "# HELP http_requests_total Total number of HTTP requests processed.",
        "# TYPE http_requests_total counter",
        f'http_requests_total{{pod="{POD_NAME}",cluster="{CLUSTER_NAME}"}} {REQUEST_COUNT}',
        "",
        "# HELP app_uptime_seconds Total application uptime in seconds.",
        "# TYPE app_uptime_seconds gauge",
        f'app_uptime_seconds{{pod="{POD_NAME}",cluster="{CLUSTER_NAME}"}} {uptime_sec}',
        "",
        "# HELP process_resident_memory_bytes Resident memory size in bytes.",
        "# TYPE process_resident_memory_bytes gauge",
        f'process_resident_memory_bytes{{pod="{POD_NAME}",cluster="{CLUSTER_NAME}"}} {memory_bytes}',
        ""
    ]
    return "\n".join(lines), 200, {"Content-Type": "text/plain; version=0.0.4"}


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    logger.info("Starting EKS microservice on port %d...", port)
    app.run(host="0.0.0.0", port=port)
