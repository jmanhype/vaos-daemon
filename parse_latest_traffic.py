#!/usr/bin/env python3
import json
import sys
from collections import defaultdict

# Parse PostHog response
with open('/Users/batmanosama/vas-swarm/posthog_response_latest.json', 'r') as f:
    data = json.load(f)

# Extract page paths from event properties
page_stats = defaultdict(lambda: {'views': 0, 'unique': set()})

for result in data.get('results', []):
    if len(result) >= 3:
        properties_blob = result[0]
        views = result[1]
        unique = result[2]

        # Parse the properties JSON string
        try:
            properties = json.loads(properties_blob)
            pathname = properties.get('$pathname', '/unknown')

            page_stats[pathname]['views'] += views
            page_stats[pathname]['unique'].add(unique)
        except:
            pass

# Convert sets to counts
summary = []
for path, stats in sorted(page_stats.items(), key=lambda x: x[1]['views'], reverse=True):
    summary.append({
        'path': path,
        'views': stats['views'],
        'unique': len(stats['unique'])
    })

# Print results
print("VAOS.sh Traffic - Last 6 Hours (March 23, 2026)")
print("=" * 60)
for page in summary[:10]:
    print(f"{page['path']:50} {page['views']:3} views ({page['unique']:2} unique)")

print("\n" + "=" * 60)
print("BASELINE COMPARISON (March 20 - 14 days):")
print("  Landing page:  38 unique / 14 days = 2.7/day")
print("  Blog posts:    42 unique / 14 days = 3.0/day")
print("  Pricing page:   6 unique / 14 days = 0.43/day")
print("=" * 60)

# Calculate projections
landing_6h = next((p for p in summary if p['path'] == '/'), None)
blog_6h = next((p for p in summary if p['path'].startswith('/blog')), None)
pricing_6h = next((p for p in summary if p['path'] == '/pricing'), None)

if landing_6h:
    projected = landing_6h['unique'] * 4  # 6h -> 24h
    print(f"\nLanding page projection: {landing_6h['unique']} unique/6h → ~{projected} unique/day (vs baseline 2.7/day)")

if blog_6h:
    projected = blog_6h['unique'] * 4
    print(f"Blog projection: {blog_6h['unique']} unique/6h → ~{projected} unique/day (vs baseline 3.0/day)")

if pricing_6h:
    projected = pricing_6h['unique'] * 4
    print(f"Pricing page projection: {pricing_6h['unique']} unique/6h → ~{projected} unique/day (vs baseline 0.43/day)")
else:
    print(f"\n⚠️  PRICING PAGE: 0 unique visitors in last 6 hours (baseline: 0.43/day)")
    print("   This is a CRITICAL TRAFFIC COLLAPSE.")

print("=" * 60)
