# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ming's personal tech blog — a Jekyll site (jekyll ~3.6.2, `rdiscount` markdown) deployed to `ming1.github.io`. It is built on the legacy **Jekyll-Bootstrap** scaffold, so layouts/includes go through the `JB` Liquid namespace (`{% include JB/setup %}`, `_includes/JB/...`, `_includes/themes/twitter-modified/...`) rather than the modern `jekyll new` template. The `JB:` hash in `_config.yml` is Jekyll-Bootstrap configuration, not stock Jekyll.

GitHub Pages' server-side build is **not** used (the `gem "github-pages"` line in `Gemfile` is intentionally commented out) — the site is built locally and the rendered output is what ships.

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
  category: tech            # one of: tech | operation | life (use singular `category:`, not `categories:`)
  tags: [tag1, tag2, ...]
  ---
  ```
- For drafting new posts, the `writing-blog-post` skill encodes Ming's voice and the conventions used here — invoke it via the Skill tool rather than reinventing structure.

## Supporting code for posts

`code/` is **not** site code — it's reproducers and analysis scripts referenced from posts (e.g. `ublk-mntns-*.sh` backs the ublk mount-namespace deadlock post; `xfs-meta-*.sh|*.py` back the XFS metadata internals post; `writeback-observe.bt` is a bpftrace script). When editing one of those posts, expect the script in `code/` to be the authoritative source the post quotes from.

## Repo hygiene gotchas

- `.gitignore` excludes `*~`, but the working tree is full of stray backup files (`*.md~`, `:w`, single-letter files like `2`/`3`, dumps like `ll`, `test.log`) and binary artifacts (`fast26-pan.pdf`, `favicon.ico` duplicated at root). **Do not `git add -A`** — stage explicitly. Most of these are untracked clutter, not in-progress work.
- `_site/`, `.sass-cache/`, and `.jekyll-cache/` are build output; never commit changes inside them.
- Two remotes: `github` (public, `git@github.com:ming1/ming1.github.io.git`) and `origin` (a private bare mirror at `/kvm/git/ming1.github.io.git/`). Publishing requires pushing to both, which is what `./update` does.
