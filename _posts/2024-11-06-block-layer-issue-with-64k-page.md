---
title: block layer issues with 64K page size
category: tech
tags: [linux kernel, IO]
---

* TOC
{:toc}

block layer issues with 64K page size

# **some issues with 64K page size**

- linux kernel v6.13

## storage device with small segment size(< 64KB) or seg_boundary_mask

- blk_validate_limits() failed

```
static int blk_validate_limits(struct queue_limits *lim)
{
    ...
	/*
	 * By default there is no limit on the segment boundary alignment,
	 * but if there is one it can't be smaller than the page size as
	 * that would break all the normal I/O patterns.
	 */
	if (!lim->seg_boundary_mask)
		lim->seg_boundary_mask = BLK_SEG_BOUNDARY_MASK;
	if (WARN_ON_ONCE(lim->seg_boundary_mask < PAGE_SIZE - 1))
		return -EINVAL;
    ...

    /*
	 * The maximum segment size has an odd historic 64k default that
	 * drivers probably should override.  Just like the I/O size we
	 * require drivers to at least handle a full page per segment.
	 */
	if (!lim->max_segment_size)
		lim->max_segment_size = BLK_MAX_SEGMENT_SIZE;
	if (WARN_ON_ONCE(lim->max_segment_size < PAGE_SIZE))
		return -EINVAL;
    ...
}
```

## ->max_user_sectors can't be less than 128(64K/512)

- blk_validate_limits() failed

```
linux kernel v6.13
static int blk_validate_limits(struct queue_limits *lim)
{
    ...
	if (lim->max_user_sectors) {
		if (lim->max_user_sectors < PAGE_SIZE / SECTOR_SIZE)
			return -EINVAL;
		lim->max_sectors = min(max_hw_sectors, lim->max_user_sectors);
        ...
    }
    ...
}
```

## max block size may be aligned with PAGE_SIZE

Some virtual drivers(loop, nbd, brd, ...), max logical block size is often aligned
with PAGE_SIZE, this is one device property which is decided by kernel configuration.

## other potential issues

- blk_round_down_sectors()

If real 'max_hw_sectors' is less than 64K/512, the calculated number may be
too big. But in reality, such kind of device may be very unusual.

```
static unsigned int blk_round_down_sectors(unsigned int sectors, unsigned int lbs)
{
	sectors = round_down(sectors, lbs >> SECTOR_SHIFT);
	if (sectors < PAGE_SIZE >> SECTOR_SHIFT)
		sectors = PAGE_SIZE >> SECTOR_SHIFT;
	return sectors;
}


int blk_stack_limits(struct queue_limits *t, struct queue_limits *b,
		     sector_t start)
{
    ...
	t->max_sectors = blk_round_down_sectors(t->max_sectors, t->logical_block_size);
	t->max_hw_sectors = blk_round_down_sectors(t->max_hw_sectors, t->logical_block_size);
	t->max_dev_sectors = blk_round_down_sectors(t->max_dev_sectors, t->logical_block_size);
    ...
}
```
