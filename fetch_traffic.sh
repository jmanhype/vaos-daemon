#!/bin/bash

curl -s -X POST "https://us.posthog.com/api/projects/319864/query/" \
  -H "Authorization: Bearer phx_o848ezOXXtgOt9ZmaIlh1zCg0cSL7VTE5D6YocgB8A4OJ4C" \
  -H "Content-Type: application/json" \
  -d @- << 'EOF'
{
  "query": {
    "kind": "HogQLQuery",
    "query": "SELECT replaceAll(toString(properties), 'https://vaos.sh', '') as url, count() as views, uniqExact(distinct_id) as uniq FROM events WHERE event = '\$pageview' AND timestamp > now() - toIntervalHour(6) GROUP BY url ORDER BY views DESC LIMIT 15"
  }
}
EOF