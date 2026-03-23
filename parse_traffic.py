import json
import sys
from collections import defaultdict

# Read PostHog response
with open('/Users/batmanosama/vas-swarm/posthog_traffic_query.json', 'r') as f:
    query_data = json.load(f)

# Execute the query via curl
import subprocess
result = subprocess.run([
    'curl', '-s', '-X', 'POST',
    'https://us.posthog.com/api/projects/319864/query/',
    '-H', 'Authorization: Bearer phx_o848ezOXXtgOt9ZmaIlh1zCg0cSL7VTE5D6YocgB8A4OJ4C',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps(query_data)
], capture_output=True, text=True)

response = json.loads(result.stdout)

# Parse results
url_stats = defaultdict(lambda: {'views': 0, 'uniq': set()})

for row in response.get('results', []):
    try:
        props = json.loads(row[0])
        url = props.get('$pathname', '/')
        views = row[1]
        uniq = row[2]

        if url not in url_stats:
            url_stats[url] = {'views': 0, 'uniq': set()}

        url_stats[url]['views'] += views
        url_stats[url]['uniq'].add(uniq)
    except:
        continue

# Convert sets to counts and sort by views
sorted_urls = sorted(
    [(url, data['views'], len(data['uniq'])) for url, data in url_stats.items()],
    key=lambda x: x[1],
    reverse=True
)

print("VAOS.sh Traffic - Last 6 Hours")
print("=" * 50)
for url, views, uniq in sorted_urls[:15]:
    print(f"{url:30} {views:4} views ({uniq:2} unique)")