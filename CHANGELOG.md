# Changelog

All notable changes to HealGrid are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0]

### Added
- Standalone healer raid grid — 8x5 group layout, no external dependencies
- Health and power bars with class, gradient or fully custom colors,
  configurable background color and alpha
- Click-cast system with a full binding matrix (5 buttons x 4 modifiers),
  per-binding action types (spell, macro, item, target, focus, menu),
  `heal` / `dispel` / `rez` class-spell keywords and rez-on-dead
- Debuff-only aura display with dispel-type colored cell borders and an
  optional "only dispellable" filter per class
- Incoming heal and absorb previews, aggro dot/border, raid marker,
  role letter, ready check, resurrection icon, AFK / offline / dead states,
  out-of-range fading with configurable alpha
- Layout options: horizontal/vertical orientation, growth directions,
  index/name/role sorting, cell size, spacing, group spacing, scale,
  hide-empty-groups, hide-in-combat and visibility rules
  (always / group / raid)
- Pets column using the owner's class color
- Test mode filling the grid with 5–40 deterministic fake cells for
  layout preview and click-cast testing
- Tabbed options window (General / Layout / Bars / Text / Icons / Colors /
  Click Cast / About) with color pickers for all bar and border colors
- Minimap launcher button and `/healgrid` / `/hg` slash commands
- Automatic visibility on healer classes
- deDE locale with English fallback
- Multi-client compatibility layer (aura access, color picker APIs,
  secret-value safe previews) and combat-deferred frame operations
