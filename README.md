# ED-ExpeditionStats

A PowerShell script that generates expedition statistics from Elite Dangerous journal files.

## Purpose

Elite Dangerous does not have a built-in expedition summary. This script processes your journal files for a given time period and produces a plain-text report suitable for sharing on forums or Discord.

Originally written for the **Distant Worlds III** community expedition (3312 / 2026).

## Requirements

- PowerShell 5.1 (Windows Desktop) or PowerShell 7+ (cross-platform)
- Elite Dangerous journal files

## Usage

```powershell
# DW3 default (2026-01-18 to today)
.\ED-ExpeditionStats.ps1

# Custom date range (real-world dates)
.\ED-ExpeditionStats.ps1 -StartDate "2026-01-18" -EndDate "2026-03-22"

# In-game dates also accepted (year offset 1286)
.\ED-ExpeditionStats.ps1 -StartDate "3312-01-18"

# Custom journal path
.\ED-ExpeditionStats.ps1 -LogPath "D:\Journals"
```

The script automatically finds your journal folder under `Saved Games\Frontier Developments\Elite Dangerous`. Use `-LogPath` to override if your journals are elsewhere.

## Output

```
==================================================
  Expedition Statistics
  Period: 2026-01-18 to now
==================================================

DISTANCE TRAVELED
  FSD:              168,496.8 ly
  Carrier:           32,371.6 ly
  Total:            200,868.4 ly

EXPLORATION
  Systems visited:        1736
  Systems discovered:      793
  Codex entries:           961

FSD JUMPS
  Total jumps:            1824
  Supercharged:            310

FIRST DISCOVERIES
  Earth-like worlds:         2
  Water worlds:             55
  Ammonia worlds:            8
  Terraformable:           146
  Neutron stars:            35
  White dwarfs:              7
  Black holes:               0
  Wolf-Rayet stars:          0

  Note: 6 death(s) recorded. Distance figures may include recovery travel.

==================================================
```

## Statistics explained

| Stat | Source |
|------|--------|
| FSD distance | Sum of `FSDJump.JumpDist` |
| Carrier distance | `CarrierJump` events (online) + StarPos delta across sessions (offline while docked) |
| Systems visited | Unique destinations from `FSDJump` |
| Systems discovered | Unique systems where a star `Scan` had `WasDiscovered=false` |
| Codex entries | Unique `EntryID + Region` combinations where `IsNewEntry=true` |
| Supercharged jumps | `JetConeBoost` events (neutron star / white dwarf cone) |
| First discoveries | Unique bodies with `WasDiscovered=false` in `Scan` events |
| Deaths | `Died` events — distance figures may include recovery travel |

## Notes

- Journal files are selected by filename date, so sessions spanning midnight may be partially included or excluded at the boundaries.
- Carrier distance covers both online jumps (logged via `CarrierJump` event) and offline jumps while docked (calculated from StarPos coordinates between sessions).
- First footfall count is not included — the game does not log a dedicated first footfall event in the journal.
