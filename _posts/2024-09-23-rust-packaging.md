---
title: Fedora Rust packaging tips
category: operation
tags: [Fedora, package, Rust]
---

Fedora Rust packaging tips

* TOC
{:toc}


# **Packaging from Rust Source Project**

## Generate spec

```
rust2rpm ${path_to_source_dir}
```

## Make source tarball

```
Rename Rust source project top directory into ${package_name}-${version}
```

```
tar czvf ~/${package_name}-${version}.tar.gz  ${package_name}-${version}
```

Example,

```
tar czvf qcow2-rs-0.1.4.tar.gz qcow2-rs-0.1.4/

package_name: qcow2-rs, version: 0.1.4
```

## Setup Source of spec

- change

```
SOURCE:            # FIXME
```

into

```
Source:         ${package_name}-${version}.tar.gz
```


## Build source package

```
mock -r fedora-rawhide-x86_64 --buildsrpm --spec ${SPEC_FILE} --sources ./ --resultdir=./
```

And make sure that ${package_name}-${version}.tar.gz stays in current directory.

Then src.rpm will be built in current directory.

## Build RPM

```
mock -r fedora-rawhide-x86_64 --spec ${SPEC_FILE} --resultdir=./  ${source_rpm}
```

Or run koji build directly:

```
koji build --scratch f42 ${SRC_RPM}
```



# **Packaging from crate.io**

Very similar with Packaging from local source directy, except for:

- generate spec file

```
rust2rpm ${crate_name}
```

- download crate

```
spectool -g ${spec_file}
```

# **Packaging from crate.io/vendor**

vendor mode is useful when the dependency packages don't exit in Fedora, which should
always be the last resort. And all dependencies source code are put into one tarball,
and build from all these source code directly. 

- generate spec file & ${package_name}-${version}-vendor.tar.xz

```
rust2rpm -V ${crate_name}
```

- Source in spec

```
Source:         %{crates_source}
Source:         ${package_name}-${version}-vendor.tar.xz
```

# **Troubleshoot**

## cargo test with debug message

```
%cargo_test -- -- --nocapture
```

## build crate from local source repo

```
cargo package
```

## check crate

```
tar -tf ${crate_path}
```

Then use the built crate tarball to create source rpm and run test.

