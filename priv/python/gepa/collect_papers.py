#!/usr/bin/env python3
"""
Bootstrap training data for GEPA from all pipeline paper sources.

Sources (matching investigate.ex):
  - OpenAlex: generous rate limits (10 req/s with polite pool)
  - Semantic Scholar: 1 req/s without API key, 429s common
  - HuggingFace Papers: ML/AI papers from arXiv via HF Hub API, no auth
  - alphaXiv: embedding search (requires MCP OAuth, skipped if unavailable)

Usage:
    python -m gepa.collect_papers --seed --output training_data.jsonl
    python -m gepa.collect_papers --topics topics.txt --output training_data.jsonl
    python -m gepa.collect_papers --seed --sources openalex,semantic_scholar,huggingface
"""

import argparse
import json
import sys
import time
from pathlib import Path

import requests

# -- API endpoints --
OPENALEX_API = "https://api.openalex.org/works"
SEMANTIC_SCHOLAR_API = "https://api.semanticscholar.org/graph/v1/paper/search"
HUGGINGFACE_PAPERS_API = "https://huggingface.co/api/papers/search"

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

ALL_SOURCES = ["openalex", "semantic_scholar", "huggingface"]


# -- OpenAlex --

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
        print(f"  [openalex] Failed for '{query[:50]}': {e}", file=sys.stderr)
        return []


def reconstruct_abstract(inverted_index):
    """Reconstruct abstract text from OpenAlex inverted index format."""
    if not inverted_index:
        return ""

    positions = []
    for word, pos_list in inverted_index.items():
        for pos in pos_list:
            positions.append((pos, word))

    positions.sort()
    return " ".join(word for _, word in positions)


def format_openalex_paper(work):
    """Convert OpenAlex work to pipeline-compatible format."""
    title = work.get("title", "Unknown")
    year = work.get("publication_year", "unknown")
    citations = work.get("cited_by_count", 0)
    abstract = reconstruct_abstract(work.get("abstract_inverted_index"))

    authors = []
    for authorship in (work.get("authorships") or [])[:5]:
        author = authorship.get("author", {})
        name = author.get("display_name", "")
        if name:
            authors.append(name)

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


# -- Semantic Scholar --

def search_semantic_scholar(query, limit=10):
    """Search Semantic Scholar. Rate-limited: 1 req/s without API key."""
    params = {
        "query": query,
        "limit": limit,
        "fields": "title,abstract,year,citationCount,authors,externalIds,publicationTypes",
    }

    # Use API key if available (100 req/s vs 1 req/s)
    headers = {}
    ss_key = None
    try:
        import os
        ss_key = os.environ.get("SEMANTIC_SCHOLAR_API_KEY")
    except Exception:
        pass
    if ss_key:
        headers["x-api-key"] = ss_key

    try:
        resp = requests.get(SEMANTIC_SCHOLAR_API, params=params, headers=headers, timeout=15)
        if resp.status_code == 429:
            print(f"  [semantic_scholar] Rate limited, waiting 2s...", file=sys.stderr)
            time.sleep(2)
            resp = requests.get(SEMANTIC_SCHOLAR_API, params=params, headers=headers, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        return data.get("data", [])
    except Exception as e:
        print(f"  [semantic_scholar] Failed for '{query[:50]}': {e}", file=sys.stderr)
        return []


def format_ss_paper(paper):
    """Convert Semantic Scholar paper to pipeline-compatible format."""
    authors = []
    for author in (paper.get("authors") or [])[:5]:
        name = author.get("name", "")
        if name:
            authors.append(name)

    doi = ""
    ext_ids = paper.get("externalIds") or {}
    if ext_ids.get("DOI"):
        doi = ext_ids["DOI"]

    return {
        "title": paper.get("title", "Unknown"),
        "abstract": paper.get("abstract") or "",
        "year": str(paper.get("year") or "unknown"),
        "citation_count": paper.get("citationCount") or 0,
        "source": "semantic_scholar",
        "authors": authors,
        "doi": doi,
        "paper_id": paper.get("paperId", ""),
    }


# -- HuggingFace Papers --

def search_huggingface(query, limit=10):
    """Search HuggingFace Papers API (ML/AI papers from arXiv, no auth)."""
    params = {"q": query}

    try:
        resp = requests.get(HUGGINGFACE_PAPERS_API, params=params, timeout=15)
        resp.raise_for_status()
        papers = resp.json()
        if isinstance(papers, list):
            return papers[:limit]
        return []
    except Exception as e:
        print(f"  [huggingface] Failed for '{query[:50]}': {e}", file=sys.stderr)
        return []


def format_hf_paper(paper):
    """Convert HuggingFace paper to pipeline-compatible format."""
    # HF papers API returns {id, title, summary, authors: [{name}], ...}
    authors = []
    for author in (paper.get("authors") or [])[:5]:
        if isinstance(author, dict):
            name = author.get("name", "")
        elif isinstance(author, str):
            name = author
        else:
            name = ""
        if name:
            authors.append(name)

    arxiv_id = paper.get("id", "")

    return {
        "title": paper.get("title", "Unknown"),
        "abstract": paper.get("summary", "") or paper.get("abstract", "") or "",
        "year": str(paper.get("publishedAt", "unknown"))[:4] if paper.get("publishedAt") else "unknown",
        "citation_count": paper.get("citationCount", 0) or 0,
        "source": "huggingface",
        "authors": authors,
        "doi": "",
        "paper_id": arxiv_id,
        "url": f"https://arxiv.org/abs/{arxiv_id}" if arxiv_id else "",
    }


# -- Shared --

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


def dedup_papers(papers):
    """Deduplicate papers by normalized title (matches investigate.ex merge_papers_raw)."""
    seen = set()
    deduped = []
    for p in papers:
        key = " ".join(
            sorted(
                w for w in p["title"].lower().split()
                if len(w) >= 4
            )[:5]
        )
        if key and key not in seen:
            seen.add(key)
            deduped.append(p)
    return deduped


def collect_for_topic(topic, per_page=10, sources=None):
    """Collect papers from all sources and format as a training example."""
    if sources is None:
        sources = ALL_SOURCES

    print(f"  Collecting papers for: {topic[:60]}...")

    all_papers = []

    # -- OpenAlex (generous limits, multiple query variants) --
    if "openalex" in sources:
        oa_queries = [
            topic,
            f"systematic review {topic}",
            f"{topic} meta-analysis",
        ]
        for query in oa_queries:
            works = search_openalex(query, per_page=per_page)
            for work in works:
                all_papers.append(format_openalex_paper(work))
            time.sleep(0.15)

    # -- Semantic Scholar (rate-limited, 1.5s between requests) --
    if "semantic_scholar" in sources:
        ss_queries = [
            topic,
            f"systematic review {topic}",
        ]
        for query in ss_queries:
            papers = search_semantic_scholar(query, limit=per_page)
            for paper in papers:
                all_papers.append(format_ss_paper(paper))
            time.sleep(1.5)  # Respect unauthenticated rate limit

    # -- HuggingFace Papers (ML/AI only, no auth needed) --
    if "huggingface" in sources:
        hf_papers = search_huggingface(topic, limit=per_page)
        for paper in hf_papers:
            all_papers.append(format_hf_paper(paper))

    # Dedup, sort by citations, take top 15
    all_papers = dedup_papers(all_papers)
    all_papers.sort(key=lambda p: p["citation_count"], reverse=True)
    all_papers = all_papers[:15]

    if not all_papers:
        return None

    # Count by source
    source_counts = {}
    for p in all_papers:
        source_counts[p["source"]] = source_counts.get(p["source"], 0) + 1

    return {
        "claim": topic,
        "papers_context": format_papers_context(all_papers),
        "papers": all_papers,
        "prior_evidence": "",
        "source_counts": source_counts,
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
    parser.add_argument(
        "--sources",
        type=str,
        default=",".join(ALL_SOURCES),
        help=f"Comma-separated sources to use (default: {','.join(ALL_SOURCES)})",
    )
    args = parser.parse_args()

    sources = [s.strip() for s in args.sources.split(",")]
    invalid = [s for s in sources if s not in ALL_SOURCES]
    if invalid:
        print(f"ERROR: Unknown sources: {invalid}. Valid: {ALL_SOURCES}", file=sys.stderr)
        sys.exit(1)

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

    print(f"Collecting papers for {len(topics)} topics from {sources}...")

    output_path = Path(args.output)
    collected = 0
    total_by_source = {}

    with open(output_path, "w") as f:
        for topic in topics:
            example = collect_for_topic(topic, per_page=args.per_page, sources=sources)
            if example:
                training_entry = {
                    "claim": example["claim"],
                    "papers_context": example["papers_context"],
                    "prior_evidence": example["prior_evidence"],
                }
                f.write(json.dumps(training_entry) + "\n")
                collected += 1
                for src, count in example["source_counts"].items():
                    total_by_source[src] = total_by_source.get(src, 0) + count
                print(f"  -> {len(example['papers'])} papers ({example['source_counts']})")
            else:
                print(f"  -> No papers found, skipping")

            time.sleep(0.5)

    print(f"\nDone! {collected}/{len(topics)} topics -> {output_path}")
    print(f"Papers by source: {total_by_source}")


if __name__ == "__main__":
    main()
