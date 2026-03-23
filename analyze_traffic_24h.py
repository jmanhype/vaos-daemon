import json

# The actual results from the API response
results_data = [
    ["{\"$pathname\":\"/pricing\",\"$current_url\":\"/pricing\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
    ["{\"$pathname\":\"/dashboard/rules\",\"$current_url\":\"/dashboard/rules\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
    ["{\"$pathname\":\"/pricing\",\"$current_url\":\"/pricing\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
    ["{\"$pathname\":\"/\",\"$current_url\":\"/\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
    ["{\"$pathname\":\"/login\",\"$current_url\":\"/login\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
    ["{\"$pathname\":\"/\",\"$current_url\":\"/\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
    ["{\"$pathname\":\"/dashboard\",\"$current_url\":\"/dashboard\",\"title\":\"VAOS — Your AI Agent Forgets Everything. Fix That.\"}", 1, 1],
]

# Parse URLs and counts
traffic = {}
for result in results_data:
    properties_str = result[0]
    views = result[1]
    unique = result[2]

    # Extract pathname from properties
    props = json.loads(properties_str)
    pathname = props.get('$pathname', 'unknown')

    if pathname not in traffic:
        traffic[pathname] = {'views': 0, 'unique': set()}

    traffic[pathname]['views'] += views
    traffic[pathname]['unique'].add(unique)

# Convert sets to counts
for path in traffic:
    traffic[path]['unique'] = len(traffic[path]['unique'])

# Sort by views
sorted_traffic = sorted(traffic.items(), key=lambda x: x[1]['views'], reverse=True)

# Print results
print("VAOS.sh Traffic Analysis - March 21 Last 24 Hours")
print("=" * 70)
for url, stats in sorted_traffic:
    print(f"{url:35} {stats['views']:5} views ({stats['unique']:2} unique)")
print("=" * 70)

# Calculate totals
total_views = sum(s['views'] for s in traffic.values())
total_unique = sum(s['unique'] for s in traffic.values())
print(f"TOTAL: {total_views} views, {total_unique} unique visitors")
print()

# Compare to baseline
print("COMPARISON TO MARCH 20 BASELINE (14 days):")
print("-" * 70)
print("Pricing page:")
print(f"  March 20: 6 unique / 14 days = 0.43 unique/day")
print(f"  March 21: {traffic.get('/pricing', {'unique': 0})['unique']} unique / 1 day = {traffic.get('/pricing', {'unique': 0})['unique']} unique/day")
if traffic.get('/pricing', {'unique': 0})['unique'] > 0:
    increase = traffic.get('/pricing', {'unique': 0})['unique'] / 0.43
    print(f"  Change: {increase:.1f}x increase")
print()

print("Landing page (/):")
print(f"  March 20: 38 unique / 14 days = 2.7 unique/day")
print(f"  March 21: {traffic.get('/', {'unique': 0})['unique']} unique / 1 day")
print()

print("Blog pages:")
print(f"  March 20: 42 unique / 14 days = 3.0 unique/day")
print(f"  March 21: Check blog-specific paths for comparison")
print("=" * 70)