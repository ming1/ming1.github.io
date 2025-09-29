---
title: Filesystem notes
category: tech
tags: [linux kernel, filesystem, IO]
---

* TOC
{:toc}


Filesystem notes


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


## JOURNALING FILE SYSTEMS



