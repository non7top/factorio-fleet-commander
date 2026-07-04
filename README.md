# Fleet Commander

A Factorio 2.0 (Space Age) mod that automates space platform schedules using
name and number matching.

## How it works

- **Name-based grouping**: platforms are grouped into a "fleet" by their name's
  text prefix and trailing number, e.g. `Cargo 1`, `Cargo 2`, `Cargo 10`.
- **Follow the leader**: the platform numbered `1` is the fleet Leader.
  Whenever the Leader's schedule changes, it is copied to every Follower
  (number > 1) sharing the same prefix.
- **Smart auto-naming**: newly created platforms are automatically named into
  the default `Cargo` fleet with the next free number, and immediately synced
  to that fleet's Leader if one exists.
- **Anti-breakaway protection**: manual schedule edits on a Follower are
  detected and reverted to match the Leader; edits on the Leader are pushed
  out to the whole fleet.
- **Empty fleet protection**: a fleet with no Leader yet operates
  independently until a Leader is built or renamed into place.

Phase 1 is fully headless (no GUI). Phase 2 adds an optional collapsible
left-side panel for viewing and managing fleets.

## Installation

Copy this repository's contents into a folder named `fleet-commander_<version>`
inside your Factorio `mods` directory (matching the `version` in `info.json`),
or download a packaged zip from the [Releases](../../releases) page.

## License

MIT
