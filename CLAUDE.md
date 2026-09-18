# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ming's personal tech blog — a Jekyll site (jekyll ~3.6.2, `kramdown` markdown, set in `_config.yml`) deployed to `ming1.github.io`. It is built on the legacy **Jekyll-Bootstrap** scaffold, so layouts/includes go through the `JB` Liquid namespace (`{% include JB/setup %}`, `_includes/JB/...`, `_includes/themes/twitter-modified/...`) rather than the modern `jekyll new` template. The `JB:` hash in `_config.yml` is Jekyll-Bootstrap configuration, not stock Jekyll.

Deployment is GitHub Pages' **server-side** Jekyll build from the `master` branch source: there is no committed `_site/`, no `.nojekyll`, no GitHub Actions workflow, and no `gh-pages` branch, so GitHub rebuilds the site itself on every push. The commented-out `gem "github-pages"` line in `Gemfile` only affects the **local** bundle (so `jekyll serve` runs plain jekyll ~3.6.2 for preview); it does **not** disable GitHub's build. Practical consequences: `_site/` is local preview output only — never commit it; publishing is just pushing source to both remotes (`./update`), after which GitHub regenerates the live pages (including the `/category/` and `/tags/` archives and each post's `/:category/:title` URL).

## Common commands

```bash
bundle exec jekyll serve --watch   # local preview with live reload (also: ./local-test)
bundle exec jekyll build           # one-shot build into _site/
make clean                         # delete editor backup files (*~)
./update                           # publish: git push origin -u && git push github -u
```

There are no tests or linters configured.

## Posts

- Live in `_posts/` and are named `YYYY-MM-DD-slug.md`.
- Permalink scheme is `/:categories/:title` (set in `_config.yml`), so the `category:` front-matter field becomes part of the URL — changing it on an existing post breaks the link.
- Front-matter shape (see any recent post, e.g. `_posts/2026-06-07-linux-rust-kernel-module-explained.md`):

  ```yaml
  ---
  layout: post
  title: "..."
  description: "..."
  category: linux kernel    # one of: linux kernel | bpf | filesystem | storage | hardware | ai | programming | operation | life | others
                            # (use singular `category:`, not `categories:`)
  tags: [tag1, tag2, ...]
  ---
  ```
- For drafting new posts, the `writing-blog-post` skill encodes Ming's voice and the conventions used here — invoke it via the Skill tool rather than reinventing structure.

## Supporting code for posts

`code/` is **not** site code — it's reproducers and analysis scripts referenced from posts (e.g. `ublk-mntns-*.sh` backs the ublk mount-namespace deadlock post; `xfs-meta-*.sh|*.py` back the XFS metadata internals post; `writeback-observe.bt` is a bpftrace script). When editing one of those posts, expect the script in `code/` to be the authoritative source the post quotes from.

## Ceph tracker notes (`_posts/2026-08-12-ceph-tracker-notes.md`)

One `# N.` section per issue: a status line (how found · affects · component · fix · Status), then Report → Analysis → Proposed solution → Takeaways. When adding or reworking a section:

- **Open with the story.** Unless the issue is a few paragraphs long, make `N.1` a "story in one view" (model: §5.1) so the reader has the whole idea before any evidence:
  1. a one- or two-sentence thesis;
  2. one lane/flow diagram with `#N` gutter markers;
  3. a numbered cause→effect chain keyed to the same `#N` — how the path normally works → where it goes wrong → what that costs → what was supposed to prevent it → the gap → the fix (and any twist the fix exposes);
  4. a 2–3 line map of which subsection proves which step.
- The N.1 chain runs top-down (cause→effect) in plain words; the Analysis `why?` tree runs bottom-up (symptom→cause) with `file:line`. Keep both, and don't restate the mechanism in prose between them.
- **One bug, one linear story.** If an issue grows a second bug (a review finding, a sibling gap), give it its own `N.x` block — observation → root cause → fix → why safe → validation — instead of interleaving it through Report/Analysis/Solution. One merged Takeaways at the end.
- When renumbering, fix the in-section `N.x.y` cross-refs; other posts link only to a section as a whole.

## Repo hygiene gotchas

- `.gitignore` excludes `*~`, but the working tree is full of stray backup files (`*.md~`, `:w`, single-letter files like `2`/`3`, dumps like `ll`, `test.log`) and binary artifacts (`fast26-pan.pdf`, `favicon.ico` duplicated at root). **Do not `git add -A`** — stage explicitly. Most of these are untracked clutter, not in-progress work.
- `_site/`, `.sass-cache/`, and `.jekyll-cache/` are build output; never commit changes inside them.
- Two remotes: `origin` and `github`. Publishing requires pushing to both, which is what `./update` does.

## writing style

- Prefer diagrams (ASCII, in fenced code blocks) over prose for structure, flow, and call paths; keep the words in and around a diagram trimmed to the minimum.
- Make it concise and information-dense.
- Remove repetition and unnecessary explanations.
- Replace long sentences with clear, direct statements.
- Keep all important technical details and reasoning.
- Avoid marketing language and generic phrases.
- Preserve the author's technical voice.

### kernel or storage blogs

Rewrite this as a concise, information-dense technical article for senior engineers.
Preserve technical depth, remove verbosity, avoid generic explanations, and focus on
architecture, implementation details, and trade-offs.

