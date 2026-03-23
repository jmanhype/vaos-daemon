#!/usr/bin/env python3
import json
import sys

# Load the PostHog response
with open('/Users/batmanosama/vas-swarm/posthog_traffic_march22.json', 'r') as f:
    data = json.load(f)

# Parse the results
results = data.get('results', [])

print(f"DEBUG: Found {len(results)} results in PostHog response")

# Extract pathname from properties and aggregate
pages = {}
for row in results:
    try:
        # The first column is the full properties JSON string
        properties_str = row[0]

        # Parse the JSON to extract pathname
        properties = json.loads(properties_str)

        # Get the pathname
        pathname = properties.get('$pathname', 'unknown')

        # Get views and unique counts from columns 1 and 2
        views = row[1]
        uniq = row[2]

        if pathname not in pages:
            pages[pathname] = {'views': 0, 'uniq': 0}

        pages[pathname]['views'] += views
        pages[pathname]['uniq'] += uniq
    except Exception as e:
        print(f"DEBUG: Error parsing row: {e}")
        pass

# Sort by views
sorted_pages = sorted(pages.items(), key=lambda x: x[1]['views'], reverse=True)

# Print top 15
print("\nVAOS.sh Traffic - March 22, Last 6 Hours")
print("=" * 60)
print(f"{'Page':<30} {'Views':>10} {'Unique':>10}")
print("-" * 60)

for page, stats in sorted_pages[:15]:
    print(f"{page:<30} {stats['views']:>10} {stats['uniq']:>10}")

print("\n" + "=" * 60)
print("Baseline (March 20, 14 days):")
print("  / (landing): 38 unique/14d = 2.7/day")
print("  /blog/*: 42 unique/14d = 3.0/day")
print("  /pricing: 6 unique/14d = 0.43/day")
