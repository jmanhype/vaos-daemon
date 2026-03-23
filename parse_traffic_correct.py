import json
import re

# Load the PostHog results
with open('/Users/batmanosama/vas-swarm/ph_query_traffic.json', 'r') as f:
    data = json.load(f)

# Parse results
results = data.get('results', [])

# Extract URL paths and aggregate stats
traffic = {}
for row in results:
    properties_str = row[0]
    views = row[1]
    unique = row[2]

    # Extract $pathname using regex
    match = re.search(r'" \$pathname ":" ( [ ^ " ] +)"', properties_str)
    if match:
        pathname = match.group(1)

        if pathname not in traffic:
            traffic[pathname] = {'views': 0, 'unique': 0}
        traffic[pathname]['views'] += views
        traffic[pathname]['unique'] += unique

# Sort by views
sorted_traffic = sorted(traffic.items(), key=lambda x: x[1]['views'], reverse=True)

# Print results
print("VAOS.sh Traffic - Last 6 Hours (March 22)")
print("=" * 50)
for path, stats in sorted_traffic[:10]:
    print(f"{path}: {stats['views']} views ({stats['unique']} unique)")

print("\n" + "=" * 50)
print("BASELINE (March 20 - 14 days):")
print("landing: 38 unique/14d = 2.7/day")
print("blog: 42 unique/14d = 3.0/day")
print("pricing: 6 unique/14d = 0.43/day")
print("=" * 50)

# Calculate current rates
print("\nCURRENT RATES (Last 6 hours → projected daily):")
for path, stats in sorted_traffic[:5]:
    daily_unique = round(stats['unique'] * 4)  # 6h → 24h
    print(f"{path}: {stats['unique']} unique/6h → ~{daily_unique}/day")
