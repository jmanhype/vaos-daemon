#!/usr/bin/env python3
import json
import sys

# Read PostHog response
with open('/Users/batmanosama/vas-swarm/posthog_current_traffic.json', 'r') as f:
    data = json.load(f)

results = data['results']

# Extract pathnames from the properties JSON
traffic = {}
for row in results:
    try:
        props = json.loads(row[0])
        pathname = props.get('$pathname', 'unknown')
        views = row[1]
        unique = row[2]

        if pathname not in traffic:
            traffic[pathname] = {'views': 0, 'unique': 0}
        traffic[pathname]['views'] += views
        traffic[pathname]['unique'] += unique
    except:
        pass

# Sort by views
sorted_traffic = sorted(traffic.items(), key=lambda x: x[1]['views'], reverse=True)

print("VAOS.sh Traffic - Last 6 Hours")
print("=" * 50)
for pathname, stats in sorted_traffic:
    print(f"{pathname}: {stats['views']} views ({stats['unique']} unique)")

# Compare to baseline
print("\n" + "=" * 50)
print("BASELINE COMPARISON (March 20 - 14 days):")
print("=" * 50)
baseline = {
    '/': {'unique': 38, 'days': 14, 'per_day': 38/14},
    '/blog': {'unique': 42, 'days': 14, 'per_day': 42/14},
    '/pricing': {'unique': 6, 'days': 14, 'per_day': 6/14}
}

current_6h = {
    '/': 0,
    '/pricing': 0,
    '/blog': 0
}

for pathname, stats in sorted_traffic:
    if pathname == '/':
        current_6h['/'] = stats['unique']
    elif pathname == '/pricing':
        current_6h['/pricing'] = stats['unique']
    elif '/blog' in pathname:
        current_6h['/blog'] += stats['unique']

# Project 6h to 24h
for page, current in current_6h.items():
    projected = current * 4  # 6h -> 24h
    baseline_per_day = baseline[page]['per_day']
    change = "same"
    if projected > baseline_per_day * 1.5:
        change = "↑ IMPROVED"
    elif projected < baseline_per_day * 0.5:
        change = "↓ DECLINED"

    print(f"{page}: {current} unique/6h (~{projected}/day) vs baseline {baseline_per_day:.2f}/day - {change}")
