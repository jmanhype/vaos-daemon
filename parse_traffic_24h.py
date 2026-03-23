import json
import sys

# Read the PostHog response
with open('/Users/batmanosama/vas-swarm/posthog_query_24h.json', 'r') as f:
    data = json.load(f)

# Extract results
results = data.get('results', [])

# Parse URLs and counts
traffic = {}
for result in results:
    properties_str = result[0]
    views = result[1]
    unique = result[2]

    # Extract pathname from properties
    props = json.loads(properties_str)
    pathname = props.get('$pathname', 'unknown')

    if pathname not in traffic:
        traffic[pathname] = {'views': 0, 'unique': 0}

    traffic[pathname]['views'] += views
    traffic[pathname]['unique'] += unique

# Sort by views
sorted_traffic = sorted(traffic.items(), key=lambda x: x[1]['views'], reverse=True)

# Print results
print("VAOS.sh Traffic - Last 24 Hours")
print("=" * 60)
for url, stats in sorted_traffic[:15]:
    print(f"{url:30} {stats['views']:5} views ({stats['unique']:2} unique)")
print("=" * 60)