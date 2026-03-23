#!/usr/bin/env python3
import json
import re

# Read the saved response
with open('/Users/batmanosama/vas-swarm/posthog_traffic_march22.json', 'r') as f:
    data = json.load(f)

results = data.get('results', [])

print("VAOS.sh Traffic - Last 6 Hours (March 22, ~5:25pm UTC)")
print("=" * 70)

# Parse URL from properties and aggregate
page_stats = {}
for row in results:
    if len(row) >= 3:
        properties_str = row[0]
        views = row[1]
        unique = row[2]

        # Extract pathname from properties JSON using regex
        match = re.search(r'"\\\$pathname":"([^"]+)"', properties_str)
        if match:
            pathname = match.group(1)

            if pathname not in page_stats:
                page_stats[pathname] = {'views': 0, 'unique': 0}

            page_stats[pathname]['views'] += views
            page_stats[pathname]['unique'] += unique

# Sort by views
sorted_pages = sorted(page_stats.items(), key=lambda x: x[1]['views'], reverse=True)

for pathname, stats in sorted_pages:
    print(f"{pathname:55} {stats['views']:3} views ({stats['unique']} unique)")

print("\n" + "=" * 70)
print("Baseline (March 20, 14 days):")
print("  /pricing:     6 unique / 14 days = 0.43/day")
print("  /:            38 unique / 14 days = 2.7/day")
print("  /blog/*:      42 unique / 14 days = 3.0/day")

# Analysis
print("\n" + "=" * 70)
print("ANALYSIS:")
print("-" * 70)

pricing_views = page_stats.get('/pricing', {}).get('views', 0)
pricing_unique = page_stats.get('/pricing', {}).get('unique', 0)

if pricing_views == 0:
    print("🚨 CRITICAL: ZERO pricing page traffic in last 6 hours!")
    print("\nThis is worse than the March 20 baseline (0.43/day).")
    print("\nPrevious CRO fix (blog CTA) appears to have been:")
    print("  - Reverted")
    print("  - OR traffic quality has collapsed")
    print("  - OR the blog post getting views isn't the marketing crew post")
else:
    print(f"Pricing page: {pricing_views} views ({pricing_unique} unique) in 6h")
    projected_daily = pricing_unique * 4  # 6h -> 24h
    baseline_daily = 0.43
    improvement = projected_daily / baseline_daily if baseline_daily > 0 else 0
    print(f"  Projected: {projected_daily:.1f} unique/day vs baseline {baseline_daily}/day")
    print(f"  Improvement: {improvement:.1f}x")

print("\nNEXT STEP:")
print("-" * 70)
print("Add sticky, pulsing CTA button to blog posts that appears at 50% scroll")
print("with text 'See Pricing - $29/mo' to recover blog-to-pricing traffic flow.")
