---
title: Fedora packaging guide
category: operation
tags: [Fedora, package]
---

Fedora packaging guide

* TOC
{:toc}

# Fedora packaging guide

## Terms

- RPM

- SPEC

- mock

build SRPMs in a chroot

Mock  is a simple program that will build source RPMs inside a chroot.
It doesn't do anything fancy other than populating a chroot with the
contents specified by a configuration file, then build any input SRPM(s)
in that chroot.

The content of a chroot is specified by the configuration specified  with
the  -r  option.  The  default  configuration  file  is /etc/mock/default.cfg,
which is usually a symlink to one of the installed configurations.


- Koji

The Koji Build System is Fedora’s RPM buildsystem. Packagers use the koji
client to request package builds and get information about the buildsystem.
Koji runs on top of Mock to build RPM packages for specific architectures
and ensure that they build correctly.

- fedpkg

You can use the koji command directly, or use fedpkg, a script that interacts
with the RPM Packaging system and other subsystems, like git and koji itself.

`dnf install fedora-packager fedora-review`

- lookaside cache

For storing upstream tarball, and can't be covered by SCM

- src.fedoraproject.org

: alias: pkgs.fedoraproject.org, Fedora package sources

- copr.fedorainfracloud.org

Fedora project portal

- pagure.io

> Pagure is an Open Source software code hosting system.

- koschei.fedoraproject.org

package build status summery

## Fedora Packaging Framework & Principle

Split Fedora source code into `tarball(upstream)` and patch(Fedora)

The big tarball is stored into lookaside cache by 'fedpkg new-sources' in
oneshot way, and it is immutable.

The patch is delta change against the tarball.


# fedpkg commands

## scratch build

fedpkg build --scratch --srpm ${src_rpm_path}

## add new sources

- `fedpkg new-sources`

Upload new source files to the lookaside cache, meantime update `sources`
& .gitignore, then add them into git workspace

- `fedpkg clog`

Generate git changelog from package changelog, and the log is saved to `clog`
file

- `fedpkg commit -F clog -p`

This behaves by default like git commit -a: It stages modified files and commits
all at once, though it does not add files which git is not yet tracking.

The -F clog parameter will use the clog file from the previous step as the changelog.
-p will push (see below) at the same time as committing. 

- `fedpkg push`

This sends all the new commits in your local working copy to the upstream server.
If you are still learning the system, now is a good time to fedpkg co another copy
of the repository somewhere else, compare what you get to your working copy, and
run a test build on it.

- `fedpkg update`

Submit a package update for the latest build, not necessary for rawhide.


# package build status

[koschei](https://koschei.fedoraproject.org/)


# Fedora packaging utilities

## /usr/lib/rpm/macros.d/

/usr/lib/rpm/macros.d/macros.cargo


# **Examples**

## rust-rublk

### Prepare

- new upstream release, such as v0.2.10

- checkout repo

```
fedpkg co rust-rublk
cd rust-rublk
```

### Build sources and run local tests

- build/get sources

```
rust2rpm -V ${crate_name}       #rust-rublk-0.2.10-vendor.tar.xz is generated

gedit rust-rublk.spec for updating version 0.2.10

spectool -g rust-rublk.sepc     #rust-rublk-0.2.10.crate is generated
```

Note, now you should to use mock to generate source RPM:

```
mock -r fedora-rawhide-x86_64 --buildsrpm --spec ${SPEC_FILE} --sources ./ --resultdir=./
```

And run local build test via mock or koji:

```
mock -r fedora-rawhide-x86_64 --spec ${SPEC_FILE} --resultdir=./  ${source_rpm}

or

koji build --scratch rawhide ${SRC_RPM}
```

### Commit to Fedora

- add new sources

```
fedpkg new-sources rust-rublk-0.2.10-vendor.tar.xz rust-rublk-0.2.10.crate
```

source files are added to Fedora lookaside cache, and which is global.
Meantime `sources` in the repo is automatically updated, since checksum
has to be updated. New source files are added to `.gitignore` too.

- commit meta files

```
gedit rust-rublk.spec

git add rust-rublk.spec

git add .gitignore

fedpkg commit [-F <clog>] [-p]

```

- Do an 'official' build of the latest pushed changes

```
fedpkg build
```

- switch to other releases

```
fedpkg switch-branch (f42 | f43 | rawhide)

commit meta files to each release

Note: sources are global, which can be retrieved for any release, so just
need to added to looaside cache once.

```

# Good References

[Maintaining Packages in Fedora: Cheat Sheet](https://github.com/i386x/pubdocs/blob/main/fedpkg-HOWTO.md)

[fedpgk tools introduction(Chinese)](https://blog.csdn.net/renajia/article/details/45840545)

[My notes about packaging for Fedora](https://lenkaseg.github.io/packaging/)

[Fedora Packaging Tutorial(Official)](https://docs.fedoraproject.org/en-US/package-maintainers/Packaging_Tutorial/)

[Package Maintenance Guide(Official)](https://docs.fedoraproject.org/en-US/package-maintainers/Package_Maintenance_Guide/)

