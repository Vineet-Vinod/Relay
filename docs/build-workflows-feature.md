# Remote Build Workflows

## Goal

Let Relay run saved build and test workflows from a phone, stream output live, and make the workflows easy to maintain on the remote machine.

The feature should reuse Relay's existing SSH and terminal architecture instead of inventing a second remote-execution system.

## Product Shape

Add a new host-scoped concept: `RemoteBuildWorkflow`.

Each workflow is a saved command profile that belongs to one remote SSH identity and includes:

- a short name
- a workflow kind such as `build` or `test`
- an optional working directory
- a command definition

The default command style should be `make`-first:

- `make build`
- `make test`
- `make ci`

Advanced users can still store a raw shell script when a project does not expose stable `make` targets.

## Why `make` Should Be The Default

`make` gives Relay a narrow and durable integration point:

- Relay only needs to choose a target and stream stdout/stderr.
- project-specific complexity stays in the repo instead of in the phone UI
- the same target can be used from local terminals, CI, and Relay
- build behavior stays versioned with the codebase

Relay should not try to model every build tool directly in the app.
The app should model workflows, not toolchains.

## Recommended Remote Conventions

Relay should encourage projects to expose stable targets such as:

```make
build:
	./scripts/build.sh

test:
	./scripts/test.sh

lint:
	./scripts/lint.sh

ci: build test
```

That keeps the phone UI simple:

- `Build`
- `Test`
- `Lint`
- `CI`

## User Experience

### Entry Points

Primary:

- Device detail screen: add a `Workflows` section

Secondary:

- Terminal overflow menu: `Run Workflow`

### Workflows Surface

For a host, Relay should show:

- saved workflows
- last run status
- last run time
- one primary action: `Run`

Actions on the workflows surface:

- run workflow
- add workflow
- edit workflow
- delete workflow
- duplicate workflow

### Workflow Editor

The editor should be a sheet.
Fields:

- name
- type: `Build`, `Test`, `Lint`, `Custom`
- working directory
- command mode: `Make Target` or `Shell Script`
- make arguments or script body

Copy should be direct about behavior:

- `Relay runs this command over SSH on the selected host.`
- `Prefer make targets so the workflow stays versioned with the project.`

### Run Experience

Running a workflow should open a focused terminal-adjacent screen, not a settings-style sheet.

The run screen should show:

- workflow name
- host
- working directory
- running state: `Running`, `Succeeded`, `Failed`, `Cancelled`
- live output

Primary actions:

- while running: `Cancel`
- after completion: `Run Again`

Secondary actions:

- `Open Terminal`
- `Copy Output`

## Architecture

### Data Model

Use a local workflow store keyed by remote SSH identity, not by the current mesh provider implementation.

Reason:

- workflows should work for saved devices and future mesh-backed devices
- the storage model should not depend on whether the host came from manual entry, Tailscale, or another provider

Suggested model:

- `RemoteBuildWorkflowHostIdentity`
- `RemoteBuildWorkflow`
- `RemoteBuildWorkflowCommand`
- `RemoteBuildWorkflowStore`

### Execution

Use a dedicated workflow runner view model layered on top of Relay's SSH transport.

Recommended first implementation:

1. Resolve the remote host.
2. Build the remote command from the workflow definition.
3. Start a streaming SSH command session.
4. Render output in a focused run screen.
5. Preserve the final output until the user dismisses it.

The workflow runner should not depend on the interactive terminal widget for correctness.
It can share the same SSH primitives, but a workflow run is logically a task run, not a general shell session.

That distinction will make retries, status, and future notifications much easier.

### Command Construction

Relay should support two command modes:

1. `make(arguments: [String])`
2. `shell(script: String)`

For `make`, Relay should quote arguments safely and execute a fixed binary path such as `/usr/bin/make`.

For `shell`, Relay should be explicit that the workflow is advanced and potentially unsafe if the stored script is wrong.
Relay should run the script through `bash -lc` with strict shell flags enabled.

## Security Constraints

- Reuse Relay's existing SSH host trust flow and credential storage.
- Treat shell workflows as advanced mode.
- Quote every generated shell argument.
- Do not interpolate user input into a shell command without escaping.
- Keep workflow definitions local to the device unless export is explicitly added later.
- If output copying or sharing is added later, make it an explicit user action.

## Suggested Rollout

### Phase 1

- add workflow model and local store
- add command builder
- add workflow editor and saved list on the device detail screen

### Phase 2

- add workflow runner screen with live output
- add retry and cancel support
- add `Open Terminal` handoff

### Phase 3

- add quick-run actions on the device card or detail view
- add last-run history
- optionally add notifications for completion

## Fit With The Current Relay Codebase

This feature maps cleanly onto Relay's current architecture:

- `HostListView` and device detail can own workflow discovery and editing
- the terminal palette already fits a run-output surface
- SSH session handling already exists and should be reused
- workflows can stay local even while actual build execution happens remotely

The main implementation rule is to keep workflow definitions separate from terminal tabs.
A workflow run is a named remote task with state, not merely a prefilled command line.
