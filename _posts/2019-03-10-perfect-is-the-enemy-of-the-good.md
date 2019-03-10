---
title: Perfect is the enemy of the good!
date: 2019-03-10 00:18:03
category: "design"
tags: [design]
---

Sun’s Network File System (NFS)

1 Focus: Simple and Fast Server Crash Recovery

In NFSv2, the main goal in the design of the protocol was simple and
fast server crash recovery.

2 Key To Fast Crash Recovery: Statelessness

One example of a stateful (not stateless) protocol:

	open(), read(), close()

3 The NFSv2 Protocol

3.1 File handle

One key to understanding the design of the NFS protocol is understanding
the file handle. File handles are used to uniquely describe the file or
directory a particular operation is going to operate upon; thus, many of
the protocol requests include a file handle.

Three important components:
		a volume identifier, an inode number, and a generation number;

together, these three items comprise a unique identifier for a file or
directory that a client wishes to access.


3.2 The NFS Protocol: Examples

NFSPROC_GETATTR
	expects: file handle
	returns: attributes

NFSPROC_SETATTR
	expects: file handle, attributes
	returns: nothing

NFSPROC_LOOKUP
	expects: directory file handle, name of file/directory to look up
	returns: file handle

NFSPROC_READ
	expects: file handle, offset, count
	returns: data, attributes

NFSPROC_WRITE
	expects: file handle, offset, count, data
	returns: attributes

NFSPROC_CREATE
	expects: directory file handle, name of file, attributes
	returns: nothing

NFSPROC_REMOVE
	expects: directory file handle, name of file to be removed
	returns: nothing

NFSPROC_MKDIR
	expects: directory file handle, name of directory, attributes
	returns: file handle

NFSPROC_RMDIR
	expects: directory file handle, name of directory to be removed
	returns: nothing

NFSPROC_READDIR
	expects: directory handle, count of bytes to read, cookie
	returns: directory entries, cookie (to get more entries)

First, the LOOKUP protocol message is used to obtain a file handle, which
is then subsequently used to access file data.

Once a file handle is available, the client can issue READ and WRITE
protocol messages on a file to read or write the file, respectively.



4 From Protocol to Distributed File System

5 Handling Server Failure with Idempotent Operations

In NFSv2, a client handles all of these failures in a single, uniform, and
elegant way: it simply retries the request.

The ability of the client to simply retry the request (regardless of what
caused the failure) is due to an important property of most NFS requests:
they are idempotent. An operation is called idempotent when the effect
of performing the operation multiple times is equivalent to the effect of
performing the operating a single time.

The heart of the design of crash recovery in NFS is the idempotency
of most common operations. LOOKUP, READ and WRITE are. MKDIR isn't.

PERFECT IS THE ENEMY OF THE GOOD (VOLTAIRE’S LAW)


