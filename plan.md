Act as an expert Factorio mod developer. Write a Factorio 2.0 (Space Age compatible) mod named "Fleet Commander" that automates space platform schedules using clever name and number matching.

Please generate all necessary files based on the project requirements, architecture specifications, and safety safeguards outlined below.

---

### 1. PROJECT REQUIREMENTS & FEATURES
- Name-Based Grouping: Ships belong to a fleet group based purely on their name text prefix and a trailing number (e.g., "Cargo 1", "Cargo 10", "Cargo 11").
- Follow the Leader: The ship ending in number "1" is the group Leader (e.g., "Cargo 1"). Whenever a Leader's schedule changes, that exact schedule must automatically copy to all valid follower platforms in the universe sharing the same prefix (number > 1).
- Smart Auto-Naming: When a new space platform is created (on_space_platform_created), the mod scans all existing platforms to find the highest number for a default prefix ("Cargo"). It names the new ship "[Prefix] [Highest Number + 1]" and immediately syncs it to Leader 1's schedule if it exists.
- Headless Design: Do not build any visual GUI window or sidebar. Everything must run natively in the background via event hooks to keep the mod completely performance-friendly and seamless.

---

### 2. ARCHITECTURE & FILE SPECIFICATION

Please generate the following files inside a root directory named 'fleet-commander_1.0.0':

#### File A: info.json
Generate a standard Factorio manifest manifest. Ensure "space-age" is explicitly listed as a required dependency. Set author to "Player", version to "1.0.0", and factorio_version to "2.0".

#### File B: control.lua
Implement the following core Lua systems:
1. Pattern Matching Parser: Use Lua's `string.match("^(.-)%s*(%d+)$")` to accurately split a ship name into its text group and a numerical index. Convert the number string using `tonumber()` so that double-digit and triple-digit follower counts (10, 11, 100) are treated mathematically as greater than 1.
2. Schedule Synchronizer: A function that iterates through `game.space_platforms` and pushes a modified schedule from a Leader to its respective followers.
3. Event Hook 1 (`on_space_platform_changed_state`): Fires when a platform updates its status or destination. If it's a Leader, trigger the schedule sync.
4. Event Hook 2 (`on_space_platform_created`): Detects when a new platform starter hub is launched. Dynamically calculate the next available integer for the "Cargo" fleet, rename the platform, and automatically inject the leader's schedule if one is active.

---

### 3. SAFEGUARDS & REFACTORING BOUNDARIES

To ensure a robust user experience, implement these two gameplay safeguards:
- Anti-Breakaway Logic: Factorio 2.0 does not have a unique event for 'schedule edited'. To capture manual edits, you must listen to 'on_gui_closed'.
  *CRITICAL COMPATIBILITY FIX*: In Factorio 2.0, the space platform UI is opened from a remote view or an item, so checking `player.opened.type == "space-platform-hub"` will fail. Instead, when `on_gui_closed` fires, you must check the player's context using `player.opened_space_platform`. If a player manually changes a follower's route and closes the GUI, your code must instantly catch it, reset its schedule back to match Leader 1, and print an in-game warning to the chat. If they edited the Leader, immediately push the update to the entire fleet.
- Empty Fleet Protection: If a player creates "Cargo 10" but "Cargo 1" does not exist yet, the ship should not crash the game. It should operate as an independent ship until a "Cargo 1" is built or renamed, at which point it snaps into formation.

Please write clean, heavily-commented, and production-ready code for both files.







# Second phase
Act as an expert Factorio mod developer. We are now moving into Phase 2 of the "Fleet Commander" mod. We already have the background name-matching automation working perfectly.

Your task is to build a custom, collapsible Graphical User Interface (GUI) on the left side of the player's screen using Factorio's native 'LuaGuiElement' API.

Please rewrite the mod code to integrate the new interface based on the specifications below.

---

### 1. GUI ARCHITECTURE & LAYOUT
- Main Toggle Button: Add a small, permanent shortcut button or top-left screen icon (using mod-gui or the shortcut bar) displaying an anchor or ship icon. Clicking this toggles the main Fleet Commander panel open/closed.
- Main Panel Structure: When opened, display a vertical frame on the left side of the screen. It must contain:
  1. A title bar with a "Close (X)" button.
  2. A scroll pane to hold the fleets, preventing the UI from breaking if the player has dozens of ships.
- Collapsible Fleet Groups (Foldable Lists):
  - Dynamically scan all space platforms and group them by their prefix (e.g., "Cargo", "Miner").
  - For each group, create a collapsible UI component (a 'collapsible-pane' or a custom vertical flow toggled by a small arrow button '▶' / '▼').
  - The header of the collapsible pane must display the Group Name and the total number of ships inside it (e.g., "▼ 📦 Cargo Fleet (4)").
- Inside the Foldable List:
  - List each ship sequentially by its number.
  - Place a star icon '⭐' next to Leader 1 and a document icon '📄' next to followers.
  - Display the ship's name and its current status text (e.g., "Cargo 10 [In Transit]" or "Cargo 1 [At Vulcanus]"). Clicking a ship's name should instantly open that platform's native remote view.
  - At the very bottom of each collapsible section, add a punchy text button: "[➕ Add New Ship]".

---

### 2. CORE INTERFACE LOGIC & INTERACTION
- The "Add New Ship" Button Functionality:
  - When the "[➕ Add New Ship]" button inside a specific collapsible section (like "Cargo") is clicked, it must trigger our existing smart auto-naming logic for that exact group.
  - It should check if the player has a "space-platform-starter-pack" in their personal inventory or character trash slots. If found, consume 1 pack and programmatically trigger the creation of the next numbered ship in that fleet. If not found, print a flying text warning on the screen: "Missing Space Platform Starter Pack!"
- Dynamic UI Refreshing:
  - The UI must stay accurate without causing UPS (performance) lag.
  - Create a central `update_gui(player)` function.
  - Do NOT refresh the UI every single tick. Instead, call `update_gui` only when specific events fire: `on_space_platform_created`, `on_space_platform_changed_state`, `on_space_platform_removed`, or when a player renames a platform.

---

### 3. CODE REFACTORING RULES
- Do not lose any of the automation, name-parsing, or anti-breakaway logic established in Phase 1.
- Ensure all GUI elements use unique, structured names (e.g., "fleet_commander_main_frame", "fleet_commander_add_btn_" .. group_name) to avoid overlapping with vanilla UI elements or other mods.
- Make sure to handle multiplayer safety by storing individual player UI state data inside the 'storage' table (formerly 'global' in older Factorio versions, ensure compatibility with 2.0).

Please output the completely updated, modular, and heavily-commented 'control.lua' file integrating this collapsible user interface.
