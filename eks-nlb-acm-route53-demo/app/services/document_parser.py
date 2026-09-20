"""
Document Parser Service
Extracts raw text and metadata from PDF, TXT, and Markdown files.
"""

import io
import re
from typing import Dict, Any, List
from pypdf import PdfReader


def clean_text(text: str) -> str:
    """Normalize whitespace and remove non-printable characters."""
    if not text:
        return ""
    text = re.sub(r"\r\n|\r", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()


def parse_pdf(file_bytes: bytes) -> Dict[str, Any]:
    """Extract text from PDF pages with page numbers."""
    reader = PdfReader(io.BytesIO(file_bytes))
    pages: List[Dict[str, Any]] = []
    full_text_parts: List[str] = []

    for idx, page in enumerate(reader.pages):
        raw_text = page.extract_text() or ""
        cleaned = clean_text(raw_text)
        page_num = idx + 1
        pages.append({
            "page_number": page_num,
            "text": cleaned,
            "char_count": len(cleaned),
        })
        full_text_parts.append(f"[Page {page_num}]\n{cleaned}")

    full_text = "\n\n".join(full_text_parts)
    return {
        "format": "pdf",
        "total_pages": len(pages),
        "full_text": full_text,
        "pages": pages,
        "char_count": len(full_text),
    }


def parse_text(text_content: str, filename: str = "document.txt") -> Dict[str, Any]:
    """Parse plain text or markdown document into simulated pages."""
    cleaned = clean_text(text_content)
    # Break into simulated pages of ~3000 chars for consistent UX
    chunk_size = 3000
    chunks = [cleaned[i:i + chunk_size] for i in range(0, len(cleaned), chunk_size)]
    if not chunks:
        chunks = [""]

    pages = [
        {"page_number": idx + 1, "text": chunk, "char_count": len(chunk)}
        for idx, chunk in enumerate(chunks)
    ]

    return {
        "format": "text",
        "total_pages": len(pages),
        "full_text": cleaned,
        "pages": pages,
        "char_count": len(cleaned),
    }


def parse_document(file_bytes: bytes, filename: str) -> Dict[str, Any]:
    """Dispatch document parsing based on file extension."""
    lower_name = filename.lower()
    if lower_name.endswith(".pdf"):
        return parse_pdf(file_bytes)
    else:
        text_content = file_bytes.decode("utf-8", errors="replace")
        return parse_text(text_content, filename)
