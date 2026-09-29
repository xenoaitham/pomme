#!/usr/bin/env python3
"""Render site/index.html from site/state.json.

Run after any meaningful change:  ./scripts/update-progress.py
The page is fully self-contained (no external assets) so it can be
deployed anywhere as a static file.
"""
import json
import pathlib
import datetime

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / "site" / "state.json"
OUT = ROOT / "site" / "index.html"

STATUS_ICON = {
    "done": "&#9679; done",
    "active": "&#9654; in progress",
    "blocked": "&#9632; blocked",
    "todo": "&#9679; queued",
}
STATUS_CLASS = {
    "done": "done",
    "active": "active",
    "blocked": "blocked",
    "todo": "todo",
}


def esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def render() -> str:
    state = json.loads(STATE.read_text())
    pieces_rows = []
    for p in state["pieces"]:
        ev = p.get("evidence", [])
        ev_html = "<br>".join(
            f'<a href="{esc(e["path"])}">{esc(e["label"])}</a>' if e.get("link")
            else esc(e["label"])
            for e in ev
        ) or "&mdash;"
        critic = esc(p.get("critic", ""))
        pieces_rows.append(
            f"<tr class='{STATUS_CLASS.get(p['status'], 'todo')}'>"
            f"<td>{esc(p['name'])}</td>"
            f"<td>{esc(p['desc'])}</td>"
            f"<td class='status'>{STATUS_ICON.get(p['status'], p['status'])}</td>"
            f"<td>{critic}</td>"
            f"<td class='ev'>{ev_html}</td>"
            f"</tr>"
        )

    art_rows = []
    for a in state.get("artifacts", []):
        art_rows.append(
            "<tr>"
            f"<td><code>{esc(a['name'])}</code></td>"
            f"<td>{esc(a['desc'])}</td>"
            f"<td>{esc(a.get('size', ''))}</td>"
            f"<td><code>{esc(a.get('sha256', ''))[:16]}&hellip;</code></td>"
            f"<td>{esc(a.get('provenance', ''))}</td>"
            "</tr>"
        )

    log_html = "".join(
        f"<li><b>{esc(e['t'])}</b> &mdash; {esc(e['msg'])}</li>"
        for e in list(reversed(state.get("log", [])))[:40]
    )

    bars_rows = []
    for b in state.get("bars", []):
        bars_rows.append(
            "<tr>"
            f"<td>{esc(b['name'])}</td>"
            f"<td><code>{esc(b['commit'])[:12]}</code></td>"
            f"<td>{esc(b['date'])}</td>"
            f"<td>{esc(b['role'])}</td>"
            "</tr>"
        )

    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pomme &mdash; build progress</title>
<style>
:root {{ --bg:#0e1116; --fg:#d6dae2; --dim:#8a93a3; --line:#232a35;
        --accent:#e5484d; --ok:#46a758; --warn:#f5a623; }}
* {{ box-sizing:border-box; }}
body {{ background:var(--bg); color:var(--fg); margin:0;
  font:16px/1.55 Georgia,'Times New Roman',serif; }}
.wrap {{ max-width:1080px; margin:0 auto; padding:2.5rem 1.25rem 4rem; }}
header h1 {{ font-size:2.4rem; margin:0 0 .2rem; letter-spacing:.5px; }}
header h1 span {{ color:var(--accent); }}
header .tag {{ color:var(--dim); font-style:italic; margin-bottom:.4rem; }}
.badge {{ display:inline-block; border:1px solid var(--line); border-radius:4px;
  padding:.1rem .55rem; margin:.15rem .3rem .15rem 0; font-size:.8rem;
  color:var(--dim); font-family:ui-monospace,monospace; }}
h2 {{ font-size:1.25rem; border-bottom:1px solid var(--line);
  padding-bottom:.25rem; margin-top:2.4rem; }}
table {{ border-collapse:collapse; width:100%; font-size:.92rem; }}
th,td {{ text-align:left; vertical-align:top; padding:.45rem .6rem;
  border-bottom:1px solid var(--line); }}
th {{ color:var(--dim); font-weight:normal; text-transform:uppercase;
  font-size:.72rem; letter-spacing:.08em; font-family:ui-monospace,monospace; }}
td.status {{ white-space:nowrap; font-family:ui-monospace,monospace;
  font-size:.8rem; }}
tr.done td.status {{ color:var(--ok); }}
tr.active td.status {{ color:var(--warn); }}
tr.blocked td.status {{ color:var(--accent); }}
td.ev a {{ color:#7ab8ff; text-decoration:none; }}
code {{ font-family:ui-monospace,SFMono-Regular,monospace; font-size:.85em;
  background:#161b23; padding:.05rem .3rem; border-radius:3px; }}
ul#log {{ list-style:none; padding:0; font-size:.9rem; }}
ul#log li {{ padding:.3rem 0; border-bottom:1px dashed var(--line); }}
ul#log li b {{ font-family:ui-monospace,monospace; font-weight:normal;
  color:var(--dim); margin-right:.5rem; }}
.honesty {{ border:1px solid var(--warn); border-radius:6px; padding: .8rem 1rem;
  margin:1.4rem 0; }}
.honesty b {{ color:var(--warn); }}
footer {{ margin-top:3rem; color:var(--dim); font-size:.85rem; }}
a {{ color:#7ab8ff; }}
</style></head><body><div class="wrap">
<header>
  <h1>pomme<span>.</span></h1>
  <div class="tag">Linux for checkm8-era iPhones (A7&ndash;A11) &mdash;
  gaster &rarr; pongoOS &rarr; kernel, one reproducible pipeline</div>
  <div>
    <span class="badge">status: builds-not-boots (no device in this session)</span>
    <span class="badge">A12+ unsupported &mdash; no public boot exploit, and we will not pretend otherwise</span>
    <span class="badge">generated {esc(state["generated"])}</span>
  </div>
</header>

<div class="honesty"><b>Honesty bar:</b>
This project has <u>not</u> been booted on hardware. Every artifact traces to a
pinned upstream commit or to a committed build log produced in CI. The
compatibility matrix cites evidence per cell. When hardware is attached, see
RESUME.md for the exact bring-up sequence.</div>

<h2>Pipeline pieces</h2>
<table>
<thead><tr><th>Piece</th><th>What it is</th><th>Status</th>
<th>Blind critic verdict</th><th>Evidence</th></tr></thead>
<tbody>{''.join(pieces_rows)}</tbody>
</table>

<h2>Reference bars (pinned upstreams)</h2>
<table>
<thead><tr><th>Project</th><th>Pinned commit</th><th>Date</th><th>Role in pomme</th></tr></thead>
<tbody>{''.join(bars_rows)}</tbody>
</table>

<h2>Shipped artifacts</h2>
<table>
<thead><tr><th>Artifact</th><th>What</th><th>Size</th><th>sha256</th>
<th>Provenance</th></tr></thead>
<tbody>{''.join(art_rows) or '<tr><td colspan="5">&mdash; none yet &mdash;</td></tr>'}</tbody>
</table>

<h2>Build log</h2>
<ul id="log">{log_html}</ul>

<footer>Project name disclaimer: &ldquo;pomme&rdquo; is an independent open-source
project, not affiliated with, endorsed by, or sponsored by Apple Inc.
&ldquo;iPhone&rdquo; and &ldquo;iPad&rdquo; are trademarks of Apple Inc., used here
nominatively to identify hardware compatibility.</footer>
</div></body></html>"""


def main() -> None:
    state = json.loads(STATE.read_text())
    state["generated"] = datetime.datetime.now().isoformat(timespec="seconds")
    STATE.write_text(json.dumps(state, indent=2) + "\n")
    OUT.write_text(render())
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
