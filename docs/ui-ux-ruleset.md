# Relay UI/UX Ruleset

This document is the default UI implementation reference for Relay.
Agents should consult it before adding or changing any user-facing screen, component, or interaction.

## Product Character

Relay should feel:

- Calm: low visual noise, restrained ornament, clear hierarchy.
- Technical: terminal-adjacent, infrastructure-aware, credible to developers.
- Direct: concise copy, obvious next actions, minimal indirection.
- Safe: the UI should communicate trust and system state without feeling alarmist.

Relay is not a playful consumer app and should not use trendy gradients, glassmorphism, or decorative color for its own sake.

## Core Principles

1. Prefer clarity over density.
2. Prefer semantic color over arbitrary color.
3. Prefer one primary action per surface.
4. Prefer native Apple interaction patterns unless Relay has a strong product reason not to.
5. Prefer durable structure over clever one-off styling.
6. Keep the app feeling like one product: standard app surfaces and terminal surfaces should feel related, not identical.

## Visual Modes

Relay has two visual modes:

- App mode: standard native surfaces for navigation, lists, settings, discovery, and status.
- Terminal mode: more focused, shell-adjacent surfaces for SSH authentication, session state, and terminal output.

Light and dark appearance should be global and follow system settings.
Terminal mode should not force dark mode while the rest of the app stays light.
Differentiate terminal surfaces through typography, contrast, accent usage, and framing instead.
Terminal mode should feel like a neutral shell appliance: graphite, slate, and cool gray surfaces with crisp contrast.
Do not tint terminal backgrounds, cards, or input chrome toward green.

Do not apply terminal styling to general app flows.
Do not make terminal screens look like generic iOS settings screens.

## Color System

Use semantic roles, not raw colors, in implementation where possible.

### App Palette

- `accent / action`: `#0A84FF`
- `success`: `#30D158`
- `warning`: `#FFD60A`
- `danger`: `#FF453A`
- `info`: `#64D2FF`
- `text-primary`: system primary label
- `text-secondary`: system secondary label
- `text-tertiary`: system tertiary label
- `surface-base`: system grouped background
- `surface-raised`: secondary system background
- `surface-stroke`: separator at low opacity

### Terminal Palette

- `terminal-bg`: theme-relative shell surface
- `terminal-surface`: theme-relative raised shell surface
- `terminal-surface-raised`: theme-relative content block surface
- `terminal-text`: theme-relative high-emphasis text
- `terminal-muted`: theme-relative low-emphasis text
- `terminal-subtle`: theme-relative divider or stroke
- `terminal-accent`: blue action and focus color for terminal-adjacent UI
- `terminal-success`: `#30D158`
- `terminal-red`: `#FF453A`
- `terminal-amber`: `#FFD60A`

### Color Rules

- Blue is the default action color on app surfaces.
- Blue is also the default action, focus, and selection color on terminal-adjacent surfaces.
- Green is reserved for explicit success or healthy connected-state indicators, not general UI chrome.
- Yellow indicates recoverable attention states.
- Red is reserved for destructive actions, failures, and irreversible warnings.
- Avoid introducing new brand colors unless the design system is intentionally expanded.
- Never rely on color alone to communicate state; pair it with text or iconography.
- In dark mode, both app and terminal surfaces should darken together.
- In light mode, both app and terminal surfaces should lighten together.
- Terminal carets, focus rings, primary buttons, and prompts should not default to green.
- Terminal neutrals should stay visually neutral; avoid olive, mint, or phosphor-cast backgrounds unless the product direction is intentionally revised.

## Typography

Use typography to separate product UI from shell UI.

### App Typography

- Default to SF Pro via SwiftUI system fonts.
- Use `.headline` or `.title3` for section-driving labels.
- Use `.subheadline` and `.footnote` for supporting metadata.
- Keep labels short and scannable.

### Terminal Typography

- Use the bundled FiraCode Nerd Font for terminal content and shell-adjacent metadata when a monospaced voice adds clarity.
- Use monospaced typography for:
  - commands
  - hostnames
  - usernames
  - ports
  - terminal messages
- Do not render entire non-terminal screens in monospaced text.

## Spacing And Shape

Use a restrained spacing scale:

- `4`: micro spacing inside compact rows
- `8`: tight grouping
- `12`: default control gap
- `16`: default inner padding
- `20`: section spacing
- `24`: sheet and card padding
- `32`: major section separation

Corner radius guidance:

- `12-16`: inputs and compact surfaces
- `18-22`: cards and modal content blocks
- full capsule only when the component semantics call for it

Do not mix many unrelated radii on the same screen.

## Layout Rules

- Each screen should have one obvious structural anchor: a status card, device list, credential block, or terminal canvas.
- Lead with state and action, then metadata.
- Use whitespace to separate groups before reaching for borders.
- Prefer full-width primary actions inside sheets and critical flows.
- Avoid placing two equally emphasized primary actions side by side.
- Keep row layouts simple: icon or status, main content, trailing status/action.

## Component Guidance

### Lists

- Use native list styles for discovery and management flows.
- Each row should expose the minimum data needed for decision-making.
- Sort by usefulness first, then alphabetically.
- De-emphasize unavailable or offline items with both text and opacity/state treatment.

### Cards

- Use cards for status summaries and contextual framing, not as the default container for everything.
- Cards should usually contain:
  - a semantic icon
  - a single strong title
  - one supporting explanation
  - one primary action at most

### Buttons

- `borderedProminent`: primary action only.
- `bordered`: secondary or cancel action.
- destructive style only for actions with real teardown consequences.
- Buttons should use verb-led copy: `Connect Tailscale`, `Start Session`, `Disconnect`.

### Inputs

- Labels and placeholder text must make the field purpose explicit.
- Sensitive fields must disclose storage behavior when relevant.
- Focus states should be visible without being loud.
- Validate by preventing bad submission, then explain errors near the point of failure.

### Status Messaging

- Status should read as current truth, not vague reassurance.
- Good: `3 devices available`
- Good: `Relay couldn't load devices`
- Bad: `Everything looks great!`
- Bad: `Oops`

## Interaction Rules

- Loading states should appear in-place near the affected content.
- Refresh should preserve context and avoid jarring layout jumps.
- If an action launches an external auth flow, explain what will happen before the user starts it.
- Navigation titles should be short nouns, not full sentences.
- Use sheets for contained subtasks such as authentication or credentials.
- Use full-screen focus for the terminal session itself.

## Empty, Loading, And Error States

Every new data-backed surface should define all three.

### Empty State

- Explain why the list is empty in plain language.
- Suggest the next useful action if one exists.
- Do not blame the user.

### Loading State

- Use a spinner plus concise context text when loading takes more than a moment.
- Keep surrounding structure visible so the UI does not feel like it reset.

### Error State

- State what failed.
- Use human-readable wording first; expose raw technical detail only when it helps recovery.
- When possible, provide a recovery action on the same surface.

## Copy Rules

- Use short, declarative sentences.
- Prefer concrete nouns and verbs over product language.
- Avoid exclamation points.
- Avoid anthropomorphic copy.
- Avoid filler like `simply`, `just`, `easy`, or `seamless`.
- Explain security-sensitive behavior directly, such as whether credentials are stored.

## Accessibility And Quality Bar

- Maintain sufficient contrast in both app and terminal modes.
- Do not communicate important state with color alone.
- Touch targets and click targets should not be cramped.
- Support Dynamic Type where practical on standard app surfaces.
- Preserve keyboard-first workflows where they matter, especially in terminal-adjacent flows.
- Respect native behaviors for focus, selection, sheets, lists, and navigation.

## Implementation Rules For Agents

- Reuse existing semantic patterns before inventing new ones.
- Prefer extracting shared view modifiers, tokens, or helper views once a pattern appears twice.
- If a screen needs new colors, add semantic tokens first; do not scatter magic RGB values.
- If a screen is terminal-adjacent, use the terminal palette and monospaced type intentionally, not everywhere.
- If a surface is standard product UI, stay close to native Apple controls and materials.
- When in doubt, choose the plainer option unless the screen truly benefits from stronger atmosphere.

## Current Product Direction

Use the current app as the baseline:

- Device discovery and network management screens should stay native, light-touch, and status-led.
- SSH login and active session screens may carry more terminal character: monospaced details, cool-toned prompt accents, and tighter framing.
- Blue remains the main action color outside terminal-focused flows.
- Terminal-focused flows should still anchor on blue for interaction, with green limited to explicit positive status moments.
- The visual system should feel infrastructural and trustworthy, not consumer-branded.
