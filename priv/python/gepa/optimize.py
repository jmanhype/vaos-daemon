#!/usr/bin/env python3
"""
GEPA optimizer for investigation prompts.

Uses the daemon's existing Z.AI/Anthropic auth — no separate OpenAI keys needed.

Usage:
    # Light optimization (~50 rollouts):
    python -m gepa.optimize --auto light

    # Medium optimization (~200 rollouts):
    python -m gepa.optimize --auto medium

    # With custom training data:
    python -m gepa.optimize --auto light --trainset training_data.jsonl

Environment:
    ANTHROPIC_API_KEY  - Z.AI proxy key (= ZHIPU_API_KEY on Mac Mini)
    ANTHROPIC_BASE_URL - Z.AI proxy URL (default: https://api.z.ai/api/anthropic/v1)
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import dspy

from .metric import citation_accuracy_metric
from .signatures import AgainstAdvocate, ForAdvocate, VerifyCitation


def get_lm():
    """Configure LM using daemon's Z.AI auth."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set.", file=sys.stderr)
        print("On Mac Mini: export ANTHROPIC_API_KEY=$ZHIPU_API_KEY", file=sys.stderr)
        sys.exit(1)

    api_base = os.environ.get(
        "ANTHROPIC_BASE_URL", "https://api.z.ai/api/anthropic/v1"
    )

    return dspy.LM(
        "anthropic/claude-sonnet-4-6",
        api_base=api_base,
        api_key=api_key,
    )


class InvestigationProgram(dspy.Module):
    """DSPy program mirroring the Elixir investigation pipeline."""

    def __init__(self):
        self.for_advocate = dspy.ChainOfThought(ForAdvocate)
        self.against_advocate = dspy.ChainOfThought(AgainstAdvocate)
        self.verifier = dspy.Predict(VerifyCitation)

    def forward(self, claim, papers_context, prior_evidence=""):
        # Run both advocates
        for_result = self.for_advocate(
            claim=claim,
            papers_context=papers_context,
            prior_evidence=prior_evidence,
        )

        against_result = self.against_advocate(
            claim=claim,
            papers_context=papers_context,
            prior_evidence=prior_evidence,
        )

        # Return for_result as main output (GEPA optimizes the FOR advocate first)
        return for_result


def load_training_data(path=None):
    """Load training examples from JSONL file or generate seed examples."""
    if path and Path(path).exists():
        examples = []
        with open(path) as f:
            for line in f:
                data = json.loads(line)
                examples.append(
                    dspy.Example(
                        claim=data["claim"],
                        papers_context=data.get("papers_context", ""),
                        prior_evidence=data.get("prior_evidence", ""),
                    ).with_inputs("claim", "papers_context", "prior_evidence")
                )
        return examples

    # Seed examples from common investigation topics
    seeds = [
        "Does MCTS improve LLM reasoning?",
        "Effect of retrieval-augmented generation on hallucination",
        "Scaling laws in language models",
        "Prompt optimization for factual accuracy",
        "Citation verification in AI systems",
        "Does chain-of-thought prompting improve mathematical reasoning?",
        "Effectiveness of RLHF for reducing harmful outputs",
        "Impact of model size on few-shot learning capability",
    ]

    return [
        dspy.Example(
            claim=seed,
            papers_context="[Paper 1] Example paper (2024, 50 citations)\nAbstract: Example abstract about " + seed.lower(),
            prior_evidence="",
        ).with_inputs("claim", "papers_context", "prior_evidence")
        for seed in seeds
    ]


def export_prompts(optimized_program, output_path):
    """Extract optimized prompts from DSPy program and save as JSON."""
    output_path = Path(output_path).expanduser()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Extract the optimized instructions from the program's predictors
    prompts = {}

    # Get instructions from the for_advocate predictor
    if hasattr(optimized_program.for_advocate, "extended_signature"):
        sig = optimized_program.for_advocate.extended_signature
        if hasattr(sig, "instructions"):
            prompts["for_system"] = sig.instructions

    # Get instructions from the against_advocate predictor
    if hasattr(optimized_program.against_advocate, "extended_signature"):
        sig = optimized_program.against_advocate.extended_signature
        if hasattr(sig, "instructions"):
            prompts["against_system"] = sig.instructions

    # Get instructions from the verifier predictor
    if hasattr(optimized_program.verifier, "extended_signature"):
        sig = optimized_program.verifier.extended_signature
        if hasattr(sig, "instructions"):
            prompts["verify_prompt"] = sig.instructions

    # Load defaults and merge (keep any prompts GEPA didn't optimize)
    defaults_path = Path(__file__).parent.parent.parent / "prompts" / "investigation_default.json"
    if defaults_path.exists():
        with open(defaults_path) as f:
            defaults = json.loads(f.read()).get("prompts", {})
        for key, val in defaults.items():
            if key not in prompts:
                prompts[key] = val

    data = {
        "version": 1,
        "optimized_at": datetime.now(timezone.utc).isoformat(),
        "optimizer": "gepa",
        "prompts": prompts,
    }

    output_path.write_text(json.dumps(data, indent=2))
    print(f"Exported optimized prompts to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="GEPA optimizer for investigation prompts")
    parser.add_argument(
        "--auto",
        choices=["light", "medium", "heavy"],
        default="light",
        help="Optimization intensity (light=~50, medium=~200, heavy=~500 rollouts)",
    )
    parser.add_argument(
        "--trainset",
        type=str,
        default=None,
        help="Path to training data JSONL file",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="~/.daemon/prompts/investigation_optimized.json",
        help="Output path for optimized prompts JSON",
    )
    args = parser.parse_args()

    # Configure LM
    lm = get_lm()
    dspy.configure(lm=lm)

    # Load training data
    trainset = load_training_data(args.trainset)
    print(f"Loaded {len(trainset)} training examples")

    # Create program
    program = InvestigationProgram()

    # Run GEPA optimization
    print(f"Starting GEPA optimization (auto={args.auto})...")
    optimizer = dspy.GEPA(
        metric=citation_accuracy_metric,
        auto=args.auto,
    )

    optimized = optimizer.compile(program, trainset=trainset)
    print("Optimization complete!")

    # Export optimized prompts
    export_prompts(optimized, args.output)

    # Print summary
    print("\nTo use these prompts, restart the daemon.")
    print(f"Prompts saved to: {Path(args.output).expanduser()}")


if __name__ == "__main__":
    main()
