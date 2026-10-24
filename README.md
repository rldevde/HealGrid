# HealGrid

![HealGrid](logo.png)

A standalone, healer-oriented raid grid for World of Warcraft —
fully configurable, completely independent of any other addon.

Homepage: https://xrl-dev.de · Bugtracker: https://xrl-dev.de/bugtracker

## Features

- **8x5 raid grid** (up to 40 cells) with horizontal or vertical layout,
  growth directions, group spacing and index / name / role sorting
- **Click-casting** — a full binding matrix (5 mouse buttons x 4 modifiers),
  `heal` / `dispel` / `rez` keywords resolve to your class spells automatically,
  dead units automatically get the class resurrection spell
- **Debuff-centric display** — only harmful auras are shown, with a
  dispel-type colored cell border and an optional "only what I can dispel"
  filter (per-class dispel table)
- **Healer info at a glance** — incoming heal wedge, absorb bar, aggro
  dot/border, raid marker, role letter, ready check, resurrection icon,
  AFK / offline / dead states and out-of-range fading
- **Highly customizable** — tabbed options window covering layout, bar
  textures, text sizes and modes, indicator toggles and fully configurable
  colors (health, background, incoming heal, absorb, aggro, debuff borders)
- **Pets column**, automatic visibility for healer classes, visibility rules
  (always / group / raid) and a test mode that fills the grid with
  5–40 fake cells so the layout can be previewed anywhere
- **deDE locale** and a multi-client compatibility layer (aura API,
  color picker, secret-value safe health previews)

## Installation

Copy the `HealGrid` folder into
`World of Warcraft/<version>/Interface/AddOns/` and enable it on the
character screen's addon list.

## Usage

| Command | Action |
|---|---|
| `/healgrid` or `/hg` | Toggle the grid |
| `/healgrid options` | Open the options window |
| `/healgrid scan` | Dump visible frames near the grid (debug) |

The grid shows automatically on healer classes (Priest, Paladin, Druid,
Shaman, Monk, Evoker). Right-click the small anchor tab above the grid
or the minimap button to open the options.

## Options overview

- **General** — visibility rules, solo display, lock frame, tooltips,
  target highlight, pets, AFK, test mode, scale and opacity
- **Layout** — cell size, spacing, group spacing, power bar height,
  growth directions, orientation, sorting
- **Bars** — power bar, incoming heal / absorb previews, range fade,
  health color mode (class / gradient / custom), bar texture
- **Text** — name and health text sizes, name truncation, life text mode
  (percent / deficit / both / none), role letter
- **Icons** — debuffs, only-dispellable filter, raid marker, rez and
  ready-check icons, debuff icon size, aggro style
- **Colors** — health, background, incoming heal, absorb, aggro and all
  five debuff border colors via color picker
- **Click Cast** — every mouse button and modifier combination, per-binding
  action type (spell / macro / item / target / focus / menu) with a class
  spell picker
- **Profiles** — named settings snapshots, string export/import and
  optional per-character profiles
- **About** — version, links and slash command reference

## Saved variables

`HealGridDB` (account-wide settings) and `HealGridCharDB`
(per-character, e.g. minimap button position).
