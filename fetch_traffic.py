#!/usr/bin/env python3
import json
import subprocess
import sys

# Execute the PostHog query
query = {
    "query": {
        "kind": "HogQLQuery",
        "query": "SELECT replaceAll(toString(properties), 'https://vaos.sh', '') as url, count() as views, uniqExact(distinct_id) as uniq FROM events WHERE event = '$pageview' AND timestamp > now() - toIntervalHour(6) GROUP BY url ORDER BY views DESC LIMIT 15"
    }
}

# Write query to file
with open('/tmp/posthog_query.json', 'w') as f:
    json.dump(query, f)

# Execute curl
result = subprocess.run([
    'curl', '-s', '-X', 'POST',
    'https://us.posthog.com/api/projects/319864/query/',
    '-H', 'Authorization: Bearer phx_o848ezOXXtgOt9ZmaIlh1zCg0cSL7VTE5D6YocgB8A4OJ4C',
    '-H', 'Content-Type: application/json',
    '-d', '@/tmp/posthog_query.json'
], capture_output=True, text=True)

if result.returncode != 0:
    print(f"Error: {result.stderr}")
    sys.exit(1)

data = json.loads(result.stdout)

if 'results' in data:
    print("March 22 Last 6 Hours - VAOS.sh Traffic:")
    print("-" * 60)
    for row in data['results']:
        url_props = json.loads(row[0])
        pathname = url_props.get('$pathname', 'unknown')
        views = row[1]
        unique = row[2]
        print(f"{pathname:30} | views: {row[1]:3} | unique: {row[2]}")

    print("\n" + "=" * 60)
    print("COMPARISON TO MARCH 20 BASELINE (14 days):")
    print("-" * 60)
    print("Pricing: 6 unique / 14 days = 0.43/day")
    print("Landing: 38 unique / 14 days = 2.7/day")
    print("Blog:    42 unique / 14 days = 3.0/day")
else:
    print("No results or error in response")
    print(json.dumps(data, indent=2)[:500])
