import json

# Read the PostHog results
with open('/Users/batmanosama/vas-swarm/ph_query_traffic_march22.json', 'r') as f:
    data = json.load(f)

# Check structure
print("Results count:", len(data.get('results', [])))
print("\nFirst result structure:")
if data.get('results'):
    first = data['results'][0]
    print(f"Result has {len(first)} fields")
    print(f"Field 0 type: {type(first[0])}")
    print(f"Field 0 length: {len(first[0]) if isinstance(first[0], str) else 'N/A'}")

    # Try to parse field 0 as JSON
    try:
        props = json.loads(first[0])
        print("\nParsed properties keys:")
        for key in sorted(props.keys()):
            if '$' in key or 'url' in key.lower() or 'path' in key.lower():
                print(f"  {key}: {props[key]}")
    except Exception as e:
        print(f"Error parsing: {e}")

print("\nAll results:")
for i, result in enumerate(data.get('results', [])[:3]):
    print(f"\nResult {i}:")
    print(f"  Views: {result[1]}")
    print(f"  Unique: {result[2]}")