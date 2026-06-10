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

## How to Build Your Own Claude Code Plugin

[How to Build Your Own Claude Code Plugin (Complete Guide)](https://agnost.ai/blog/claude-code-plugins-guide/)

### What Actually is a Claude Code Plugin?

A plugin is basically a git repo that lives in ~/.claude/plugins/ and tells Claude about
custom commands, agents, or MCP servers you want available.

Structure:

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json       # Plugin metadata
├── commands/
│   └── hello.md          # Custom slash command
├── agents/
│   └── helper.md         # Subagent definition
└── hooks/
    └── hooks.json        # Workflow hooks
```

The key insight: Everything is just markdown files with frontmatter. No complex APIs,
no build process. Just write markdown and Claude understands it.

### Team Plugins: Share Across Your Org

- Option 1: Team Marketplace

Create a repo called claude-plugins in your org:

```
claude-plugins/
├── .claude-plugin/
│   └── marketplace.json
├── api-generator/
├── test-writer/
└── code-reviewer/
```

marketplace.json:

```
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

Team members add it once:

```
/plugin marketplace add github.com/acme/claude-plugins
/plugin install api-generator@acme-tools
```

# Best practice

## Customize your setup

- `CLAUDE.md`

- Curate Claude's list of allowed tools

    - Select "Always allow" when prompted during a session.

    - Use the /permissions command after starting Claude Code to add or remove tools from the allowlist.

    For example, you can add Edit to always allow file edits, Bash(git commit:*) to allow git commits,
    or mcp__puppeteer__puppeteer_navigate to allow navigating with the Puppeteer MCP server.

    - Manually edit your .claude/settings.json or ~/.claude.json

    (we recommend checking the former into source control to share with your team). Use the --allowedTools
    CLI flag for session-specific permissions.

- If using GitHub, install the gh CLI

## Give Claude more tools

- Use Claude with bash tools

Tell Claude the tool name with usage examples

Tell Claude to run --help to see tool documentation

Document frequently used tools in CLAUDE.md

- Use Claude with MCP

- Use custom slash commands

For repeated workflows—debugging loops, log analysis, etc.—store prompt templates
in Markdown files within the .claude/commands folder. These become available through
the slash commands menu when you type /. You can check these commands into git to
make them available for the rest of your team.

Custom slash commands can include the special keyword $ARGUMENTS to pass parameters
from command invocation.

For example, here's a slash command that you could use to automatically pull and fix a
Github issue:

```
Please analyze and fix the GitHub issue: $ARGUMENTS.

Follow these steps:

1. Use `gh issue view` to get the issue details
2. Understand the problem described in the issue
3. Search the codebase for relevant files
4. Implement the necessary changes to fix the issue
5. Write and run tests to verify the fix
6. Ensure code passes linting and type checking
7. Create a descriptive commit message
8. Push and create a PR

Remember to use the GitHub CLI (`gh`) for all GitHub-related tasks.
```

Putting the above content into .claude/commands/fix-github-issue.md makes it available
as the /project:fix-github-issue command in Claude Code. You could then for example
use /project:fix-github-issue 1234 to have Claude fix issue #1234. Similarly, you
can add your own personal commands to the ~/.claude/commands folder for commands
you want available in all of your sessions.

## Try common workflows

### Explore, plan, code, commit

This versatile workflow suits many problems:

- Ask Claude to read relevant files, images, or URLs,

providing either general pointers ("read the file that handles logging") or specific
filenames ("read logging.py"), but explicitly tell it not to write any code just yet.

- Ask Claude to make a plan for how to approach a specific problem.

"think" < "think hard" < "think harder" < "ultrathink." Each level allocates
progressively more thinking budget for Claude to use

- Ask Claude to implement its solution in code.

- Ask Claude to commit the result and create a pull request.

### Write tests, commit; code, iterate, commit

This is an Anthropic-favorite workflow for changes that are easily verifiable with
unit, integration, or end-to-end tests. Test-driven development (TDD) becomes even
more powerful with agentic coding:

- Ask Claude to write tests based on expected input/output pairs.

- Tell Claude to run the tests and confirm they fail.

- Ask Claude to commit the tests

- Ask Claude to write code that passes the tests,

- Ask Claude to commit the code

Claude performs best when it has a clear target to iterate against—a visual
mock, a test case, or another kind of output. By providing expected outputs like
tests, Claude can make changes, evaluate results, and incrementally improve until
it succeeds.

### Write code, screenshot result, iterate

- Give Claude a way to take browser screenshots

- Give Claude a visual mock

- Ask Claude to implement the design

Ask Claude to implement the design in code, take screenshots of the result, and
iterate until its result matches the mock

- Ask Claude to commit when you're satisfied.

### Safe YOLO mode

Instead of supervising Claude, you can use claude --dangerously-skip-permissions
to bypass all permission checks and let Claude work uninterrupted until completion.
This works well for workflows like fixing lint errors or generating boilerplate code.

### Codebase Q&A

When onboarding to a new codebase, use Claude Code for learning and exploration.
You can ask Claude the same sorts of questions you would ask another engineer
on the project when pair programming. Claude can agentically search the codebase
to answer general questions like:

- How does logging work?

- How do I make a new API endpoint?

- What does async move { ... } do on line 134 of foo.rs?

- What edge cases does CustomerOnboardingFlowImpl handle?

- Why are we calling foo() instead of bar() on line 333?

- What's the equivalent of line 334 of baz.py in Java?

At Anthropic, using Claude Code in this way has become our core onboarding workflow,
significantly improving ramp-up time and reducing load on other engineers. No
special prompting is required! Simply ask questions, and Claude will explore the
code to find answers.

### Use Claude to interact with git

Claude can effectively handle many git operations. Many Anthropic engineers use
Claude for 90%+ of our git interactions:

- Searching git history

- Writing commit messages

- Handling complex git operations like reverting files, resolving rebase conflicts,
and comparing and grafting patches

### Use Claude to interact with GitHub

- Creating pull requests

- Implementing one-shot resolutions for simple code review comments

- Fixing failing builds or linter warnings

- Categorizing and triaging open issues by asking Claude to loop over open GitHub issues

## Optimize your workflow

### Be specific in your instructions

### Give Claude images

Claude excels with images and diagrams through several methods:

    - Paste screenshots
    - Drag and drop
    - Provide file paths

### Mention files you want Claude to look at or work on

Use tab-completion to quickly reference files or folders anywhere in your repository,
helping Claude find or update the right resources.

### Give Claude URLs

Paste specific URLs alongside your prompts for Claude to fetch and read. To avoid
permission prompts for the same domains (e.g., docs.foo.com), use /permissions to
add domains to your allowlist.

### Course correct early and often

    - Ask Claude to make a plan before coding. Explicitly tell it not to code until
    you've confirmed its plan looks good.

    - Press Escape to interrupt Claude during any phase (thinking, tool calls, file edits),
    preserving context so you can redirect or expand instructions.

    - Double-tap Escape to jump back in history, edit a previous prompt, and explore a
    different direction. You can edit the prompt and repeat until you get the result
    you're looking for.

    - Ask Claude to undo changes, often in conjunction with option #2 to take a different
    approach.

### Use /clear to keep context focused

During long sessions, Claude's context window can fill with irrelevant conversation,
file contents, and commands. This can reduce performance and sometimes distract
Claude. Use the /clear command frequently between tasks to reset the context window.

### Use checklists and scratchpads for complex workflows

### Pass data into Claude

    - Copy and paste directly into your prompt (most common approach)

    - Pipe into Claude Code (e.g., cat foo.txt | claude), particularly useful for logs, CSVs, and large data

    - Tell Claude to pull data via bash commands, MCP tools, or custom slash commands

    - Ask Claude to read files or fetch URLs (works for images too)

## Use headless mode to automate your infra

Claude Code includes headless mode for non-interactive contexts like CI,
pre-commit hooks, build scripts, and automation. Use the -p flag with a prompt to
enable headless mode, and --output-format stream-json for streaming JSON output.

Note that headless mode does not persist between sessions. You have to trigger it
each session.

### Use Claude for issue triage

### Use Claude as a linter

## Uplevel with multi-Claude workflows

### Have one Claude write code; use another Claude to verify

### Have multiple checkouts of your repo

### Use git worktrees

This approach shines for multiple independent tasks, offering a lighter-weight
alternative to multiple checkouts.

### Use headless mode with a custom harness

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
