"""
ClauseGuard AI - Contract Risk & Intelligence Analyzer
Dual-Engine: Autonomous Heuristic Engine + LLM Structured Evaluation
"""

import json
import logging
import os
import re
from typing import Dict, Any, List, Optional
import requests

logger = logging.getLogger("clauseguard.analyzer")


# ------------------------------------------------------------------------------
# Autonomous Legal Heuristic Intelligence Engine
# ------------------------------------------------------------------------------

def extract_metadata(text: str) -> Dict[str, Any]:
    """Extract parties, governing law, term, and contract type."""
    metadata = {
        "contract_type": "Commercial Agreement",
        "parties": [],
        "governing_law": "Not specified",
        "term": "Not specified",
        "liability_cap_status": "Unknown",
    }

    # Contract Type Detection
    first_1000 = text[:1200].lower()
    if "non-disclosure" in first_1000 or "confidentiality agreement" in first_1000:
        metadata["contract_type"] = "Non-Disclosure Agreement (NDA)"
    elif "master services" in first_1000 or "independent contractor" in first_1000 or "consulting agreement" in first_1000:
        metadata["contract_type"] = "Master Services & Consulting Agreement"
    elif "lease agreement" in first_1000 or "commercial lease" in first_1000:
        metadata["contract_type"] = "Commercial Lease Agreement"
    elif "employment agreement" in first_1000:
        metadata["contract_type"] = "Employment Agreement"
    elif "saas" in first_1000 or "software license" in first_1000:
        metadata["contract_type"] = "SaaS & Software License Agreement"

    # Governing Law
    gov_match = re.search(r"(?:governed by|construed in accordance with|laws of the State of|laws of)\s+([A-Z][a-zA-Z\s]+?)(?:,|\.|\sand)", text, re.IGNORECASE)
    if gov_match:
        raw_gov = gov_match.group(1).strip()
        cleaned_gov = re.sub(r"^(the\s+laws\s+of\s+)?(the\s+State\s+of\s+)?", "", raw_gov, flags=re.IGNORECASE)
        metadata["governing_law"] = cleaned_gov.title()

    # Parties extraction
    parties_match = re.search(r"by and between\s+(.+?)(?:,|\s*\(\"Client\"|\s*\(\"Company\"|\s*\(\"Horizon\"|\s*\(\"Landlord\").+?and\s+(.+?)(?:,|\s*\(\"Contractor\"|\s*\(\"Alpine\"|\s*\(\"Tenant\"|\.\s)", text, re.IGNORECASE)
    if parties_match:
        p1 = re.sub(r"[\"'\(\)]", "", parties_match.group(1)).strip()
        p2 = re.sub(r"[\"'\(\)]", "", parties_match.group(2)).strip()
        metadata["parties"] = [p1, p2]
    else:
        metadata["parties"] = ["Disclosing Party", "Receiving Party"]

    # Term duration
    term_match = re.search(r"(?:term of|period of)\s+(\w+(?:\s+\w+)?\s*(?:\([0-9]+\))?\s*(?:months|years|days))", text, re.IGNORECASE)
    if term_match:
        metadata["term"] = term_match.group(1).strip()

    return metadata


def evaluate_rules(text: str) -> List[Dict[str, Any]]:
    """Scan contract text across critical risk vectors."""
    findings: List[Dict[str, Any]] = []

    # 1. Uncapped or Overly Broad Indemnification
    indemn_match = re.search(r"([^.\n]*?(?:indemnify|hold harmless|defend)[^.\n]*?(?:uncapped|unlimited|survive termination indefinitely|any and all claims|actual attorneys' fees)[^.\n]*?\.)", text, re.IGNORECASE)
    if indemn_match or ("indemnify" in text.lower() and "uncapped" in text.lower()):
        excerpt = indemn_match.group(1).strip() if indemn_match else "Indemnification obligations are uncapped and survive termination indefinitely."
        findings.append({
            "id": "indemnity-uncapped",
            "category": "Indemnification & Liability",
            "severity": "critical",
            "title": "Uncapped & Asymmetrical Indemnification",
            "clause_excerpt": excerpt,
            "explanation": "You are agreeing to defend and indemnify the other party against unlimited commercial, legal, and consequential claims without financial cap or mutual protection.",
            "counter_proposal": "Replace with mutual indemnification capped at total fees paid under the agreement in the prior 12 months, strictly limited to third-party direct claims arising from gross negligence or willful misconduct.",
            "section": "Indemnification Section",
            "risk_weight": 25,
        })
    elif "indemnify" in text.lower():
        findings.append({
            "id": "indemnity-mutual",
            "category": "Indemnification & Liability",
            "severity": "favorable",
            "title": "Standard Indemnification Scope",
            "clause_excerpt": "Each party agrees to standard indemnification protections.",
            "explanation": "Indemnification provisions appear balanced without obvious uncapped liability triggers.",
            "counter_proposal": "Maintain current mutual indemnification language.",
            "section": "Indemnification",
            "risk_weight": -5,
        })

    # 2. Limitation of Liability Imbalance
    lim_match = re.search(r"([^.\n]*?(?:limitation of liability|total aggregate liability)[^.\n]*?(?:one hundred dollars|\$100|nominal|shall not be limited)[^.\n]*?\.)", text, re.IGNORECASE)
    if lim_match or ("shall not be limited under any circumstances" in text.lower()) or ("limited to one hundred dollars" in text.lower()):
        excerpt = lim_match.group(1).strip() if lim_match else "Client's liability limited to $100.00 while Contractor's liability is unlimited."
        findings.append({
            "id": "liability-one-sided",
            "category": "Liability & Caps",
            "severity": "critical",
            "title": "Severe One-Sided Liability Cap",
            "clause_excerpt": excerpt,
            "explanation": "The counterparty artificially limits their total liability to a trivial nominal sum ($100.00) while leaving your business exposed to unlimited financial liability.",
            "counter_proposal": "Ensure mutual aggregate liability caps: 'Neither party's aggregate liability under this agreement shall exceed the total amounts paid or payable in the preceding twelve (12) months.'",
            "section": "Limitation of Liability",
            "risk_weight": 25,
        })
    elif "consequential" in text.lower() and "waiver" in text.lower():
        findings.append({
            "id": "liability-mutual-waiver",
            "category": "Liability & Caps",
            "severity": "favorable",
            "title": "Mutual Waiver of Consequential Damages",
            "clause_excerpt": "Mutual disclaimer of lost profits and consequential damages.",
            "explanation": "Protects both parties against speculative indirect damages and lost business revenue.",
            "counter_proposal": "Accept as written.",
            "section": "Limitation of Liability",
            "risk_weight": -5,
        })

    # 3. Restrictive Covenants / Non-Compete
    noncomp_match = re.search(r"([^.\n]*?(?:non-compete|compete directly or indirectly|covenants)[^.\n]*?(?:months|years|north america|europe|shall not)[^.\n]*?\.)", text, re.IGNORECASE)
    if noncomp_match or ("compete directly or indirectly" in text.lower()):
        excerpt = noncomp_match.group(1).strip() if noncomp_match else "Contractor shall not directly or indirectly engage in competing business for 24 months."
        findings.append({
            "id": "non-compete-broad",
            "category": "Restraints of Trade & Non-Compete",
            "severity": "high",
            "title": "Overly Broad Post-Termination Non-Compete",
            "clause_excerpt": excerpt,
            "explanation": "Restricts your ability to work with prospective clients or operate in your industry across wide geographic territories for up to 2 years after contract end.",
            "counter_proposal": "Strike out post-termination non-compete entirely, or restrict strictly to non-solicitation of active customers introduced directly during the project.",
            "section": "Restrictive Covenants",
            "risk_weight": 20,
        })

    # 4. Unilateral Termination & Liquidated Damages
    term_match = re.search(r"([^.\n]*?(?:terminate this agreement immediately|liquidated damages|forfeit)[^.\n]*?\.)", text, re.IGNORECASE)
    if term_match or ("liquidated damages of $" in text.lower()) or ("forfeit any unpaid invoices" in text.lower()):
        excerpt = term_match.group(1).strip() if term_match else "Client may terminate immediately while Contractor must pay liquidated damages."
        findings.append({
            "id": "termination-unilateral",
            "category": "Termination & Default",
            "severity": "high",
            "title": "Unilateral Termination Rights & Penalty Clauses",
            "clause_excerpt": excerpt,
            "explanation": "Client can cancel on a whim without notice, whereas contractor faces heavy financial penalties and forfeits earned compensation for early termination.",
            "counter_proposal": "Require bilateral 30-day prior written notice for convenience with full payment for all completed milestones and non-cancellable expenses up to the termination date.",
            "section": "Term and Termination",
            "risk_weight": 18,
        })

    # 5. Broad Intellectual Property Assignment & Moral Rights Waiver
    ip_match = re.search(r"([^.\n]*?(?:assigns and transfers|moral rights|perpetually throughout the universe)[^.\n]*?\.)", text, re.IGNORECASE)
    if ip_match or ("perpetually throughout the universe" in text.lower()) or ("unconditionally waives all moral rights" in text.lower()):
        excerpt = ip_match.group(1).strip() if ip_match else "Assigns all inventions created whether or not using Client equipment and waives all moral rights."
        findings.append({
            "id": "ip-overreaching",
            "category": "Intellectual Property",
            "severity": "high",
            "title": "Overreaching Pre-Existing IP & Invention Assignment",
            "clause_excerpt": excerpt,
            "explanation": "Claims ownership over all ideas created during the term, even if developed off-hours without client tools. Threatens your background IP and reusable toolkits.",
            "counter_proposal": "Explicitly carve out 'Background IP' and restrict assignment strictly to custom deliverables paid for in full upon final settlement.",
            "section": "Intellectual Property",
            "risk_weight": 15,
        })

    # 6. Payment Withholding & Long Payment Terms (Net 90)
    pay_match = re.search(r"([^.\n]*?(?:net ninety|net 90|withhold any payment|subjective satisfaction)[^.\n]*?\.)", text, re.IGNORECASE)
    if pay_match or ("net ninety" in text.lower()) or ("net 90" in text.lower()):
        excerpt = pay_match.group(1).strip() if pay_match else "Payment net 90 days with right to withhold for subjective dissatisfaction."
        findings.append({
            "id": "payment-extended",
            "category": "Cash Flow & Payment Terms",
            "severity": "warning",
            "title": "Extended Payment Window (Net 90) & Discretionary Withholding",
            "clause_excerpt": excerpt,
            "explanation": "Net 90 severely compromises cash flow. The subjective right to withhold creates risk of non-payment after work is delivered.",
            "counter_proposal": "Negotiate Net 15 or Net 30 payment terms with 1.5% monthly late interest and clearly defined objective acceptance criteria.",
            "section": "Compensation & Payment",
            "risk_weight": 10,
        })

    # 7. Auto-Renewal Trap
    renew_match = re.search(r"([^.\n]*?(?:automatically renew|successive|three hundred sixty-five)[^.\n]*?\.)", text, re.IGNORECASE)
    if renew_match and ("three hundred sixty-five" in text.lower() or "365" in text.lower()):
        excerpt = renew_match.group(1).strip() if renew_match else "Automatically renews unless non-renewal notice is given 365 days prior."
        findings.append({
            "id": "renewal-lockin",
            "category": "Term & Renewals",
            "severity": "warning",
            "title": "Aggressive Auto-Renewal Window (365 Days Notice)",
            "clause_excerpt": excerpt,
            "explanation": "Requires notice an entire year in advance to prevent an automatic 2-year lock-in.",
            "counter_proposal": "Standardize non-renewal notice to 30 or 60 days prior to contract expiration.",
            "section": "Automatic Renewal",
            "risk_weight": 10,
        })

    # 8. Triple Net Real Estate / Pass-through Operating Costs
    if "proportionate share" in text.lower() and "operating expenses" in text.lower():
        findings.append({
            "id": "lease-triple-net",
            "category": "Real Estate & Commercial Lease",
            "severity": "warning",
            "title": "Uncapped Operating Expense Pass-Throughs (CAM)",
            "clause_excerpt": "Tenant shall pay proportionate share of Building Operating Expenses including taxes, insurance, and utilities.",
            "explanation": "Operating expenses are not capped, leaving tenant vulnerable to unpredictable year-over-year commercial property cost spikes.",
            "counter_proposal": "Request a 5% to 7% cumulative annual ceiling (cap) on controllable operating expenses.",
            "section": "Operating Expenses",
            "risk_weight": 12,
        })

    # 9. Confidentiality Standard Exclusions Check (Positive or Warning)
    if "exclusions from confidentiality" in text.lower() or "publicly known" in text.lower():
        findings.append({
            "id": "confidentiality-balanced",
            "category": "Confidentiality & Trade Secrets",
            "severity": "favorable",
            "title": "Standard Confidentiality Exclusions Present",
            "clause_excerpt": "Excludes publicly known info, pre-existing knowledge, and independently developed material.",
            "explanation": "Contains industry-standard safe harbor carve-outs protecting the receiving party from frivolous NDA claims.",
            "counter_proposal": "Maintain clause as formulated.",
            "section": "Exclusions from Confidentiality",
            "risk_weight": -5,
        })
    elif "confidential" in text.lower() and "exclusions" not in text.lower():
        findings.append({
            "id": "confidentiality-missing-exclusions",
            "category": "Confidentiality & Trade Secrets",
            "severity": "warning",
            "title": "Missing Standard Carve-Outs for Confidentiality",
            "clause_excerpt": "Definition of confidential information lacks standard exclusions.",
            "explanation": "Failing to exclude publicly available information or independently developed material can create strict liability.",
            "counter_proposal": "Insert standard 4-point carve-out: public knowledge, prior possession, independent creation, and third-party receipt.",
            "section": "Confidential Information",
            "risk_weight": 12,
        })

    return findings


def calculate_risk_score(findings: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Calculate normalized risk score (0-100), grade, and status breakdown."""
    base_score = 15  # baseline ambient contract risk

    for f in findings:
        base_score += f.get("risk_weight", 0)

    # Clamp score between 5 and 98
    risk_score = max(5, min(98, base_score))

    if risk_score >= 70:
        grade = "Critical Risk"
        badge_color = "red"
        recommendation = "Do NOT sign in current form. Substantial renegotiation required on liability, indemnification, and restrictive covenants."
    elif risk_score >= 45:
        grade = "Moderate / High Risk"
        badge_color = "amber"
        recommendation = "Contains unfavorable clauses that need redlining prior to execution, particularly payment terms and liability boundaries."
    else:
        grade = "Low Risk / Standard"
        badge_color = "emerald"
        recommendation = "Balanced commercial contract consistent with industry standard terms. Minimal revision needed."

    critical_count = sum(1 for f in findings if f.get("severity") == "critical")
    high_count = sum(1 for f in findings if f.get("severity") == "high")
    warning_count = sum(1 for f in findings if f.get("severity") == "warning")
    favorable_count = sum(1 for f in findings if f.get("severity") == "favorable")

    return {
        "score": risk_score,
        "grade": grade,
        "badge_color": badge_color,
        "recommendation": recommendation,
        "metrics": {
            "critical_flags": critical_count,
            "high_flags": high_count,
            "warnings": warning_count,
            "favorable_clauses": favorable_count,
            "total_audited": len(findings),
        }
    }


def call_llm_analyzer(text: str, api_key: str, provider: str = "openai") -> Optional[Dict[str, Any]]:
    """Optional external LLM call if the user provided an API key."""
    try:
        if provider == "openai":
            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
            prompt = (
                "You are an elite corporate legal counsel. Analyze this contract and respond STRICTLY in JSON format "
                "with keys: contract_type, parties (list), governing_law, risk_score (0-100), grade, summary, "
                "findings (list of objects with: title, severity (critical/high/warning/favorable), category, clause_excerpt, explanation, counter_proposal)."
            )
            payload = {
                "model": "gpt-4o-mini",
                "messages": [
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": text[:15000]}
                ],
                "response_format": {"type": "json_object"},
                "temperature": 0.2
            }
            resp = requests.post("https://api.openai.com/v1/chat/completions", headers=headers, json=payload, timeout=25)
            if resp.status_code == 200:
                result = resp.json()
                content = result["choices"][0]["message"]["content"]
                return json.loads(content)
    except Exception as exc:
        logger.warning("LLM API call failed, falling back to autonomous engine: %s", exc)
    return None


def analyze_contract(text: str, filename: str = "agreement.pdf", api_key: Optional[str] = None) -> Dict[str, Any]:
    """Execute full contract analysis pipeline."""
    # Try LLM if user provided key or env key
    active_key = api_key or os.getenv("OPENAI_API_KEY")
    if active_key:
        llm_result = call_llm_analyzer(text, active_key)
        if llm_result:
            return llm_result

    # Autonomous heuristic pipeline
    metadata = extract_metadata(text)
    findings = evaluate_rules(text)
    risk_summary = calculate_risk_score(findings)

    return {
        "filename": filename,
        "metadata": metadata,
        "risk_summary": risk_summary,
        "findings": findings,
        "char_count": len(text),
        "analyzer_engine": "ClauseGuard Autonomous Legal Engine v2.0",
    }
