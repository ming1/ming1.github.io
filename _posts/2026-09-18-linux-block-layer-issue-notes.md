---
title: "Linux Block Layer Issue Notes"
category: linux kernel
tags: [linux kernel, block, blk-mq, ublk, nvme, scsi, dm, loop, io_uring, debugging, regression, race, lore]
---

* TOC
{:toc}

Running notes on Linux block layer issues I work on upstream — one section
per issue, each covering symptom, root-cause chain, fix, and how the fix was
validated. Sources are lore threads, syzbot and bugzilla reports, and patch
review. Written so the reasoning is reproducible later, not just the
conclusion.

{::comment}
Section skeleton — copy below this block, renumber, fill in. See CLAUDE.md
("Issue notes") for the rules.

# N. <subsystem>: <what breaks, in one line>

[Report](https://lore.kernel.org/linux-block/<msgid>/) · found by <lore
report | syzbot | bugzilla | review | own testing> · affects <vX.Y+, since
`<12-char sha>` ("subject")> · component <blk-mq | ublk | nvme | scsi | dm |
loop | ...> · fix: <one line> · Status: <analysis only | posted vN | applied
to block-X.Y | in vX.Y-rcN | stable backport pending>

## N.1 The story in one view
thesis · lane diagram with #N gutter markers · numbered cause→effect chain ·
map of which subsection proves which step

## N.2 Report            symptom, splat / hung-task trace, reproducer
## N.3 Analysis          bottom-up `why?` tree with file:line
## N.4 Fix               the patch, why it is safe, alternatives rejected
## N.5 Validation        A/B table: stock REPRODUCED -> patched clean
## N.6 Takeaways
{:/comment}
