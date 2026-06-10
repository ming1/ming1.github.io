---
title: "Claude Code Usage and Best Practices"
category: operation
tags: [claude code, ai, best practice, productivity]
---

* TOC
{:toc}

# Overview

Notes on using Anthropic's Claude Code CLI for day-to-day engineering work:
how to configure it (`CLAUDE.md`, tool allowlist, MCP servers, custom slash
commands), workflows that work in practice (Explore-Plan-Code-Commit, TDD
loop, screenshot-iterate, codebase Q&A, headless mode), and how plugins are
structured. The content is curated from Anthropic's own guidance and
community sources — links are inline so the original sources stay the
authority for anything that changes.

> Primary sources:
> - [Claude Code docs](https://docs.anthropic.com/claude-code)
> - [Claude Code: Best practices for agentic coding](https://www.anthropic.com/engineering/claude-code-best-practices) — Anthropic engineering blog
> - [awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) — curated commands/files/workflows
> - [Claude Code Spec Workflow](https://github.com/pimzino/claude-code-spec-workflow#readme)
> - [How to Build Your Own Claude Code Plugin (Complete Guide)](https://agnost.ai/blog/claude-code-plugins-guide/)

# Usages

Concrete recipes that come up often. Each one names the exact files,
flags, and prompt patterns rather than gesturing at the idea.

## Subagents: use cases and exact commands

A subagent is a separate Claude invocation with its own context window,
its own tool allowlist, and its own system prompt. The main session
dispatches it via the `Task` (a.k.a. `Agent`) tool and gets back a
single summary message — the agent's intermediate tool output never
touches the main context. That property is what makes subagents
worthwhile: they protect the main window from logs, search results,
and long file reads.

**When to reach for one**

- *Open-ended code search* across many files ("where is X handled?",
  "find every caller pattern of Y"). Use the built-in `Explore` agent
  — read-only, fast, won't pollute main context with file dumps.
- *Independent parallel work* — two refactors that don't share state,
  a research task plus a code change. Dispatch in one message with
  multiple `Task` calls so they run concurrently.
- *Verification / second opinion* — have one agent implement, another
  review the diff. The reviewer starts cold, so its read is genuinely
  independent.
- *Heavy-context one-shots* — auditing a large PR, summarizing a long
  log, ingesting a paper. The agent returns a digest; you keep the
  digest, not the raw input.

**Where subagents live**

Per-project: `.claude/agents/<name>.md`. User-global:
`~/.claude/agents/<name>.md`. The file is a markdown body (the
agent's system prompt) plus YAML frontmatter:

```markdown
---
name: pr-reviewer
description: Use proactively after a logical chunk of code is written, before opening a PR. Reviews staged + unstaged diff for correctness and project conventions.
tools: Bash, Read, Grep, Glob
---

You are a meticulous code reviewer for this repository.
Steps you must follow:
1. Run `git diff HEAD` to get the full change.
2. Cross-check against CLAUDE.md conventions.
3. Report findings as a punch list, severity-tagged.
Do not edit files.
```

The `description` field is what Claude's auto-dispatcher matches
against — write it like a routing label, not a tagline. Restrict
`tools:` to the minimum the agent actually needs; omitting the field
grants all tools.

**Slash commands and prompts**

- `/agents` — list, create, edit, and delete agents from the chat.
  Easier than hand-editing the YAML when you're prototyping.
- Explicit dispatch in a prompt: *"Use the `pr-reviewer` subagent to
  audit the staged diff and return a punch list."* Claude will spawn
  it through the `Task` tool.
- Parallel dispatch — ask in one message: *"In parallel, dispatch
  `Explore` to find all callers of `foo()`, and `Plan` to outline a
  refactor that removes the third argument."* Claude sends both
  `Task` calls in a single tool block, and they execute concurrently.

**Headless invocation**

For CI or scripted pipelines, headless mode picks the agent the same
way an interactive session does — through the prompt's wording:

```bash
claude -p "Use the pr-reviewer subagent to review the diff against origin/master; \
emit findings as JSON" \
  --output-format stream-json
```

## Use Claude Code with git worktrees

Worktrees let you run several Claude sessions on the same repository
at the same time, each on its own branch, sharing one `.git`
directory. This is the lightweight version of "have multiple checkouts
of your repo" — no second clone, no duplicated object database.

**Bootstrap a worktree session**

```bash
# from the repo root
git worktree add ../myrepo-featX -b feat/X        # new branch
# or attach to an existing branch:
git worktree add ../myrepo-fix-Y fix/Y

cd ../myrepo-featX
claude                                            # one Claude session per worktree
```

Open each worktree in its own terminal (or `tmux` pane). The sessions
are fully independent: separate context windows, separate `/clear`
state, separate tool histories. You can have one driving a refactor
on `feat/X` while another investigates a regression on `fix/Y`.

**When it shines**

- *Trying two approaches to the same problem* — branch A and branch B
  in parallel worktrees, compare diffs, keep the winner.
- *Long-running task + interactive work* — kick off a slow refactor in
  worktree #1, keep coding in worktree #2 without waiting.
- *Subagent fan-out across worktrees* — main session in the primary
  checkout dispatches subagents into worktrees so each one operates
  on an isolated working tree.

**Cleanup**

```bash
git worktree remove ../myrepo-featX           # safe: refuses if dirty
git worktree prune                            # drop stale entries
```

The `superpowers:using-git-worktrees` skill automates the bootstrap
when starting feature work that needs isolation. The Agent tool also
accepts `isolation: "worktree"` to spawn a subagent into a fresh
temporary worktree — useful when a subagent's edits should not race
the main session's working tree.

## Agent teams: multi-agent orchestration

> Official references:
> - [Create custom subagents](https://docs.anthropic.com/en/docs/claude-code/sub-agents) — Claude Code docs: subagent file shape, frontmatter (`name`, `description`, `tools`), built-in agents (`Explore`, `Plan`, `general-purpose`), invocation rules.
> - [How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) — Anthropic engineering write-up on the deep-research multi-agent system; the closest thing to a production orchestration case study.
> - [Claude Code Advanced Patterns: Subagents, MCP, and Scaling to Real Codebases](https://www.anthropic.com/webinars/claude-code-advanced-patterns) — Anthropic webinar covering subagent + MCP composition at scale (deck linked from the page).

### Motivation

An *agent team* is a set of specialized subagents — planner,
explorer, implementer, reviewer — that one coordinator dispatches and
integrates. Each member sees only its own narrow slice of context,
so the team can handle work that would overflow a single session's
budget.

Three things this buys you: a reviewer with no `Write` tool
*cannot* "fix" code it doesn't understand; an `Explore` agent that
reads 200 files returns one paragraph, not 200 files; two
independent investigations run in parallel rather than serially.
The coordinator stays small because it sees digests, not raw tool
transcripts.

### How to start the agents

Pick the mechanism based on whether the agents need to live in
separate processes.

**In-session, via the `Task` tool.** The main Claude session spawns
subagents through `Task` calls; agents run inside the same Claude
process, each with its own isolated context window. The simplest
path is to just ask in prose:

> *"In parallel, dispatch `Explore` to map callers of `foo()` and
> `Plan` to sketch a refactor. Return one digest each."*

Multiple `Task` calls in a single message run concurrently;
sequential calls form a pipeline. Built-in agents (`Explore`,
`Plan`, `general-purpose`) cover most needs; custom roles live in
`.claude/agents/<name>.md` (shape covered in *Subagents* above).
This path is **fully autonomous**: dispatch routing is driven by
each agent's `description:` field and the main session selects,
spawns, and integrates without human intervention.

**Cross-process, via tmux.** Start one `claude` process per role,
each in its own tmux pane:

```bash
tmux new -s team
# split into manager + workers
tmux split-window -h -t team
tmux split-window -v -t team
# launch claude in each pane
tmux send-keys -t team.0 "claude" Enter   # manager
tmux send-keys -t team.1 "claude" Enter   # worker 1
tmux send-keys -t team.2 "claude" Enter   # worker 2
```

This path is **only semi-autonomous**: the human builds the topology
once (creating panes, launching workers), and tells each Claude its
role (the manager prompt or its `CLAUDE.md` overlay says "you have
workers in panes `team.1` and `team.2`; dispatch via `tmux
send-keys`, poll with `tmux capture-pane`, use a `__DONE_<rand>__`
sentinel"). After that scaffolding is in place, the manager
dispatches autonomously through `Bash` calls to `tmux`. A common
pattern is to wrap the setup in a one-shot `team-up.sh` and the
dispatch loop in a `/team-dispatch <task>` slash command, so the
human is out of the loop once the team is live; open-source
wrappers like `claude-squad` automate roughly this.

Reach for this when agents need to outlive each other — one watches
a log, one runs a server, one writes code — or when each agent needs
a different working tree. For most teams the in-session variant is
simpler: a tmux pane crash loses the worker's context window with
no way to recover, and the manager has to address every worker by
its exact pane id, so one rename breaks the pipeline.

### How the agents communicate

The orchestrator is the channel. Agents don't talk to each other
directly; everything goes through the coordinator, which decides
what to forward where.

**In-session — digest hand-off.** Every `Task` call returns one
message: the subagent's digest. The coordinator either passes that
digest into the next `Task` (pipeline), merges digests from parallel
calls (fan-out + fan-in), or loops two agents over a shared artifact
like a diff (adversarial review). The discipline is: hand off
summaries, never raw transcripts. If you catch yourself piping a
file dump between agents, the boundary is in the wrong place.

**Cross-process — tmux send-keys + capture-pane.** Two transports,
both polled, neither shared-memory:

- *Inject a prompt into a worker's stdin* — the manager pane runs
  `tmux send-keys -t team.1 "<prompt>" Enter`.
- *Read the worker's reply* — `tmux capture-pane -p -t team.1 -S -200`
  dumps the worker pane's last 200 lines back to the manager.

`send-keys` is fire-and-forget, so the manager needs a printable
sentinel to know the worker actually finished:

```bash
MARK="__DONE_$RANDOM__"
tmux send-keys -t team.1 "<your prompt>; echo $MARK" Enter
# poll capture-pane every couple of seconds until $MARK appears
```

Without a sentinel the manager reads truncated output mid-run and
acts on garbage.

**Shared scratchpad for large payloads.** When a hand-off is bigger
than fits cleanly into a `send-keys` invocation — a long plan, a
file list, a diff — write it to a path both panes agree on
(`/tmp/claude/<run-id>/handoff-N.md`) and pass only the *filename*
through `send-keys`. The worker reads the file directly. This also
makes the hand-off resumable: the file survives if a pane crashes.

## Hooks: shell commands wired into the agent loop

> Official reference:
> - [Hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks) — Claude Code docs: full event list, matcher syntax, JSON I/O schema, decision-control fields.

Hooks are shell commands the Claude Code harness runs at fixed
lifecycle events: when a tool is about to execute, when it finishes,
when the assistant's turn ends, when the user submits a prompt, when
a session starts, and so on. They are configured in
`.claude/settings.json` (project, checked into git) or
`~/.claude/settings.json` (user-global) — *not* in `CLAUDE.md`, which
is just instructions to the model and cannot enforce anything.

The distinction that matters: hooks run *outside* the model. They
execute even if Claude "decides" not to call them. That is what makes
them the right tool for enforcement — formatting on save, blocking
edits to sensitive paths, audit logging — anywhere "trust the model
to remember" is too weak.

**Event cadences**

- *Per session* — `SessionStart`, `SessionEnd`. Bootstrap or
  tear-down: load secrets, warm a cache, dump a summary.
- *Per turn* — `UserPromptSubmit`, `Stop`, `StopFailure`,
  `Notification`. React to user input or end-of-turn state (the
  tmux-status-yellow trick uses `Stop`).
- *Per tool call* — `PreToolUse`, `PostToolUse`. Fire inside the
  agentic loop, on every tool invocation that matches the matcher.

**Schema**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "command": "prettier --write \"$CLAUDE_FILE_PATHS\" 2>/dev/null || true"
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "command": "/path/to/scripts/block-dangerous-bash.sh"
      }
    ],
    "Stop": [
      { "command": "tmux set -t claude status-style bg=yellow" }
    ]
  }
}
```

The matcher is a regex against the tool name (`Edit`, `Write`,
`Bash`, `Read`, …); omit it to match every tool of that event.
Context is delivered to the hook as JSON on stdin — full schema in
the docs reference linked above.

**Decision control**

A `PreToolUse` hook can *block* the tool: exit non-zero with a JSON
body like `{"decision": "block", "reason": "…"}` and the call is
denied; the model sees the reason and adjusts. This is how you
enforce "no `rm -rf` outside `/tmp`" or "no edits to
`prod/config/*`" *as a hard rule*, independent of what the prompt
told the model.

`PostToolUse` can transform a tool's output before the model sees it
via `updatedToolOutput`; `PreToolUse` can rewrite arguments via
`updatedInput`. These exist for the rare cases where filtering at the
boundary is cleaner than instructing the model.

**Typical recipes**

- *Auto-format on edit* — `PostToolUse` on `Edit|Write` runs the
  project formatter against the touched files. Eliminates the
  "Claude wrote unformatted code, lint complains, Claude reformats"
  loop entirely.
- *Path-based deny rule* — `PreToolUse` on `Edit|Write` checks the
  target path against an allowlist; exits with `"decision":
  "block"` for anything under `.env`, `secrets/`, `prod/`. Survives
  Claude "forgetting" the rule.
- *Bash safety gate* — `PreToolUse` on `Bash` rejects commands
  matching `rm -rf /`, `sudo`, `git push --force` unless an
  override env var is set.
- *Audit log* — `PostToolUse` (no matcher) appends every tool call
  to a JSONL file. Useful post-mortem when an agent run went
  sideways.
- *Tmux status flip on idle* — `Stop` hook flips the status bar so
  you can see from across the room that the session is waiting;
  `Notification` hook does the same for permission prompts.
- *Context injection at prompt time* — `UserPromptSubmit` writes
  extra context (current branch, last build status, today's date)
  into the conversation before Claude sees the prompt.

**Hookify**

The `hookify:writing-rules` skill (`/hookify` command from the
hookify plugin) generates hook rules from observed mistakes — point
it at a transcript where Claude did something wrong and it proposes
a `PreToolUse` hook that would have prevented it. Useful for turning
post-mortems into enforceable rules.

**Discipline**

- *Hooks run with your shell's privileges.* A buggy `PreToolUse`
  command that always exits non-zero will block every matching tool
  call until you fix it.
- *Keep hooks fast.* They run synchronously inside the agentic
  loop; a slow hook becomes a slow agent.
- *Prefer project-scoped hooks (`.claude/settings.json` checked
  into git)* for team-wide rules so they survive cloning. Reserve
  `~/.claude/settings.json` for personal hooks (notifications,
  shell-status tweaks).
- *Hooks are not where to teach the model conventions* — they are
  where to enforce constraints. Style guidance still belongs in
  `CLAUDE.md`. Treat hooks as the guardrail, not the manual.

# Plugin

> Source: condensed from agnost.ai's [How to Build Your Own Claude Code Plugin (Complete Guide)](https://agnost.ai/blog/claude-code-plugins-guide/).

## What a plugin is

A plugin is a git repo that lives at `~/.claude/plugins/<name>/` and
bundles custom slash commands, subagents, hooks, and/or MCP servers
into one shippable unit:

```text
my-plugin/
├── .claude-plugin/
│   └── plugin.json       # plugin metadata
├── commands/
│   └── hello.md          # custom slash command
├── agents/
│   └── helper.md         # subagent definition
└── hooks/
    └── hooks.json        # workflow hooks
```

Everything is markdown + JSON. No build step, no plugin SDK to
learn — write the files, drop them under `.claude-plugin/`, and the
CLI picks them up.

## Sharing plugins across an org

A *marketplace* is a git repo that wraps multiple plugins. Layout:

```text
claude-plugins/
├── .claude-plugin/
│   └── marketplace.json
├── api-generator/
├── test-writer/
└── code-reviewer/
```

The marketplace manifest names and describes each plugin:

```json
{
  "name": "acme-tools",
  "owner": {"name": "ACME Corp"},
  "plugins": [
    {
      "name": "api-generator",
      "source": "./api-generator",
      "description": "Generate REST endpoints with tests"
    },
    {
      "name": "test-writer",
      "source": "./test-writer",
      "description": "Generate comprehensive test suites"
    }
  ]
}
```

Team members add the marketplace once, then install plugins by name:

```text
/plugin marketplace add github.com/acme/claude-plugins
/plugin install api-generator@acme-tools
```

# Best practice

> Source: this section is a condensed digest, in the author's voice, of Anthropic's [Claude Code: Best practices for agentic coding](https://www.anthropic.com/engineering/claude-code-best-practices). The original is authoritative — for any tip that matters, read it there.

## Customize your setup

- *`CLAUDE.md` at the repo root* is the primary lever — project
  conventions, build/test commands, gotchas. Loaded into every
  session, including subagent sessions.
- *Tool allowlist.* Pick "Always allow" when prompted during a
  session, or use `/permissions` to add patterns like `Edit`,
  `Bash(git commit:*)`, or `mcp__puppeteer__*`. For team-shared
  defaults, edit `.claude/settings.json` and commit it; for
  per-session overrides, pass `--allowedTools` on the CLI.
- *Install `gh`.* Claude uses it for almost every GitHub
  operation; without it, the workflow degrades to scraping the
  web UI.

## Slash commands

Custom slash commands live in `.claude/commands/<name>.md` (project,
checked into git) or `~/.claude/commands/<name>.md` (personal).
Body is a prompt template; `$ARGUMENTS` is substituted from the
invocation. Example `fix-github-issue.md`:

```markdown
Please analyze and fix GitHub issue: $ARGUMENTS.

Follow these steps:
1. `gh issue view` to read the issue.
2. Find relevant files in the codebase.
3. Implement the fix.
4. Write and run tests.
5. Make linting and type-checking pass.
6. Write a descriptive commit message.
7. Push and open a PR.
```

Now `/project:fix-github-issue 1234` triggers the whole flow.
Beyond slash commands, give Claude more tools by (a) teaching it a
bash command's `--help` once and documenting it in `CLAUDE.md`,
(b) wiring an MCP server, or (c) using the *Hooks* mechanism above
to enforce constraints around tools rather than just describe them.

## Workflows that work

- *Explore → plan → code → commit.* First ask Claude to read the
  relevant files (`read logging.py`) but *not* to write code. Then
  ask for a plan. Escalate thinking budget with `think` /
  `think hard` / `think harder` / `ultrathink` if the problem
  warrants it. Approve the plan, then ask for the implementation
  and commit.
- *TDD loop.* Ask for tests written against expected
  input/output pairs; confirm they fail; commit; ask for the
  implementation; iterate to green; commit. Works whenever the
  target is mechanically verifiable.
- *Screenshot iteration.* For UI work, give Claude a screenshot
  tool and a visual mock; let it iterate the diff against the
  target until they match.
- *Safe-YOLO.* `claude --dangerously-skip-permissions` skips
  every permission prompt. Safe inside a sandboxed or ephemeral
  environment (Docker, CI, throwaway VM); on a real workstation
  it surrenders the human-in-the-loop guardrail.
- *Codebase Q&A.* Treat Claude as a pair-programming colleague
  who already knows the project — ask "how does logging work",
  "what does this on line 134 mean", "why `foo()` here instead of
  `bar()`". Claude agentically searches the code to answer.
- *Git and GitHub.* Claude is reliable at commit messages,
  history search, conflict resolution, PR creation, and bulk
  issue triage. Many engineers route 90%+ of their git
  interactions through it.

## Optimization tips

- *Be specific.* Vague prompts get vague output.
- *Images.* Paste screenshots, drag-and-drop, or pass file paths.
- *Mention files explicitly* by tab-completing repo paths.
- *URLs in prompts get fetched* — allowlist domains in
  `/permissions` to skip the per-request prompt.
- *Course-correct with Escape.* Single-Escape pauses Claude mid-action;
  double-Escape jumps back to a prior prompt for editing. Use it
  freely — cheaper than letting a wrong path run to completion.
- *`/clear` between tasks.* Context fills with irrelevant
  history; clearing it sharply improves quality on the next task.
- *Pass data in* via copy-paste, `cat foo.txt | claude`, or by
  asking Claude to fetch/read directly. The pipe is best for
  large logs and CSVs.

## Headless mode for automation

`claude -p "<prompt>"` runs Claude non-interactively. Add
`--output-format stream-json` for machine-parsable streaming
output. Useful for CI, pre-commit hooks, build scripts, and
one-shot automation. Each invocation is independent — no session
state carries over, so configuration has to be passed every time.

## Multi-Claude workflows

The Anthropic post's "Uplevel with multi-Claude workflows" section
covers patterns already documented above:

- *One Claude writes, another verifies* → see *Subagents* and
  *Agent teams: multi-agent orchestration* under *Usages*.
- *Multiple checkouts of the repo* and *git worktrees* → see
  *Use Claude Code with git worktrees* under *Usages*.
- *Headless mode with a custom harness* → headless mode above,
  composed with whatever orchestrator your CI uses.

## tmux practices with Claude Code

### Persistent sessions across SSH drops

A long Claude run — large refactor, codebase crawl, heavy test sweep —
dies the moment the terminal does. SSH timeout, laptop sleep, network
switch: the agent loses its conversation context with no way back.

Launching Claude inside tmux decouples the session from the terminal:

```bash
# First time on the box
ssh server
tmux new -s claude              # start a named session
claude                          # run Claude inside it
# ... work, then detach with Ctrl-b d, exit SSH

# From anywhere later — laptop, tablet, different network
ssh server
tmux attach -t claude           # resume exactly where you left off
```

The Claude process keeps running on the server through detach,
reconnect, and host changes. This is the single highest-value reason
to put Claude under tmux.

For a fully unattended bootstrap (e.g. from a script), start the
session detached and inject the command:

```bash
ssh server 'tmux new -d -s claude && tmux send-keys -t claude "claude" Enter'
```

### Cross-process agent orchestration with `send-keys`

A second use of tmux: running multiple `claude` processes in
parallel panes and orchestrating them with `tmux send-keys` (manager
types into worker stdin) plus `tmux capture-pane` (manager reads
worker output). This is the **cross-process** variant of the
in-session subagent pattern. Pane layout, dispatch protocol, the
`$MARK` sentinel for completion, and the shared-scratchpad transport
all live in the *Agent teams: multi-agent orchestration* section
above — the tmux mechanics are just the transport for that pattern,
not a separate technique.

### Multi-pane development dashboard

Split one tmux window into three panes so Claude's actions and their
side-effects are visible without window-switching:

- *Pane 1* — `claude`, the active session.
- *Pane 2* — live logs of whatever Claude is touching:
  `tail -f logs/development.log`, `journalctl -f -u <unit>`, or a
  `dmesg -w` for kernel work.
- *Pane 3* — a continuous validator: `npm run test:watch`,
  `cargo watch -x test`, or `htop` for resource pressure during heavy
  builds.

### Asynchronous background execution

Kick off a long task (mass refactor, bulk syntax update, repo-wide
audit), detach with `Ctrl-b d`, and keep working in the foreground
shell. Re-attach when you want to inspect progress.

Add a Claude Code `Stop` hook in `.claude/settings.json` that flips
the tmux status bar so you don't have to re-attach to know the
session is idle and waiting:

```json
{
  "hooks": {
    "Stop": [
      { "command": "tmux set -t claude status-style bg=yellow" }
    ]
  }
}
```

A second hook on session start (or the next user prompt) resets the
colour. Same trick works for "waiting for permission" prompts via
the `Notification` hook.

### Remote and mobile workflows

Run Claude on a beefy workstation or cloud VM, attach from anywhere:
tablet SSH client, lightweight laptop, phone. Because tmux decouples
session state from the display client, the workflow survives device
switches mid-task — review diffs from the tablet, finish the commit
from the laptop. (`/commit` is not a built-in slash command; either
ask Claude to commit in plain prose or define a custom
`.claude/commands/commit.md`.)

# Summary

**Main advantages**

- A single `CLAUDE.md` at the repo root carries project conventions into every
  session — the cheapest, highest-leverage configuration.
- Custom slash commands in `.claude/commands/` make repeated workflows
  (issue-fix, log triage, lint sweep) one keystroke away and share trivially
  via git.
- Headless mode (`-p`, `--output-format stream-json`) makes Claude Code usable
  from CI, pre-commit hooks, and one-shot scripts.
- Plugins are just a git repo of markdown files — no build step, no plugin SDK
  to learn; an org marketplace is one `marketplace.json` away.
- Multi-Claude patterns (writer + verifier, git worktrees, separate checkouts)
  scale beyond what a single interactive session can do.
- Running Claude inside tmux survives SSH drops, host switches, and laptop
  sleeps — the single cheapest reliability win for long agent runs.
- Hooks in `.claude/settings.json` enforce hard rules outside the model
  (formatters, path-based deny, audit logs, idle indicators) — guardrails
  the prompt cannot drift away from.

**Main problems / limitations**

- Context degrades as it fills; `/clear` between tasks is mandatory discipline,
  not a nice-to-have.
- `--dangerously-skip-permissions` ("Safe YOLO") only stays safe inside a
  sandboxed/ephemeral environment — running it on a real workstation
  surrenders the human-in-the-loop guardrail.
- Headless mode does not persist between sessions; configuration has to be
  passed each invocation.
- Cross-process orchestration via `tmux send-keys` is fragile — panes are not
  real isolation, the manager has to know each worker's exact pane address, and
  one rename breaks the pipeline. Prefer in-session `Task`-tool subagents
  unless you genuinely need separate processes.
- Best practices evolve quickly — the linked Anthropic engineering post is the
  authority; this page will lag.
