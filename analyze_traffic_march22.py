#!/usr/bin/env python3
# Manual extraction from PostHog results
print("📊 VAOS.sh Traffic Analysis - March 22, Last 6 Hours")
print("=" * 60)

# From the PostHog results, I can see entries with $pathname fields
# Counting manually from the response:
pages = [
    "/login",
    "/",
    "/dashboard",
    "/blog/non-human-identity-ai-agents",
    "/",  # second visit
    "/documentation",
    "/pricing",
    "/",  # third visit
    "/login",  # second visit
    "/",  # fourth visit
    "/documentation",  # second visit
    "/pricing",  # second visit
    "/",  # fifth visit
    "/documentation",  # third visit
    "/",  # sixth visit
]

from collections import Counter
page_counts = Counter(pages)

print(f"\nPage Views (last 6 hours):")
for page, count in page_counts.most_common():
    print(f"  {page:45} {count:2} views")

print(f"\n📈 Comparison to March 20 Baseline (14 days):")
print("  /pricing:  6 unique/14d = 0.43/day")
print("  /:        38 unique/14d = 2.7/day")
print("  /blog:    42 unique/14d = 3.0/day")

print(f"\n🔍 Current Traffic (March 22, last 6h):")
pricing_6h = page_counts.get('/pricing', 0)
blog_6h = page_counts.get('/blog/non-human-identity-ai-agents', 0)
landing_6h = page_counts.get('/', 0)
docs_6h = page_counts.get('/documentation', 0)
login_6h = page_counts.get('/login', 0)
dashboard_6h = page_counts.get('/dashboard', 0)

print(f"  /pricing:       {pricing_6h:2} views")
print(f"  /blog:          {blog_6h:2} views")
print(f"  /:              {landing_6h:2} views")
print(f"  /documentation: {docs_6h:2} views")
print(f"  /login:         {login_6h:2} views")
print(f"  /dashboard:     {dashboard_6h:2} views")

print(f"\n💡 Analysis:")
# Estimate unique visitors (assuming ~1-2 unique based on patterns)
unique_visitors = 2  # Appears to be 2 distinct users in the data

print(f"  Estimated unique visitors in 6h: {unique_visitors}")
print(f"  Pricing page views: {pricing_6h}")
print(f"  Blog post views: {blog_6h}")

print(f"\n🎯 Key Finding:")
baseline_pricing_daily = 0.43
current_pricing_daily = pricing_6h * 4  # Project 6h to 24h

print(f"  Baseline pricing traffic: {baseline_pricing_daily}/day")
print(f"  Current pricing traffic: ~{current_pricing_daily}/day (projected)")

if pricing_6h == 0:
    print(f"\n⚠️  CRITICAL: Zero pricing page views in 6 hours!")
    print(f"  The blog CTA fix from March 21 is NOT driving traffic")
    print(f"  to pricing today. Traffic volume is extremely low.")
else:
    change = current_pricing_daily / baseline_pricing_daily
    print(f"  Change: {change:.1f}x {'increase' if change > 1 else 'decrease'}")

print(f"\n🔧 Recommendation:")
print(f"  ONE specific change needed:")
print(f"  → Add a STICKY, PULSING CTA button to the blog post")
print(f"    that appears at 50% scroll with text:")
print(f"    'See Pricing - $29/mo'")
print(f"  ")
print(f"  Current issue: Users read the blog but don't notice")
print(f"  or click the mid-article CTA. A sticky CTA will be")
print(f"  always-visible and increase conversion.")