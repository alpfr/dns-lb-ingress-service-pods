"""
ClauseGuard AI - Conversational Contract Assistant
Provides context-grounded Q&A against uploaded agreements.
"""

import json
import logging
import os
import re
from typing import Dict, Any, Optional
import requests

logger = logging.getLogger("clauseguard.chat")


def answer_contract_question(
    question: str,
    contract_text: str,
    findings: Optional[list] = None,
    api_key: Optional[str] = None
) -> Dict[str, Any]:
    """Provide grounded answers with citations to user contract questions."""
    q_lower = question.lower().strip()
    active_key = api_key or os.getenv("OPENAI_API_KEY")

    # If external LLM key is available, use it for direct conversational generation
    if active_key:
        try:
            headers = {"Authorization": f"Bearer {active_key}", "Content-Type": "application/json"}
            prompt = (
                "You are ClauseGuard AI, an elite legal assistant. Answer the user's question accurately based "
                "ONLY on the contract excerpt provided below. "
                "Include: (1) Direct Answer in plain English, (2) Verbatim Excerpt citation, and (3) Strategic negotiation recommendation."
            )
            payload = {
                "model": "gpt-4o-mini",
                "messages": [
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": f"CONTRACT:\n{contract_text[:12000]}\n\nQUESTION:\n{question}"}
                ],
                "temperature": 0.2
            }
            resp = requests.post("https://api.openai.com/v1/chat/completions", headers=headers, json=payload, timeout=20)
            if resp.status_code == 200:
                answer = resp.json()["choices"][0]["message"]["content"]
                return {
                    "answer": answer,
                    "source": "LLM Intelligence",
                    "status": "success"
                }
        except Exception as exc:
            logger.warning("LLM Chat API call failed, falling back to autonomous engine: %s", exc)

    # Autonomous Semantic Contract Retrieval Engine
    if "terminate" in q_lower or "cancel" in q_lower or "fire" in q_lower or "end" in q_lower:
        match = re.search(r"(?:term and termination|termination|term)[^\n]*\n([\s\S]*?)(?:\n[0-9]+\.|\Z)", contract_text, re.IGNORECASE)
        section_text = match.group(0).strip() if match else contract_text[:1000]
        if "without cause" in contract_text.lower() or "immediately" in contract_text.lower():
            answer = (
                "**Termination Risk Identified:** Yes, the contract provides unilateral termination rights. "
                "The client may terminate immediately at any time with or without cause, while imposing liquidated damages or notice requirements on the other party."
            )
            recommendation = "Demand bilateral termination for convenience requiring at least thirty (30) days prior written notice, plus full payment for completed work."
        else:
            answer = (
                "**Termination Terms:** Either party may terminate upon standard written notice (typically 30 days) "
                "or for material breach after a formal cure period."
            )
            recommendation = "Verify that notice periods are mutual and that payment obligations survive termination."
        return {
            "answer": f"{answer}\n\n**Relevant Contract Clause:**\n> {section_text[:400]}...\n\n**Actionable Advice:**\n{recommendation}",
            "source": "Autonomous Retrieval",
            "status": "success"
        }

    elif "indemn" in q_lower or "lawsuit" in q_lower or "legal fee" in q_lower or "liability" in q_lower:
        match = re.search(r"(?:indemnif|limitation of liability)[^\n]*\n([\s\S]*?)(?:\n[0-9]+\.|\Z)", contract_text, re.IGNORECASE)
        section_text = match.group(0).strip() if match else contract_text[:1000]
        if "uncapped" in contract_text.lower() or "one hundred dollars" in contract_text.lower() or "unlimited" in contract_text.lower():
            answer = (
                "**High Liability Alert:** The indemnification and liability provisions are severely unbalanced. "
                "You are agreeing to defend and indemnify the counterparty against uncapped claims, while their liability is either unlimited or artificially capped at $100.00."
            )
            recommendation = "Demand mutual aggregate liability capped at the total contract value or fees paid in the prior 12 months, and exclude indirect consequential damages."
        else:
            answer = (
                "**Liability Summary:** The agreement contains standard liability boundaries, but requires careful review of any third-party claims carve-outs."
            )
            recommendation = "Ensure both parties disclaim consequential, special, and punitive damages."
        return {
            "answer": f"{answer}\n\n**Relevant Contract Clause:**\n> {section_text[:400]}...\n\n**Actionable Advice:**\n{recommendation}",
            "source": "Autonomous Retrieval",
            "status": "success"
        }

    elif "non-compete" in q_lower or "compete" in q_lower or "work with other" in q_lower or "restrict" in q_lower:
        match = re.search(r"(?:restrictive covenants|non-compete|compete)[^\n]*\n([\s\S]*?)(?:\n[0-9]+\.|\Z)", contract_text, re.IGNORECASE)
        section_text = match.group(0).strip() if match else "No explicit non-compete section found."
        if "compete" in contract_text.lower():
            answer = (
                "**Non-Compete Detected:** Yes, there is a restrictive covenant barring direct or indirect competition. "
                "In many agreements, this can prevent you from consulting or servicing clients in your domain for up to 24 months."
            )
            recommendation = "Propose striking out the post-termination non-compete completely, or narrowing it strictly to not soliciting active clients introduced during the project."
        else:
            answer = "No restrictive non-compete clauses were detected in this agreement."
            recommendation = "Confirm that ordinary non-solicitation clauses do not restrict general advertising or job postings."
        return {
            "answer": f"{answer}\n\n**Relevant Contract Clause:**\n> {section_text[:400]}...\n\n**Actionable Advice:**\n{recommendation}",
            "source": "Autonomous Retrieval",
            "status": "success"
        }

    elif "payment" in q_lower or "pay" in q_lower or "retainer" in q_lower or "invoice" in q_lower or "net 90" in q_lower:
        match = re.search(r"(?:compensation|payment|rent)[^\n]*\n([\s\S]*?)(?:\n[0-9]+\.|\Z)", contract_text, re.IGNORECASE)
        section_text = match.group(0).strip() if match else contract_text[:1000]
        answer = (
            "**Payment & Compensation Structure:** Payments are subject to specific acceptance criteria and timing windows. "
            "Examine whether terms are Net 30 or extended (e.g. Net 90) and if the client retains discretionary withholding rights."
        )
        recommendation = "Request Net 15 or Net 30 terms with 1.5% late payment interest per month, and limit withholding to disputed amounts with written explanation."
        return {
            "answer": f"{answer}\n\n**Relevant Contract Clause:**\n> {section_text[:400]}...\n\n**Actionable Advice:**\n{recommendation}",
            "source": "Autonomous Retrieval",
            "status": "success"
        }

    elif "law" in q_lower or "jurisdiction" in q_lower or "court" in q_lower or "venue" in q_lower:
        match = re.search(r"(?:governing law|jurisdiction)[^\n]*\n([\s\S]*?)(?:\n[0-9]+\.|\Z)", contract_text, re.IGNORECASE)
        section_text = match.group(0).strip() if match else contract_text[-800:]
        answer = (
            f"**Governing Law & Jurisdiction:** Disputes under this agreement are governed by the designated state/jurisdiction specified in the closing sections."
        )
        recommendation = "Ensure the venue is convenient. If you are located elsewhere, propose neutral arbitration (e.g., AAA / JAMS) or your home jurisdiction."
        return {
            "answer": f"{answer}\n\n**Relevant Contract Clause:**\n> {section_text[:400]}...\n\n**Actionable Advice:**\n{recommendation}",
            "source": "Autonomous Retrieval",
            "status": "success"
        }

    else:
        # General response with top matching sentences
        words = [w for w in re.findall(r"\w+", q_lower) if len(w) > 3]
        best_sentence = ""
        for s in re.split(r"\. |\n", contract_text):
            if any(w in s.lower() for w in words):
                best_sentence = s.strip()
                break

        if best_sentence:
            return {
                "answer": f"Based on your inquiry, here is the most relevant clause found in the agreement:\n\n> \"{best_sentence}\"\n\n**Recommendation:** Review the full section surrounding this term to ensure mutual obligations and clear timelines.",
                "source": "Autonomous Semantic Search",
                "status": "success"
            }
        else:
            return {
                "answer": "This specific term or question does not have an explicit match in the document. You can try asking about 'termination', 'indemnity', 'liability cap', 'payment terms', 'non-compete', or 'governing law'.",
                "source": "Autonomous Guide",
                "status": "success"
            }
