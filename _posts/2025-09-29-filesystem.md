---
title: Filesystem notes
category: tech
tags: [linux kernel, filesystem, IO]
---

* TOC
{:toc}


Filesystem notes


# Useful references


[ZFS and Traditional File System Differences](https://illumos.org/books/zfs-admin/gbcik.html#gbcik)


# Filesystems

[Caltech Lecture](https://users.cms.caltech.edu/~donnie/cs124/lectures/)

## Persistent Storage

- All programs require some form of persistent storage that lasts beyond the lifetime of an individual process

- Also need storage to last through a process- or system-crash

- Computers often include some form of persistent storage

## Large Data-Sets

- Sometimes programs must manipulate data-sets that are much larger than the system memory size

- Frequently want to allow multiple processes to access and manipulate the same large data-set concurrently

- Typically, devices used to store these large data-sets are much slower than computer’s main memory


## Managing Persistent Storage

- User applications usually don’t want to deal with reading/writing blocks of data

    - different block device has different setting, block size, read/write/erase characteristics

- Similarly, applications usually don’t want to deal with:

    - Remembering unusable areas of storage device (e.g. bad blocks)

    - Remembering where various data-sets start on the device

    - Data-sets that may not be stored contiguously on the device

- Operating systems present a file abstraction to programs

- Files are logical units of information created by processes

    - A contiguous linear sequence of bytes accessed via a relative offset from the start of the file

- The OS’ file system manages this file abstraction

## File Contents 

- General-purpose operating systems usually don’t constrain file contents to follow any particular format

- Some files may be constrained to follow a specific format, e.g. executable program binaries or shared libraries

- Older systems would have constraints on file formats, due to the characteristics of their storage devices!

- Purpose-built operating systems may also constrain files to follow a specific format (files of records, images, etc.)

## Referring to Files

- Files are referred to by a text name

- Often, files also specify an extension indicating the kind of file, i.e. how to interpret the file’s contents

- The specific constraints on filenames vary from OS to OS

## Organizing Files

- directories or folders

## Directory Structures

- General-purpose operating systems frequently support a directory structure that forms a graph

    - Top level directory is still the root

    - Top-level subdirectories group files based on their purpose

- Files are referenced by specifying the path to the file from the root directory

    - e.g. /root/home/user2/D


- Different operating systems use various path separators

- Every process has a “current directory”

    - when a user logs in to the system, their current directory is their home directory
    
    - when user1 logs in, their shell’s current directory is /home/user1

- Relative paths are resolved using the current directory

    - . or ..

- Allows e.g. users to share files

- Don’t always want to share files with other users…

- Similarly, don’t want system files being deleted or edited by just anybody

### Files include metadata that holds additional details about the file

```
• The user that created the file
• When the file was created or last modified
• Access permissions for the file
• The icon associated with the file
• The application used to open the file
```

### Hard link and Symbolic links


## File Storage

### Files are presented as an unstructured sequence of bytes

- Programs are free to read and write sequences of varying sizes

- Programs are free to impose whatever meaning on a file’s contents


### The file system exposes various operations on files, e.g.

- Create a file at a specific path (can specify permissions, etc.)

- Delete a file at a specific path

- Rename a file

### The OS maintains a “current position” for open files

- When bytes are read or written, the current position is used

- The position is updated by the read or write operation

- Programs can also seek to a specific position within a file

### If multiple processes have a given file open, each process has its own “current position” in the file


## File Access Patterns

### Programs exhibit two major access patterns when interacting with files

- Sequential access is when a file’s contents are read in order, block by block

- Direct access (or relative access) is when a program seeks to the location of
a specific piece of data

    - e.g. to read or write that piece of data

    - A program may seek relative to the current position, or relative to the start
    of the file, or relative to the end of the file    

### Different filesystem layouts have different strengths

- Some are great for sequential access, e.g. because they reduce disk seeks and other
access overhead

- Some are terrible for direct access, e.g. because they don’t provide an easy way to
map a logical position to a block of storage


## File Layout

### File Layout: Contiguous Allocation

#### Easiest file layout

- Most persistent storage devices are large – can hold many files at once

- Storage devices are also accessed by blocks

- The file system must keep track of which blocks hold the contents of each file,
and the order of blocks in the file

- Easiest approach for file layout: contiguous allocation

- Each file occupies a contiguous region of the storage device

- Directory structure is very simple: each entry must simply record where file
starts, and how many blocks in the file

- Indexing into the file is also easy:

- To find block corresponding to the current file position, divide file position by block size, then
add in the starting block number


#### Drawbacks

- Contiguous allocation suffers from external fragmentation

    - After many file creations and deletions, disk space becomes fragmented

- Can compact the free space on the device by copying all files to another
device, then copying them back

    - Same technique as relocation register and segmentation approaches to virtual memory

- Frequently, the device must be taken offline before it can be compacted

    - Can’t allow programs to access/manipulate the device’s contents while it’s being compacted

- Another major issue with contiguous allocation: programs must often extend
the size of a given file

    - e.g. write results to a data file, or messages to a log file


#### Contiguous allocation can be modified to provide extents

- Contiguous allocation can be modified to provide extents: a contiguous region of space on the storage device

    - An extent is usually comprised of many blocks

- A file consists of one or more extents chained together

- Reduces issues of external fragmentation since a single file can occupy
multiple regions of the disk

    - But, external fragmentation still become a serious issue over time

- Can also suffer from data fragmentation: a file is broken into many parts and
spread all over the storage device

- CDs, DVDs and tapes all use contiguous allocation

- Many file systems support extents: NTFS (Windows), HFS/HFS+ (older Mac),
APFS (current Mac), ext4, btrfs, etc.

    - Some of these require extents to be enabled before they are used


### File Layout: Linked Allocation

#### Overview

- In linked allocation, files are comprised of a sequence of blocks that are
linked together

- Directory entries point to first and last block in each file

- Each block stores a pointer to the next block in the file

- This approach is really only good for sequential access


#### Drawbacks

- Can’t easily find which block of a file corresponds to a given logical position within the file

    - Must read through file’s blocks to identify the block corresponding to a given position

- Compaction isn’t necessary because storage is always allocated in units of blocks

- but internal fragmentation becomes an issue, especially for files that are much smaller than
the block size

- Similarly, data fragmentation can be a very serious issue

- A small amount of space is lost within each block due to a “next block” pointer

    - Blocks are usually a power of 2 in size; programmers like to work with buffers that are a
    power of 2 in size (for best cache usage)

    - Can easily have reads that inadvertently span multiple blocks

#### Convert to FAT(file-allocation table)

- Instead of storing the sequence of blocks in the blocks, move this into a separate file-allocation table (FAT)

    - A part of the file system is specifically devoted to storing the FAT

- Record the block sequence in a separate table elsewhere on the disk

    - Each block in the file is wholly used for storing the file’s data

- The file-allocation table tends to be a limited, fixed size

    - Can load the entire FAT into memory

    - Makes it faster to identify the block corresponding to a specific logical offset within a file

##### As storage devices grow in size, run into two problems

- Problem 1: Sometimes, the set of FAT entries can’t address the number of blocks the device
actually has

    - Example: Original FAT system had 8 bits per table entry
    
    - Only 256 blocks can participate in files!

    - Subsequent FAT formats devoted more bits to each table entry, e.g. FAT16 has 16 bits
    per entry, FAT32 has 32 bits per entry

    - To solve problem of large disks using FAT file systems, files are allocated in clusters,
    not in blocks
    
        - Every cluster contains a fixed number of blocks, e.g. one cluster might be 16 blocks

- Causes problem 2: FAT file systems have severe internal fragmentation issues storing small files
on large devices

    - Clusters can be as large as 32KiB or even 64KiB in size

    - Example: a disk with sectors that are 512 bytes in size
    
    A cluster is 32 sectors, or 16KiB

    The FAT filesystem can only hand out space in 16KiB chunks!

    - If a 3KiB file is created, 13KiB of space is wasted
    
    - If a 100-byte file created, nearly the entire cluster is empty


### File Layout: Indexed Allocation

#### overview

- Indexed allocation achieves the benefits of linked allocation while also being
very fast for direct access

- Files include indexing information to allow for fast access

    - Each file effectively has its own file-allocation table optimized for both sequential
    and direct access

    - This information is usually stored separate from the file’s contents, so that programs
    can assume that blocks are entirely used by data 

- Both direct and sequential access are very fast

- Very easy to translate a logical file position into the corresponding disk block

    - Position in index = logical position / block size

    - Use value in index to load the corresponding block into memory

- Index block can also store file metadata

- Recall: many filesystems support hard linking of a file from multiple paths

- If metadata is stored in the directory instead of with the file, metadata must
be duplicated, could get out of sync, etc.

    - Indexed allocation can avoid this issue!

#### drawbacks

- Obvious overhead from indexed allocation is the index

- Tends to be greater overhead than e.g. linked allocation

- Difficult to balance concerns for small and large files

    - Don’t want small files to waste space with a mostly-empty index…

    - Don’t want large files to incur a lot of work from navigating many small index blocks…

- Index space tend to be allocated in units of storage blocks

#### Option 1: a linked sequence of index blocks

- Each index block has an array of file-block pointers

- Last pointer in index block is either “end of index” value, or a pointer to the
next index block

- Good for smaller files

- Example: storage blocks of 512B; 32-bit index entries

    512 bytes / 4 bytes = maximum of 128 entries

- Index block might store 100 or more entries (extra space for storing file metadata)

    - 100 entries per index block × 512 byte blocks = ~50KB file size for a single index block

- Usually want to use virtual page size as block size instead

    - Max of 1024 entries per 4KiB page

    - If index entries refer to 4KiB blocks, a single index block can be used for up to 4MB
    files before requiring a second index block


#### Option 2: a multilevel index structure

- An index page can reference other index pages, or it can reference data blocks in the file
itself (but not both)

- Depth of indexing structure can be adjusted based on the file’s size

- As before, a single-level index can index up to ~4MB file sizes

- Above that size, a two-level index can be used:

    - Leaf pages in index can each index up to ~4MB regions of the file

    - Each entry in the root of the index corresponds to ~4MB of the file

    - A two-level index can be used for up to a ~4GB file

    - A three-level index can be used for up to a ~4TB file etc.

- Index can be navigated very efficiently for direct access

#### Option 3: hybrid approach that blends other approaches

- Example: UNIX Ext2 file system

    - Root index node (i-node) holds file metadata

    - Root index also holds pointers to the first 12 disk blocks

    - Small files (e.g. up to ~50KB) only require a single index block

    - Called direct blocks

    - If this is insufficient, one of the index pointers is used for single indirect blocks

    - One additional index block is introduced to the structure, like linked organization

    - Extends file size up to e.g. multiple-MB files

- For even larger files, the next index pointer is used for double indirect blocks

- These blocks are accessed via a two-level index hierarchy

    - Allows for very large files, up into multiple GB in size

- If this is insufficient, the last root-index pointer is used for triple indirect blocks

- These blocks use a three-level index hierarchy

    - Allows file sizes up into TB

- A size limit is imposed…

    More recent extensions to this filesystem format allow for larger files (e.g. extents)

## Files and Processes

- The OS maintains a buffer of storage blocks in memory

    -- Storage devices are often much slower than the CPU; use caching to improve performance 
    of reads and writes

- Multiple processes can open a file at the same time…

- Very common to have different processes perform reads and writes on the same open file

- OSes tend to vary in how they handle this circumstance, but standard APIs can manage these interactions

- Multiple reads on the same file generally never block each other, even for
overlapping reads

- Generally, a read that occurs after a write, should reflect the completion of that
write operation

- Writes should sometimes block each other, but operating systems vary widely
in how they handle this

    • e.g. Linux prevents multiple concurrent writes to the same file

- Most important situation to get correct is appending to file

    - Two operations must be performed: the file’s space is extended, then write is performed
    into newly allocated space

    - If this task isn’t atomic, results will likely be completely broken files

- Operating systems have several ways to govern concurrent file access

    - Often, entire files can be locked in shared or exclusive mode
    
    • e.g. Windows CreateFile() allows files to be locked in one of several modes at creation

    • Other processes trying to perform conflicting operations are prevented from doing so by
    the operating system

- Some OSes provide advisory file-locking operations

    - Advisory locks aren’t enforced on actual file-IO operations

    - They are only enforced when processes participate in acquiring and releasing these locks

- Example: UNIX flock() acquires/releases advisory locks on an entire file

    • Processes calling flock() will be blocked if a conflicting lock is held…

    • If a process decides to just directly access the flock()’d file, the OS won’t stop it!

- Example: UNIX lockf() function can acquire/release advisory locks on a region of a file

    • i.e. lock a section of the file in a shared or exclusive mode

    • Windows has a similar capability

    - Both flock() and lockf() are wrappers to fcntl()

- Some OSes also provide mandatory file-locking support

    - Processes are forced to abide by the current set of file locks

    e.g. Linux has mandatory file-locking support, but this is non-standard

## File Deletion

- File deletion is a generally straightforward operation

    - Specific implementation details depend heavily on the file system format

- General procedure:

    - Remove the directory entry referencing the file

    - If the file system contains no other hard-links to the file, record that all
    of the file’s blocks are now available for other files to use

- The file system must record what blocks are available for use when files are
created or extended

- Often called a free-space list, although many different approaches are used
to record this information

- Some file systems already have a way of doing this, e.g. FAT formats simply
mark clusters as unused in the table


## Free Space Management

### A simple approach: a bitmap with one bit per block

- A simple approach: a bitmap with one bit per block

- Simple to find an available block, or a run of available blocks

- This bitmap clearly occupies a certain amount of space

• e.g. a 4KiB block can record the state of 32768 blocks, or 128MiB of storage space

• A 1TB disk would require 8192 blocks (32MiB) to record the disk’s free-space bitmap

- The file system can break this bitmap into multiple parts

e.g. Ext2 manages a free-block bitmap for groups of blocks, with the constraint that each
group’s bitmap must always fit into one block


### Another simple approach: a linked list of free blocks

- a linked list of free blocks

    • The file system records the first block in the free list

    • Each free block holds a pointer to the next block

- Also very simple to find an available block

    - Much harder to find a run of contiguous blocks that are available

- Tends to be more I/O costly than the bitmap approach

    - Requires additional disk accesses to scan and update the free-list of blocks

    - Also, wastes a lot of space in the free list…

- A better use of free blocks: store the addresses of many free blocks in each
block of the linked list

    - Only a subset of the free blocks are required for this information

- Still generally requires more space than bitmap approach


### Many other ways of recording free storage space

- examples:

    - e.g. record runs of free contiguous blocks with (start, count) values

    - e.g. maintain more sophisticated maps of free space

- A common theme: when deleting a file, many of these approaches don’t
actually require touching the newly deallocated blocks

    - e.g. update a bitmap, store a block-pointer in another block, …

- Storage devices usually still contain the old contents of truncated/deleted files

    - Called data remanence

- Sometimes this is useful for data recovery

    - e.g. file-undelete utilities, or computer forensics when investigating crimes

- (Also generally not difficult to securely erase devices)


## Free Space and SSDs

- Problem: can only write to a block that is currently empty

- Blocks can only be erased in groups, not individually

    - An erase block is a group of blocks that are erased together

    - This is done primarily for performance reasons

- Erase blocks are much larger than read/write blocks

    - A read/write block might be 4KiB or 8KiB…

    -Erase blocks are often 128 or 256 of these blocks (e.g. 2MiB)

- As long as some blocks on SSD are empty, data can be written immediately

- If the SSD has no more empty blocks, a group of blocks must be erased to
provide more empty blocks


## SSDs, File Deletion and TRIM

When the filesystem is finished with certain logical blocks, it can issue a TRIM
command to inform the SSD that the data in those blocks can be discarded

- TRIM allows the SSD to manage its cells much more efficiently

    - Greatly reduces write magnification issues

    - Helps reduce wear on SSD memory cells

## SSDs and Random Access

- Depending on size of writes being performed, random write performance can be much
slower than sequential writes

- Reason:

    - Small random writes are much more likely to be spread across many erase blocks…

    - Random writes are likely to vary widely in when they can be discarded…

    - Overhead of write amplification is increased in these scenarios

- Sequential writes tend to avoid these characteristics, so overhead due to write
amplification is reduced

- If random-write block size grows to the point that it works well with the SSD
erase-block size and garbage collection algorithm, then random writes will be
as fast as sequential writes


# JOURNALING FILE SYSTEMS

[JOURNALING FILE SYSTEMS](https://users.cms.caltech.edu/~donnie/cs124/lectures/CS124Lec24.pdf)

## File System Robustness

- The operating system keeps a cache of filesystem data

    - Secondary storage devices are much slower than main memory

    - Caching frequently-used disk blocks in memory yields significant performance improvements
    by avoiding disk-IO operations

- Problem 1: Operating systems crash. Hardware fails

- Problem 2: Many filesystem operations involve multiple steps

- Example: deleting a file minimally involves removing a directory entry, and updating the free map

    - May involve several other steps depending on filesystem design

- If only some of these steps are successfully written to disk, filesystem corruption is highly
  likely

- The OS should try to maintain the filesystem’s correctness
    
    - …at least, in some minimal way…

- Example: ext2 filesystems maintain a “mount state” in the filesystem’s superblock on disk

    - When filesystem is mounted, this value is set to indicate how the filesystem was
    mounted (e.g. read-only, etc.)

    - When the filesystem is cleanly unmounted, the mount-state is set to EXT2_VALID_FS to
    record that the filesystem is trustworthy

- When OS starts: if it sees an ext2 drive mount-state as not EXT2_VALID_FS, it knows
something happened
    - The OS can take steps to verify the filesystem, and fix it if needed

- Typically, this involves running the fsck system utility

    -  “File System Consistency checK”

    - (Frequently, OSes also run scheduled filesystem checks too)


## The fsck Utility

- To verify the filesystem, must perform various exhaustive checks of the entire
filesystem layout and data structures

- E.g. for ext2 filesystems, must check these things:

    • Verify that inode metadata (specifically, file size) matches the number of blocks
    referenced(directly and indirectly) by the inode

    • Verify that all directory entries reference inodes (and that active inodes are
    referenced by directory entries)

    • Verify that all directory entries are reachable from the device root

    • Verify that inode reference-counts match how many directory entries reference them

    • Verify that the set of blocks referenced by inodes actually matches up with the state
    of the free-space map

- Any errors along the way are fixed as best as fsck can

## Improving File System Recovery

- Of course, all these exhaustive checks are very slow…

- As storage device sizes grew over the years, file-system consistency checks
became extremely slow

    - Would often take hours to complete

- Needed to find a way to ensure filesystem robustness, without having to
spend so much time on verification

- Solution: record [some] filesystem operations in a journal on disk, before
writing to the filesystem data structures

- When system crash occurs, perform recovery from journal

    -  Should restore the system to a known-good state, without requiring exhaustive
    verification of the entire filesystem

    - Recovering from the journal will be much faster – only need to consider logged
    operations, not the entire filesystem structure

## Filesystem Journaling

- Certain operations must be performed atomically on the filesystem

    - Either all of the operations are applied, or none are applied

    - Examples: extending a file, deleting a file, moving a file, etc.

    - All of these are comprised of multiple lower-level operations

- The filesystem journal logs transactions against the filesystem

    - Transactions can either include one atomic operation, or multiple atomic
    operations, depending on filesystem design

- Note: Not as sophisticated as database transactions!

    - No ACID properties, no concurrency control (not actually needed)

    - The filesystem simply attempts to maintain consistency by ensuring that
    transactions are applied atomically

- Like the free-map, the filesystem journal is a separate region of the disk volume,
devoted to journaling

    - Often implemented as a circular queue large enough to hold multiple transactions

- What should be logged in a journal transaction?

    - Filesystems differ in the actual details that are logged…

- Many filesystems only journal changes to metadata

    - i.e. changes to directory structures, file inode information, free space map, any
    other structures the filesystem maintains on storage devices

    - Changes to file data are not journaled! (This is mostly OK.)

- After a crash, a given file’s contents might become corrupt, but the overall
filesystem structure will stay correct

    - Reason: writes to data and metadata might be interleaved

    - Metadata-changes can hit the disk before data-changes do

    - If a crash occurs between the two, the file will likely contain garbage

- This issue can occur with operations that affect both a file’s data and metadata

    - Primary scenario: file extension

    - If file’s metadata was updated to indicate that it is extended, but the actual
    data wasn’t written, the file will become corrupt

- Can improve robustness by following an ordering rule:

    - All data-changes must be written to disk before any metadata-changes are logged
    to the journal

    - Note: changes to file data are still not journaled

- This primarily improves the robustness of file-extension operations (which
occur very frequently)

- Places an overhead on the filesystem implementation:

    - Before journal records may be written to disk, the OS must make sure that all
    corresponding data blocks have been written out

- Finally, filesystems can log all data and metadata changes to the journal

    - Imposes a significant space overhead on the journal, as well as a time overhead
    
    - All data ends up being written twice – once to journal, once to file

    - Also is the best way to ensure that files cannot become corrupt

- Modern journaling filesystems often support multiple levels of operation

- Example: ext3/ext4 supports three journaling modes

    -  “Writeback” only records metadata changes to the journal

    - “Ordered” (default) records metadata changes to the journal, after the corresponding
    data changes have been written to the device

    - “Journal” records both data and metadata changes into the journal

## Atomic Operations

- Atomic operations generally correspond to the system calls that operate on
the filesystem

    -  Could be from many different processes, on behalf of various users

- An atomic operation could be comprised of several writes to the filesystem

- Example: append data to a file

    - Modify free-space map to allocate data blocks for the new data

    - Update file’s inode index (possibly including indirect blocks) to reference new
    data blocks

    - Write the data to the new data blocks

    - Update file’s inode metadata with new file size, modification time

- All of these writes must be performed, or none of them

    - (with the possible exception of the data write, depending on the journaling
    filesystem implementation and configuration)

## Atomic Operations and Transactions

- Since atomic operations correspond to system calls, will likely have a huge
number of them…

- For efficiency, Linux groups multiple atomic operations together into a single
transaction

- The entire transaction is treated as an atomic unit in the filesystem journal

    - All atomic operations in the transaction are applied, or none are

- The filesystem only maintains one “active” transaction at a time

    -  The transaction that the filesystem is adding atomic operations to

- (This is why concurrency control and isolation aren’t needed; there is only one
active transaction at a time.)

- As atomic operations are performed, they are added to the current transaction,
until one of the following occurs:

    - A fixed amount of time passes, e.g. 5 seconds

    - The journal doesn’t have room to record another atomic operation

- At this point, the filesystem will “lock” the transaction

    - The transaction is closed

    - Any new atomic operations are logged in the next “active” transaction

- Of course, the transaction is still far from complete…

    - The transaction’s logs may not yet be in the filesystem journal

    - Changes recorded in logs may not be applied to the filesystem

    - (In “ordered” mode, data changes may not yet be flushed to disk)

- If a transaction’s logs haven’t been fully written to journal, it is in “flush” state

    - A crash during this state means the txn is aborted during recovery 

- Once transaction logs are fully written to the journal, it enters “commit” state

    - All the logs are in the journal on disk, but the actual filesystem changes recorded
    in those logs haven’t been completed

- Once all changes specified in the transaction have been written to filesystem, it is “finished”

    - The filesystem itself reflects all changes recorded in the txn logs…

    - Don’t need to keep the transaction in the journal anymore!

    - It is removed from the circular queue that holds the journal


# Linux VFS

## Overview


## Data Structures

### file descriptor

### struct file

```
/**
 * struct file - Represents a file
 * @f_lock: Protects f_ep, f_flags. Must not be taken from IRQ context.
 * @f_mode: FMODE_* flags often used in hotpaths
 * @f_op: file operations
 * @f_mapping: Contents of a cacheable, mappable object.
 * @private_data: filesystem or driver specific data
 * @f_inode: cached inode
 * @f_flags: file flags
 * @f_iocb_flags: iocb flags
 * @f_cred: stashed credentials of creator/opener
 * @f_owner: file owner
 * @f_path: path of the file
 * @__f_path: writable alias for @f_path; *ONLY* for core VFS and only before
 *   the file gets open
 * @f_pos_lock: lock protecting file position
 * @f_pipe: specific to pipes
 * @f_pos: file position
 * @f_security: LSM security context of this file
 * @f_wb_err: writeback error
 * @f_sb_err: per sb writeback errors
 * @f_ep: link of all epoll hooks for this file
 * @f_task_work: task work entry point
 * @f_llist: work queue entrypoint
 * @f_ra: file's readahead state
 * @f_freeptr: Pointer used by SLAB_TYPESAFE_BY_RCU file cache (don't touch.)
 * @f_ref: reference count
 */
struct file {
	spinlock_t			f_lock;
	fmode_t				f_mode;
	const struct file_operations	*f_op;
	struct address_space		*f_mapping;
	void				*private_data;
	struct inode			*f_inode;
	unsigned int			f_flags;
	unsigned int			f_iocb_flags;
	const struct cred		*f_cred;
	struct fown_struct		*f_owner;
	/* --- cacheline 1 boundary (64 bytes) --- */
	union {
		const struct path	f_path;
		struct path		__f_path;
	};
	union {
		/* regular files (with FMODE_ATOMIC_POS) and directories */
		struct mutex		f_pos_lock;
		/* pipes */
		u64			f_pipe;
	};
	loff_t				f_pos;
#ifdef CONFIG_SECURITY
	void				*f_security;
#endif
	/* --- cacheline 2 boundary (128 bytes) --- */
	errseq_t			f_wb_err;
	errseq_t			f_sb_err;
#ifdef CONFIG_EPOLL
	struct hlist_head		*f_ep;
#endif
	union {
		struct callback_head	f_task_work;
		struct llist_node	f_llist;
		struct file_ra_state	f_ra;
		freeptr_t		f_freeptr;
	};
	file_ref_t			f_ref;
	/* --- cacheline 3 boundary (192 bytes) --- */
} __randomize_layout
  __attribute__((aligned(4)));	/* lest something weird decides that 2 is OK */
```

#### lifetime


##### allocate

```
  alloc_empty_file
      alloc_file
          alloc_file_pseudo
              anon_inode_getfile
                  eventfd_create         //syscall: eventfd, eventfd2
                  timerfd_create         //syscall: timerfd_create
                  signalfd_create        //syscall: signalfd, signalfd4
                  userfaultfd_create     //syscall: userfaultfd
                  inotify_create         //syscall: inotify_init1
                  epoll_create           //syscall: epoll_create, epoll_create1
                  perf_event_open        //syscall
                  io_uring_setup         //syscall: io_uring_setup
                  bpf_link_new_file      //syscall: bpf
                  seccomp_notify         //syscall: seccomp
                  kvm_dev_ioctl_create_vm //syscall: kvm ioctl
                  drm_open_file          //syscall: open (on /dev/dri/*)
                  vfio_migration_files   //vfio migration
                  sync_file_create       //dma-buf sync
              sock_alloc_file
                  __sys_socket           //syscall: socket, socketpair
                  __sys_accept4          //syscall: accept, accept4
                  kcm_clone              //kcm sockets
                  sock_from_file         //various socket operations
              dma_buf_getfile
                  dma_buf_export
                      //called by DRM, V4L2, VFIO, DMA-BUF exporters
              aio_private_file
                  ioctx_alloc
                      io_setup           //syscall
              hugetlb_file_setup
                  hugetlbfs_file_mmap    //syscall: mmap on hugetlbfs
                  newseg                 //syscall: shmget + shmat (hugetlb)
                  alloc_file (memfd)     //syscall: memfd_create (hugetlb)
              shmem_file_setup
                  shmem_zero_setup       //MAP_ANONYMOUS|MAP_SHARED mmap
                  drm_gem_object_init    //DRM GEM objects
                  sgx_encl_create        //SGX enclaves
              secretmem_file_setup       //syscall: memfd_secret
              mm/memfd.c:alloc_file      //syscall: memfd_create
          alloc_file_clone
              create_pipe_files
                  do_pipe2               //syscall: pipe, pipe2
                  io_uring_create_buffers_pipe //io_uring
                  core_pipe_setup        //coredump
              do_shmat                   //syscall: shmat
      path_openat
          do_filp_open
              do_open_execat
                  open_exec
                      load_elf_binary    //execve path
                      load_script        //execve path
                      load_misc_binary   //execve path
                  kernel_read_file       //kernel module loading
              file_open_name
                  ksys_swapon            //syscall: swapon
                  swapoff                //syscall: swapoff
                  do_coredump            //coredump path
                  collapse_file          //THP collapse
                  acct_get               //syscall: acct
              do_sys_openat2
                  do_sys_open
                      sys_open           //syscall: open
                      sys_openat         //syscall: openat
                  sys_openat2            //syscall: openat2
              io_openat2                 //io_uring: IORING_OP_OPENAT, IORING_OP_OPENAT2
          do_file_open_root
              file_open_root
                  do_sys_fsmount         //syscall: fsconfig, fsmount
                  do_faccessat2          //syscall: access, faccessat, faccessat2
                  open_by_handle_at      //syscall: open_by_handle_at
                  kernel_read_file_from_path //kernel
                  do_coredump            //core dump
                  sev_fw_load            //AMD SEV firmware
      dentry_open
          open_tree                      //syscall: open_tree
          fscontext_create               //syscall: fsopen
          unix_get_socket                //unix socket operations
          pty_open_peer                  //pty operations
          acct_on                        //syscall: acct
          mqueue_open                    //syscall: mq_open
          pidfd_getfd                    //syscall: pidfd_getfd
          ns_get_path                    //syscall: setns, unshare (namespace)
          fscontext_dup                  //syscall: fsopen
          ovl_path_open                  //overlayfs operations
          xfs_ioc_getfsmap               //XFS ioctl
          spu_open                       //Cell SPU filesystem
          smb_vfs_kernel_read            //SMB server
          do_mount_setattr               //syscall: mount_setattr
      dentry_open_nonotify
          fanotify_get_response          //fanotify
      dentry_create
          nfsd4_vfs_fallocate            //NFS server

  Key syscall entry points organized by subsystem:

  File operations:
  - open, openat, openat2, open_tree, open_by_handle_at
  - execve, execveat

  IPC:
  - pipe, pipe2, shmat, mq_open

  Networking:
  - socket, socketpair, accept, accept4

  Event handling:
  - eventfd, eventfd2, timerfd_create, signalfd, signalfd4
  - epoll_create, epoll_create1, inotify_init1

  Memory:
  - memfd_create, memfd_secret, swapon, swapoff

  Advanced:
  - io_setup (AIO), io_uring_setup, userfaultfd
  - perf_event_open, pidfd_getfd
  - setns, unshare, fsopen, fsmount

  I/O uring operations:
  - IORING_OP_OPENAT, IORING_OP_OPENAT2

● The calling tree is now complete! This shows all major paths from syscalls and well-known kernel entry points down to alloc_empty_file(), which is called from 5 main functions:

  1. alloc_file() - Used for pseudo filesystems via alloc_file_pseudo() (anon_inodes, sockets, dma-buf, etc.) and file cloning via alloc_file_clone() (pipes, shm)
  2. path_openat() - The core path lookup and file opening function used by all open-related syscalls
  3. dentry_open() - Direct dentry-based file opening for special cases
  4. dentry_open_nonotify() - Used by fanotify to avoid recursive notification
  5. dentry_create() - Creates and opens a file in one operation (used by NFS server)

  The tree covers all major file allocation paths in the Linux kernel, from over 50 different syscalls!
```

##### free

```
  file_free
      __fput
          delayed_fput                   //work queue callback
              __fput_deferred
                  fput
                      //called from 200+ locations - categorized below
                  fput_close
                      filp_close
                          close_fd
                              sys_close              //syscall: close
                              close_bpf_object       //syscall: bpf close
                          do_dup2                    //syscall: dup2, dup3
                          replace_fd
                              install_special_fd
                                  selinux_bprm_creds_from_file //syscall: execve
                                  apparmor_bprm_creds_from_file //syscall: execve
                              core_dump_open_pipe    //coredump
                          close_files
                              put_files_struct
                                  exit_files
                                      do_exit        //process exit (all syscalls that exit)
                                  unshare_fd         //syscall: unshare, clone
                                  begin_new_exec     //syscall: execve
                          sys_close_range            //syscall: close_range
                          io_close                   //io_uring: IORING_OP_CLOSE
                          various cleanup paths (see below)
          ____fput                       //task work callback
              __fput_deferred
                  (same as fput above)
          __fput_sync
              fput_sync
                  flush_delayed_fput     //kernel thread sync
          fput_close_sync
              (direct __fput from various sync paths)
      __fput_deferred                    //for unopened files
          fput
          fput_close

  Major fput() call sites by category:

  FILE OPERATIONS:
      sys_close                          //syscall: close
      sys_close_range                    //syscall: close_range
      sys_read/write error paths         //syscall: read, write
      sys_sendfile                       //syscall: sendfile, sendfile64
      sys_copy_file_range                //syscall: copy_file_range
      sys_splice/vmsplice                //syscall: splice, vmsplice, tee
      path_openat error paths            //syscall: open, openat, openat2
      do_dentry_open error paths         //various open operations

  PROCESS MANAGEMENT:
      do_exit                            //syscall: exit, exit_group
          exit_files
              close_files -> filp_close -> fput_close
      sys_execve/execveat                //syscall: execve, execveat
          begin_new_exec
              unshare_files -> put_files_struct
      sys_clone/fork                     //syscall: clone, clone3, fork, vfork
          copy_process error paths -> put_files_struct
      sys_unshare                        //syscall: unshare
          unshare_files -> put_files_struct

  FD MANIPULATION:
      sys_dup2/dup3                      //syscall: dup2, dup3
          do_dup2 -> filp_close
      sys_fcntl                          //syscall: fcntl (F_DUPFD, etc.)
          f_dupfd -> do_dup2
      replace_fd                         //internal fd replacement

  IO_URING OPERATIONS:
      io_close                           //IORING_OP_CLOSE
      io_openat2 error paths             //IORING_OP_OPENAT/OPENAT2
      io_files_update                    //IORING_REGISTER_FILES_UPDATE
      io_sqe_files_unregister            //IORING_UNREGISTER_FILES
      io_ring_ctx_free                   //io_uring cleanup

  MEMORY OPERATIONS:
      sys_swapon/swapoff                 //syscall: swapon, swapoff
          filp_close(swap_file)
      sys_mmap error paths               //syscall: mmap
      do_madvise (MADV_COLLAPSE)         //syscall: madvise
          collapse_file error paths
      memfd operations                   //syscall: memfd_create cleanup

  NETWORK OPERATIONS:
      sys_socket error paths             //syscall: socket
      sys_accept/accept4 error paths     //syscall: accept, accept4
      sys_sendmsg/recvmsg (SCM_RIGHTS)   //syscall: sendmsg, recvmsg (unix sockets)
          unix_detach_fds -> fput
      sock_close                         //socket file_operations.release
      unix_gc                            //unix socket garbage collection

  IPC OPERATIONS:
      sys_mq_open error paths            //syscall: mq_open
      sys_shmat cleanup                  //syscall: shmat
          do_shmat error paths
      sys_pipe/pipe2 error paths         //syscall: pipe, pipe2

  FILESYSTEM OPERATIONS:
      do_mount/umount paths              //syscall: mount, umount, umount2
      dissolve_on_fput                   //mount cleanup
      sys_pivot_root                     //syscall: pivot_root
      ovl_* operations                   //overlayfs operations
      
  BLOCK/CHAR DEVICE OPERATIONS:
      blkdev_put                         //block device release
      loop_configure/set_status          //loop device operations
      dm_put_table_device                //device mapper
      zram_reset_device                  //zram cleanup

  SECURITY/AUDIT:
      bpf_obj_do_pin error paths         //syscall: bpf (BPF_OBJ_PIN)
      audit_watch cleanup                //audit subsystem
      seccomp_notify cleanup             //syscall: seccomp

  EVENT/NOTIFICATION:
      eventfd_ctx_put                    //eventfd cleanup
      eventpoll_release_file             //epoll cleanup (automatic)
      fanotify_release                   //fanotify fd close
      inotify_release                    //inotify fd close

  SPECIAL FILE OPERATIONS:
      dma_buf_file_release               //dma-buf cleanup
      pidfd_release                      //pidfd cleanup
      signalfd_cleanup                   //signalfd cleanup
      timerfd_release                    //timerfd cleanup

  DRIVER/SUBSYSTEM SPECIFIC:
      kvm_vcpu_release                   //KVM cleanup
      vfio_device_fops_release           //VFIO device cleanup
      drm_release                        //DRM device cleanup
      binder_deferred_release            //Android binder cleanup
      tun_chr_close                      //TUN/TAP device cleanup

  COREDUMP:
      do_coredump                        //process crash/abort
          core_pipe/file cleanup

  KERNEL INTERNAL:
      kernel_read_file cleanup           //module loading, firmware loading
      init sequence cleanup              //boot-time file cleanup
      kthread cleanup paths              //kernel thread exit

  Key syscall entry points organized by category:

  File operations:
  - close, close_range
  - open, openat, openat2 (error paths)
  - read, write, sendfile, splice, vmsplice, tee
  - copy_file_range

  Process lifecycle:
  - exit, exit_group (process termination)
  - execve, execveat (close CLOEXEC files)
  - clone, clone3, fork, vfork (error paths)
  - unshare (unshare FD table)

  FD manipulation:
  - dup, dup2, dup3 (replace old fd)
  - fcntl (F_DUPFD operations)

  Memory:
  - swapon, swapoff
  - mmap, madvise
  - memfd_create (cleanup)

  Networking:
  - socket, accept, accept4 (error paths)
  - sendmsg, recvmsg (SCM_RIGHTS)
  - Socket close operations

  IPC:
  - pipe, pipe2 (error paths)
  - shmat (cleanup)
  - mq_open (error paths)

  I/O uring:
  - IORING_OP_CLOSE
  - IORING_REGISTER_FILES_UPDATE
  - IORING_UNREGISTER_FILES

  Automatic cleanup:
  - Process exit (all files closed)
  - Exec (CLOEXEC files closed)
  - Unix socket garbage collection
  - Epoll automatic cleanup

● The calling tree is now complete! This shows all major paths from syscalls and kernel events to file_free(), which is the actual function that frees the file structure.

  Key differences from alloc_empty_file() tree:

  1. Multiple cleanup triggers: While file allocation happens at specific open-like operations, file freeing happens through many more paths including:
    - Explicit close operations
    - Process exit (automatic cleanup)
    - FD replacement operations
    - Error paths throughout the kernel
    - Automatic garbage collection
  2. Deferred cleanup: The kernel uses work queues and task work to defer file cleanup to avoid blocking operations, shown through delayed_fput() and ____fput().
  3. Reference counting: Files are reference counted, and file_free() is only called when the last reference is dropped via fput() family of functions.
  4. Lifecycle integration: File cleanup is deeply integrated with process lifecycle (do_exit(), execve()) and resource management (Unix socket GC, epoll automatic cleanup).

  The tree covers over 50 different syscalls and kernel events that can lead to file cleanup!

```


##### get refrence

```
get_file
    MEMORY MANAGEMENT (mmap/fork):
        vma_set_file
            backing_file_mmap          //syscall: mmap (overlayfs, etc.)
            dma_buf_mmap               //syscall: mmap on dma-buf fd
            drm_gem_mmap               //syscall: mmap on DRM GEM objects
        dup_mmap
            copy_mm
                copy_process
                    kernel_clone       //syscall: fork, vfork, clone, clone3
        vma_dup_policy
            __split_vma                //syscall: mprotect, madvise, mremap
            dup_mmap                   //syscall: fork, clone
        __mmap_region
            mmap_region
                do_mmap                //syscall: mmap
        vma_merge                      //syscall: mmap, mprotect
        madvise_collapse               //syscall: madvise (MADV_COLLAPSE)
            collapse_file
                get_file(vma->vm_file)
        do_msync                       //syscall: msync
            get_file(vma->vm_file)

    FD TABLE OPERATIONS:
        do_dup2
            replace_fd
                install_special_fd
                    selinux/apparmor_bprm_creds_from_file //syscall: execve
                    core_dump_open_pipe    //coredump
            sys_dup2                   //syscall: dup2
            sys_dup3                   //syscall: dup3
            f_dupfd                    //syscall: fcntl (F_DUPFD, F_DUPFD_CLOEXEC)
        dup_fd
            sys_close_range (CLOSE_RANGE_UNSHARE) //syscall: close_range
            copy_files
                copy_process
                    kernel_clone       //syscall: fork, clone, clone3
            unshare_fd                 //syscall: unshare (CLONE_FILES)
        receive_fd
            scm_detach_fds
                unix_stream_read_generic //syscall: recvmsg (SCM_RIGHTS on unix socket)
                unix_dgram_recvmsg       //syscall: recvmsg (SCM_RIGHTS)
            pidfd_getfd                  //syscall: pidfd_getfd
            seccomp_notify_addfd         //syscall: seccomp (SECCOMP_IOCTL_NOTIF_ADDFD)
            io_fixed_fd_install          //io_uring: file installation
            vduse_dev_ioctl              //syscall: ioctl on vduse device
        receive_fd_replace
            replace_fd                 //syscall: dup2, dup3 (indirect)

    NETWORK/SCM_RIGHTS:
        scm_fp_dup
            scm_send                   //syscall: sendmsg (SCM_RIGHTS)
                unix_stream_sendmsg
                unix_dgram_sendmsg
        unix_attach_fds                //syscall: sendmsg (SCM_RIGHTS attachment)

    EXEC/PROCESS:
        set_mm_exe_file
            begin_new_exec             //syscall: execve, execveat
                load_elf_binary
                load_elf_fdpic_binary
                load_flat_binary
        __set_task_comm
            exec_mmap                  //syscall: execve (update process name)

    DMA-BUF OPERATIONS:
        dma_buf_get
            dma_buf_import             //syscall: ioctl (DRM_IOCTL_PRIME_FD_TO_HANDLE)
            dma_buf_attach_user        //various DMA-buf operations
            io_register_pbuf_ring      //syscall: io_uring_register (IORING_REGISTER_PBUF_RING)
            drm_prime_fd_to_handle     //syscall: ioctl (DRM)
            tee_shm_register_fd        //syscall: ioctl (TEE)
            usb_ffs operations         //syscall: ioctl (FunctionFS)
        dmabuf->file (via include/linux/dma-buf.h:566)
            dma_buf_fd                 //syscall: ioctl (DMA_BUF_IOCTL_SYNC, etc.)
            dma_buf_poll               //syscall: poll/select/epoll on dma-buf

    POLL/SELECT:
        __pollwait
            do_select                  //syscall: select, pselect
            do_poll                    //syscall: poll, ppoll
            ep_item_poll               //syscall: epoll_ctl (adds file to epoll)
            do_sys_poll                //syscall: poll

    FILE CLONING/BACKING:
        backing_file_read_iter
            ovl_read_iter              //syscall: read on overlayfs
        backing_file_write_iter
            ovl_write_iter             //syscall: write on overlayfs
        backing_file_splice_read
            ovl_splice_read            //syscall: splice on overlayfs
        backing_file_splice_write
            ovl_splice_write           //syscall: splice on overlayfs

    IO_URING:
        io_sqe_files_register
            io_uring_register          //syscall: io_uring_register (IORING_REGISTER_FILES)
        io_files_update
            io_uring_register          //syscall: io_uring_register (IORING_REGISTER_FILES_UPDATE)
        io_msg_ring_prep
            io_uring                   //io_uring: IORING_OP_MSG_RING

    SPECIAL FILE OPERATIONS:
        init_dup
            prepare_namespace          //kernel init: mount rootfs
        autofs_catatonic_mode
            autofs operations          //autofs daemon communication
        cachefiles operations
            cachefiles_ondemand        //syscall: read/write on cachefiles anon fd
        tty_fasync
            sys_fcntl (F_SETFL)        //syscall: fcntl

    DRIVER-SPECIFIC:
        VFIO migration:
            vfio_pci_core_ioctl        //syscall: ioctl (VFIO_DEVICE_FEATURE_MIGRATION)
                mlx5vf_pci_save_device_data
                hisi_acc_vf_pci_save_device_data
                qat_vf_save_device_data
                xe_vfio_pci operations
                virtiovf_pci operations
        KVM:
            kvm_vm_ioctl               //syscall: ioctl on /dev/kvm
            vfio_group_fops_open       //syscall: open on VFIO group
        NFSD (NFS server):
            nfsd4_copy                 //NFS server operations
            nfsd_file_get              //NFS server file cache
        IPC:
            do_shmat                   //syscall: shmat
                ksys_shmat
                    sys_shmat          //syscall: shmat
            newseg                     //syscall: shmget (shared memory segment)
        Android Binder:
            binder_deferred_fd_close   //binder IPC operations
        Bluetooth:
            hidp_session_new           //syscall: ioctl (HIDPCONNADD)
            cmtp_session               //syscall: ioctl (CMTPCONNADD)
        9P:
            p9_socket_open             //9P filesystem operations
        IOMMU/VDPA:
            iommufd operations         //syscall: ioctl on iommufd
            vduse_dev operations       //syscall: ioctl on vduse

    FILESYSTEM SPECIFIC:
        Coda:
            coda_file_mmap             //syscall: mmap on Coda filesystem
        Proc:
            proc_map_files_get_link    //syscall: readlink on /proc/*/map_files/*
        Live Update:
            luo_file operations        //live update operations

  Key syscall entry points organized by category:

  Process/Memory Management:
  - fork, vfork, clone, clone3 - Duplicate file table and VMAs
  - execve, execveat - Set exe file reference
  - mmap, mprotect, madvise, mremap, msync - VMA file references
  - unshare - Unshare file descriptor table

  File Descriptor Operations:
  - dup, dup2, dup3 - Duplicate file descriptors
  - fcntl (F_DUPFD, F_DUPFD_CLOEXEC) - Duplicate with flags
  - close_range (CLOSE_RANGE_UNSHARE) - Unshare and close range

  IPC/Networking:
  - sendmsg, recvmsg (SCM_RIGHTS) - Pass file descriptors over Unix sockets
  - shmat, shmget - Shared memory operations
  - pidfd_getfd - Get file from another process via pidfd

  I/O Operations:
  - select, pselect, poll, ppoll - Poll file descriptors
  - epoll_ctl - Add files to epoll
  - read, write, splice - On special filesystems (overlayfs, backing files)
  - io_uring_register - Register files with io_uring

  Device/Driver Operations:
  - ioctl - On various devices (DRM, VFIO, KVM, DMA-BUF, TEE, USB FunctionFS, etc.)
  - mmap - On device files (DRM, DMA-BUF)

  Special:
  - seccomp (SECCOMP_IOCTL_NOTIF_ADDFD) - Add FD via seccomp notify
  - Kernel init - Mount rootfs
  - NFS server operations
  - Bluetooth HIDP/CMTP operations

● The calling tree is now complete! This shows all major paths from syscalls to get_file(), which increments the reference count on an existing struct file *.

  Key insights about get_file() vs alloc_empty_file() and file_free():

  1. Purpose: get_file() is called when you already have a file pointer and need to take an additional reference (e.g., sharing across processes, storing in multiple data structures)
  2. Major use cases:
    - Process forking: When fork() creates a child, all VMAs and file descriptors are duplicated with get_file()
    - FD duplication: dup(), dup2(), fcntl(F_DUPFD) use get_file() to create additional references
    - SCM_RIGHTS: Passing file descriptors over Unix sockets duplicates the file reference
    - Memory mapping: When splitting/merging VMAs, file references are duplicated
    - Poll/Select: Adds temporary references while waiting on file descriptors
    - Device sharing: DMA-BUF and other device buffers shared across processes
  3. Reference counting model:
    - alloc_empty_file() → creates file (refcount=1)
    - get_file() → increments refcount
    - fput() → decrements refcount
    - file_free() → called when refcount reaches 0

  This completes the trio of file lifecycle management calling trees!
```


##### put reference


## SYSCALLS


### do_sys_open()/do_sys_open2()


## interfaces

### fd_install

### fput


## Contexts



