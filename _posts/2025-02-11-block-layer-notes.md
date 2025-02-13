---
title: block layer notes
category: tech
tags: [linux kernel, block, storage]
---

Title: block layer notes

* TOC
{:toc}

# fallocate: introduce FALLOC_FL_WRITE_ZEROES flag

[\[RFC PATCH v2 0/8\] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250115114637.2705887-1-yi.zhang@huaweicloud.com/)

## ideas

- Introduce a new feature BLK_FEAT_WRITE_ZEROES_UNMAP

Add the feature to the block device queue limit features, which indicates whether
the storage is device explicitly supports the unmapped write zeroes command.

- Introduce a new flag FALLOC_FL_FORCE_ZERO into the fallocate,

Introduce a new flag FALLOC_FL_FORCE_ZERO into the fallocate,
filesystems with this operaion should allocate written extents and
issuing zeroes to the range of the device. If the device supports
unmap write zeroes command, the zeroing can be accelerated, if not,
we currently still allow to fall back to submit zeroes data. Users
can verify if the device supports the unmap write zeroes command and
then decide whether to use it.


# Atomic write

## background

### why does DB need it?

[atomic in database](https://en.wikipedia.org/wiki/Atomicity_\(database_systems\))

An example of an atomic transaction is a monetary transfer from bank
account A to account B. It consists of two operations, withdrawing
the money from account A and saving it to account B. Performing these
operations in an atomic transaction ensures that the database remains
in a consistent state, that is, money is neither lost nor created if
either of those two operations fails.[2]

### AWS torn write

[aws torn write prevention](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/storage-twp.html)

- Torn write prevention

Torn write prevention is a block storage feature designed by AWS to improve
the performance of your I/O-intensive relational database workloads and reduce
latency without negatively impacting data resiliency. Relational databases
that use InnoDB or XtraDB as the database engine, such as MySQL and MariaDB,
will benefit from torn write prevention.

Typically, relational databases that use pages larger than the power fail
atomicity of the storage device use data logging mechanisms to protect against
torn writes. MariaDB and MySQL use a doublewrite buffer file to log data
before writing it to data tables. In the event of incomplete or torn writes,
as a result of operating system crashes or power loss during write transactions,
the database can recover the data from the doublewrite buffer. The additional
I/O overhead associated with writing to the doublewrite buffer impacts
database performance and application latency, and it reduces the number
transactions that can be processed per second. For more information about
doublewrite buffer, see the MariaDB and MySQL documentation.

With torn write prevention, data is written to storage in all-or-nothing write
transactions, which eliminates the need for using the doublewrite buffer.
This prevents partial, or torn, data from being written to storage in the
event of operating system crashes or power loss during write transactions.
The number of transactions processed per second can be increased by up to 30
percent, and write latency can be decreased by up to 50 percent, without
compromising the resiliency of your workloads.

- Supported block sizes and block boundary alignments

Torn write prevention supports write operations for 4 KiB, 8 KiB, and 16 KiB
blocks of data. The data block start logical block address (LBA) must be
aligned to the respective block boundary size of 4 KiB, 8 KiB, or 16 KiB.
For example, for 16 KiB write operations, the data block start LBA must be
aligned to a block boundary size of 16 KiB.

The following table shows support across storage and instance types.

 	4 KiB blocks	8 KiB blocks	16 KiB blocks

Instance store volumes	All NVMe instance store volumes attached to current
generation I-family instances.	I4i, Im4gn, and Is4gen instances supported
by AWS Nitro SSD. Amazon EBS volumes

All Amazon EBS volumes attached to nitro-based instances.


### doublewrite buffer

[Innodb doublewrite buffer](https://mariadb.com/kb/en/innodb-doublewrite-buffer/)

InnoDB Doublewrite Buffer

The InnoDB doublewrite buffer was implemented to recover from half-written pages.
This can happen when there's a power failure while InnoDB is writing a page to
disk. On reading that page, InnoDB can discover the corruption from the
mismatch of the page checksum. However, in order to recover, an intact copy of
the page would be needed.

The double write buffer provides such a copy.

Whenever InnoDB flushes a page to disk, it is first written to the double
write buffer. Only when the buffer is safely flushed to disk will InnoDB
write the page to the final destination. When recovering, InnoDB scans the
double write buffer and for each valid page in the buffer checks if the
page in the data file is valid too.

Doublewrite Buffer Settings

To turn off the doublewrite buffer, set the innodb_doublewrite system variable
to 0. This is safe on filesystems that write pages atomically - that is, a
page write fully succeeds or fails. But with other filesystems, it is not
recommended for production systems. An alternative option is atomic writes.
See atomic write support for more details.


[Innodb doublewrite buffer](https://dev.mysql.com/doc/refman/5.7/en/innodb-doublewrite-buffer.html)

- Doublewrite Buffer

The doublewrite buffer is a storage area where InnoDB writes pages flushed
from the buffer pool before writing the pages to their proper positions in
the InnoDB data files. If there is an operating system, storage subsystem,
or unexpected mysqld process exit in the middle of a page write, InnoDB can
find a good copy of the page from the doublewrite buffer during crash recovery.

Although data is written twice, the doublewrite buffer does not require twice
as much I/O overhead or twice as many I/O operations. Data is written to the
doublewrite buffer in a large sequential chunk, with a single fsync() call to
the operating system (except in the case that innodb_flush_method is set to
O_DIRECT_NO_FSYNC).

The doublewrite buffer is enabled by default in most cases. To disable the
doublewrite buffer, set innodb_doublewrite to 0.

If system tablespace files (“ibdata files”) are located on Fusion-io devices
that support atomic writes, doublewrite buffering is automatically disabled
and Fusion-io atomic writes are used for all data files. Because the
doublewrite buffer setting is global, doublewrite buffering is also disabled
for data files residing on non-Fusion-io hardware. This feature is only
supported on Fusion-io hardware and is only enabled for Fusion-io NVMFS on
Linux. To take full advantage of this feature, an innodb_flush_method setting
of O_DIRECT is recommended.

### others

[The golden rule of atomicity](http://web.cs.ucla.edu/classes/spring07/cs111-2/scribe/lecture14.html)

[google atomic write talk](https://www.youtube.com/watch?v=gIeuiGg-_iw)

Database performance tuning can be challenging and time-consuming. In this session, we
will share the performance tuning our team has conducted in the last year to
considerably improve Cloud SQL for MySQL, and highlight changes we've made in
the Linux kernel, EXT4 filesystem, and Google's Persistent Disk storage layer
to improve write performance. You'll come away knowing more about MySQL
performance tuning, an underused EXT4 feature called “bigalloc” and how to let
Cloud SQL handle mundane, yet necessary, tasks so you can focus on developing
your next great app.

## patchset

[[Patch v9 00/10] block atomic writes](https://lore.kernel.org/linux-block/20240620125359.2684798-1-john.g.garry@oracle.com/)


## comments

- about atomic_write_unit_min_sectors/atomic_write_unit_max_sectors

1) split can't cross atomic_unit_sectors

2) lim->atomic_write_max_sectors override lim->max_sectors

- how does block layer know what the exact atomic_write_unit_sectors is taken?

## atomic write applications


# Ideas


