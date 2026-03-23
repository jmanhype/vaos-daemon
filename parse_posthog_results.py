#!/usr/bin/env python3
import json
import sys
from urllib.parse import parse_qs, urlparse

# Read the PostHog results
with open('posthog_query_24h.json', 'r') as f:
    query = json.load(f)

# Execute the query
import subprocess
result = subprocess.run([
    'curl', '-s', '-X', 'POST', 'https://us.posthog.com/api/projects/319864/query/',
    '-H', 'Authorization: Bearer phx_o848ezOXXtgOt9ZmaIlh1zCg0cSL7VTE5D6YocgB8A4OJ4C',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps(query)
], capture_output=True, text=True)

data = json.loads(result.stdout)

# Parse results and extract pathnames
from collections import defaultdict
url_stats = defaultdict(lambda: {'views': 0, 'unique': set()})

for row in data.get('results', []):
    if len(row) >= 3:
        properties_str = row[0]
        views = row[1]
        unique = row[2]

        # Parse the properties JSON to extract $pathname
        try:
            props = json.loads(properties_str)
            pathname = props.get('$pathname', '/unknown')

            if pathname not in ['/unknown']:
                url_stats[pathname]['views'] += views
                # Note: we're not tracking distinct_id here for simplicity
        except:
            pass

# Sort by views
sorted_urls = sorted(url_stats.items(), key=lambda x: x[1]['views'], reverse=True)

print("\n=== VAOS.sh Traffic - Last 24 Hours ===\n")
print(f"{'URL':<30} {'Views':>10} {'Unique':>10}")
print("-" * 52)

for url, stats in sorted_urls[:15]:
    print(f"{url:<30} {stats['views']:>10} {'N/A':>10}")

# Compare to baseline
print("\n=== Comparison to March 20 Baseline ===")
print("March 20 (14 days):")
print("  - pricing: 6 unique (0.43/day)")
print("  - landing: 38 unique (2.7/day)")
print("  - blog: 42 unique (3.0/day)")
print("\nMarch 21 (last 24h):")
for url, stats in sorted_urls[:3]:
    if url in ['/pricing', '/landing', '/', '/blog']:
        print(f"  - {url}: {stats['views']} views")
