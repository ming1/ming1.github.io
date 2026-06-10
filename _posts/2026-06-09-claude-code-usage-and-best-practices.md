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

An *agent team* is a set of specialized subagents that the main
session composes into a workflow — planner, explorer, implementer,
reviewer, tester — with a defined topology (pipeline, fan-out, or
adversarial loop). The main session is the orchestrator: it
decomposes the user's request, dispatches subagents through the
`Task` tool, and integrates their results. Each team member sees only
its own narrow slice of context, which is what lets the team tackle
work that would blow past a single session's context budget.

**Why bother orchestrating instead of one big agent**

- Each subagent gets a fresh, focused context — no contamination from
  earlier phases.
- Specialized system prompts and tool allowlists raise quality (a
  reviewer with no `Write` tool *cannot* "fix" code it doesn't
  understand) and reduce blast radius.
- Independent work runs in parallel, cutting wall-clock time.
- The main session's context stays small because it only sees
  summaries, not the agents' raw tool transcripts.

**Common topologies**

- *Pipeline* — `Plan` → `Implementer` → `Reviewer` → `Tester`. Each
  stage's output is the next stage's input. Use when the work has a
  clear linear dependency.
- *Fan-out + fan-in* — dispatch N `Explore`/research agents in
  parallel, then a single synthesizer agent merges. Best for
  open-ended questions across many files or sources.
- *Adversarial loop* — implementer writes, reviewer critiques, loop
  until clean. The two agents see only the diff, not each other's
  reasoning.
- *Hierarchical* — orchestrator dispatches sub-orchestrators, each of
  which dispatches leaf agents. Reserve for genuinely large work;
  flat is simpler and usually enough.

**Orchestration patterns from the main session**

Parallel dispatch — one message, multiple `Task` calls, agents run
concurrently:

> *"In parallel: dispatch `Explore` to map every caller of
> `blk_mq_submit_bio`, `Plan` to outline a refactor that removes the
> third argument, and `general-purpose` to summarize how
> `blk_mq_dispatch_rq_list` interacts with elevators. Return three
> separate digests."*

Sequential pipeline — dispatch the next stage only after the previous
one returns, passing its digest as input:

> *"Step 1: have the `Plan` agent produce an implementation outline
> for migrating callers off the deprecated API. Step 2: pass that
> outline to an `implementer` subagent that writes the code.
> Step 3: dispatch `code-reviewer` against the resulting diff. Stop
> if the reviewer rejects."*

Adversarial loop — same diff, two roles, bounded iterations:

> *"Loop up to 3 times: implementer agent edits to fix the failing
> test; reviewer agent inspects the diff and either approves or
> returns specific objections. Stop on approval or after 3 rounds."*

**Persisting a team for reuse**

Bundle the agents into `.claude/agents/*.md` and check them into the
repo (or ship them as a plugin — see the Plugin section). Pair each
team with a custom slash command in `.claude/commands/` that names
the orchestration, so the whole pipeline becomes one prompt:

```markdown
---
description: Full PR pipeline — plan, implement, review, test.
---

Dispatch the following agents in sequence and stop on any rejection:

1. `Plan` agent: outline the change requested in $ARGUMENTS.
2. `implementer` agent: realize the outline as a diff.
3. `code-reviewer` agent: audit the diff.
4. `pr-test-analyzer` agent: confirm test coverage.

Return a final summary keyed by stage.
```

Stored as `.claude/commands/pipeline.md`, this becomes
`/project:pipeline <task description>` — one keystroke launches the
whole team.

**Discipline that keeps a team coherent**

- *Narrow `description:` fields* — they drive auto-dispatch routing.
  A vague description sends the wrong agent at the wrong time.
- *Minimal `tools:` per role* — reviewer agents do not need `Write`;
  planner agents do not need `Bash`. The allowlist is a safety rail.
- *Pass digests, not raw context* — each stage's summary is the
  hand-off. If you find yourself piping a full file transcript
  between agents, the boundary is in the wrong place.
- *Idempotent inputs* — write each agent's prompt so re-running it on
  the same input yields the same output. That's what makes retry and
  bounded loops safe.
- *The relevant superpowers skills*
  (`superpowers:dispatching-parallel-agents` and
  `superpowers:subagent-driven-development`) encode the
  fan-out and plan-driven variants of this pattern; consult them
  before hand-rolling.

**Use case examples**

These are concrete teams that pay back the setup cost. Each names
the trigger, the topology, the agents, and the single sentence that
launches the whole pipeline.

*Kernel patch-series review* — *fan-out + synthesizer*. Trigger:
a lore.kernel.org URL with a 6-patch series.

- `kernel-patchset-analysis` skill kicks off the review.
- In parallel: `code-reviewer` per patch for correctness; an
  `Explore` agent maps callers of the touched API; a
  `silent-failure-hunter` audits error paths.
- A synthesizer agent merges the four streams into one severity-tagged
  punch list.

> *"Use the kernel-patchset-analysis skill on `<lore URL>`. In
> parallel, dispatch code-reviewer per patch, an Explore agent
> against the touched API surface, and silent-failure-hunter on the
> error paths. Then have one agent merge the findings into a single
> punch list."*

*Subsystem onboarding* — *pure fan-out + fan-in*. Trigger: "I have
to ramp up on `fs/iomap/`."

- N parallel `Explore` agents, each scoped to one subdirectory or
  one of {data structures, public API, callers, lifetimes,
  locking}.
- A synthesizer produces an architecture map plus a "read these
  files first" ordered list.

> *"Fan out five Explore agents over `fs/iomap/`: one for public API,
> one for data structures, one for the IO submission path, one for
> the writeback path, one for callers in fs/xfs. Then have a
> synthesizer produce an architecture map and a reading order."*

*Bug triage* — *pipeline + adversarial loop*. Trigger: an oops
trace or a failing reproducer.

- `Plan` agent reads the trace, forms 3–5 ranked hypotheses with
  the evidence supporting each.
- Fan-out: one investigator agent per hypothesis, each instructed
  to falsify (not confirm) its assignment.
- An adjudicator agent collects the surviving hypotheses and asks
  for one more reproducer experiment.

> *"Step 1: Plan agent reads the oops trace and produces 5 ranked
> hypotheses. Step 2: dispatch 5 investigators in parallel, each
> trying to falsify its hypothesis. Step 3: an adjudicator returns
> the surviving hypothesis and the minimal experiment that confirms
> it."*

*Cross-cutting refactor* — *pipeline with bounded review loop*.
Trigger: rename or signature change with many call sites.

- `Plan` agent produces an ordered migration list.
- Implementer agent edits one batch.
- `code-reviewer` audits the diff; on rejection, the implementer
  re-runs with the objections as input. Cap at three rounds.
- `pr-test-analyzer` confirms coverage of the changed call sites.

> *"Step 1: Plan a migration off `foo_v1()` → `foo_v2()`, ordered by
> safety. Step 2: implementer edits batch 1. Step 3: code-reviewer
> audits; loop with the implementer up to 3 times. Step 4:
> pr-test-analyzer confirms new tests exist for every touched call
> site. Repeat for remaining batches."*

*Blog post drafting* — *strict pipeline*. Trigger: "write a deep
dive on X."

- Researcher agent collects authoritative sources (RFCs, kernel
  commits, man pages) with citations.
- Outliner agent turns the source bundle into a top-down section
  outline.
- Writer agent drafts each section against the outline and sources.
- Fact-checker agent re-grounds every claim against the original
  citations.

> *"Step 1: researcher returns sources for X with citations. Step 2:
> outliner produces a top-down section plan. Step 3: writer drafts
> per the outline. Step 4: fact-checker re-grounds every claim and
> flags anything unsupported."*

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
tmux new -s claude              # start
# ... work, then detach with Ctrl-b d
tmux attach -t claude           # resume from anywhere
```

The Claude process keeps running on the server through detach,
reconnect, and host changes. This is the single highest-value reason
to put Claude under tmux.

### Cross-process agent orchestration with `send-keys`

This is the **cross-process** variant of the in-session pattern in
[Agent teams](#agent-teams-multi-agent-orchestration): a manager
Claude in one pane drives worker Claudes in other panes by writing
into their stdin with `tmux send-keys`.

- *Setup* — one tmux window per agent role (manager, tester,
  architect, researcher). Each pane is its own `claude` process with
  its own context window.
- *Dispatch* — the manager runs `tmux send-keys -t worker:0
  "<prompt>" Enter` to hand a task to a worker pane.
- *When to choose this over in-session subagents* — different repos,
  different worktrees, or when each worker genuinely needs to live in
  its own long-running process (e.g. one watches a server, one
  watches tests). For everything else, the in-session `Task`-tool
  variant is simpler and cheaper.

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
