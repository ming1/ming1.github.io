---
title: Fedora packaging guide
category: operation
tags: [Fedora, package]
---

# Fedora packaging guide

## Terms

- RPM

- SPEC

- fedpkg

- Koji

- mock

- dist-git

- lookaside cache

For storing upstream tarball, and can't be covered by SCM

- src.fedoraproject.org

: alias: pkgs.fedoraproject.org, Fedora package sources

- copr.fedorainfracloud.org

- pagure.io

- koschei.fedoraproject.org

## Fedora Packaging Framework & Principle

- split Fedora source code into tarball(upstream) and patch(Fedora)


## fedpkg commands

### scratch build

fedpkg build --scratch --srpm ${src_rpm_path}

### add new sources

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


## package build status

[koschei](https://koschei.fedoraproject.org/)


## Good References

[Maintaining Packages in Fedora: Cheat Sheet](https://github.com/i386x/pubdocs/blob/main/fedpkg-HOWTO.md)

[fedpgk tools introduction(Chinese)](https://blog.csdn.net/renajia/article/details/45840545)

[My notes about packaging for Fedora](https://lenkaseg.github.io/packaging/)

[Fedora Packaging Tutorial(Official)](https://docs.fedoraproject.org/en-US/package-maintainers/Packaging_Tutorial/)

[Package Maintenance Guide(Official)](https://docs.fedoraproject.org/en-US/package-maintainers/Package_Maintenance_Guide/)

