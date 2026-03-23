#!/usr/bin/env python3
import json
import sys

# Read PostHog response
with open('/Users/batmanosama/vas-swarm/posthog_response_latest.json', 'r') as f:
    data = json.load(f)

# Parse results
print("VAOS.sh Traffic Analysis - March 23 Last 6 Hours")
print("=" * 60)

results = data.get('results', [])

# Track unique pages and visitors
page_stats = {}

for row in results:
    if len(row) < 3:
        continue

    properties_json = row[0]
    views = row[1]
    uniq = row[2]

    try:
        properties = json.loads(properties_json)
        pathname = properties.get('$pathname', 'unknown')

        if pathname not in page_stats:
            page_stats[pathname] = {'views': 0, 'uniq': 0}

        page_stats[pathname]['views'] += views
        page_stats[pathname]['uniq'] += uniq
    except:
        pass

# Sort by views
sorted_pages = sorted(page_stats.items(), key=lambda x: x[1]['views'], reverse=True)

print(f"{'Page':<50} {'Views':>10} {'Unique':>10}")
print("-" * 72)

for page, stats in sorted_pages[:15]:
    print(f"{page:<50} {stats['views']:>10} {stats['uniq']:>10}")

print("\n" + "=" * 60)
print("Baseline (March 20, 14 days):")
print("  - Landing page: 38 unique/14d (2.7/day)")
print("  - Blog posts: 42 unique/14d (3.0/day)")
print("  - Pricing page: 6 unique/14d (0.43/day)")
