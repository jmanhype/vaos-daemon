"""
GEPA (Generalized Efficient Prompt Architect) optimizer for the investigation pipeline.

Uses DSPy's GEPA optimizer (ICLR 2026 Oral) to optimize investigation prompt templates
via the daemon's existing Z.AI/Anthropic auth. Reads production verification outcomes
from ~/.daemon/prompt_feedback/ to ground the metric in real-world performance.

Usage:
    python -m gepa.optimize --auto light
    python -m gepa.collect_papers --topics topics.txt --output training_data.jsonl
"""
