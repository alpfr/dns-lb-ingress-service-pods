"""
Unit Tests for EKS Enterprise Microservice
"""

import pytest
import json
import sys
import os

# Add app directory to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_home_html_dashboard(client):
    """Test that GET / returns the interactive HTML dashboard for browser requests."""
    response = client.get("/")
    assert response.status_code == 200
    assert response.content_type.startswith("text/html")
    html = response.get_data(as_text=True)
    assert "EKS Microservice" in html
    assert "AWS Application Load Balancer" in html
    assert "Direct IP" in html
    assert "CLUSTER OPERATIONAL" in html


def test_home_json_negotiation(client):
    """Test that GET / returns JSON when requested via Accept header or query param."""
    # Via Accept header
    res_header = client.get("/", headers={"Accept": "application/json"})
    assert res_header.status_code == 200
    assert res_header.is_json
    data = res_header.get_json()
    assert data["status"] == "running"
    assert "pod" in data
    assert data["ingress"]["class"] == "alb"
    assert data["ingress"]["target_type"] == "ip"

    # Via query param
    res_param = client.get("/?format=json")
    assert res_param.status_code == 200
    assert res_param.is_json
    data_param = res_param.get_json()
    assert data_param["message"] == "Hello from Kubernetes on AWS"


def test_healthz_liveness(client):
    """Test that /healthz returns 200 OK and healthy status."""
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.is_json
    data = response.get_json()
    assert data["status"] == "healthy"
    assert data["service"] == "demo-app"
    assert "uptime_seconds" in data


def test_ready_readiness(client):
    """Test that /ready returns 200 OK and ready status."""
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.is_json
    data = response.get_json()
    assert data["status"] == "ready"
    assert data["service"] == "demo-app"


def test_api_info_telemetry(client):
    """Test that /api/info returns complete cluster and pod telemetry."""
    response = client.get("/api/info", headers={
        "X-Forwarded-For": "203.0.113.195",
        "X-Forwarded-Proto": "https",
        "X-Amzn-Trace-Id": "Root=1-6789abcd-0123456789abcdef01234567"
    })
    assert response.status_code == 200
    assert response.is_json
    data = response.get_json()
    assert "pod" in data
    assert "ingress" in data
    assert "runtime" in data
    assert data["ingress"]["client_ip"] == "203.0.113.195"
    assert data["ingress"]["protocol"] == "HTTPS"
    assert "Root=1-6789abcd" in data["ingress"]["amzn_trace_id"]
    assert "memory_rss" in data["runtime"]
    assert data["runtime"]["total_requests"] >= 1


def test_api_headers_inspector(client):
    """Test that /api/headers inspects incoming HTTP headers."""
    response = client.get("/api/headers", headers={"X-Custom-Header": "EKS-ALB-Demo"})
    assert response.status_code == 200
    assert response.is_json
    data = response.get_json()
    assert "headers" in data
    assert data["headers"].get("X-Custom-Header") == "EKS-ALB-Demo"


def test_metrics_prometheus(client):
    """Test that /metrics returns Prometheus-compatible plain text format."""
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "text/plain" in response.content_type
    text = response.get_data(as_text=True)
    assert "# HELP http_requests_total" in text
    assert "# HELP app_uptime_seconds" in text
    assert "# HELP process_resident_memory_bytes" in text
    assert "http_requests_total" in text
