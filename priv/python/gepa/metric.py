"""
Citation accuracy metric for GEPA optimization.

Scores advocate output by:
  - Verification rate (40%): SOURCED items passing VerifyCitation
  - Format compliance (20%): parses with expected regex
  - Citation validity (20%): [Paper N] refs point to real papers
  - Production feedback (20%): historical verification rate from PromptFeedback store
"""

import json
import os
import re
from pathlib import Path


# Regex matching the expected evidence format
EVIDENCE_PATTERN = re.compile(
    r"\d+\.\s*\[(SOURCED|REASONING)\]\s*\(strength:\s*\d+\)\s*.+", re.IGNORECASE
)
PAPER_REF_PATTERN = re.compile(r"\[Paper (\d+)\]")


def citation_accuracy_metric(example, prediction, trace=None):
    """
    Composite metric for GEPA optimization.

    Args:
        example: DSPy Example with input fields (claim, papers_context, etc.)
        prediction: DSPy Prediction with evidence output
        trace: Optional execution trace for debugging

    Returns:
        float: Score between 0.0 and 1.0
    """
    evidence_text = prediction.evidence if hasattr(prediction, "evidence") else ""
    if not evidence_text:
        return 0.0

    # 1. Format compliance (20%)
    lines = [l.strip() for l in evidence_text.strip().split("\n") if l.strip()]
    format_matches = sum(1 for l in lines if EVIDENCE_PATTERN.match(l))
    format_score = min(format_matches / max(len(lines), 1), 1.0)

    # 2. Citation validity (20%): [Paper N] refs point to real papers
    papers_context = getattr(example, "papers_context", "")
    max_paper_num = len(re.findall(r"\[Paper \d+\]", papers_context))
    if max_paper_num == 0:
        max_paper_num = 20  # Fallback

    refs = [int(m) for m in PAPER_REF_PATTERN.findall(evidence_text)]
    valid_refs = sum(1 for r in refs if 1 <= r <= max_paper_num)
    citation_score = valid_refs / max(len(refs), 1) if refs else 0.5  # No refs = neutral

    # 3. Verification rate (40%): requires VerifyCitation check
    # In GEPA training, this is computed by running VerifyCitation on each SOURCED item
    # For now, use a proxy: SOURCED items that cite real papers get higher scores
    sourced_lines = [l for l in lines if re.search(r"\[SOURCED\]", l, re.IGNORECASE)]
    sourced_with_refs = sum(
        1
        for l in sourced_lines
        if PAPER_REF_PATTERN.search(l)
        and any(1 <= int(m) <= max_paper_num for m in PAPER_REF_PATTERN.findall(l))
    )
    verification_score = sourced_with_refs / max(len(sourced_lines), 1) if sourced_lines else 0.0

    # 4. Production feedback (20%): historical verification rate
    feedback_score = load_production_feedback_score()

    # Composite
    score = (
        0.40 * verification_score
        + 0.20 * format_score
        + 0.20 * citation_score
        + 0.20 * feedback_score
    )

    return score


def load_production_feedback_score():
    """
    Load average verification rate from production feedback store.

    Reads ~/.daemon/prompt_feedback/*.json and computes the overall
    average verification rate across all prompt versions.

    Returns:
        float: Average verification rate (0.0-1.0), defaults to 0.5 if no data
    """
    feedback_dir = Path.home() / ".daemon" / "prompt_feedback"
    if not feedback_dir.exists():
        return 0.5  # No production data yet — neutral

    rates = []
    for f in feedback_dir.glob("*.json"):
        try:
            entries = json.loads(f.read_text())
            if isinstance(entries, list):
                for entry in entries:
                    rate = entry.get("metrics", {}).get("verification_rate", None)
                    if rate is not None:
                        rates.append(float(rate))
        except (json.JSONDecodeError, KeyError, ValueError):
            continue

    if not rates:
        return 0.5

    return sum(rates) / len(rates)


def verify_evidence_with_llm(evidence_text, papers_context, lm=None):
    """
    Run VerifyCitation on each SOURCED item to get true verification scores.

    Used during GEPA training (not in the fast metric path).

    Args:
        evidence_text: The advocate's evidence output
        papers_context: The papers context string
        lm: Optional DSPy LM instance

    Returns:
        float: Verification rate (verified / total sourced)
    """
    import dspy
    from .signatures import VerifyCitation

    verifier = dspy.Predict(VerifyCitation)

    # Parse papers from context
    paper_map = {}
    for match in re.finditer(
        r"\[Paper (\d+)\]\s*(.+?)\n(?:Abstract:\s*(.+?))?(?=\n\[Paper|\Z)",
        papers_context,
        re.DOTALL,
    ):
        num = int(match.group(1))
        title = match.group(2).strip()
        abstract = (match.group(3) or "").strip()
        paper_map[num] = {"title": title, "abstract": abstract}

    # Find SOURCED items with paper refs
    sourced_verified = 0
    sourced_total = 0

    for line in evidence_text.split("\n"):
        if not re.search(r"\[SOURCED\]", line, re.IGNORECASE):
            continue

        refs = PAPER_REF_PATTERN.findall(line)
        if not refs:
            continue

        sourced_total += 1
        paper_num = int(refs[0])
        paper = paper_map.get(paper_num)

        if not paper:
            continue

        try:
            result = verifier(
                paper_title=paper["title"],
                paper_abstract=paper["abstract"][:2000],
                claim=line,
            )
            if "VERIFIED" in result.verdict.upper():
                sourced_verified += 1
            elif "PARTIAL" in result.verdict.upper():
                sourced_verified += 0.5
        except Exception:
            continue

    return sourced_verified / max(sourced_total, 1)
