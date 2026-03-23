import json
import urllib.request

url = 'https://us.posthog.com/api/projects/319864/query/'
headers = {
    'Authorization': 'Bearer phx_o848ezOXXtgOt9ZmaIlh1zCg0cSL7VTE5D6YocgB8A4OJ4C',
    'Content-Type': 'application/json'
}

data = {
    'query': {
        'kind': 'HogQLQuery',
        'query': "SELECT replaceAll(toString(properties), 'https://vaos.sh', '') as url, count() as views, uniqExact(distinct_id) as uniq FROM events WHERE event = '$pageview' AND timestamp > now() - toIntervalHour(24) GROUP BY url ORDER BY views DESC LIMIT 15"
    }
}

req = urllib.request.Request(url, json.dumps(data).encode(), headers)
try:
    response = urllib.request.urlopen(req)
    result = json.loads(response.read().decode())

    # Extract the pathname from properties
    traffic = {}
    for row in result.get('results', []):
        props = json.loads(row[0])
        pathname = props.get('$pathname', 'unknown')
        views = row[1]
        unique = row[2]

        if pathname not in traffic:
            traffic[pathname] = {'views': 0, 'unique': 0}
        traffic[pathname]['views'] += views
        traffic[pathname]['unique'] += unique

    print("VAOS.sh Traffic Analysis - March 21 Last 24 Hours")
    print("=" * 60)
    for pathname, stats in sorted(traffic.items(), key=lambda x: x[1]['views'], reverse=True):
        print(f"{pathname}: {stats['views']} views ({stats['unique']} unique)")
    print()

    # Compare to baseline
    print("Baseline Comparison (March 20 - 14 days):")
    print("pricing: 6 unique/14 days = 0.43/day")
    print("landing: 38 unique/14 days = 2.7/day")
    print("blog: 42 unique/14 days = 3.0/day")
    print()

    pricing_24h = traffic.get('/pricing', {}).get('unique', 0)
    landing_24h = traffic.get('/', {}).get('unique', 0)
    blog_24h = traffic.get('/blog', {}).get('unique', 0)

    print(f"Current (March 21 last 24h):")
    print(f"pricing: {pricing_24h} unique")
    print(f"landing: {landing_24h} unique")
    print(f"blog: {blog_24h} unique")
    print()

    pricing_change = (pricing_24h - 0.43) / 0.43 * 100 if pricing_24h > 0 else 0
    print(f"Pricing page traffic change: {pricing_change:+.1f}%")

except urllib.error.HTTPError as e:
    print(f"HTTP Error {e.code}: {e.reason}")
    print(f"Response: {e.read().decode()}")
