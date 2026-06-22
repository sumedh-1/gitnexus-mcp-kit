# GitNexus MCP Kit

A **drop-in folder** that gives any VS Code workspace a code-intelligence assistant
(impact analysis, call graphs, execution flows) inside **Copilot Chat → Agent mode** —
with **one shared server** that is never duplicated, even across multiple windows.

It **auto-detects the repos in your workspace** and indexes them for you. You don't have
to configure anything; just open the folder.

---

## What's in here

```
gitnexus-mcp-kit/
├── README.md              ← you are here
├── repos.list             ← OPTIONAL: pin extra repos (auto-detect covers most)
├── .vscode/
│   ├── mcp.json           ← points Copilot at the shared server (port 4747)
│   └── tasks.json         ← auto-runs the bootstrap when the folder opens
└── scripts/
    ├── index-workspace.sh ← ONE command: index every folder in a .code-workspace
    ├── bootstrap.sh       ← macOS / Linux setup (detect + index + 1 server)
    └── bootstrap.ps1      ← Windows / PowerShell setup
```

---

## Fastest path: index a whole `.code-workspace` in one command

Already have a multi-folder VS Code workspace file? Index **every folder in it** with a
single command — no copying the kit, no per-folder setup:

```bash
bash scripts/index-workspace.sh /path/to/your.code-workspace
```

It reads the `folders` array from the workspace file (comments OK), resolves each path,
and indexes them all into the **one shared server** on port 4747. Git repos get an
incremental `analyze`; non-git code gets `analyze --skip-git`. Folders indexed in the last
few days are skipped (set `GITNEXUS_FORCE=1` to override). Missing folders are skipped
with a notice. **It then automatically groups every project in the workspace** so you can
ask cross-repo questions right away (see below). When it finishes, `gitnexus list` shows
everything and Copilot Agent mode can query across all of them.

> One command in, a whole multi-repo workspace out: every project indexed, all of them
> grouped, one shared server, ready for cross-repo questions.

---

## How to use it (import into ANY workspace)

1. **Copy this whole `gitnexus-mcp-kit/` folder** into your project, **or** add it to your
   VS Code workspace as a folder (multi-root works fine).
2. **Open / reopen** the folder in VS Code. The first time, VS Code asks to **Trust** the
   folder and **Allow** the automatic task — say yes.
3. Wait a few seconds (a "GitNexus: bootstrap" task runs silently). It **auto-detects every
   repo in your workspace** and indexes them. Then open **Copilot Chat**, switch the mode
   dropdown to **Agent**, and ask:

   > Using the GitNexus impact tool, what breaks if I change `<SymbolName>` in `<repo>`?

That's it. No keys, no per-project server, no manual repo list.

> **Want explicit control instead of auto-detect?** List repo paths in `repos.list`
> (they're merged with auto-detected ones). To use *only* that list, set `GITNEXUS_AUTO=0`.

> Prefer to run it by hand the first time? Open a terminal in this folder and run
> `bash scripts/bootstrap.sh` (macOS/Linux) or
> `powershell -ExecutionPolicy Bypass -File scripts/bootstrap.ps1` (Windows).

---

## Why there is only ONE server (no duplicates)

GitNexus keeps a **single global registry** of every repo you've indexed. The bootstrap
script starts **one** shared server on port **4747** and, before starting, checks whether
that port is already serving. If it is, it **reuses** it. So:

- Two VS Code windows? They share the **same** server.
- Two different workspaces, each with this kit? Still the **same** server.
- The `.vscode/mcp.json` in every workspace points at the same `http://localhost:4747/api/mcp`.

One engine, every repo, zero duplication.

---

## Keeping results fresh (avoiding stale analysis)

The graph is a **snapshot** taken when you run `analyze`. If code changes and you don't
re-index, impact results go stale. This kit keeps it fresh in two ways:

1. **On folder-open** — the bootstrap **re-indexes** any repo whose index is older than
   `GITNEXUS_FRESH_DAYS` (default **3** days). Recent indexes are skipped (fast startup).
2. **On `git pull` (optional)** — install git hooks once and every repo **re-indexes
   automatically after a pull/merge/checkout**:

   ```bash
   # macOS / Linux
   GITNEXUS_INSTALL_HOOKS=1 bash scripts/bootstrap.sh
   # Windows
   $env:GITNEXUS_INSTALL_HOOKS=1; powershell -ExecutionPolicy Bypass -File scripts/bootstrap.ps1
   ```

   This adds non-blocking `post-merge` / `post-checkout` hooks to each git repo. Re-indexing
   runs in the background, so your `git pull` is never slowed down.

> Force a full refresh any time: set `GITNEXUS_FORCE=1` before opening, or run
> `GITNEXUS_FORCE=1 bash scripts/bootstrap.sh`.
>
> Note: for git repos, `gitnexus analyze` is **incremental** (fast). For non-git code
> (indexed with `--skip-git`, e.g. some MR modules) it re-scans fully but is still quick.

---

## Cross-repo impact — every workspace project, grouped automatically

The whole point of a workspace is that **projects affect each other** — a change in one
repo can ripple into another. So when you index a workspace, the kit **automatically puts
every project into one group** and links them. No manual setup: one command indexes *and*
groups.

Once grouped, ask questions that span the entire workspace — in Copilot Agent mode or the
CLI:

```bash
# Cross-repo flow search: "where does X happen anywhere in the workspace?"
gitnexus group query <workspace> "viewport rendering"

# Cross-repo blast radius: "if I change this symbol, what across the workspace is at risk?"
gitnexus group impact <workspace> --target <Symbol> --repo <project>
```

In Copilot Agent mode the same thing is just natural language:

> Across my workspace, what is the blast radius if I change `<Symbol>` in `<project>`?
> Which other projects are affected, and at what risk level?

`group query` returns ranked hits from **every** repo at once; `group impact` reports the
direct dependants, affected execution flows, and a risk level (LOW → CRITICAL).

> **About cross-links.** When projects reference each other by **source** (shared symbol
> names), the group links them automatically and impact flows across repos. When one
> project consumes another as a **published artifact** (e.g. an npm package whose name
> differs from the repo), the automatic cross-link count can be 0 — the group still gives
> you per-repo blast radius plus cross-repo `query`, and you can match the changed
> *exported* names against the consumer's imports. Re-grouping happens automatically every
> time you re-run the indexer.

---

## Configuration (optional env overrides)

| Variable | Default | Meaning |
|----------|---------|---------|
| `GITNEXUS_PORT` | `4747` | Port for the shared server. |
| `GITNEXUS_FRESH_DAYS` | `3` | Re-index only if the index is older than this many days. |
| `GITNEXUS_FORCE` | `0` | Set to `1` to force re-index of every repo. |
| `GITNEXUS_AUTO` | `1` | Auto-detect repos in the workspace. Set `0` to use only `repos.list`. |
| `GITNEXUS_SCAN_ROOT` | workspace folder | Directory to auto-detect repos under. |
| `GITNEXUS_INSTALL_HOOKS` | `0` | Set to `1` to install re-index-on-pull git hooks. |
| `GITNEXUS_GROUP` | `1` | Auto-group all workspace projects for cross-repo impact. Set `0` to skip. |
| `GITNEXUS_GROUP_NAME` | workspace file name | Override the auto-generated group name. |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Tools not showing in chat | Copilot must be in **Agent** mode. Then check the 🛠️ tools icon for `impact`/`context`/`query`. |
| `fetch failed` when a tool runs | The shared server isn't up. Re-run the bootstrap, or `gitnexus serve --port 4747`. |
| Task didn't run on open | VS Code blocks auto-tasks until you **Trust** the folder and **Allow Automatic Tasks** (Command Palette → "Tasks: Manage Automatic Tasks"). |
| `gitnexus: command not found` | Install Node.js, then re-run bootstrap (it installs gitnexus globally). |
| Want the visual graph | Open `http://localhost:4747` in a browser after bootstrap. |

---

## Does this save tokens? (yes)

GitNexus answers structural questions with **deterministic graph lookups**, not by reading
source code. The lookups themselves cost **zero LLM tokens** — they're plain API calls. The
saving is that the AI no longer has to pull large amounts of code into its context window
to reason about structure:

| Without GitNexus | With GitNexus |
|------------------|----------------|
| To find callers of a symbol, the model greps, then **reads every matching file** into context. | `impact` / `context` return a compact list of exact callers + risk — **no source in context**. |
| To gauge a change, you paste **whole files or diffs** so the model can trace dependencies. | `detect-changes` returns just the **changed symbols**; you only open the few that matter. |
| "Where is X handled?" → dump many files and let the model search. | `query` returns **ranked, process-grouped** hits — a few hundred tokens. |

The pattern: the graph does the mechanical search for free, and the model spends its token
budget on **judgement** instead of scrolling through code. The bigger the codebase, the
bigger the saving — a multi-repo workspace question that would otherwise mean loading
thousands of lines becomes a small structured answer.

---

---

## What's safe about this

Impact / context / query are **deterministic graph lookups** — **no LLM ever reads your
source code** to produce them. That makes the kit safe for proprietary codebases. The only
AI step is Copilot reasoning over the *results* the tools return, in your own approved IDE.
