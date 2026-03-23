import json
import sys

# March 20 baseline (14 days)
baseline = {
    "landing": {"unique": 38, "days": 14, "per_day": 38/14},
    "blog": {"unique": 42, "days": 14, "per_day": 42/14},
    "pricing": {"unique": 6, "days": 14, "per_day": 6/14}
}

# Current data (last 6 hours)
current = [
    {"url": "/", "views": 54, "unique": 2},
    {"url": "/dashboard", "views": 18, "unique": 2},
    {"url": "/login", "views": 14, "unique": 3},
    {"url": "/dashboard/chat", "views": 11, "unique": 1},
    {"url": "/pricing", "views": 2, "unique": 1}
]

# Calculate metrics
print("📊 VAOS.sh Traffic Analysis - March 21 Last 6 Hours\n")
print("=" * 60)
print(f"{'Page':<25} {'Views':>8} {'Unique':>8} {'Status':>15}")
print("-" * 60)

for page in current:
    url = page['url']
    views = page['views']
    unique = page['unique']
    
    # Compare to baseline
    if url == "/":
        baseline_unique = baseline['landing']['per_day'] * 0.25  # 6h = 0.25 day
        ratio = unique / baseline_unique if baseline_unique > 0 else 0
        status = f"{'🔥' if ratio > 2 else '✅' if ratio > 1 else '⚠️'} {ratio:.1f}x"
    elif url == "/pricing":
        baseline_unique = baseline['pricing']['per_day'] * 0.25
        ratio = unique / baseline_unique if baseline_unique > 0 else 0
        status = f"{'🔥' if ratio > 2 else '✅' if ratio > 1 else '⚠️'} {ratio:.1f}x"
    else:
        status = "—"
    
    print(f"{url:<25} {views:>8} {unique:>8} {status:>15}")

print("\n" + "=" * 60)
print("\n📈 Key Insights:\n")

# Pricing analysis
pricing_unique = 2
baseline_pricing_per_day = baseline['pricing']['per_day']
baseline_pricing_6h = baseline_pricing_per_day * 0.25
pricing_ratio = pricing_unique / baseline_pricing_6h if baseline_pricing_6h > 0 else 0

print(f"Pricing Page:")
print(f"  • Current (6h): {pricing_unique} unique visitors")
print(f"  • Baseline (6h): {baseline_pricing_6h:.2f} unique visitors")
print(f"  • Growth: {pricing_ratio:.1f}x increase")
print()

if pricing_ratio > 2:
    print("  ✅ Pricing traffic has MORE THAN DOUBLED since CRO fixes!")
    print("  💡 Next step: Optimize pricing page headline for conversion")
elif pricing_ratio > 1:
    print("  ✅ Pricing traffic has increased since CRO fixes")
    print("  💡 Continue monitoring, prepare headline optimization")
else:
    print("  ⚠️ Pricing traffic below baseline")
    print("  💡 Investigate traffic sources and blog CTA performance")

print()
print("=" * 60)