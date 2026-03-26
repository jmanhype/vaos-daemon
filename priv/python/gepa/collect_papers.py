#!/usr/bin/env python3
"""
Bootstrap training data for GEPA by fetching papers from OpenAlex.

OpenAlex has generous rate limits (10 req/s with polite pool) — ideal for
collecting the paper abstracts needed by the investigation pipeline.

Usage:
    python -m gepa.collect_papers --topics topics.txt --output training_data.jsonl
    python -m gepa.collect_papers --seed --output training_data.jsonl
"""

import argparse
import json
import sys
import time
from pathlib import Path

import requests

OPENALEX_API = "https://api.openalex.org/works"
POLITE_EMAIL = "vaos-daemon@users.noreply.github.com"

# Default seed topics covering areas the investigation pipeline handles
SEED_TOPICS = [
    "Does MCTS improve LLM reasoning?",
    "Effect of retrieval-augmented generation on hallucination",
    "Scaling laws in language models",
    "Prompt optimization for factual accuracy",
    "Citation verification in AI systems",
    "Does chain-of-thought prompting improve mathematical reasoning?",
    "Effectiveness of RLHF for reducing harmful outputs",
    "Impact of model size on few-shot learning capability",
    "Active inference and epistemic foraging",
    "Adversarial robustness in large language models",
    "Knowledge graph completion with language models",
    "Self-play for improving language model capabilities",
    "Systematic review methodology in computer science",
    "Meta-analysis of deep learning architectures",
    "Reproducibility crisis in machine learning research",
]


def search_openalex(query, per_page=10):
    """Search OpenAlex for papers matching query."""
    params = {
        "search": query,
        "per_page": per_page,
        "mailto": POLITE_EMAIL,
        "select": "id,title,publication_year,cited_by_count,authorships,doi,primary_location,abstract_inverted_index",
    }

    try:
        resp = requests.get(OPENALEX_API, params=params, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        return data.get("results", [])
    except Exception as e:
        print(f"  Warning: OpenAlex search failed for '{query[:50]}': {e}", file=sys.stderr)
        return []


def reconstruct_abstract(inverted_index):
    """Reconstruct abstract text from OpenAlex inverted index format."""
    if not inverted_index:
        return ""

    # Build word-position pairs
    positions = []
    for word, pos_list in inverted_index.items():
        for pos in pos_list:
            positions.append((pos, word))

    # Sort by position and join
    positions.sort()
    return " ".join(word for _, word in positions)


def format_paper(work):
    """Convert OpenAlex work to pipeline-compatible format."""
    title = work.get("title", "Unknown")
    year = work.get("publication_year", "unknown")
    citations = work.get("cited_by_count", 0)

    # Reconstruct abstract from inverted index
    abstract = reconstruct_abstract(work.get("abstract_inverted_index"))

    # Extract authors
    authors = []
    for authorship in (work.get("authorships") or [])[:5]:
        author = authorship.get("author", {})
        name = author.get("display_name", "")
        if name:
            authors.append(name)

    # Extract DOI
    doi = work.get("doi", "") or ""
    if doi.startswith("https://doi.org/"):
        doi = doi[len("https://doi.org/"):]

    return {
        "title": title,
        "abstract": abstract,
        "year": str(year),
        "citation_count": citations,
        "source": "openalex",
        "authors": authors,
        "doi": doi,
        "paper_id": work.get("id", ""),
    }


def format_papers_context(papers):
    """Format papers into the context string used by the investigation pipeline."""
    if not papers:
        return "No relevant papers found."

    lines = []
    for i, p in enumerate(papers, 1):
        abstract = p["abstract"][:2000] if p["abstract"] else "No abstract available."
        lines.append(
            f"[Paper {i}] {p['title']} ({p['year']}, {p['citation_count']} citations, via {p['source']})\n"
            f"Abstract: {abstract}"
        )

    return "RELEVANT PAPERS FOUND:\n" + "\n\n".join(lines)


def collect_for_topic(topic, per_page=10):
    """Collect papers and format as a training example for one topic."""
    print(f"  Collecting papers for: {topic[:60]}...")

    # Search with multiple query variants
    queries = [
        topic,
        f"systematic review {topic}",
        f"{topic} meta-analysis",
    ]

    all_papers = []
    seen_titles = set()

    for query in queries:
        works = search_openalex(query, per_page=per_page)
        for work in works:
            title = (work.get("title") or "").lower().strip()
            if title and title not in seen_titles:
                seen_titles.add(title)
                all_papers.append(format_paper(work))
        time.sleep(0.15)  # Polite delay

    # Sort by citations (most cited first)
    all_papers.sort(key=lambda p: p["citation_count"], reverse=True)
    all_papers = all_papers[:15]  # Keep top 15

    if not all_papers:
        return None

    return {
        "claim": topic,
        "papers_context": format_papers_context(all_papers),
        "papers": all_papers,
        "prior_evidence": "",
    }


def main():
    parser = argparse.ArgumentParser(description="Collect papers for GEPA training")
    parser.add_argument(
        "--topics",
        type=str,
        default=None,
        help="Path to text file with one topic per line",
    )
    parser.add_argument(
        "--seed",
        action="store_true",
        help="Use built-in seed topics",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="training_data.jsonl",
        help="Output JSONL file path",
    )
    parser.add_argument(
        "--per-page",
        type=int,
        default=10,
        help="Papers per query (default: 10)",
    )
    args = parser.parse_args()

    # Load topics
    if args.topics:
        topics_path = Path(args.topics)
        if not topics_path.exists():
            print(f"ERROR: Topics file not found: {args.topics}", file=sys.stderr)
            sys.exit(1)
        topics = [
            line.strip()
            for line in topics_path.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
    elif args.seed:
        topics = SEED_TOPICS
    else:
        print("ERROR: Specify --topics <file> or --seed", file=sys.stderr)
        sys.exit(1)

    print(f"Collecting papers for {len(topics)} topics...")

    output_path = Path(args.output)
    collected = 0

    with open(output_path, "w") as f:
        for topic in topics:
            example = collect_for_topic(topic, per_page=args.per_page)
            if example:
                # Write without the full papers array (just claim + context for GEPA)
                training_entry = {
                    "claim": example["claim"],
                    "papers_context": example["papers_context"],
                    "prior_evidence": example["prior_evidence"],
                }
                f.write(json.dumps(training_entry) + "\n")
                collected += 1
                print(f"  -> {len(example['papers'])} papers collected")
            else:
                print(f"  -> No papers found, skipping")

            time.sleep(0.5)  # Be polite between topics

    print(f"\nDone! Collected {collected}/{len(topics)} topics -> {output_path}")


if __name__ == "__main__":
    main()
