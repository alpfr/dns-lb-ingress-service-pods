/**
 * ClauseGuard AI - Client-side Interactive Application Logic
 */

document.addEventListener("DOMContentLoaded", () => {
  // Global State
  let currentContractText = "";
  let currentAnalysis = null;
  let customApiKey = localStorage.getItem("clauseguard_api_key") || "";

  // DOM Elements
  const dropzone = document.getElementById("dropzone");
  const fileInput = document.getElementById("file-input");
  const browseBtn = document.getElementById("browse-btn");
  const sampleCards = document.querySelectorAll(".sample-card");
  const loadingOverlay = document.getElementById("loading-overlay");
  const loadingStatusText = document.getElementById("loading-status-text");
  const uploadSection = document.getElementById("upload-section");
  const heroSection = document.getElementById("hero-section");
  const resultsDashboard = document.getElementById("results-dashboard");
  const resetDocBtn = document.getElementById("reset-doc-btn");
  const exportBtn = document.getElementById("export-btn");

  // Dashboard Elements
  const riskScoreVal = document.getElementById("risk-score-val");
  const gaugeCircle = document.getElementById("gauge-circle");
  const riskBadge = document.getElementById("risk-badge");
  const docTitleDisplay = document.getElementById("doc-title-display");
  const docRecDisplay = document.getElementById("doc-recommendation-display");
  const metaType = document.getElementById("meta-type");
  const metaParties = document.getElementById("meta-parties");
  const metaJurisdiction = document.getElementById("meta-jurisdiction");
  const metaTerm = document.getElementById("meta-term");
  const findingsContainer = document.getElementById("findings-container");

  // Metrics Pills
  const metricCritical = document.getElementById("metric-critical-count");
  const metricWarning = document.getElementById("metric-warning-count");
  const metricFavorable = document.getElementById("metric-favorable-count");

  // Chat Elements
  const chatForm = document.getElementById("chat-form");
  const chatInput = document.getElementById("chat-input");
  const chatMessages = document.getElementById("chat-messages");
  const promptChips = document.querySelectorAll(".prompt-chip");

  // Theme & Settings Elements
  const themeToggleBtn = document.getElementById("theme-toggle-btn");
  const themeIcon = document.getElementById("theme-icon");
  const settingsBtn = document.getElementById("settings-btn");
  const settingsModal = document.getElementById("settings-modal");
  const closeModalBtn = document.getElementById("close-modal-btn");
  const saveSettingsBtn = document.getElementById("save-settings-btn");
  const apiKeyInput = document.getElementById("api-key-input");

  // Load Saved Theme
  const savedTheme = localStorage.getItem("clauseguard_theme") || "dark";
  document.documentElement.setAttribute("data-theme", savedTheme);
  themeIcon.textContent = savedTheme === "dark" ? "🌙" : "☀️";

  themeToggleBtn.addEventListener("click", () => {
    const currentTheme = document.documentElement.getAttribute("data-theme");
    const nextTheme = currentTheme === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", nextTheme);
    localStorage.setItem("clauseguard_theme", nextTheme);
    themeIcon.textContent = nextTheme === "dark" ? "🌙" : "☀️";
  });

  // Settings Modal Handlers
  settingsBtn.addEventListener("click", () => {
    apiKeyInput.value = customApiKey;
    settingsModal.style.display = "flex";
  });

  closeModalBtn.addEventListener("click", () => {
    settingsModal.style.display = "none";
  });

  saveSettingsBtn.addEventListener("click", () => {
    customApiKey = apiKeyInput.value.trim();
    localStorage.setItem("clauseguard_api_key", customApiKey);
    settingsModal.style.display = "none";
  });

  // File Upload Handlers
  browseBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    fileInput.click();
  });

  dropzone.addEventListener("click", () => {
    fileInput.click();
  });

  ["dragenter", "dragover"].forEach(event => {
    dropzone.addEventListener(event, (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropzone.classList.add("dragover");
    });
  });

  ["dragleave", "drop"].forEach(event => {
    dropzone.addEventListener(event, (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropzone.classList.remove("dragover");
    });
  });

  dropzone.addEventListener("drop", (e) => {
    const files = e.dataTransfer.files;
    if (files.length > 0) {
      handleFileUpload(files[0]);
    }
  });

  fileInput.addEventListener("change", (e) => {
    if (e.target.files.length > 0) {
      handleFileUpload(e.target.files[0]);
    }
  });

  // Sample Card Click Handlers
  sampleCards.forEach(card => {
    card.addEventListener("click", async () => {
      const sampleId = card.getAttribute("data-sample");
      showLoading("Loading and analyzing sample contract...");
      try {
        const resp = await fetch(`/api/samples/${sampleId}`);
        if (!resp.ok) throw new Error("Failed to load sample");
        const data = await resp.json();
        
        await analyzeContractText(data.text, data.title);
      } catch (err) {
        alert("Error loading sample: " + err.message);
        hideLoading();
      }
    });
  });

  // Reset to Upload Screen
  resetDocBtn.addEventListener("click", () => {
    resultsDashboard.style.display = "none";
    uploadSection.style.display = "block";
    heroSection.style.display = "block";
    fileInput.value = "";
    currentContractText = "";
    currentAnalysis = null;
  });

  // Export / Print PDF
  exportBtn.addEventListener("click", () => {
    window.print();
  });

  // Upload Processing
  async function handleFileUpload(file) {
    showLoading(`Parsing and analyzing ${file.name}...`);

    const formData = new FormData();
    formData.append("file", file);
    if (customApiKey) {
      formData.append("api_key", customApiKey);
    }

    try {
      const resp = await fetch("/api/analyze/upload", {
        method: "POST",
        body: formData,
      });

      if (!resp.ok) {
        const errData = await resp.json();
        throw new Error(errData.detail || "Analysis failed");
      }

      const result = await resp.json();
      renderAnalysis(result);
    } catch (err) {
      alert("Analysis error: " + err.message);
      hideLoading();
    }
  }

  // Analyze Raw Text
  async function analyzeContractText(text, title) {
    try {
      const payload = {
        text: text,
        filename: title,
        api_key: customApiKey || null
      };

      const resp = await fetch("/api/analyze/text", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      if (!resp.ok) {
        const errData = await resp.json();
        throw new Error(errData.detail || "Analysis failed");
      }

      const result = await resp.json();
      renderAnalysis(result);
    } catch (err) {
      alert("Analysis error: " + err.message);
      hideLoading();
    }
  }

  function showLoading(msg) {
    loadingStatusText.textContent = msg || "Auditing contract clauses...";
    uploadSection.style.display = "none";
    heroSection.style.display = "none";
    resultsDashboard.style.display = "none";
    loadingOverlay.style.display = "block";
  }

  function hideLoading() {
    loadingOverlay.style.display = "none";
  }

  // Render Dashboard
  function renderAnalysis(data) {
    currentAnalysis = data;
    currentContractText = data.extracted_text || "";
    hideLoading();

    uploadSection.style.display = "none";
    heroSection.style.display = "none";
    resultsDashboard.style.display = "block";

    // Metadata
    const meta = data.metadata || {};
    const risk = data.risk_summary || {};
    docTitleDisplay.textContent = data.filename || "Contract Analysis";
    docRecDisplay.textContent = risk.recommendation || "";
    metaType.textContent = meta.contract_type || "Commercial Agreement";
    metaParties.textContent = (meta.parties && meta.parties.length > 0) ? meta.parties.join(" & ") : "Not specified";
    metaJurisdiction.textContent = meta.governing_law || "Not specified";
    metaTerm.textContent = meta.term || "Not specified";

    // Risk Meter Animation
    const score = risk.score || 0;
    riskScoreVal.textContent = score;

    // Circumference = 2 * PI * 70 =~ 440
    const circumference = 440;
    const offset = circumference - (circumference * score / 100);
    gaugeCircle.style.strokeDashoffset = offset;

    let badgeClass = "badge-emerald";
    let circleColor = "#10b981";

    if (score >= 70) {
      badgeClass = "badge-red";
      circleColor = "#ef4444";
    } else if (score >= 45) {
      badgeClass = "badge-amber";
      circleColor = "#f59e0b";
    }

    gaugeCircle.style.stroke = circleColor;
    riskBadge.className = `verdict-badge ${badgeClass}`;
    riskBadge.textContent = risk.grade || "Risk Assessment";

    // Metrics counts
    const metrics = risk.metrics || {};
    metricCritical.textContent = (metrics.critical_flags || 0) + (metrics.high_flags || 0);
    metricWarning.textContent = metrics.warnings || 0;
    metricFavorable.textContent = metrics.favorable_clauses || 0;

    // Findings List Rendering
    findingsContainer.innerHTML = "";
    const findings = data.findings || [];

    if (findings.length === 0) {
      findingsContainer.innerHTML = `
        <div class="finding-card">
          <div class="finding-title">No Critical Risk Flags Detected</div>
          <p class="finding-explanation">The automated audit did not detect high-severity legal liabilities or asymmetrical covenants in this document.</p>
        </div>
      `;
    } else {
      findings.forEach(finding => {
        const card = createFindingCard(finding);
        findingsContainer.appendChild(card);
      });
    }

    // Reset Chat Messages with personalized prompt
    chatMessages.innerHTML = `
      <div class="chat-msg msg-assistant">
        <div class="msg-bubble">
          I've finished auditing <strong>${data.filename}</strong> (Risk Score: ${score}/100). You can ask me specific questions about terms, penalties, or liabilities below.
        </div>
        <span class="msg-time">Just now</span>
      </div>
    `;

    // Scroll to dashboard smoothly
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  // Create Individual Finding Card Component
  function createFindingCard(finding) {
    const card = document.createElement("div");
    card.className = "finding-card";

    let indicatorClass = "indicator-warning";
    if (finding.severity === "critical") indicatorClass = "indicator-critical";
    else if (finding.severity === "high") indicatorClass = "indicator-high";
    else if (finding.severity === "favorable") indicatorClass = "indicator-favorable";

    const excerptHtml = finding.clause_excerpt ? `
      <div class="clause-quote-box">
        &ldquo;${escapeHtml(finding.clause_excerpt)}&rdquo;
      </div>
    ` : "";

    const counterHtml = finding.counter_proposal ? `
      <div class="counter-box">
        <div class="counter-header">
          <div class="counter-label">
            <span>⚡ Proposed Negotiation Counter-Clause:</span>
          </div>
          <button type="button" class="btn-copy" data-copy="${escapeHtml(finding.counter_proposal)}">
            <span>📋 Copy Language</span>
          </button>
        </div>
        <div class="counter-text">${escapeHtml(finding.counter_proposal)}</div>
      </div>
    ` : "";

    card.innerHTML = `
      <div class="finding-header">
        <div class="finding-title-group">
          <div class="severity-indicator ${indicatorClass}"></div>
          <div class="finding-title">${escapeHtml(finding.title)}</div>
        </div>
        <span class="finding-category-badge">${escapeHtml(finding.category || "General")}</span>
      </div>
      ${excerptHtml}
      <div class="finding-explanation">${escapeHtml(finding.explanation)}</div>
      ${counterHtml}
    `;

    // Add Copy Button Handler
    const copyBtn = card.querySelector(".btn-copy");
    if (copyBtn) {
      copyBtn.addEventListener("click", () => {
        const textToCopy = copyBtn.getAttribute("data-copy");
        navigator.clipboard.writeText(textToCopy).then(() => {
          copyBtn.innerHTML = "<span>✔ Copied!</span>";
          copyBtn.style.background = "#10b981";
          copyBtn.style.color = "#ffffff";
          setTimeout(() => {
            copyBtn.innerHTML = "<span>📋 Copy Language</span>";
            copyBtn.style.background = "";
            copyBtn.style.color = "";
          }, 2000);
        });
      });
    }

    return card;
  }

  // Interactive Chat Assistant Handler
  chatForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const query = chatInput.value.trim();
    if (!query) return;

    appendUserMessage(query);
    chatInput.value = "";

    const typingMsg = appendAssistantTyping();

    try {
      const resp = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          question: query,
          contract_text: currentContractText,
          api_key: customApiKey || null
        })
      });

      if (!resp.ok) throw new Error("Chat request failed");
      const data = await resp.json();
      typingMsg.remove();
      appendAssistantMessage(data.answer);
    } catch (err) {
      typingMsg.remove();
      appendAssistantMessage("Sorry, I encountered an error answering your question: " + err.message);
    }
  });

  // Suggested Prompts Handlers
  promptChips.forEach(chip => {
    chip.addEventListener("click", () => {
      const question = chip.getAttribute("data-q");
      chatInput.value = question;
      chatForm.dispatchEvent(new Event("submit"));
    });
  });

  function appendUserMessage(text) {
    const msg = document.createElement("div");
    msg.className = "chat-msg msg-user";
    msg.innerHTML = `
      <div class="msg-bubble">${escapeHtml(text)}</div>
      <span class="msg-time">You</span>
    `;
    chatMessages.appendChild(msg);
    chatMessages.scrollTop = chatMessages.scrollHeight;
  }

  function appendAssistantMessage(text) {
    const msg = document.createElement("div");
    msg.className = "chat-msg msg-assistant";
    // Parse basic markdown quotes and bolding for clean display
    const formatted = formatMarkdown(text);
    msg.innerHTML = `
      <div class="msg-bubble">${formatted}</div>
      <span class="msg-time">ClauseGuard Assistant</span>
    `;
    chatMessages.appendChild(msg);
    chatMessages.scrollTop = chatMessages.scrollHeight;
  }

  function appendAssistantTyping() {
    const msg = document.createElement("div");
    msg.className = "chat-msg msg-assistant";
    msg.innerHTML = `
      <div class="msg-bubble" style="color: var(--text-dim); font-style: italic;">
        Consulting contract clauses...
      </div>
    `;
    chatMessages.appendChild(msg);
    chatMessages.scrollTop = chatMessages.scrollHeight;
    return msg;
  }

  function formatMarkdown(str) {
    if (!str) return "";
    let html = escapeHtml(str);
    // Bold
    html = html.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
    // Blockquotes
    html = html.replace(/^&gt; (.*$)/gim, '<blockquote style="border-left: 3px solid var(--accent-primary); padding-left: 0.75rem; margin: 0.5rem 0; color: var(--text-muted); font-style: italic;">$1</blockquote>');
    // Newlines
    html = html.replace(/\n\n/g, '<br><br>');
    return html;
  }

  function escapeHtml(str) {
    if (!str) return "";
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }
});
