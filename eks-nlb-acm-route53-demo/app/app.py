import logging
import os
import socket
from flask import Flask, jsonify

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)


@app.get("/")
def home():
    hostname = socket.gethostname()
    app.logger.info("Handling home request from pod: %s", hostname)
    return jsonify(
        message="Hello from Kubernetes on AWS",
        pod=hostname,
        status="running"
    )


@app.get("/healthz")
def health():
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
