#!/usr/bin/env python3
import subprocess
import json

# Build the curl command with proper escaping
url = "https://us.posthog.com/api/projects/319864/query/"

# The JSON payload with the HogQL query
payload = {
    "query": {
        "kind": "HogQLQuery",
        "query": """SELECT replaceAll(toString(properties), 'https://vaos.sh', '') as url, count() as views, uniqExact(distinct_id) as uniq FROM events WHERE event = '$pageview' AND timestamp > now() - toIntervalHour(6) GROUP BY url ORDER BY views DESC LIMIT 15"""
    }
}

# Execute curl command
cmd = [
    'curl', '-s', '-X', 'POST', url,
    '-H', 'Authorization: Bearer phx_o848ezOXXtgOt9ZmaIlh1zCg0cSL7VTE5D6YocgB8A4OJ4C',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps(payload)
]

result = subprocess.run(cmd, capture_output=True, text=True)
print(result.stdout)
