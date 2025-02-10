---
title: Rust Error Handling
category: tech
tags: [Rust, programming, Error]
---

title: Rust Error Handling

* TOC
{:toc}


# Rust Error Handling


# thiserror vs. anyhow

[thiserror and anyhow](https://google.github.io/comprehensive-rust/zh-CN/error-handling/thiserror-and-anyhow.html)

## Overview

The thiserror and anyhow crates are widely used to simplify error
handling.

- **thiserror is often used in libraries to create custom error types that
implement From\<T\>.**

- **anyhow is often used by applications to help with error handling in
functions, including adding contextual information to your errors.**

## Example code

```
use anyhow::{bail, Context, Result};
use std::fs;
use std::io::Read;
use thiserror::Error;

#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("Found no username in {0}")]
struct EmptyUsernameError(String);

fn read_username(path: &str) -> Result<String> {
    let mut username = String::with_capacity(100);
    fs::File::open(path)
        .with_context(|| format!("Failed to open {path}"))?
        .read_to_string(&mut username)
        .context("Failed to read")?;
    if username.is_empty() {
        bail!(EmptyUsernameError(path.to_string()));
    }
    Ok(username)
}

fn main() {
    //fs::write("config.dat", "").unwrap();
    match read_username("config.dat") {
        Ok(username) => println!("Username: {username}"),
        Err(err) => println!("Error: {err:?}"),
    }
}
```

## thiserror

[thiserror in comprehensive-rust](https://google.github.io/comprehensive-rust/error-handling/thiserror.html)

The thiserror crate provides macros to help avoid boilerplate when
defining error types. It provides derive macros that assist in
implementing From<T>, Display, and the Error trait.

- The Error derive macro is provided by thiserror, and has lots of
useful attributes to help define error types in a compact way.

- The message from #[error] is used to derive the Display trait.

- Note that the (thiserror::)Error derive macro, while it has the
effect of implementing the (std::error::)Error trait, is not the same
this; traits and macros do not share a namespace.

## anyhow

[anyhow in comprehensive-rust](https://google.github.io/comprehensive-rust/error-handling/anyhow.html)

- anyhow::Error is essentially a wrapper around Box<dyn Error>. As such
it's again generally not a good choice for the public API of a library,
but is widely used in applications.

- anyhow::Result<V> is a type alias for Result<V, anyhow::Error>.

- Functionality provided by anyhow::Error may be familiar to Go developers,
as it provides similar behavior to the Go error type and Result<T, anyhow::Error>
is much like a Go (T, error) (with the convention that only one element of
the pair is meaningful).

- anyhow::Context is a trait implemented for the standard Result and
Option types. use anyhow::Context is necessary to enable .context() and
.with_context() on those types.

- anyhow::bail!()

Return early with an error.

This macro is equivalent to return Err(anyhow!($args...)).

The surrounding function’s or closure’s return value is required to be
Result\<_, anyhow::Error\>.
