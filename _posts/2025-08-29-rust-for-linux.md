---
title: Rust For Linux
category: tech
tags: [rust, programming, kernel]
---

title: Rust For Linux

* TOC
{:toc}


# Fundamental building blocks

## Structs

### Opaque<T>

#[repr(transparent)]
pub struct Opaque<T> {
    value: UnsafeCell<MaybeUninit<T>>,
    _pin: PhantomPinned,
}

### Key Components

- `#[repr(transparent)]`

Ensures the struct has the same memory layout as its single field

Critical for FFI compatibility - the wrapper adds no overhead

- UnsafeCell<MaybeUninit<T>>

UnsafeCell: Provides interior mutability, allowing mutation through shared references

MaybeUninit<T>: Allows the value to be uninitialized or have invalid bit patterns

[interior-mut.unsafe-cell](https://doc.rust-lang.org/reference/interior-mutability.html)

```
std::cell::UnsafeCell<T> type is the only allowed way to disable this requirement.
When UnsafeCell<T> is immutably aliased, it is still safe to mutate, or obtain a
mutable reference to, the T it contains.
```

- PhantomPinned

Prevents the struct from being moved in memory

Ensures stable memory addresses for C interop


# Rust references

## Pin

[Module pin](https://doc.rust-lang.org/std/pin/)

### Pin definition

```
Types that pin data to a location in memory.

It is sometimes useful to be able to rely upon a certain value not being able to move,
in the sense that its address in memory cannot change. This is useful especially when
there are one or more pointers pointing at that value. The ability to rely on this
guarantee that the value a pointer is pointing at (its pointee) will:

- Not be moved out of its memory location
- More generally, remain valid at that same memory location
```

### What is “moving”?

```
When we say a value is moved, we mean that the compiler copies, byte-for-byte, the value
from one location to another. In a purely mechanical sense, this is identical to Copying
a value from one place in memory to another. In Rust, “move” carries with it the semantics
of ownership transfer from one variable to another, which is the key difference between
a Copy and a move.
```

```
Common smart-pointer types such as Box<T> and &mut T also allow moving the underlying
value they point at: you can move out of a Box<T>, or you can use mem::replace to move
a T out of a &mut T. Therefore, putting a value (such as tracker above) behind a pointer
isn’t enough on its own to ensure that its address does not change.
```

### What is “pinning”?

```
We say that a value has been pinned when it has been put into a state where it is
guaranteed to remain located at the same place in memory from the time it is pinned until
its drop is called.
```

