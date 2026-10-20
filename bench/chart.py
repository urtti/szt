#!/usr/bin/env python3
"""Draws the README benchmark chart from a bench/run.sh result file.

    python3 bench/chart.py bench/results-projects.json "Scanning a 123 GB folder" "667,000 files" docs/benchmark

writes docs/benchmark-light.svg and docs/benchmark-dark.svg: one bar per tool,
fastest first, szt in the accent color and everything else in gray.
"""
import json
import statistics
import sys
from html import escape

THEMES = {
    "light": {
        "accent": "#2a78d6", "context": "#c3c2b7", "baseline": "#c3c2b7",
        "primary": "#0b0b0b", "secondary": "#52514e", "muted": "#898781",
    },
    "dark": {
        "accent": "#3987e5", "context": "#52514e", "baseline": "#383835",
        "primary": "#f0efec", "secondary": "#c3c2b7", "muted": "#898781",
    },
}

FONT = 'system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif'
WIDTH = 720
PAD = 24
LABEL_WIDTH = 92      # tool names
VALUE_ROOM = 118      # "15.1 s  6.3× slower" past the longest bar
ROW = 34
BAR = 20
RADIUS = 4


def wall_times(result):
    if "measurements" in result:  # hyperfine 2
        return [run["time_wall_clock"]["value"] for run in result["measurements"]]
    return result["times"]        # hyperfine 1


def medians(path):
    with open(path) as file:
        results = json.load(file)["results"]
    return sorted(((r.get("name") or r["command"], statistics.median(wall_times(r))) for r in results),
                  key=lambda item: item[1])


def bar_path(x0, x1, y, height, r):
    """A bar that is square at the baseline and rounded at its data end."""
    r = min(r, (x1 - x0) / 2, height / 2)
    return (f"M{x0:.1f},{y:.1f} H{x1 - r:.1f} A{r},{r} 0 0 1 {x1:.1f},{y + r:.1f} "
            f"V{y + height - r:.1f} A{r},{r} 0 0 1 {x1 - r:.1f},{y + height:.1f} H{x0:.1f} Z")


def seconds(value):
    return f"{value:.1f} s" if value >= 1 else f"{value * 1000:.0f} ms"


def svg(rows, title, subtitle, theme):
    colors = THEMES[theme]
    fastest = next(value for name, value in rows if name == "szt")
    longest = max(value for _, value in rows)
    top = PAD + 58
    height = top + len(rows) * ROW + 30
    x0 = PAD + LABEL_WIDTH
    span = WIDTH - PAD - VALUE_ROOM - x0

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
        f'viewBox="0 0 {WIDTH} {height}" role="img" aria-labelledby="title desc">',
        f'<title id="title">{escape(title)}</title>',
        f'<desc id="desc">{escape("; ".join(f"{name}: {seconds(value)}" for name, value in rows))}</desc>',
        f'<style>text {{ font-family: {FONT}; }} .num {{ font-variant-numeric: tabular-nums; }}</style>',
        f'<text x="{PAD}" y="{PAD + 14}" font-size="17" font-weight="600" fill="{colors["primary"]}">{escape(title)}</text>',
        f'<text x="{PAD}" y="{PAD + 36}" font-size="13" fill="{colors["secondary"]}">{escape(subtitle)}</text>',
    ]
    for index, (name, value) in enumerate(rows):
        y = top + index * ROW
        mine = name == "szt"
        x1 = x0 + max(2 * RADIUS, span * value / longest)
        middle = y + BAR / 2 + 4.5
        weight = ' font-weight="600"' if mine else ""
        out.append(f'<text x="{x0 - 12}" y="{middle:.1f}" font-size="13" text-anchor="end"{weight} '
                   f'fill="{colors["primary"] if mine else colors["secondary"]}">{escape(name)}</text>')
        out.append(f'<path d="{bar_path(x0, x1, y, BAR, RADIUS)}" fill="{colors["accent"] if mine else colors["context"]}"/>')
        label = f'<tspan fill="{colors["primary"] if mine else colors["secondary"]}"{weight}>{seconds(value)}</tspan>'
        if not mine:
            label += f'<tspan dx="8" fill="{colors["muted"]}">{value / fastest:.1f}× slower</tspan>'
        out.append(f'<text class="num" x="{x1 + 8:.1f}" y="{middle:.1f}" font-size="13">{label}</text>')
    out.append(f'<line x1="{x0}" y1="{top - 6}" x2="{x0}" y2="{top + len(rows) * ROW - ROW + BAR + 6}" '
               f'stroke="{colors["baseline"]}" stroke-width="1"/>')
    note = "Median of 5 warm-cache runs with hyperfine, each tool with its default settings. Lower is better."
    out.append(f'<text x="{PAD}" y="{height - 12}" font-size="11" fill="{colors["muted"]}">{escape(note)}</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    results, title, subtitle, prefix = sys.argv[1:]
    rows = medians(results)
    for theme in THEMES:
        with open(f"{prefix}-{theme}.svg", "w") as file:
            file.write(svg(rows, title, subtitle, theme))
    for name, value in rows:
        print(f"{name:10} {seconds(value):>8}")


if __name__ == "__main__":
    main()
