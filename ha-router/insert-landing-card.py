#!/usr/bin/env python3
"""Insert a game card into the live ha-router landing page (called by new-game.sh on the host).

Usage: insert-landing-card.py <path/to/landing/index.html> "<Display Title>" <host> <hex-no-#> <r,g,b>

The card markup mirrors ha-router/landing-card.html (card / card-icon / card-body / card-name /
card-host / card-arrow + badge-wip). It is inserted as the first card of the Games section.
Idempotent: does nothing if a card for <host> already exists.
"""
import sys

path, title, host, hex_color, rgb = sys.argv[1:6]
red, green, blue = rgb.split(",")
html = open(path).read()
if f"https://{host}" in html:
    sys.exit(0)

games_section = html.index("<!-- Games -->")
cards_open = '<div class="cards">'
anchor = html.index(cards_open, games_section) + len(cards_open)
card = f"""

            <a class="card" href="https://{host}">
              <div class="card-icon" style="background: rgba({red}, {green}, {blue}, 0.1); border: 1px solid rgba({red}, {green}, {blue}, 0.15);">
                <svg viewBox="0 0 24 24" fill="none" stroke="#{hex_color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="2" y="6" width="20" height="12" rx="2"/>
                  <path d="M6 12h4"/>
                  <path d="M8 10v4"/>
                  <line x1="15" y1="13" x2="15.01" y2="13"/>
                  <line x1="18" y1="11" x2="18.01" y2="11"/>
                </svg>
              </div>
              <div class="card-body">
                <div class="card-name">{title} <span class="badge badge-wip">WIP</span></div>
                <div class="card-host">{host}</div>
              </div>
              <span class="card-arrow">&rarr;</span>
            </a>"""
open(path, "w").write(html[:anchor] + card + html[anchor:])
