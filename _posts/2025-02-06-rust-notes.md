---
title: Rust learning notes
category: tech
tags: [Rust, programming]
---

title: Rust learning notes 

* TOC
{:toc}



# core ideas

Think about how Rust compiler handles borrow checker

## threads vs. closure vs. trait object

1) trait object can't be copied/moved between threads

2) Arc() is still for sharing object in read-only style

[Rust under the hood](https://www.eventhelix.com/rust/)


## rustc trick

- type size

RUSTFLAGS="-Z print-type-sizes" 

[layout](https://www.ralfj.de/blog/2020/04/04/layout-debugging.html)

[rust performance](https://nnethercote.github.io/perf-book/)


## ownership

### core idea

It follows that the owners and their owned values form trees: your owner
is your parent, and the values you own are your children. And at the ultimate
root of each tree is a variable; when that variable goes out of scope, the
entire tree goes with it.

<any variable can only have one single owner, but one can owns many variables>

#### how to make it useful

It is still much too rigid to be useful. Rust extends this simple idea in
several ways:

- You can move values from one owner to another. This allows you to build,
rearrange, and tear down the tree.

- Very simple types like integers, ﬂoating-point numbers, and characters are
excused from the ownership rules. These are called Copy types.

- The standard library provides the reference-counted pointer types Rc and
Arc, which allow values to have multiple owners, under some restrictions.

- You can “borrow a reference” to a value; references are non-owning pointers,
with limited lifetimes.

### move

The Rust compiler guarantees that a static item always has the same address
for the entire duration of the program, and never moves. This means that a
reference to a static item has a 'static lifetime, logically enough.

Note that a const global variable does not have the same guarantee: only the
value is guaranteed to be the same everywhere, and the compiler is allowed
to make as many copies as it likes, wherever the variable is used. These
potential copies may be ephemeral, and so won't satisfy the 'static requirements:


#### `move is more like moving one sub-tree as child of another node`

Moving a value leaves the source of the move uninitialized, so referring to
uninitialized variable will be found during compiling


#### several places at which moves occur, beyond initialization and assignment:

- Returning values from a function

- Constructing new values

- Passing values to a function

```
for mut s in v		//v[i] is moved to s
```

#### is move inefficient?

Moving values around like this may sound inefficient, but
there are two things to keep in mind.

- First, the moves always apply to the value proper, not the heap
storage they own. For vectors and strings, the value proper is the
three-word header alone; the potentially large element arrays
and text buffers sit where they are in the heap.

- Second, the Rust compiler’s code generation is good at “seeing through”
all these moves; in practice, the machine code often stores the value
directly where it belongs.

#### Copy Types: The Exception to Moves

- Assigning a value of a Copy type copies the value, rather than moving it.
The source of the assignment remains initialized and usable, with the same
value it had before. Passing Copy types to functions and constructors
behaves similarly.

- The standard Copy types include all the machine integer and ﬂoating-point
numeric types, the char and bool types, and a few others. A tuple or
fixed-size array of Copy types is itself a Copy type.

- any type that needs to do something special when a value is dropped cannot
be Copy: a Vec needs to free its elements, a File needs to close its
file handle, a MutexGuard needs to unlock its mutex, and so on.

### references

#### reference can't outlive value

#### References are non-owning pointers

#### multiple shared(ro) reference vs single mutable reference

You can think of the distinction between shared and mutable references as
a way to enforce a multiple readers or single writer rule at compile time.
In fact, this rule doesn’t apply only to references; it covers the
borrowed value’s owner as well. As long as there are shared references to
a value, not even its owner can modify it; the value is locked down. Nobody
can modify table while show is working with it. Similarly, if there is a
mutable reference to a value, it has exclusive access to the value; you can’t
use the owner at all, until the mutable reference goes away.

Keeping sharing and mutation fully separate turns out to be
essential to memory safety, for reasons we’ll go into later in
the chapter.

#### by value vs. by reference

When we pass a value to a function in a way that moves ownership of the value
to the function, we say that we have passed it by value. If we instead pass the
function a reference to the value, we say that we have passed the value by
reference.

#### . operator implicitly dereferences its left operand(*)

Since references are so widely used in Rust, the . operator implicitly dereferences
its left operand, if needed:

```
	struct Anime { name: &'static str, bechdel_pass: bool };
	let aria = Anime { name: "Aria: The Animation", bechdel_pass: true };
	let anime_ref = &aria;
	assert_eq!(anime_ref.name, "Aria: The Animation");
	// Equivalent to the above, but with the dereference written out:
	assert_eq!((*anime_ref).name, "Aria: The Animation");
```

```
	let mut v = vec![1973, 1968];
	v.sort();			// implicitly borrows a mutable reference to v
	(&mut v).sort();	// equivalent, but more verbose
```

#### Comparing References

- reference always de-reference its value

	assert!(rx == ry); // their referents are equal
	assert!(!std::ptr::eq(rx, ry)); // but occupy different addresses

#### References Are Never Null

In Rust, if you need a value that is either a reference to something or not,
use the type Option<&T>. At the machine level, Rust represents None as a null
pointer and Some(r), where r is a &T value, as the nonzero address, so
Option<&T> is just as eﬀicient as a nullable pointer in C or C++, even though
it’s safer: its type requires you to check whether it’s None before you can
use it.

#### References to Slices and Trait Objects(fat pointer)

- A reference to a slice is a fat pointer, carrying the starting address of
the slice and its length.

- Rust’s other kind of fat pointer is a trait object, a reference to a value
that implements a certain trait. A trait object carries a value’s address and
a pointer to the trait’s implementation appropriate to that value, for
invoking the trait’s methods.

#### can we append the vector to itself?

	extend(&mut wave, &wave);
	assert_eq!(wave, vec![0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0]);

Suppose wave starts with space for four elements and so must allocate a
larger buﬀer via realloc() when extend tries to add a ﬁfth.

- Shared access is read-only access.
- Mutable access is exclusive access.


## Result

```
enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

### as_ref() & as_mut()

One reason these last two methods are useful is that all of the other methods
listed here, except .is_ok() and .is_err(), consume the result they operate
on. That is, they take the self argument by value. Sometimes it’s quite
handy to access data inside a result without destroying it, and this is what
.as_ref() and .as_mut() do for us.

### Result Type Aliases

- `fn remove_file(path: &Path) -> Result<()>`

- `pub type Result<T> = result::Result<T, Error>;`

### err.source()

```
use std::error::Error;
use std::io::{Write, stderr};
fn print_error(mut err: &dyn Error) {
	let _ = writeln!(stderr(), "error: {}", err);
	
	while let Some(source) = err.source() {
		let _ = writeln!(stderr(), "caused by: {}", source);
		err = source;
	}
}
```

### thiserror

```
use thiserror::Error;
#[derive(Error, Debug)]
#[error("{message:} ({line:}, {column})")]
pub struct JsonError {
	message: String,
	line: usize,
	column: usize,
}
```

### Bubble up multiple errors

- fix this by Boxing the errors, or Anyhow

```
- fn get_current_date() -> Result<String, reqwest::Error> {
+ fn get_current_date() -> Result<String, Box<dyn std::error::Error>> {
    let url = "https://postman-echo.com/time/object";
    let res = reqwest::blocking::get(url)?.json::<HashMap<String, i32>>()?;

    let formatted_date = format!("{}-{}-{}", res["years"], res["months"] + 1, res["date"]);
    let parsed_date = NaiveDate::parse_from_str(formatted_date.as_str(), "%Y-%m-%d")?;
    let date = parsed_date.format("%Y %B %d").to_string();

    Ok(date)
}
```

[Rust error handling](https://www.sheshbabu.com/posts/rust-error-handling/)


## Macro

### introduction

- token

Rust macros are very different from macros in C. Rust macros are applied to the
token tree whereas C macros are text substitution.

```
    item — an item, like a function, struct, module, etc.
    block — a block (i.e. a block of statements and/or an expression, surrounded by braces)
    stmt — a statement
    pat — a pattern
    expr — an expression
    ty — a type
    ident — an identifier
    path — a path (e.g., foo, ::std::mem::replace, transmute::<_, int>, …)
    meta — a meta item; the things that go inside #[...] and #![...] attributes
    tt — a single token tree
    vis — a possibly empty Visibility qualifier
```

- repeat

Here, the macro repeat_print takes a single argument, ($($x:expr),*), which is
a repeating pattern.

The pattern consists of zero or more expressions, separated by commas, that are
matched by the macro. The star (*) symbol at the end will repeatedly match
against the pattern inside $().

The code inside the curly braces println!("{}", $x);, is repeated zero or more
times, once for each expression in the list of arguments as it is wrapped
around $(...)* in the body of the macro definition. The $x in the code refers
to the matched expressions


### And Rust macros come with pattern matching,

A macro deﬁned with macro_rules! works entirely by pattern matching. The body of a
macro is just a series of rules:

```
( pattern1 ) => ( template1 );
( pattern2 ) => ( template2 );
...
```

### macro_rules! is the main way to deﬁne macros in Rust.

Note that there is no ! after assert_eq in this macro deﬁnition: the ! is only
included when calling a macro, not when deﬁning it.

### default macros

- try!

try! is used for error handling. It takes something that can return a
Result<T, E>, and gives T if it’s a Ok<T>, and returns with the Err(E) if
it’s that. Like this:

```
	use std::fs::File;
	fn foo() -> std::io::Result<()> {
	    let f = try!(File::create("foo.txt"));
	
	    Ok(())
	}
```

- unreachable!

This macro is used when you think some code should never execute:

```
	if false {
    	unreachable!();
	}
```

Sometimes, the compiler may make you have a different branch that you know will
never, ever run. In these cases, use this macro, so that if you end up wrong, you’ll
get a panic! about it.

```
	let x: Option<i32> = None;
	match x {
	    Some(_) => unreachable!(),
	    None => println!("I know x is None!"),
	}
```

- unimplemented!

The unimplemented! macro can be used when you’re trying to get your functions to
typecheck, and don’t want to worry about writing out the body of the function. One
example of this situation is implementing a trait with multiple required methods,
where you want to tackle one at a time. Define the others as unimplemented! until
you’re ready to write them.

```
trait Foo {
    fn bar(&self) -> u8;
    fn baz(&self);
    fn qux(&self) -> Result<u64, ()>;
}

struct MyStruct;

impl Foo for MyStruct {
    fn bar(&self) -> u8 {
        1 + 1
    }

    fn baz(&self) {
        // "thread 'main' panicked at 'not implemented'"。
        unimplemented!();
    }

    fn qux(&self) -> Result<u64, ()> {
        // "thread 'main' panicked at 'not implemented: MyStruct isn't quxable'"。
        unimplemented!("MyStruct isn't quxable");
    }
}

fn main() {
    let s = MyStruct;
    s.bar();
}
```


## visibility levels

Here's a breakdown of the visibility levels:

    pub: The item is public and accessible from anywhere.

    pub(crate): The item is public within the entire crate. It can be accessed from
	any module within the same crate.

    pub(super): The item is public to the parent module, but not beyond that.
	It can be accessed from within the same module and any nested modules, but
	not from sibling modules or external modules.

    pub(in path::to::module): The item is public only to the specified module path
	and its submodules. This provides a more fine-grained control over visibility.


# something interesting

## misc

```
//a will point to buffer allocated from heap.
let a = format!("{}", "hello world");

//push move 'a' to vector
vec.push(a)

//move v[i] to s
for mut s in v {
}
```

```
//A value owned by an Rc pointer is immutable.
let s: Rc<String> = Rc::new("shirataki".to_string());
s.push_str(" noodles");
```

```
//c typedef
type Table = HashMap<String, Vec<String>>;

//references
fn show(table: &Table) {}
fn show(table: &mut Table) {}
fn show(table: Table) {}
```

```
//?
for entry_result in src.read_dir()? { // opening dir could fail
	let entry = entry_result?;	// reading dir could fail
	let dst_file = dst.join(entry.file_name());

	fs::rename(entry.path(), dst_file)?; // renaming could fail
}
```

```
//current_line current_column
return Err(JsonError {
	message: "expected ']' at end of array".to_string(),
	line: current_line,column: current_column
});
```

```
//dyn for trait

//path as_ref
      let src: &Path = source.as_ref();
      let dst: &Path = destination.as_ref();

//rust workqueue: Rayon

// return raw pointer:
let b = a.as_bytes().as_ptr();

unsafe {
	println!("!!!!!!!!!!!!!!!val dereferred from raw ptr {}", *b);
}
```

# Data Representation in Rust

Rust gives you the following ways to lay out composite data:

    structs (named product types)

    tuples (anonymous product types)

    arrays (homogeneous product types)

    enums (named sum types -- tagged unions)

    unions (untagged unions)

An enum is said to be field-less if none of its variants have associated data.

## Dynamically Sized Types (DSTs)

There are two major DSTs exposed by the language:

```
    trait objects: dyn MyTrait
    slices: [T], str, and others
```

## Zero Sized Types (ZSTs)

Rust also allows types to be specified that occupy no space:

```
struct Nothing; // No fields = no size

// All fields have no size = no size
struct LotsOfNothing {
    foo: Nothing,
    qux: (),      // empty tuple has no size
    baz: [u8; 0], // empty array has no size
}
```

## Empty Types

Rust also enables types to be declared that cannot even be instantiated. These
types can only be talked about at the type level, and never at the value level.
Empty types can be declared by specifying an enum with no variants:

`enum Void {} // No variants = EMPTY`


# Generic Types, Traits, and Lifetimes

Every programming language has tools for effectively handling the
duplication of concepts. In Rust, one such tool is generics. Generics
are abstract stand-ins for concrete types or other properties. When we’re
writing code, we can express the behavior of generics or how they relate
to other generics without knowing what will be in their place when
compiling and running the code.

Similar to the way a function takes parameters with unknown values to
run the same code on multiple concrete values, functions can take parameters
of some generic type instead of a concrete type, like i32 or String. In
fact, we’ve already used generics in Chapter 6 with Option<T>, Chapter 8
with Vec<T> and HashMap<K, V>, and Chapter 9 with Result<T, E>. In this
chapter, you’ll explore how to define your own types, functions, and methods
with generics!

Generics and traits are closely related: generic functions use traits in
bounds to spell out what types of arguments they can be applied to. So we’ll
also talk about how "&mut dyn Write" and <T: Write> are similar, how they’re
different, and how to choose between these two ways of using traits.

A variable’s size has to be known at compile time, and types that implement
Write(Traits) can be any size.

Trait object:

	let writer: &mut dyn Write = &mut buf; // ok

A reference to a trait type, like writer, is called a trait object. Like any
other reference, a trait object points to some value, it has a lifetime, and
it can be either mut or shared.

## Generic Data Types

We can use generics to create definitions for items like function signatures or
structs, which we can then use with many different concrete data types. Let’s
first look at how to define functions, structs, enums, and methods using generics.
Then we’ll discuss how generics affect code performance.

```
struct Point<T> {
    x: T,
    y: T,
}

impl<T> Point<T> {
    fn x(&self) -> &T {
        &self.x
    }
}
```

Note that we have to declare T just after impl so we can use T to specify that
we’re implementing methods on the type Point<T>. By declaring T as a generic type
after impl, Rust can identify that the type in the angle brackets in Point is a
generic type rather than a concrete type. 

## Traits: Defining Shared Behavior

A trait defines functionality a particular type has and can share with other
types. We can use traits to define shared behavior in an abstract way.

We can use trait bounds to specify that a generic type can be any type that has
certain behavior.

### Defining a Trait

### Implementing a Trait on a Type

### Default Implementations

```
pub trait Summary {
    fn summarize(&self) -> String {
        String::from("(Read more...)")
    }
}
```

### Trait Bound Syntax

```
pub fn notify<T: Summary>(item: &T) {
    println!("Breaking news! {}", item.summarize());
}

pub fn notify(item1: &impl Summary, item2: &impl Summary) {
	...
}
```

### Specifying Multiple Trait Bounds with the + Syntax

We can also specify more than one trait bound. Say we wanted notify to use
display formatting as well as summarize on item: we specify in the notify
definition that item must implement both Display and Summary. We can do
so using the + syntax:

```
pub fn notify(item: &(impl Summary + Display)) {
...

pub fn notify<T: Summary + Display>(item: &T) {
...
```

### Clearer Trait Bounds with where Clauses

```
fn some_function<T, U>(t: &T, u: &U) -> i32
where
    T: Display + Clone,
    U: Clone + Debug,
{
...
```

### Returning Types that Implement Traits

```
fn returns_summarizable() -> impl Summary {
    Tweet {
        username: String::from("horse_ebooks"),
        content: String::from(
            "of course, as you probably already know, people",
        ),
        reply: false,
        retweet: false,
    }
}
```

### Using Trait Bounds to Conditionally Implement Methods

By using a trait bound with an impl block that uses generic type parameters,
we can implement methods conditionally for types that implement the specified
traits. For example, the type Pair<T> in Listing 10-15 always implements the
new function to return a new instance of Pair<T> (recall from the “Defining
Methods” section of Chapter 5 that Self is a type alias for the type of the
impl block, which in this case is Pair<T>). But in the next impl block, Pair<T>
only implements the cmp_display method if its inner type T implements the
PartialOrd trait that enables comparison and the Display trait that enables printing.


```
use std::fmt::Display;

struct Pair<T> {
    x: T,
    y: T,
}

impl<T> Pair<T> {
    fn new(x: T, y: T) -> Self {
        Self { x, y }
    }
}

impl<T: Display + PartialOrd> Pair<T> {
    fn cmp_display(&self) {
        if self.x >= self.y {
            println!("The largest member is x = {}", self.x);
        } else {
            println!("The largest member is y = {}", self.y);
        }
    }
}
```


## Validating References with Lifetimes

Most of the time, lifetimes are implicit and inferred, just like most of the time,
types are inferred. We only must annotate types when multiple types are possible.
In a similar way, we must annotate lifetimes when the lifetimes of references could
be related in a few different ways. Rust requires us to annotate the relationships
using generic lifetime parameters to ensure the actual references used at runtime
will definitely be valid.

### Preventing Dangling References with Lifetimes

The main aim of lifetimes is to prevent dangling references, which cause a program
to reference data other than the data it’s intended to reference

```
fn main() {
    let r;

    {
        let x = 5;
        r = &x;
    }

    println!("r: {}", r);
}
```

### Generic Lifetimes in Functions

```
fn longest(x: &str, y: &str) -> &str {
    if x.len() > y.len() {
        x
    } else {
        y
    }
}
```

```
$ cargo run
error[E0106]: missing lifetime specifier
 --> src/main.rs:9:33
  |
9 | fn longest(x: &str, y: &str) -> &str {
  |               ----     ----     ^ expected named lifetime parameter
  |
  = help: this function's return type contains a borrowed value, but the signature does not say whether it is borrowed from `x` or `y`
help: consider introducing a named lifetime parameter
  |
9 | fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
  |           ++++     ++          ++          ++

For more information about this error, try `rustc --explain E0106`.
error: could not compile `chapter10` due to previous error
```

### Lifetime Annotation Syntax

We place lifetime parameter annotations after the & of a reference, using a space to
separate the annotation from the reference’s type.

&i32        // a reference
&'a i32     // a reference with an explicit lifetime
&'a mut i32 // a mutable reference with an explicit lifetime

### Lifetime Annotations in Function Signatures

```
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
    if x.len() > y.len() {
        x
    } else {
        y
    }
}
```

Remember, when we specify the lifetime parameters in this function signature, we’re
not changing the lifetimes of any values passed in or returned. Rather, we’re
specifying that the borrow checker should reject any values that don’t adhere to
these constraints. Note that the longest function doesn’t need to know exactly
how long x and y will live, only that some scope can be substituted for 'a that
will satisfy this signature.

When annotating lifetimes in functions, the annotations go in the function signature,
not in the function body. The lifetime annotations become part of the contract of
the function, much like the types in the signature. 

Having function signatures contain the lifetime contract means the analysis the Rust
compiler does can be simpler.

### Thinking in Terms of Lifetimes

```
fn longest<'a>(x: &str, y: &str) -> &'a str {
    let result = String::from("really long string");
    result.as_str()
}

$ cargo run
   Compiling chapter10 v0.1.0 (file:///projects/chapter10)
error[E0515]: cannot return reference to local variable `result`
  --> src/main.rs:11:5
   |
11 |     result.as_str()
   |     ^^^^^^^^^^^^^^^ returns a reference to data owned by the current function

For more information about this error, try `rustc --explain E0515`.
error: could not compile `chapter10` due to previous error
```

The problem is that result goes out of scope and gets cleaned up at the end of
the longest function. We’re also trying to return a reference to result from
the function. There is no way we can specify lifetime parameters that would
change the dangling reference, and Rust won’t let us create a dangling reference.
In this case, the best fix would be to return an owned data type rather than
a reference so the calling function is then responsible for cleaning up the value.

Ultimately, lifetime syntax is about connecting the lifetimes of various parameters
and return values of functions. Once they’re connected, Rust has enough information
to allow memory-safe operations and disallow operations that would create dangling
pointers or otherwise violate memory safety.

### Lifetime Annotations in Struct Definitions

So far, the structs we’ve defined all hold owned types. We can define structs to
hold references, but in that case we would need to add a lifetime annotation on
every reference in the struct’s definition. 

```
struct ImportantExcerpt<'a> {
    part: &'a str,
}

fn main() {
    let novel = String::from("Call me Ishmael. Some years ago...");
    let first_sentence = novel.split('.').next().expect("Could not find a '.'");
    let i = ImportantExcerpt {
        part: first_sentence,
    };
}
```

### Lifetime Elision

```
fn first_word(s: &str) -> &str {
    let bytes = s.as_bytes();

    for (i, &item) in bytes.iter().enumerate() {
        if item == b' ' {
            return &s[0..i];
        }
    }

    &s[..]
}
```

Lifetimes on function or method parameters are called input lifetimes, and
lifetimes on return values are called output lifetimes.

The compiler uses three rules to figure out the lifetimes of the references
when there aren’t explicit annotations. The first rule applies to input lifetimes,
and the second and third rules apply to output lifetimes. If the compiler gets
to the end of the three rules and there are still references for which it can’t
figure out lifetimes, the compiler will stop with an error. These rules apply
to fn definitions as well as impl blocks.

- The first rule is that the compiler assigns a lifetime parameter to each parameter
that’s a reference. In other words, a function with one parameter gets one lifetime
parameter: fn foo<'a>(x: &'a i32); a function with two parameters gets two separate
lifetime parameters: fn foo<'a, 'b>(x: &'a i32, y: &'b i32); and so on.

- The second rule is that, if there is exactly one input lifetime parameter, that
lifetime is assigned to all output lifetime parameters: fn foo<'a>(x: &'a i32) -> &'a i32.

- The third rule is that, if there are multiple input lifetime parameters, but one
of them is &self or &mut self because this is a method, the lifetime of self is assigned
to all output lifetime parameters. This third rule makes methods much nicer to read and
write because fewer symbols are necessary.

### Lifetime Annotations in Method Definitions

```
impl<'a> ImportantExcerpt<'a> {
    fn level(&self) -> i32 {
        3
    }
}
```

The lifetime parameter declaration after impl and its use after the type name are
required, but we’re not required to annotate the lifetime of the reference to self
because of the first elision rule.

### The Static Lifetime

One special lifetime we need to discuss is 'static, which denotes that the affected
reference can live for the entire duration of the program. All string literals have
the 'static lifetime, which we can annotate as follows:

```
let s: &'static str = "I have a static lifetime.";
```


### Generic Type Parameters, Trait Bounds, and Lifetimes Together

```
use std::fmt::Display;

fn longest_with_an_announcement<'a, T>(
    x: &'a str,
    y: &'a str,
    ann: T,
) -> &'a str
where
    T: Display,
{
    println!("Announcement! {}", ann);
    if x.len() > y.len() {
        x
    } else {
        y
    }
}
```

But now it has an extra parameter named ann of the generic type T, which can
be filled in by any type that implements the Display trait as specified by
the where clause. This extra parameter will be printed using {}, which is why
the Display trait bound is necessary. Because lifetimes are a type of generic,
the declarations of the lifetime parameter 'a and the generic type parameter
T go in the same list inside the angle brackets after the function name

## Lifetime elision

### Lifetime elision in functions

In order to make common patterns more ergonomic, lifetime arguments can be elided
in function item, function pointer, and closure trait signatures. The
following rules are used to infer lifetime parameters for elided lifetimes. It
is an error to elide lifetime parameters that cannot be inferred. The
placeholder lifetime, '_, can also be used to have a lifetime inferred in the
same way. For lifetimes in paths, using '_ is preferred. Trait object
lifetimes follow different rules discussed below.

- Each elided lifetime in the parameters becomes a distinct lifetime parameter.

- If there is exactly one lifetime used in the parameters (elided or not), that
lifetime is assigned to all elided output lifetimes.

In method signatures there is another rule

- If the receiver has type &Self or &mut Self, then the lifetime of that reference
to Self is assigned to all elided output lifetime parameters.


### Default trait object lifetimes

The assumed lifetime of references held by a trait object is called its default
object lifetime bound. These were defined in RFC 599 and amended in RFC 1156.

These default object lifetime bounds are used instead of the lifetime
parameter elision rules defined above when the lifetime bound is omitted entirely.
If '_ is used as the lifetime bound then the bound follows the usual elision rules.

If the trait object is used as a type argument of a generic type then the
containing type is first used to try to infer a bound.

- If there is a unique bound from the containing type then that is the default

- If there is more than one bound from the containing type then an explicit bound
must be specified

If neither of those rules apply, then the bounds on the trait are used:

- If the trait is defined with a single lifetime bound then that bound is used.

- If 'static is used for any lifetime bound then 'static is used.

- If the trait has no lifetime bounds, then the lifetime is inferred in expressions
and is 'static outside of expressions.

```
	// For the following trait...
	trait Foo { }

	// These two are the same because Box<T> has no lifetime bound on T
	type T1 = Box<dyn Foo>;
	type T2 = Box<dyn Foo + 'static>;

	// ...and so are these:
	impl dyn Foo {}
	impl dyn Foo + 'static {}

	// ...so are these, because &'a T requires T: 'a
	type T3<'a> = &'a dyn Foo;
	type T4<'a> = &'a (dyn Foo + 'a);

	// std::cell::Ref<'a, T> also requires T: 'a, so these are the same
	type T5<'a> = std::cell::Ref<'a, dyn Foo>;
	type T6<'a> = std::cell::Ref<'a, dyn Foo + 'a>;

	// This is an example of an error.
	struct TwoBounds<'a, 'b, T: ?Sized + 'a + 'b> {
	    f1: &'a i32,
	    f2: &'b i32,
	    f3: T,
	}
	type T7<'a, 'b> = TwoBounds<'a, 'b, dyn Foo>;
	//                                  ^^^^^^^
	// Error: the lifetime bound for this object type cannot be deduced from context
```

### 'static lifetime elision

Both constant and static declarations of reference types have implicit 'static
lifetimes unless an explicit lifetime is specified. As such, the constant
declarations involving 'static above may be written without the lifetimes.

```
// STRING: &'static str
const STRING: &str = "bitstring";

struct BitsNStrings<'a> {
    mybits: [u32; 2],
    mystring: &'a str,
}

// BITS_N_STRINGS: BitsNStrings<'static>
const BITS_N_STRINGS: BitsNStrings<'_> = BitsNStrings {
    mybits: [1, 2],
    mystring: STRING,
};
```

Note that if the static or const items include function or closure references,
which themselves include references, the compiler will first try the standard
elision rules. If it is unable to resolve the lifetimes by its usual rules,
then it will error. By way of example:

```
// Resolved as `fn<'a>(&'a str) -> &'a str`.
const RESOLVED_SINGLE: fn(&str) -> &str = |x| x;

// Resolved as `Fn<'a, 'b, 'c>(&'a Foo, &'b Bar, &'c Baz) -> usize`.
const RESOLVED_MULTIPLE: &dyn Fn(&Foo, &Bar, &Baz) -> usize = &somefunc;
```


# Smart Pointers

## overview

1) A pointer is a general concept for a variable that contains an address in
memory. This address refers to, or “points at,” some other data. The most common
kind of pointer in Rust is a reference, which you learned about in Chapter 4.
References are indicated by the & symbol and borrow the value they point to.
They don’t have any special capabilities other than referring to data, and have
no overhead.

2) Smart pointers, on the other hand, are data structures that act like a
pointer but also have additional metadata and capabilities. The concept of smart
pointers isn’t unique to Rust: smart pointers originated in C++ and exist in
other languages as well. Rust has a variety of smart pointers defined in the
standard library that provide functionality beyond that provided by references.
To explore the general concept, we’ll look at a couple of different examples of
smart pointers, including a reference counting smart pointer type. This pointer
enables you to allow data to have multiple owners by keeping track of the
number of owners and, when no owners remain, cleaning up the data.

Rust, with its concept of ownership and borrowing, has an additional difference
between references and smart pointers: while references only borrow data, in
many cases, smart pointers own the data they point to.

We’ll cover the most common smart pointers in the standard library:

- Box<T> for allocating values on the heap

- Rc<T>, a reference counting type that enables multiple ownership

- Ref<T> and RefMut<T>, accessed through RefCell<T>, a type that enforces the
borrowing rules at runtime instead of compile time

In addition, we’ll cover the interior mutability pattern where an immutable type
exposes an API for mutating an interior value. We’ll also discuss reference cycles:
how they can leak memory and how to prevent them.

## Using Box<T> to Point to Data on the Heap

Boxes don’t have performance overhead, other than storing their data on the
heap instead of on the stack. But they don’t have many extra capabilities either.
You’ll use them most often in these situations:

- When you have a type whose size can’t be known at compile time and you want to
use a value of that type in a context that requires an exact size

- When you have a large amount of data and you want to transfer ownership but
ensure the data won’t be copied when you do so

- When you want to own a value and you care only that it’s a type that
implements a particular trait rather than being of a specific type

## Treating Smart Pointers Like Regular References with the Deref Trait

### Following the Pointer to the Value

### Using Box<T> Like a Reference

We can rewrite the code in Listing 15-6 to use a Box<T> instead of a reference;
the dereference operator used on the Box<T> in Listing 15-7 functions in the
same way as the dereference operator used on the reference in Listing 15-6:

```
Filename: src/main.rs

fn main() {
    let x = 5;
    let y = Box::new(x);

    assert_eq!(5, x);
    assert_eq!(5, *y);
}
```

### Defining Our Own Smart Pointer

Let’s build a smart pointer similar to the Box<T> type provided by the
standard library to experience how smart pointers behave differently
from references by default. Then we’ll look at how to add the ability
to use the dereference operator.

The Box<T> type is ultimately defined as a tuple struct with one element,
so Listing 15-8 defines a MyBox<T> type in the same way. We’ll also define
a new function to match the new function defined on Box<T>.

```
Filename: src/main.rs

struct MyBox<T>(T);

impl<T> MyBox<T> {
    fn new(x: T) -> MyBox<T> {
        MyBox(x)
    }
}
```

### Treating a Type Like a Reference by Implementing the Deref Trait

As discussed in the “Implementing a Trait on a Type” section of Chapter 10,
to implement a trait, we need to provide implementations for the trait’s
required methods. The Deref trait, provided by the standard library, requires
us to implement one method named deref that borrows self and returns a reference
to the inner data. Listing 15-10 contains an implementation of Deref to add
to the definition of MyBox:

```
Filename: src/main.rs

use std::ops::Deref;

impl<T> Deref for MyBox<T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}
```

# Managing Growing Projects with Packages, Crates, and Modules

## terms

Rust has a number of features that allow you to manage your code’s
organization, including which details are exposed, which details are
private, and what names are in each scope in your programs. These features,
sometimes collectively referred to as the module system, include:

- Packages

A Cargo feature that lets you build, test, and share crates

- Crates

A tree of modules that produces a library or executable

- Modules and use

Let you control the organization, scope, and privacy of paths

- Paths

A way of naming an item, such as a struct, function, or module

## Packages and Crates

### Craft

A crate is the smallest amount of code that the Rust compiler considers at a time.
Even if you run rustc rather than cargo and pass a single source code file (as
we did all the way back in the “Writing and Running a Rust Program” section of Chapter 1),
the compiler considers that file to be a crate. Crates can contain modules,
and the modules may be defined in other files that get compiled with the
crate, as we’ll see in the coming sections.

binary crate vs. library crate

The crate root is a source file that the Rust compiler starts from and makes up the
root module of your crate (we’ll explain modules in depth in the “Defining
Modules to Control Scope and Privacy” section).

### Package

A package is a bundle of one or more crates that provides a set of functionality.
A package contains a Cargo.toml file that describes how to build those crates.
Cargo is actually a package that contains the binary crate for the
command-line tool you’ve been using to build your code. The Cargo package also
contains a library crate that the binary crate depends on. Other projects can
depend on the Cargo library crate to use the same logic the Cargo command-line
tool uses.

A package can contain as many binary crates as you like, but at most only one
library crate. A package must contain at least one crate, whether that’s a
library or binary crate.

## Defining Modules to Control Scope and Privacy

In this section, we’ll talk about modules and other parts of the module system,
namely paths that allow you to name items; the use keyword that brings a path
into scope; and the pub keyword to make items public. We’ll also discuss the
as keyword, external packages, and the glob operator.

### Modules Cheat Sheet

Here we provide a quick reference on how modules, paths, the use keyword,
and the pub keyword work in the compiler, and how most developers organize
their code. We’ll be going through examples of each of these rules throughout
this chapter, but this is a great place to refer to as a reminder of how
modules work.

#### Start from the crate root:

When compiling a crate, the compiler first looks in the crate root file
(usually src/lib.rs for a library crate or src/main.rs for a binary crate)
for code to compile.


#### Declaring modules:

In the crate root file, you can declare new modules; say, you declare a “garden”
module with mod garden;. The compiler will look for the module’s code in these
places:

- Inline, within curly brackets that replace the semicolon following mod garden
- In the file src/garden.rs
- In the file src/garden/mod.rs

#### Declaring submodules:

In any file other than the crate root, you can declare submodules. For example,
you might declare mod vegetables; in src/garden.rs. The compiler will look for
the submodule’s code within the directory named for the parent module in these
places:

- Inline, directly following mod vegetables, within curly brackets instead of the semicolon

- In the file src/garden/vegetables.rs

- In the file src/garden/vegetables/mod.rs

#### Paths to code in modules:

Once a module is part of your crate, you can refer to code in that module from
anywhere else in that same crate, as long as the privacy rules allow, using
the path to the code. For example, an Asparagus type in the garden vegetables
module would be found at crate::garden::vegetables::Asparagus.

#### Private vs public:

Code within a module is private from its parent modules by default. To make a
module public, declare it with pub mod instead of mod. To make items within a
public module public as well, use pub before their declarations.

#### The use keyword:

Within a scope, the use keyword creates shortcuts to items to reduce repetition
of long paths. In any scope that can refer to crate::garden::vegetables::Asparagus,
you can create a shortcut with use crate::garden::vegetables::Asparagus; and
from then on you only need to write Asparagus to make use of that type in the scope.

### Grouping Related Code in Modules

Modules let us organize code within a crate for readability and easy reuse.
Modules also allow us to control the privacy of items, because code within a
module is private by default. Private items are internal implementation
details not available for outside use. We can choose to make modules and the
items within them public, which exposes them to allow external code to use and
depend on them.

```
mod front_of_house {
    mod hosting {
        fn add_to_waitlist() {}

        fn seat_at_table() {}
    }

    mod serving {
        fn take_order() {}

        fn serve_order() {}

        fn take_payment() {}
    }
}
```

```
crate
 └── front_of_house
     ├── hosting
     │   ├── add_to_waitlist
     │   └── seat_at_table
     └── serving
         ├── take_order
         ├── serve_order
         └── take_payment
```

## Paths for Referring to an Item in the Module Tree

To show Rust where to find an item in a module tree, we use a path in the
same way we use a path when navigating a filesystem. To call a function, we
need to know its path.

A path can take two forms:

- An absolute path is the full path starting from a crate root; for code from
an external crate, the absolute path begins with the crate name, and for code
from the current crate, it starts with the literal crate.

- A relative path starts from the current module and uses self, super, or an
identifier in the current module.

Both absolute and relative paths are followed by one or more identifiers separated
by double colons (::).


# advanced topic

## unsafe

### What Unsafe Rust Can Do

The only things that are different in Unsafe Rust are that you can:

- Dereference raw pointers

- Call unsafe functions (including C functions, compiler intrinsics, and the raw allocator)

- Implement unsafe traits

- Mutate statics

- Access fields of unions

That's it. The reason these operations are relegated to Unsafe is that misusing any of
these things will cause the ever dreaded Undefined Behavior. Invoking Undefined Behavior
gives the compiler full rights to do arbitrarily bad things to your program. You definitely
should not invoke Undefined Behavior.

### four types of unsafe:

- mark one function as unsafe

```
unsafe fn danger_will_robinson() {
    // Scary stuff...
}
```

- The second use of unsafe is an unsafe block:

```
unsafe {
    // Scary stuff...
}
```

- The third is for unsafe traits:

`unsafe trait Scary { }`

- And the fourth is for implementing one of those traits:

`unsafe impl Scary for i32 {}`

### Unsafe Superpowers

In both unsafe functions and unsafe blocks, Rust will let you do three things that
you normally can not do. Just three. Here they are:

    Access or update a static mutable variable.
    Dereference a raw pointer.
    Call unsafe functions. This is the most powerful ability.

That’s it. It’s important that unsafe does not, for example, ‘turn off the borrow checker’.
Adding unsafe to some random Rust code doesn’t change its semantics, it won’t start
accepting anything. But it will let you write things that do break some of the rules.

You will also encounter the unsafe keyword when writing bindings to foreign (non-Rust)
interfaces. You're encouraged to write a safe, native Rust interface around the methods
provided by the library.

Let’s go over the basic three abilities listed, in order.

- Access or update a static mut

Rust has a feature called ‘static mut’ which allows for mutable global state. Doing so
can cause a data race, and as such is inherently not safe. For more details, see the static
section of the book.

- Dereference a raw pointer

Raw pointers let you do arbitrary pointer arithmetic, and can cause a number of
different memory safety and security issues. In some senses, the ability to dereference
an arbitrary pointer is one of the most dangerous things you can do. For more on raw
pointers, see their section of the book.

- Call unsafe functions

This last ability works with both aspects of unsafe: you can only call functions marked
unsafe from inside an unsafe block.

This ability is powerful and varied. Rust exposes some compiler intrinsics as unsafe
functions, and some unsafe functions bypass safety checks, trading safety for speed.

I’ll repeat again: even though you can do arbitrary things in unsafe blocks and
functions doesn’t mean you should. The compiler will act as though you’re upholding
its invariants, so be careful!


## Advanced Traits

### Specifying Placeholder Types in Trait Definitions with Associated Types

Associated types connect a type placeholder with a trait such that the trait method
definitions can use these placeholder types in their signatures. The
implementor of a trait will specify the concrete type to be used instead of
the placeholder type for the particular implementation. That way, we can define a
trait that uses some types without needing to know exactly what those types
are until the trait is implemented.

One example of a trait with an associated type is the Iterator trait that the
standard library provides. The associated type is named Item and stands in for
the type of the values the type implementing the Iterator trait is iterating over.
The definition of the Iterator trait is as shown in Listing 19-12.

```
pub trait Iterator {
    type Item;			//core idea & impl

    fn next(&mut self) -> Option<Self::Item>;
}
```

The type Item is a placeholder, and the next method’s definition shows that it
will return values of type Option<Self::Item>. Implementors of the Iterator
trait will specify the concrete type for Item, and the next method will return
an Option containing a value of that concrete type.

Associated types might seem like a similar concept to generics, in that the
latter allow us to define a function without specifying what types it can handle.
To examine the difference between the two concepts, we’ll look at an
implementation of the Iterator trait on a type named Counter that specifies
the Item type is u32:

```
	impl Iterator for Counter {
	    type Item = u32;		//*********
	
	    fn next(&mut self) -> Option<Self::Item> {
	        // --snip--
```

This syntax seems comparable to that of generics. So why not just define the
Iterator trait with generics, as shown in Listing 19-13?

```
	pub trait Iterator<T> {
    	fn next(&mut self) -> Option<T>;
	}
```

With associated types, we don’t need to annotate types because we can’t implement
a trait on a type multiple times. In Listing 19-12 with the definition that
uses associated types, we can only choose what the type of Item will be once,
because there can only be one impl Iterator for Counter. We don’t have to
specify that we want an iterator of u32 values everywhere that we call next on Counter.

Associated types also become part of the trait’s contract: implementors of
the trait must provide a type to stand in for the associated type placeholder.
Associated types often have a name that describes how the type will be used,
and documenting the associated type in the API documentation is good practice.

### Default Generic Type Parameters and Operator Overloading

When we use generic type parameters, we can specify a default concrete type for
the generic type. This eliminates the need for implementors of the trait to
specify a concrete type if the default type works. You specify a default type
when declaring a generic type with the <PlaceholderType=ConcreteType> syntax.

A great example of a situation where this technique is useful is with operator
overloading, in which you customize the behavior of an operator (such as +)
in particular situations.

Rust doesn’t allow you to create your own operators or overload arbitrary
operators. But you can overload the operations and corresponding traits
listed in std::ops by implementing the traits associated with the
operator. For example, in Listing 19-14 we overload the + operator to
add two Point instances together. We do this by implementing the Add
trait on a Point struct:

```
	use std::ops::Add;
	
	#[derive(Debug, Copy, Clone, PartialEq)]
	struct Point {
	    x: i32,
	    y: i32,
	}
	
	impl Add for Point {
	    type Output = Point;
	
	    fn add(self, other: Point) -> Point {
	        Point {
	            x: self.x + other.x,
	            y: self.y + other.y,
	        }
	    }
	}
	
	fn main() {
	    assert_eq!(
	        Point { x: 1, y: 0 } + Point { x: 2, y: 3 },
	        Point { x: 3, y: 3 }
	    );
	}
```

The default generic type in this code is within the Add trait. Here is its
definition:

```
	trait Add<Rhs=Self> {	#default type
	    type Output;
	
	    fn add(self, rhs: Rhs) -> Self::Output;
	}
```

This code should look generally familiar: a trait with one method and an
associated type. The new part is Rhs=Self: this syntax is called default type
parameters. The Rhs generic type parameter (short for “right hand side”)
defines the type of the rhs parameter in the add method. If we don’t specify
a concrete type for Rhs when we implement the Add trait, the type of Rhs will
default to Self, which will be the type we’re implementing Add on.

Let’s look at an example of implementing the Add trait where we want to
customize the Rhs type rather than using the default.

```
	use std::ops::Add;

	struct Millimeters(u32);
	struct Meters(u32);

	impl Add<Meters> for Millimeters {
	    type Output = Millimeters;

	    fn add(self, other: Meters) -> Millimeters {
	        Millimeters(self.0 + (other.0 * 1000))
	    }
	}
```

To add Millimeters and Meters, we specify impl Add<Meters> to set the value
of the Rhs type parameter instead of using the default of Self.

You’ll use default type parameters in two main ways:

    To extend a type without breaking existing code
    To allow customization in specific cases most users won’t need

### Fully Qualified Syntax for Disambiguation: Calling Methods with the Same Name

Nothing in Rust prevents a trait from having a method with the same name as
another trait’s method, nor does Rust prevent you from implementing both
traits on one type. It’s also possible to implement a method directly on
the type with the same name as methods from traits.

```
	trait Pilot {
	    fn fly(&self);
	}

	trait Wizard {
	    fn fly(&self);
	}

	struct Human;

	impl Pilot for Human {
	    fn fly(&self) {
	        println!("This is your captain speaking.");
	    }
	}

	impl Wizard for Human {
	    fn fly(&self) {
	        println!("Up!");
	    }
	}

	impl Human {
	    fn fly(&self) {
	        println!("*waving arms furiously*");
	    }
	}
```

When we call fly on an instance of Human, the compiler defaults to calling the
method that is directly implemented on the type. To call the fly methods from
either the Pilot trait or the Wizard trait, we need to use more explicit
syntax to specify which fly method we mean. 

```
fn main() {
    let person = Human;
    Pilot::fly(&person);
    Wizard::fly(&person);
    person.fly();
}
```

What is there isn't self parameter?

```
	trait Animal {
	    fn baby_name() -> String;
	}

	struct Dog;

	impl Dog {
	    fn baby_name() -> String {
	        String::from("Spot")
	    }
	}

	impl Animal for Dog {
	    fn baby_name() -> String {
	        String::from("puppy")
	    }
	}

	fn main() {
	    println!("A baby dog is called a {}", Dog::baby_name());
	}

	fn main() {
    	println!("A baby dog is called a {}", <Dog as Animal>::baby_name());
	}
```

In general, fully qualified syntax is defined as follows:

```
	<Type as Trait>::function(receiver_if_method, next_arg, ...);
```

### Using Supertraits to Require One Trait’s Functionality Within Another Trait

Sometimes, you might write a trait definition that depends on another trait:
for a type to implement the first trait, you want to require that type to
also implement the second trait. You would do this so that your trait
definition can make use of the associated items of the second trait. The
trait your trait definition is relying on is called a supertrait of your trait.

In the implementation of the outline_print method, we want to use the
Display trait’s functionality. Therefore, we need to specify that the
OutlinePrint trait will work only for types that also implement Display
and provide the functionality that OutlinePrint needs. We can do that
in the trait definition by specifying OutlinePrint: Display. This technique
is similar to adding a trait bound to the trait. Listing 19-22 shows an
implementation of the OutlinePrint trait.

```
use std::fmt;

trait OutlinePrint: fmt::Display {
    fn outline_print(&self) {
        let output = self.to_string();
        let len = output.len();
        println!("{}", "*".repeat(len + 4));
        println!("*{}*", " ".repeat(len + 2));
        println!("* {} *", output);
        println!("*{}*", " ".repeat(len + 2));
        println!("{}", "*".repeat(len + 4));
    }
}
```

Because we’ve specified that OutlinePrint requires the Display trait, we
can use the to_string function that is automatically implemented for any
type that implements Display. If we tried to use to_string without adding
a colon and specifying the Display trait after the trait name, we’d get
an error saying that no method named to_string was found for the type &Self
in the current scope.

```
///failure
struct Point {
    x: i32,
    y: i32,
}

impl OutlinePrint for Point {}

And Display() trait has to be implemented for Point:

use std::fmt;

impl fmt::Display for Point {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}
```

### Using the Newtype Pattern to Implement External Traits on External Types

In Chapter 10 in the “Implementing a Trait on a Type” section, we
mentioned the orphan rule that states we’re only allowed to implement a
trait on a type if either the trait or the type are local to our crate.
It’s possible to get around this restriction using the newtype pattern,
which involves creating a new type in a tuple struct. (We covered tuple
structs in the “Using Tuple Structs without Named Fields to Create
Different Types” section of Chapter 5.) The tuple struct will have one
field and be a thin wrapper around the type we want to implement a trait
for. Then the wrapper type is local to our crate, and we can implement
the trait on the wrapper. Newtype is a term that originates from the
Haskell programming language. There is no runtime performance penalty
for using this pattern, and the wrapper type is elided at compile time.

As an example, let’s say we want to implement Display on Vec<T>, which
the orphan rule prevents us from doing directly because the Display
trait and the Vec<T> type are defined outside our crate. We can make a
Wrapper struct that holds an instance of Vec<T>; then we can implement
Display on Wrapper and use the Vec<T> value, as shown in Listing 19-23.

```
	use std::fmt;

	struct Wrapper(Vec<String>);

	impl fmt::Display for Wrapper {
	    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
	        write!(f, "[{}]", self.0.join(", "))
	    }
	}

	fn main() {
	    let w = Wrapper(vec![String::from("hello"), String::from("world")]);
	    println!("w = {}", w);
	}
```

The implementation of Display uses self.0 to access the inner Vec<T>,
because Wrapper is a tuple struct and Vec<T> is the item at index 0
in the tuple. Then we can use the functionality of the Display type
on Wrapper.

If we wanted the new type to have every method the inner type has,
implementing the Deref trait (discussed in Chapter 15 in the “Treating
Smart Pointers Like Regular References with the Deref Trait” section)
on the Wrapper to return the inner type would be a solution. If we
don’t want the Wrapper type to have all the methods of the inner
type—for example, to restrict the Wrapper type’s behavior—we would
have to implement just the methods we do want manually.

## Advanced Types

The Rust type system has some features that we’ve so far mentioned
but haven’t yet discussed. We’ll start by discussing newtypes in
general as we examine why newtypes are useful as types. Then we’ll
move on to type aliases, a feature similar to newtypes but with
slightly different semantics. We’ll also discuss the ! type and
dynamically sized types.

### Using the Newtype Pattern for Type Safety and Abstraction

The newtype pattern is also useful for tasks beyond those we’ve
discussed so far, including statically enforcing that values are
never confused and indicating the units of a value. You saw an
example of using newtypes to indicate units in Listing 19-15:
recall that the Millimeters and Meters structs wrapped u32 values
in a newtype. If we wrote a function with a parameter of type
Millimeters, we couldn’t compile a program that accidentally
tried to call that function with a value of type Meters or a plain u32.

We can also use the newtype pattern to abstract away some implementation
details of a type: the new type can expose a public API that is different
from the API of the private inner type.

Newtypes can also hide internal implementation. For example, we could
provide a People type to wrap a HashMap<i32, String> that stores a person’s
ID associated with their name. Code using People would only interact with
the public API we provide, such as a method to add a name string to the
People collection; that code wouldn’t need to know that we assign an i32
ID to names internally. The newtype pattern is a lightweight way to
achieve encapsulation to hide implementation details, which we discussed
in the “Encapsulation that Hides Implementation Details” section of Chapter 17.

### Creating Type Synonyms with Type Aliases

Rust provides the ability to declare a type alias to give an existing type
another name. For this we use the type keyword. For example, we can create
the alias Kilometers to i32 like so:

```
    type Kilometers = i32;

    let x: i32 = 5;
    let y: Kilometers = 5;

    println!("x + y = {}", x + y);
```

The main use case for type synonyms is to reduce repetition. For example,
we might have a lengthy type like this:

```
	Box<dyn Fn() + Send + 'static>

    let f: Box<dyn Fn() + Send + 'static> = Box::new(|| println!("hi"));

    fn takes_long_type(f: Box<dyn Fn() + Send + 'static>) {
        // --snip--
    }

    fn returns_long_type() -> Box<dyn Fn() + Send + 'static> {
        // --snip--
    }
```

=>

```
    type Thunk = Box<dyn Fn() + Send + 'static>;

    let f: Thunk = Box::new(|| println!("hi"));

    fn takes_long_type(f: Thunk) {
        // --snip--
    }

    fn returns_long_type() -> Thunk {
        // --snip--
    }
```

Examples:

```
	type Result<T> = std::result::Result<T, std::io::Error>;
```

The type alias helps in two ways: it makes code easier to write and it
gives us a consistent interface across all of std::io. Because it’s an
alias, it’s just another Result<T, E>, which means we can use any methods
that work on Result<T, E> with it, as well as special syntax like
the ? operator.

### The Never Type that Never Returns

Rust has a special type named ! that’s known in type theory lingo as the
empty type because it has no values. We prefer to call it the never type
because it stands in the place of the return type when a function will
never return. Here is an example:

```
fn bar() -> ! {
    // --snip--
}
```

This code is read as “the function bar returns never.” Functions that
return never are called diverging functions. We can’t create values of
the type ! so bar can never possibly return.

```
        let guess: u32 = match guess.trim().parse() {
            Ok(num) => num,
            Err(_) => continue,
        };
```

As you might have guessed, continue has a ! value. That is, when Rust
computes the type of guess, it looks at both match arms, the former
with a value of u32 and the latter with a ! value. Because ! can
never have a value, Rust decides that the type of guess is u32.

The never type is useful with the panic! macro as well. Recall the
unwrap function that we call on Option<T> values to produce a value
or panic with this definition:

```
impl<T> Option<T> {
    pub fn unwrap(self) -> T {
        match self {
            Some(val) => val,
            None => panic!("called `Option::unwrap()` on a `None` value"),
        }
    }
}
```

In this code, the same thing happens as in the match in Listing 19-26: Rust
sees that val has the type T and panic! has the type !, so the result of
the overall match expression is T. This code works because panic! doesn’t
produce a value; it ends the program. In the None case, we won’t be
returning a value from unwrap, so this code is valid.


### Dynamically Sized Types and the Sized Trait

Rust needs to know certain details about its types, such as how much
space to allocate for a value of a particular type. This leaves one
corner of its type system a little confusing at first: the concept of
dynamically sized types. Sometimes referred to as DSTs or unsized
types, these types let us write code using values whose size we
can know only at runtime.

Let’s dig into the details of a dynamically sized type called str,
which we’ve been using throughout the book. That’s right, not &str,
but str on its own, is a DST. We can’t know how long the string is
until runtime, meaning we can’t create a variable of type str, nor
can we take an argument of type str. Consider the following code,
which does not work:

```
    let s1: str = "Hello there!";
    let s2: str = "How's it going?";
```

Rust needs to know how much memory to allocate for any value of a
particular type, and all values of a type must use the same amount of
memory. If Rust allowed us to write this code, these two str values would
need to take up the same amount of space. But they have different lengths:
s1 needs 12 bytes of storage and s2 needs 15. This is why it’s not
possible to create a variable holding a dynamically sized type.

So what do we do? In this case, you already know the answer: we make the
types of s1 and s2 a &str rather than a str. Recall from the “String Slices”
section of Chapter 4 that the slice data structure just stores the
starting position and the length of the slice. So although a &T is a
single value that stores the memory address of where the T is located,
a &str is two values: the address of the str and its length. As such,
we can know the size of a &str value at compile time: it’s twice the
length of a usize. That is, we always know the size of a &str, no
matter how long the string it refers to is. In general, this is the
way in which dynamically sized types are used in Rust: they have an
extra bit of metadata that stores the size of the dynamic information.
The golden rule of dynamically sized types is that we must always
put values of dynamically sized types behind a pointer of some kind.

We can combine str with all kinds of pointers: for example, Box<str>
or Rc<str>. In fact, you’ve seen this before but with a different
dynamically sized type: traits. Every trait is a dynamically sized
type we can refer to by using the name of the trait. In Chapter 17
in the “Using Trait Objects That Allow for Values of Different Types”
section, we mentioned that to use traits as trait objects, we must
put them behind a pointer, such as &dyn Trait or Box<dyn Trait>
(Rc<dyn Trait> would work too).

To work with DSTs, Rust provides the Sized trait to determine whether
or not a type’s size is known at compile time. This trait is
automatically implemented for everything whose size is known at
compile time. In addition, Rust implicitly adds a bound on Sized
to every generic function. That is, a generic function definition
like this:

```
	fn generic<T>(t: T) {
	    // --snip--
	}
```

is actually treated as though we had written this:

```
	fn generic<T: Sized>(t: T) {
	    // --snip--
	}
```

By default, generic functions will work only on types that have a known
size at compile time. However, you can use the following special syntax
to relax this restriction:

```
	fn generic<T: ?Sized>(t: &T) {
    	// --snip--
	}
```

A trait bound on ?Sized means “T may or may not be Sized” and this
notation overrides the default that generic types must have a known size
at compile time. The ?Trait syntax with this meaning is only available
for Sized, not any other traits.

Also note that we switched the type of the t parameter from T to &T.
Because the type might not be Sized, we need to use it behind some kind
of pointer. In this case, we’ve chosen a reference.

## Advanced Functions and Closures

#### Function Pointers

We’ve talked about how to pass closures to functions; you can also pass
regular functions to functions! This technique is useful when you want
to pass a function you’ve already defined rather than defining a new
closure. Functions coerce to the type fn (with a lowercase f), not to
be confused with the Fn closure trait. The fn type is called a function
pointer. Passing functions with function pointers will allow you to use
functions as arguments to other functions.

Example:

```
	fn add_one(x: i32) -> i32 {
	    x + 1
	}

	fn do_twice(f: fn(i32) -> i32, arg: i32) -> i32 {
	    f(arg) + f(arg)
	}

	fn main() {
	    let answer = do_twice(add_one, 5);
	
	    println!("The answer is: {}", answer);
	}
```

Unlike closures, fn is a type rather than a trait, so we specify fn
as the parameter type directly rather than declaring a generic type
parameter with one of the Fn traits as a trait bound.

Function pointers implement all three of the closure traits (Fn,
FnMut, and FnOnce), meaning you can always pass a function pointer
as an argument for a function that expects a closure. It’s best
to write functions using a generic type and one of the closure
traits so your functions can accept either functions or closures.

That said, one example of where you would want to only accept fn
and not closures is when interfacing with external code that doesn’t
have closures: C functions can accept functions as arguments, but C
doesn’t have closures.

### Returning Closures

Closures are represented by traits, which means you can’t return
closures directly. In most cases where you might want to return a
trait, you can instead use the concrete type that implements the
trait as the return value of the function. However, you can’t do that
with closures because they don’t have a concrete type that is
returnable; you’re not allowed to use the function pointer fn as a
return type, for example.

The following code tries to return a closure directly, but it won’t
compile:

```
fn returns_closure() -> dyn Fn(i32) -> i32 {
    |x| x + 1
}
```

```
$ cargo build
   Compiling functions-example v0.1.0 (file:///projects/functions-example)
error[E0746]: return type cannot have an unboxed trait object
 --> src/lib.rs:1:25
  |
1 | fn returns_closure() -> dyn Fn(i32) -> i32 {
  |                         ^^^^^^^^^^^^^^^^^^ doesn't have a size known at compile-time
  |
  = note: for information on `impl Trait`, see <https://doc.rust-lang.org/book/ch10-02-traits.html#returning-types-that-implement-traits>
help: use `impl Fn(i32) -> i32` as the return type, as all return paths are of type `[closure@src/lib.rs:2:5: 2:8]`, which implements `Fn(i32) -> i32`
  |
1 | fn returns_closure() -> impl Fn(i32) -> i32 {
  |                         ~~~~~~~~~~~~~~~~~~~

For more information about this error, try `rustc --explain E0746`.
error: could not compile `functions-example` due to previous error
```

The error references the Sized trait again! Rust doesn’t know how much space
it will need to store the closure. We saw a solution to this problem earlier.
We can use a trait object:

```
fn returns_closure() -> Box<dyn Fn(i32) -> i32> {
    Box::new(|x| x + 1)
}
```

### FnOnce vs. FnMut vs. Fn

1) FnOnce applies to closures that can be called once. All closures implement
at least this trait, because all closures can be called. A closure that moves
captured values out of its body will only implement FnOnce and none of the
other Fn traits, because it can only be called once.

2) FnMut applies to closures that don’t move captured values out of their body,
but that might mutate the captured values. These closures can be called more
than once.

3) Fn applies to closures that don’t move captured values out of their body
and that don’t mutate captured values, as well as closures that capture
nothing from their environment. These closures can be called more than once
without mutating their environment, which is important in cases such as
calling a closure multiple times concurrently.

### closure key concepts


#### Closure Types:

- Each closure in Rust has a unique, anonymous type generated by the compiler. This
type depends on the captured variables and their usage (immutable, mutable, or ownership).

- Example: Two closures with identical code but different captured variables are distinct types.

#### Traits as Interfaces:

The traits Fn, FnMut, and FnOnce define how a closure interacts with its environment:

Fn: Immutably borrows captured variables (&self).

FnMut: Mutably borrows captured variables (&mut self).

FnOnce: Takes ownership of captured variables (self), allowing only one call.

The compiler automatically implements the appropriate trait(s) for a closure based on
its usage of variables.

- Examples

// Closure captures `x` immutably. Implements `Fn`.
let x = 5;
let add_x = |y| x + y;

// Closure captures `x` mutably. Implements `FnMut`.
let mut x = 5;
let incr_x = || { x += 1; x };

// Closure takes ownership of `x`. Implements `FnOnce`.
let x = vec![1, 2, 3];
let consume_x = move || x.len();

#### Under the Hood:

The compiler generates a struct for each closure to store captured variables.

This struct implements the relevant closure trait(s), enabling method calls
(e.g., call(), call_mut(), call_once()).


## Macros

We’ve used macros like println! throughout this book, but we haven’t fully
explored what a macro is and how it works. The term macro refers to a family
of features in Rust: declarative macros with macro_rules! and three kinds
of procedural macros:

- Custom #[derive] macros that specify code added with the derive attribute
used on structs and enums

- Attribute-like macros that define custom attributes usable on any item

- Function-like macros that look like function calls but operate on the
tokens specified as their argument

### The Difference Between Macros and Functions

Fundamentally, macros are a way of writing code that writes other code,
which is known as metaprogramming. In Appendix C, we discuss the derive
attribute, which generates an implementation of various traits for you.
We’ve also used the println! and vec! macros throughout the book. All
of these macros expand to produce more code than the code you’ve written manually.

Metaprogramming is useful for reducing the amount of code you have to
write and maintain, which is also one of the roles of functions. However,
macros have some additional powers that functions don’t.

A function signature must declare the number and type of parameters
the function has. Macros, on the other hand, can take a variable number
of parameters: we can call println!("hello") with one argument or
println!("hello {}", name) with two arguments. Also, macros are expanded
before the compiler interprets the meaning of the code, so a macro can,
for example, implement a trait on a given type. A function can’t,
because it gets called at runtime and a trait needs to be implemented
at compile time.

The downside to implementing a macro instead of a function is that macro
definitions are more complex than function definitions because you’re
writing Rust code that writes Rust code. Due to this indirection, macro
definitions are generally more difficult to read, understand, and
maintain than function definitions.

Another important difference between macros and functions is that you
must define macros or bring them into scope before you call them in a
file, as opposed to functions you can define anywhere and call anywhere.

### Declarative Macros with macro_rules! for General Metaprogramming

```
#[macro_export]
macro_rules! vec {
    ( $( $x:expr ),* ) => {
        {
            let mut temp_vec = Vec::new();
            $(
                temp_vec.push($x);
            )*
            temp_vec
        }
    };
}
```

Note: The actual definition of the vec! macro in the standard library
includes code to preallocate the correct amount of memory up front. That
code is an optimization that we don’t include here to make the example
simpler.

The #[macro_export] annotation indicates that this macro should be made
available whenever the crate in which the macro is defined is brought
into scope. Without this annotation, the macro can’t be brought into scope.

Valid pattern syntax in macro definitions is different than the pattern
syntax covered in Chapter 18 because macro patterns are matched against
Rust code structure rather than values. Let’s walk through what the
pattern pieces in Listing 19-28 mean; for the full macro pattern syntax,
see the Rust Reference.

First, we use a set of parentheses to encompass the whole pattern. We
use a dollar sign ($) to declare a variable in the macro system that will
contain the Rust code matching the pattern. The dollar sign makes it
clear this is a macro variable as opposed to a regular Rust variable.
Next comes a set of parentheses that captures values that match the pattern
within the parentheses for use in the replacement code. Within $() is
$x:expr, which matches any Rust expression and gives the expression the
name $x.

The comma following $() indicates that a literal comma separator character
could optionally appear after the code that matches the code in $(). The *
specifies that the pattern matches zero or more of whatever precedes the *.

When we call this macro with vec![1, 2, 3];, the $x pattern matches three
times with the three expressions 1, 2, and 3.

Now let’s look at the pattern in the body of the code associated with this
arm: temp_vec.push() within $()* is generated for each part that matches $()
in the pattern zero or more times depending on how many times the pattern
matches. The $x is replaced with each expression matched. 

# Fearless Concurrency

Here are the topics we’ll cover in this chapter:

How to create threads to run multiple pieces of code at the same time

Message-passing concurrency, where channels send messages between threads

Shared-state concurrency, where multiple threads have access to some
piece of data

The Sync and Send traits, which extend Rust’s concurrency guarantees to
user-defined types as well as types provided by the standard library

## Weapons

- Box<T> is for single ownership.

- Rc<T> is for multiple ownership

- Arc<T> is for multiple ownership, but threadsafe.

- Cell<T> is for "interior mutability" for Copy types; that is, when you need
to mutate something behind a &T.

- Mutex<T> is still for "interior mutability" & threadsafe, often work with
  Arc<Mutex<T>> together. Mutex comes with the risk of creating deadlocks,
  also perf may become worse

### spawn vs. arc

```
use std::sync::Arc;

fn process_files_in_parallel(filenames: Vec<String>, glossary: Arc<GigabyteMap>)
-> io::Result<()>
{...
	for worklist in worklists {
		// This call to .clone() only clones the Arc and bumps the
		// reference count. It does not clone the GigabyteMap.
		let glossary_for_child = glossary.clone();
		thread_handles.push(
			spawn(move || process_files(worklist, &glossary_for_child))
		);
	}
...
}
```

- share immutable reference among threads

### channel

A channel is a one-way conduit for sending values from one thread to another.
In other words, it’s a thread-safe queue. Figure 19-5 illustrates how channels
are used. They’re something like Unix pipes: one end is for sending data, and
the other is for receiving.

The two ends are typically owned by two diﬀerent threads. But whereas Unix pipes
are for sending bytes, channels are for sending Rust values. sender.send(item)
puts a single value into the channel; receiver.recv() removes one. Ownership is
transferred from the sending thread to the receiving thread. If the channel is
empty, receiver.recv() blocks until a value is sent.

### Thread Safety: Send and Sync

So far we’ve been acting as though all values can be freely moved and shared
across threads. This is mostly true, but Rust’s full thread safety story hinges
on two built-in traits, std::marker::Send and std::marker::Sync.

- Types that implement Send are safe to pass by value to another thread. They can
be moved across threads.
- Types that implement Sync are safe to pass by non-mut reference to another thread.
They can be shared across threads.

By safe here, we mean the same thing we always mean: free from data races and other
undeﬁned behavior.

### mut and Mutex

- `fn join_waiting_list(&self, player: PlayerId)	//&mut self?`

But Mutex does have a way: the lock. In fact, a mutex is little more than a way to
do exactly this, to provide exclusive (mut) access to the data inside, even though
many threads may have shared (non-mut) access to the Mutex itself.

Rust’s type system is telling us what Mutex does. It dynamically enforces exclusive
access, something that’s usually done statically, at compile time, by the Rust
compiler.

(You may recall that std::cell::RefCell does the same,
except without trying to support multiple threads. Mutex
and RefCell are both ﬂavors of interior mutability, which
we covered .)

- Poisoned Mutexes

### RwLock

`RwLock<AppConfig>`

### conditional var

std::sync::Condvar

### Atomic 

`std::sync::atomic`

### Global Variables

`static PACKETS_SERVED: usize = 0;`

or `unsafe`

or

`static PACKETS_SERVED: AtomicUsize = AtomicUsize::new(0);`

- use `lazy_static::lazy_static;`

### interior mutability by Cell<T> and RefCell<T>

Values of the Cell<T> and RefCell<T> types may be mutated through shared
references (i.e. the common &T type), whereas most Rust types can only be mutated
through unique (&mut T) references. We say that Cell<T> and RefCell<T> provide
‘interior mutability’, in contrast with typical Rust types that exhibit
‘inherited mutability’.

Cell types come in two flavors: Cell<T> and RefCell<T>. Cell<T> implements interior
mutability by moving values in and out of the Cell<T>. To use references instead of
values, one must use the RefCell<T> type, acquiring a write lock before mutating.
Cell<T> provides methods to retrieve and change the current interior value:

- Used in single-thread context

- Cell<T> is for Copy types, providing interior mutability via get() and set(),
without references.

- RefCell<T> is for non-Copy types, enabling runtime-checked borrowing (borrow()
and borrow_mut()).

- Both enable mutability in immutable contexts, but Cell<T> is simpler and faster,
whereas RefCell<T> allows more flexibility but has runtime checks.


## Using Threads to Run Code Simultaneously

The Rust standard library uses a 1:1 model of thread implementation, whereby
a program uses one operating system thread per one language thread. There are
crates that implement other models of threading that make different tradeoffs
to the 1:1 model.

### Creating a New Thread with spawn

### Waiting for All Threads to Finish Using join Handles

### Using move Closures with Threads

```
use std::thread;

fn main() {
    let v = vec![1, 2, 3];

    let handle = thread::spawn(move || {
        println!("Here's a vector: {:?}", v);
    });

    handle.join().unwrap();
}
```

## Using Message Passing to Transfer Data Between Threads


## Shared-State Concurrency

Shared memory concurrency is like multiple ownership: multiple threads
can access the same memory location at the same time. As you saw in
Chapter 15, where smart pointers made multiple ownership possible,
multiple ownership can add complexity because these different owners
need managing. Rust’s type system and ownership rules greatly assist
in getting this management correct. For an example, let’s look at
mutexes, one of the more common concurrency primitives for shared memory.

```
use std::sync::{Arc, Mutex};
use std::thread;

fn main() {
    let counter = Arc::new(Mutex::new(0));
    let mut handles = vec![];

    for _ in 0..10 {
        let counter = Arc::clone(&counter);
        let handle = thread::spawn(move || {
            let mut num = counter.lock().unwrap();

            *num += 1;
        });
        handles.push(handle);
    }

    for handle in handles {
        handle.join().unwrap();
    }

    println!("Result: {}", *counter.lock().unwrap());
}
```

### Similarities Between RefCell<T>/Rc<T> and Mutex<T>/Arc<T>

You might have noticed that counter is immutable but we could get a mutable
reference to the value inside it; this means Mutex<T> provides interior
mutability, as the Cell family does. In the same way we used RefCell<T>
in Chapter 15 to allow us to mutate contents inside an Rc<T>, we use
Mutex<T> to mutate contents inside an Arc<T>.

Another detail to note is that Rust can’t protect you from all kinds of
logic errors when you use Mutex<T>. Recall in Chapter 15 that using Rc<T>
came with the risk of creating reference cycles, where two Rc<T> values
refer to each other, causing memory leaks. Similarly, Mutex<T> comes
with the risk of creating deadlocks. These occur when an operation
needs to lock two resources and two threads have each acquired one of
the locks, causing them to wait for each other forever. If you’re
interested in deadlocks, try creating a Rust program that has a
deadlock; then research deadlock mitigation strategies for mutexes in
any language and have a go at implementing them in Rust. The standard
library API documentation for Mutex<T> and MutexGuard offers useful
information.

## Extensible Concurrency with the Sync and Send Traits

Interestingly, the Rust language has very few concurrency features.
Almost every concurrency feature we’ve talked about so far in this
chapter has been part of the standard library, not the language.
Your options for handling concurrency are not limited to the
language or the standard library; you can write your own
concurrency features or use those written by others.

However, two concurrency concepts are embedded in the language:
the std::marker traits Sync and Send.

### Allowing Transference of Ownership Between Threads with Send

The Send marker trait indicates that ownership of values of the type implementing
Send can be transferred between threads. Almost every Rust type is Send, but
there are some exceptions, including Rc<T>: this cannot be Send because if you
cloned an Rc<T> value and tried to transfer ownership of the clone to another thread,
both threads might update the reference count at the same time. For this reason,
**Rc<T> is implemented for use in single-threaded situations** where you don’t
want to pay the thread-safe performance penalty.

Therefore, Rust’s type system and trait bounds ensure that you can never
accidentally send an Rc<T> value across threads unsafely. When we tried to do
this in Listing 16-14, we got the error the trait Send is not implemented for
Rc<Mutex<i32>>. When we switched to Arc<T>, which is Send, the code compiled.

Any type composed entirely of Send types is automatically marked as Send as
well. Almost all primitive types are Send, aside from raw pointers, which
we’ll discuss in Chapter 19.


### Implementing Send and Sync Manually Is Unsafe

The Sync marker trait indicates that it is safe for the type implementing Sync
to be referenced from multiple threads. **In other words, any type T is Sync if
&T (an immutable reference to T) is Send, meaning the reference can be sent
safely to another thread.** Similar to Send, **primitive types are Sync**, and types
composed entirely of types that are Sync are also Sync.

The smart pointer **Rc<T> is also not Sync** for the same reasons that it’s not
Send. **The RefCell<T> type (which we talked about in Chapter 15) and the family
of related Cell<T> types are not Sync.** The implementation of borrow checking
that RefCell<T> does at runtime is not thread-safe. **The smart pointer Mutex<T>
is Sync** and can be used to share access with multiple threads as you saw in
the “Sharing a Mutex<T> Between Multiple Threads” section.

### Implementing Send and Sync Manually Is Unsafe

Because types that are made up of Send and Sync traits are automatically
also Send and Sync, we don’t have to implement those traits manually. As
marker traits, they don’t even have any methods to implement. They’re just
useful for enforcing invariants related to concurrency.

Manually implementing these traits involves implementing unsafe Rust code.
We’ll talk about using unsafe Rust code in Chapter 19; for now, the important
information is that building new concurrent types not made up of Send and
Sync parts requires careful thought to uphold the safety guarantees. “The
Rustonomicon” has more information about these guarantees and how to uphold them.

Not everything obeys inherited mutability, though. Some types allow
you to have multiple aliases of a location in memory while mutating it.
Unless these types use synchronization to manage this access, they are
absolutely not thread-safe. Rust captures this through the Send and Sync
traits.

- **A type is Send if it is safe to send it to another thread.**

- **A type is Sync if it is safe to share between threads
(T is Sync if and only if &T is Send).**

Send and Sync are also automatically derived traits. This means that, unlike
every other trait, if a type is composed entirely of Send or Sync types, then
it is Send or Sync. Almost all primitives are Send and Sync, and as a
consequence pretty much all types you'll ever interact with are Send and Sync.

Major exceptions include:

- **raw pointers are neither Send nor Sync (because they have no safety guards).** 

- **UnsafeCell isn't Sync (and therefore Cell and RefCell aren't).**

- **Rc isn't Send or Sync (because the refcount is shared and unsynchronized).**


# Asynchronous Programming

multiple thread example:

```
	use std::{net, thread};
	let listener = net::TcpListener::bind(address)?;
	for socket_result in listener.incoming() {
		let socket = socket_result?;
		let groups = chat_group_table.clone();
		thread::spawn(|| {log_error(serve(socket, groups));});
	}
```

async example:

```
	use async_std::{net, task};
	let listener = net::TcpListener::bind(address).await?;
	let mut new_connections = listener.incoming();
	while let Some(socket_result) = new_connections.next().await {
		let socket = socket_result?;
		let groups = chat_group_table.clone();

		task::spawn(async {
			log_error(serve(socket, groups).await);
		});
	}
```

The goal of this chapter is not only to help you write asynchronous
code, but also to show how it works in enough detail that you can
anticipate how it will perform in your applications and see where
it can be most valuable.

1) To show the mechanics of asynchronous programming, we lay out a
minimal set of language features that covers all the core concepts:
	futures,
	asynchronous functions,
	await expressions,
	tasks,
	the block_on
	and spawn_local executors.

2) Then we present asynchronous blocks and the spawn executor. These
are essential to getting real work done, but conceptually, they’re
just variants on the features we just mentioned. In the process, we
point out a few issues you’re likely to encounter that are unique to
asynchronous programming and explain how to handle them.

3) To show all these pieces working together, we walk through the
complete code for a chat server and client, of which the preceding
code fragment is a part.

4) To illustrate how primitive futures and executors work, we present
simple but functional implementations of spawn_blocking and block_on.

5) Finally, we explain the Pin type, which appears from time to time
in asynchronous interfaces to ensure that asynchronous function and
block futures are used safely.

### what is async executor?

Execution of async code, IO and task spawning are provided by "async runtimes",
such as Tokio and async-std. Most async applications, and some async crates,
depend on a specific runtime. See "The Async Ecosystem" section for more details.

On futures inside other futures, we can use the await keyword. But if we
want to call an async function from the top most level of our program, we need
to manually poll the future until it is ready. That code is called a runtime
or an executor.

A runtime is responsible for polling the top level futures until they are
ready. It is also responsible for running multiple futures in parallel. The
standard library does not provide a runtime, but there are many community
built runtimes available. We will use the most popular one called tokio
in this tutorial.


#### The Async Ecosystem

Rust currently provides only the bare essentials for writing async code.
Importantly, executors, tasks, reactors, combinators, and low-level I/O
futures and traits are not yet provided in the standard library. In the
meantime, community-provided async ecosystems fill in these gaps.

The Async Foundations Team is interested in extending examples in the
Async Book to cover multiple runtimes. If you're interested in
contributing to this project, please reach out to us on Zulip.

#### Async Runtimes

Async runtimes are libraries used for executing async applications.
Runtimes usually bundle together a reactor with one or more executors.
Reactors provide subscription mechanisms for external events, like async
I/O, interprocess communication, and timers. In an async runtime,
subscribers are typically futures representing low-level I/O operations.
Executors handle the scheduling and execution of tasks. They keep track
of running and suspended tasks, poll futures to completion, and wake tasks
when they can make progress. The word "executor" is frequently used
interchangeably with "runtime". Here, we use the word "ecosystem" to
describe a runtime bundled with compatible traits and features.


##### What Is Tokio?

Tokio is an asynchronous runtime for the Rust 🦀 programming language.
It provides the building blocks needed for writing network applications.
It gives the flexibility to target a wide range of systems, from large
servers with dozens of cores to small embedded devices.

At a high level, Tokio provides a few major components:

- A multi-threaded runtime for executing asynchronous code.
- An asynchronous version of the standard library.
- A large ecosystem of libraries.

The advantage of using Tokio is that it is fast, reliable, easy to use
and very flexible.


## From Synchronous to Asynchronous

### synchronous example

```
use std::io::prelude::*;
use std::net;
fn cheapo_request(host: &str, port: u16, path: &str) -> std::io::Result<String>
{
	let mut socket = net::TcpStream::connect((host, port))?;
	let request = format!("GET {} HTTP/1.1\r\nHost: {}\r\n\r\n", path, host);

	socket.write_all(request.as_bytes())?;
	socket.shutdown(net::Shutdown::Write)?;

	let mut response = String::new();
	socket.read_to_string(&mut response)?;
	Ok(response)
}
```

While this function is waiting for the system calls to return, its single
thread is blocked: it can’t do anything else until the system call ﬁnishes.
It’s not unusual for a thread’s stack to be tens or hundreds of kilobytes
in size, so if this were a fragment of some larger system, with many threads
working away at similar jobs, locking down those threads’ resources to do
nothing but wait could become quite expensive.

To get around this, a thread needs to be able to take up other work while
it waits for system calls to complete. But it’s not obvious how to
accomplish this. For example, the signature of the function we’re using
to read the response from the socket is:

```
fn read_to_string(&mut self, buf: &mut String) -> std::io::Result<usize>;
```

It’s written right into the type: this function doesn’t return until the
job is done, or something goes wrong. This function is synchronous: the
caller resumes when the operation is complete. If we want to use our
thread for other things while the operating system does its work, we’re
going need a new I/O library that provides an asynchronous version of
this function.

### Futures

Rust’s approach to supporting asynchronous operations is to introduce a trait,
std::future::Future:

```
trait Future {
	type Output;

	// For now, read `Pin<&mut Self>` as `&mut Self`.
	fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

enum Poll<T> {
	Ready(T),
	Pending,
}
```

Q: what is Pin<> and Context<>?

A Future represents an operation that you can test for completion. A future’s
poll method never waits for the operation to ﬁnish: it always returns immediately.
If the operation is complete, poll returns Poll::Ready(output), where output
is its ﬁnal result. Otherwise, it returns Pending. If and when the future is
worth polling again, it promises to let us know by invoking a waker, a callback
function supplied in the Context. We call this the “piñata model” of
asynchronous programming: the only thing you can do with a future is whack it
with a poll until a value falls out.

All modern operating systems include variants of their system calls that we
can use to implement this sort of polling interface. On Unix and Windows, for
example, if you put a network socket in nonblocking mode, then reads and
writes return an error if they would block; you have to try again later.
So an asynchronous version of read_to_string would have a signature roughly
like this:

```
fn read_to_string(&mut self, buf: &mut String) -> impl Future<Output = Result<usize>>;
```

This is the same as the signature we showed earlier, except for the return
type: the asynchronous version returns a future of a Result<usize>. You’ll
need to poll this future until you get a Ready(result) from it. Each time
it’s polled, the read proceeds as far as it can. The ﬁnal result gives you
the success value or an error value, just like an ordinary I/O operation.
This is the general pattern: the asynchronous version of any function
takes the same arguments as the synchronous version, but the return type
has a Future wrapped around it.

Calling this version of read_to_string doesn’t actually read anything;
its sole responsibility is to construct and return a future that
will do the real work when polled. This future must hold all the
information necessary to carry out the request made by the call.
For example, the future returned by this read_to_string must remember
the input stream it was called on, and the String to which it should
append the incoming data. In fact, since the future holds the references
self and buf, the proper signature for read_to_string must be:

```
fn read_to_string<'a>(&'a mut self, buf: &'a mut String)
	-> impl Future<Output = Result<usize>> + 'a;
```

The async-std crate provides asynchronous versions of all of std’s I/O
facilities, including an asynchronous Read trait with a read_to_string
method. async-std closely follows the design of std, reusing std’s
types in its own interfaces whenever possible, so errors, results,
network addresses, and most of the other associated data are compatible
between the two worlds. Familiarity with std helps you use async-std,
and vice versa.

One of the rules of the Future trait is that, once a future has
returned Poll::Ready, it may assume it will never be polled again.
Some futures just return Poll::Pending forever if they are overpolled;
others may panic or hang. (They must not, however, violate memory or
thread safety, or otherwise cause undeﬁned behavior.) The fuse
adaptormethod on the Future trait turns any future into one that
simply returns Poll::Pending forever. But all the usual ways of
consuming futures respect this rule, so fuse is usually not necessary.

If polling sounds ineﬀicient, don’t worry. Rust’s asynchronous architecture
is carefully designed so that, as long as your basic I/O functions
like read_to_string are implemented correctly, you’ll only poll a
future when it’s worthwhile. Every time poll is called, something
somewhere should return Ready, or at least make progress toward that
goal. We’ll explain how this works in “Primitive Futures and Executors:
When Is a Future Worth Polling Again?”.

#### Where/How is Future variable allocated?

From AI

Rust Future variables for async/await are allocated in several different ways depending on the context:

- Stack Allocation (Most Common)

```
async fn example() {
    let future = some_async_function(); // Future allocated on stack
    future.await;
}
```

The Future state machine is typically allocated on the stack of the calling function.

- Heap Allocation (When Boxed)

```
let boxed_future: Pin<Box<dyn Future<Output = ()>>> = Box::pin(async {
    // Future state machine allocated on heap
});
```

- Generator State Machine

When you write an async function, the compiler transforms it into a state machine:

```
// This async function...
async fn example() {
    let x = 1;
    some_async_call().await;
    let y = 2;
}

// Becomes roughly equivalent to a state machine like:
enum ExampleFuture {
    Start,
    WaitingForAsyncCall { x: i32 },
    Finished,
}
```

Key Points:
    - Size: Future size is determined at compile time based on all variables that need to persist across await points
    - Location: Usually stack-allocated unless explicitly boxed
    - Lifetime: Tied to the scope where the Future is created
    - Zero-cost: No additional heap allocation unless you explicitly box it

```


### Async Functions and Await Expressions

```
use async_std::io::prelude::*;
use async_std::net;
async fn cheapo_request(host: &str, port: u16, path: &str) -> std::io::Result<String>
{
	let mut socket = net::TcpStream::connect((host,port)).await?;
	let request = format!("GET {} HTTP/1.1\r\nHost: {}\r\n\r\n", path, host);

	socket.write_all(request.as_bytes()).await?;
	socket.shutdown(net::Shutdown::Write)?;

	let mut response = String::new();
	socket.read_to_string(&mut response).await?;
	Ok(response)
}
```

note:
1) async fn

2) async_std crate’s asynchronous versions of TcpStream::connect, write_all, and
read_to_string

3) After each call that returns a future, the code says .await. Although
this looks like a reference to a struct ﬁeld named await, it is actually
special syntax built into the language for waiting until a future is
ready. An await expression evaluates to the ﬁnal value of the future.
This is how the function obtains the results from connect, write_all, and
read_to_string.

Unlike an ordinary function, when you call an asynchronous function, it
returns immediately, before the body begins execution at all. Obviously,
the call’s ﬁnal return value hasn’t been computed yet; what you get is
a future of its ﬁnal value. So if you execute this code:

	let response = cheapo_request(host, port, path);

then response will be a future of a std::io::Result<String>, and the
body of cheapo_request has not yet begun execution. You don’t
need to adjust an asynchronous function’s return type; Rust
automatically treats async fn f(...) -> T as a function
that returns a future of a T, not a T directly.

///////////////////////////////////////////////////

***The future returned by an async function wraps up all the information
the function body will need to run: the function’s arguments, space
for its local variables, and so on.***

(It’s as if you’d captured the call’s stack frame as an ordinary Rust value.)
So response must hold the values passed for host, port, and path, since
cheapo_request’s body is going to need those to run.

The future’s speciﬁc type is generated automatically by the compiler,
based on the function’s body and arguments. This type doesn’t have a
name; all you know about it is that it implements Future<Output=R>,
where R is the async function’s return type. In this sense, futures of
asynchronous functions are like closures: closures also have anonymous
types, generated by the compiler, that implement the FnOnce, Fn, and
FnMut traits.

///////////////////////////////////////////////////

When you ﬁrst poll the future returned by cheapo_request, execution begins
at the top of the function body and runs until the ﬁrst await of the future
returned by TcpStream::connect. The await expression polls the connect
future, and if it is not ready, then it returns Poll::Pending to its own
caller: polling cheapo_request’s future cannot proceed past that ﬁrst
await until a poll of TcpStream::connect’s future returns Poll::Ready.

So a rough equivalent of the expression TcpStream::connect(...).await
might be:

```
{
	// Note: this is pseudocode, not valid Rust
	let connect_future = TcpStream::connect(...);
	'retry_point:
	match connect_future.poll(cx) {
		Poll::Ready(value) => value,
		Poll::Pending => {
			// Arrange for the next `poll` of `cheapo_request`'s
			// future to resume execution at 'retry_point.
			...
			return Poll::Pending;
		}
	}
}
```

But crucially, the next poll of cheapo_request’s future doesn’t start at
the top of the function again: instead, it resumes execution mid-function
at the point where it is about to poll connect_future. We don’t progress
to the rest of the async function until that future is ready.

***The ability to suspend execution mid-function and then resume later is
unique to async functions. When an ordinary function returns, its stack
frame is gone for good. Since await expressions depend on the ability to
resume, you can only use them inside async functions.***

As of this writing, Rust does not yet allow traits to have asynchronous methods.
Only free functions and functions inherent to a speciﬁc type can be asynchronous.
Lifting this restriction will require a number of changes to the
language. In the meantime, if you need to deﬁne traits that include async functions,
consider using the async-trait crate, which provides a macro-based workaround.

### Calling Async Functions from Synchronous Code: block_on

In a sense, async functions just pass the buck. True, it’s easy to get a future’s
value in an async function: just await it. But the async function itself
returns a future, so it’s now the caller’s job to do the polling somehow.
Ultimately, someone has to actually wait for a value.

We can call cheapo_request from an ordinary, synchronous function (like main,
for example) using async_std’s task::block_on function, which takes a future
and polls it until it produces a value:

```
fn main() -> std::io::Result<()> {
	use async_std::task;
	let response = task::block_on(cheapo_request("example.com", 80, "/"))?;

	println!("{}", response);
	Ok(())
}
```

Since block_on is a synchronous function that produces the ﬁnal value of an
asynchronous function, you can think of it as an adapter from the asynchronous
world to the synchronous world. But its blocking character also means that
you should never use block_on within an async function: it would block the
entire thread until the value is ready. Use await instead.

1) First, main calls cheapo_request, which returns future A of its ﬁnal
result. Then main passes that future to async_std::block_on, which
polls it.

2) Polling future A allows the body of cheapo_request to begin execution.
It calls TcpStream::connect to obtain a future B of a socket and then
awaits that. More precisely, since TcpStream::connect might encounter
an error, B is a future of a Result<TcpStream, std::io::Error>.

3) Future B gets polled by the await. Since the network connection is
not yet established, B.poll returns Poll::Pending, but arranges to wake
up the calling task once the socket is ready.

4) Since future B wasn’t ready, A.poll returns Poll::Pending to its own
caller, block_on.

5) Since block_on has nothing better to do, it goes to sleep. The entire
thread is blocked now.

6) When B’s connection is ready to use, it wakes up the task that polled it.
This stirs block_on into action, and it tries polling the future A again.
Polling A causes cheapo_request to resume in its ﬁrst await, where it polls
B again.

7) This time, B is ready: socket creation is complete, so it returns
Poll::Ready(Ok(socket)) to A.poll.

8) The asynchronous call to TcpStream::connect is now complete. The value
of the TcpStream::connect(...).await expression is thus Ok(socket).

9) The execution of cheapo_request’s body proceeds normally, building
the request string using the format! macro and passing it to
socket.write_all.

10) Since socket.write_all is an asynchronous function, it returns a
future C of its result, which cheapo_request duly awaits.

It doesn’t sound too hard to just write a loop that calls poll
over and over. But what makes async_std::task::block_on valuable
is that it knows how to go to sleep until the future is actually
worth polling again, rather than wasting your processor time and battery
life making billions of fruitless poll calls. The futures returned by
basic I/O functions like connect and read_to_string retain the waker
supplied by the Context passed to poll and invoke it when block_on
should wake up and try polling again.

### Spawning Async Tasks

The spawn_local function is an asynchronous analogue of the standard
library’s std::thread::spawn function for starting threads:

1) std::thread::spawn(c) takes a closure c and starts a thread running
it, returning a std::thread::JoinHandle whose join method
waits for the thread to ﬁnish and returns whatever c returned.

2) async_std::task::spawn_local(f) takes the future f and adds it to
the pool to be polled when the current thread calls block_on. spawn_local
returns its own async_std::task::JoinHandle type, itself a future that
you can await to retrieve f’s ﬁnal value.

For example, suppose we want to make a whole set of HTTP requests concurrently.
Here’s a ﬁrst attempt:

```
pub async fn many_requests(requests: Vec<(String, u16, String)>)
	-> Vec<std::io::Result<String>>
{
	use async_std::task;
	let mut handles = vec![];

	for (host, port, path) in requests {
		handles.push(task::spawn_local(cheapo_request(&host, port, &path)));
	}
	//host & path may be dropped now, just like std::thread::spawn()

	let mut results = vec![];
	for handle in handles {
		results.push(handle.await);
	}

	results
}
```

This function calls cheapo_request on each element of requests, passing each
call’s future to spawn_local. It collects the resulting JoinHandles in a
vector and then awaits each of them. It’s ﬁne to await the join handles in
any order: since the requests are already spawned, their futures will be
polled as needed whenever this thread calls block_on and has nothing better
to do. All the requests will run concurrently. Once they’re complete,
many_requests returns the results to its caller. The previous code is almost
correct, but Rust’s borrow checker is worried about the lifetime of
cheapo_request’s future:

Naturally, if we pass references to an asynchronous function, the future
it returns must hold those references, so the future cannot safely
outlive the values they borrow.This is the same restriction that applies
to any value that holds references.

The problem is that spawn_local can’t be sure you’ll wait for the task to
ﬁnish before host and path are dropped. In fact, spawn_local only accepts
futures whose lifetimes are 'static, because you could simply ignore the
JoinHandle it returns and let the task continue to run for the rest of the
program’s execution. This isn’t unique to asynchronous tasks: you’ll get a
similar error if you try to use std::thread::spawn to start a thread
whose closure captures references to local variables.

One way to ﬁx this is to create another asynchronous function that takes
owned versions of the arguments:

```
async fn cheapo_owning_request(host: String, port: u16, path: String)
-> std::io::Result<String> {
	cheapo_request(&host, port, &path).await
}
```

This function takes Strings instead of &str references, so its future
owns the host and path strings itself, and its lifetime is 'static.
The borrow checker can see that it immediately awaits cheapo_request’s
future, and hence, if that future is getting polled at all, the host
and path variables it borrows must still be around. All is well.

Using cheapo_owning_request, you can spawn oﬀ all your requests like so:

```
//now feature owns (host, port, path)
for (host, port, path) in requests {
	handles.push(task::spawn_local(cheapo_owning_request(host, port, path)));
}
```

You can call many_requests from your synchronous main function, with block_on:

```
	let requests = vec![
		("example.com".to_string(), 80, "/".to_string()),
		("www.red-bean.com".to_string(), 80, "/".to_string()),
		("en.wikipedia.org".to_string(), 80, "/".to_string()),
	];
	let results = async_std::task::block_on(many_requests(requests));
	for result in results {
		match result {
			Ok(response) => println!("{}", response),
			Err(err) => eprintln!("error: {}", err),
		}
	}
```

The call to many_requests (not shown, for simplicity) has spawned three
asynchronous tasks, which we’ve labeled A, B, and C. block_on begins by
polling A, which starts connecting to example.com. As soon as this
returns Poll::Pending, block_on turns its attention to the next spawned
task, polling future B, and eventually C, which each begin connecting
to their respective servers.

When all the pollable futures have returned Poll::Pending, block_on goes
to sleep until one of the TcpStream::connect futures indicates that its
task is worth polling again.

All this execution takes place on a single thread, the three calls to
cheapo_request being interleaved with each other through successive polls
of their futures. An asynchronous call oﬀers the appearance of a single
function call running to completion, but this asynchronous call is
realized by a series of synchronous calls to the future’s poll method.
Each individual poll call returns quickly, yielding the thread so that
another async call can take a turn.

One important diﬀerence to keep in mind between asynchronous tasks and
threads is that switching from one async task to another happens only
at await expressions, when the future being awaited returns Poll::Pending.
This means that if you put a long-running computation in cheapo_request,
none of the other tasks you passed to spawn_local will get a chance to
run until it’s done. With threads, this problem doesn’t arise: the
operating system can suspend any thread at any point and sets timers to
ensure that no thread monopolizes the processor. Asynchronous code depends
on the willing cooperation of the futures sharing the thread. If you
need to have longrunning computations coexist with asynchronous code,
“Long Running Computations: yield_now and spawn_blocking” later in this
chapter describes some options.

### Async Blocks

In addition to asynchronous functions, Rust also supports asynchronous blocks.
Whereas an ordinary block statement returns the value of its last expression,
an async block returns a future of the value of its last expression. You can
use await expressions within an async block. An async block looks like an
ordinary block statement, preceded by the async keyword:

```
let serve_one = async {
	use async_std::net;
	// Listen for connections, and accept one.
	let listener = net::TcpListener::bind("localhost:8087").await?;
	let (mut socket, _addr) = listener.accept().await?;

	// Talk to client on `socket`....
};
```

Future versions of Rust will probably add syntax for
indicating an async block’s return type. For now, you can
work around the problem by spelling out the type of the
block’s ﬁnal Ok:

```
let future = async {
	...
	Ok::<(), std::io::Error>(())
};
```

Since Result is a generic type that expects the success and
error types as its parameters, we can specify those type
parameters when using Ok or Err as shown here.

### Building Async Functions from Async Blocks

Asynchronous blocks give us another way to get the same eﬀect as an
asynchronous function, with a little more ﬂexibility. For example, we
could write our cheapo_request example as an ordinary, synchronous
function that returns the future of an async block:

```
use std::io;
use std::future::Future;
fn cheapo_request<'a>(host: &'a str, port: u16, path: &'a str)
	-> impl Future<Output = io::Result<String>> + 'a
{
	async move {
		... function body ...
	}
}
```

When you call this version of the function, it immediately returns the
future of the async block’s value. This captures the function’s arguments
and behaves just like the future the asynchronous function would have
returned. Since we’re not using the async fn syntax, we need to write
out the impl Future in the return type, but as far as callers are
concerned, these two deﬁnitions are interchangeable implementations
of the same function signature.

This second approach can be useful when you want to do some computation
immediately when the function is called, before creating the future
of its result. For example, yet another way to reconcile cheapo_request
with spawn_local would be to make it into a synchronous function
returning a 'static future that captures fully owned copies of its arguments:

```
fn cheapo_request(host: &str, port: u16, path: &str) ->
	impl Future<Output = io::Result<String>> + 'static
{
	let host = host.to_string();
	let path = path.to_string();

	async move {
		... use &*host, port, and path ...
	}
}
```

This version lets the async block capture host and path as owned StrinG
values, not &str references. Since the future owns all the data it
needs to run, it is valid for the 'static lifetime. (We’ve spelled out +
'static in the signature shown earlier, but 'static is the default for
-> impl return types, so omitting it would have no eﬀect.)

Since this version of cheapo_request returns futures that are 'static,
we can pass them directly to spawn_local:

```
let join_handle = async_std::task::spawn_local(
	cheapo_request("areweasyncyet.rs", 80, "/")
);
... other work ...
let response = join_handle.await?;
```

### Spawning Async Tasks on a Thread Pool

The examples we’ve shown so far spend almost all their time waiting for I/O,
but some workloads are more of a mix of processor work and blocking. When
you have enough computation to do that a single processor can’t keep up,
you can use async_std::task::spawn to spawn a future onto a pool of worker
threads dedicated to polling futures that are ready to make progress.

```
async_std::task::spawn is used like
async_std::task::spawn_local:

use async_std::task;
let mut handles = vec![];
for (host, port, path) in requests {
	handles.push(task::spawn(async move {
		cheapo_request(&host, port, &path).await
	}));
}
...
```

Like spawn_local, spawn returns a JoinHandle value you can await to get the
future’s ﬁnal value. But unlikespawn_local, the future doesn’t have to wait
for you to call block_on before it gets polled. As soon as one of the
threads from the thread pool is free, it will try polling it.

In practice, spawn is more widely used than spawn_local, simply because
people like to know that their workload, no matter what its mix of
computation and blocking, is balanced across the machine’s resources.

One thing to keep in mind when using spawn is that the thread pool
tries to stay busy, so your future gets polled by whichever thread
gets around to it ﬁrst. An async call may begin execution on one
thread, block on an await expression, and get resumed in a diﬀerent
thread. So while it’s a reasonable simpliﬁcation to view an async
function call as a single, connected execution of code (indeed, the
purpose of asynchronous functions and await expressions is to encourage
you to think of it that way), the call may actually be carried out
by many diﬀerent threads.

If you’re using thread-local storage, it may be surprising to see the
data you put there before an await expression replaced by something
entirely diﬀerent afterward, because your task is now being polled by
a diﬀerent thread from the pool. If this is a problem, you should
instead use task-local storage; see the async-std crate’s documentation
for the task_local! macro for details.

### Async Iterators (Streams)

Async iterators in Rust are called "Streams" and are part of the futures crate. They're
like regular iterators but for asynchronous operations.

Stream Trait

```
use futures::stream::Stream;
use std::pin::Pin;
use std::task::{Context, Poll};

trait Stream {
    type Item;
    fn poll_next(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>
    ) -> Poll<Option<Self::Item>>;
}
```


### But Does Your Future Implement Send?

There is one restriction spawn imposes that spawn_local does not. Since
the future is being sent oﬀ to another thread to run, the future must
implement the Send marker trait. We presented Send in “Thread Safety: Send and
Sync”. A future is Send only if all the values it contains are
Send: all the function arguments, local variables, and even anonymous
temporary values must be safe to move to another thread.

This restriction is easy to trip over by accident. For example, the following
code looks innocent enough:

```
	use async_std::task;
	use std::rc::Rc;
	async fn reluctant() -> String {
		let string = Rc::new("ref-counted string".to_string());
		some_asynchronous_thing().await;
		format!("Your splendid string: {}", string)
	}
	task::spawn(reluctant());
```

An asynchronous function’s future needs to hold enough information for the
function to continue from an await expression. In this case, reluctant’s
future must use string after the await, so the future will, at least
sometimes, contain an Rc<String> value. Since Rc pointers cannot be safely
shared between threads, the future itself cannot be Send. And since spawn
only accepts futures that are Send, Rust objects:

```
error: future cannot be sent between threads safely
|
17
|
|
`Send`
|
task::spawn(reluctant());
^^^^^^^^^^^ future returned by `reluctant` is not
|
127 | T: Future + Send + 'static,
|
---- required by this bound in
`async_std::task::spawn`
|
= help: within `impl Future`, the trait `Send` is not
implemented
```

This error message is long, but it has a lot of helpful detail:

- It explains why the future needs to be Send: task::spawn requires it.
- It explains which value is not Send: the local variable string, whose type is Rc<String>.
- It explains why string aﬀects the future: it is in scope across the indicated await.


### Long Running Computations: yield_now and spawn_blocking

For a future to share its thread nicely with other tasks, its poll method
should always return as quickly as possible. But if you’re carrying out a
long computation, it could take a long time to reach the next await,
making other asynchronous tasks wait longer than you’d like for their
turn on the thread.

One way to avoid this is simply to await something occasionally. The
async_std::task::yield_now function returns a simple future designed
for this:

```
while computation_not_done() {
	... do one medium-sized step of computation ...
	async_std::task::yield_now().await;
}
```

For cases like this, you can use async_std::task::spawn_blocking. This
function takes a closure, starts it running on its own thread, and
returns a future of its return value. Asynchronous code can await
that future, yielding its thread to other tasks until the computation
is ready. By putting the hard work on a separate thread, you can let
the operating system take care of making it share the processor nicely.

For example, suppose we need to check passwords supplied by users
against the hashed versions we’ve stored in our authentication database.
For security, verifying a password needs to be computationally
intensive so that even if attackers get a copy of our database, they
can’t simply try trillions of possible passwords to see if any match.
The argonautica crate provides a hash function designed speciﬁcally
for storing passwords: a properly generated argonautica hash takes
a signiﬁcant fraction of a second to verify. We can use argonautica
(version 0.2) in our asynchronous application like this:

```
async fn verify_password(password: &str, hash: &str, key: &str)
-> Result<bool, argonautica::Error>
{
	// Make copies of the arguments, so the closure can be 'static.
	let password = password.to_string();
	let hash = hash.to_string();
	let key = key.to_string();

	async_std::task::spawn_blocking(move || {
		argonautica::Verifier::default()
		.with_hash(hash)
		.with_password(password)
		.with_secret_key(key)
		.verify()
	}).await
}
```

This returns Ok(true) if password matches hash, given key, a key for the
database as a whole. By doing the veriﬁcation in the closure passed to
spawn_blocking, we push the expensive computation onto its own thread,
ensuring that it will not aﬀect our responsiveness to other users’ requests.

### Comparing Asynchronous Designs

In many ways Rust’s approach to asynchronous programming resembles that
taken by other languages. For example, JavaScript, C#, and Rust all
have asynchronous functions with await expressions. And all these
languages have values that represent incomplete computations: Rust
calls them “futures,” JavaScript calls them “promises,” and
C# calls them “tasks,” but they all represent a value that
you may have to wait for.

Rust’s use of polling, however, is unusual. In JavaScript and C#, an
asynchronous function begins running as soon as it is called, and
there is a global event loop built into the system library that
resumes suspended async function calls when the values they were
awaiting become available. In Rust, however, an async call does
nothing until you pass it to a function like block_on, spawn,
or spawn_local that will poll it and drive the work to completion.
These functions, called executors, play the role that other
languages cover with a global event loop.

Because Rust makes you, the programmer, choose an executor to poll your
futures, Rust has no need for a global event loop built into the system.
The async-std crate oﬀers the executor functions we’ve used in this
chapter so far, butthe tokio crate, which we’ll use later in this chapter,
deﬁnes its own set of similar executor functions. And toward the end of
this chapter, we’ll implement our own executor. You can use all three in
the same program.

### A Real Asynchronous HTTP Client

```
pub async fn many_requests(urls: &[String])
-> Vec<Result<String, surf::Exception>>
{
	let client = surf::Client::new();
	let mut handles = vec![];
	for url in urls {
		let request = client.get(&url).recv_string();
		handles.push(async_std::task::spawn(request));
	}

	let mut results = vec![];
	for handle in handles {
		results.push(handle.await);
	}
	results
}

fn main() {
	let requests = &["http://example.com".to_string(),
		"https://www.red-bean.com".to_string(),
		"https://en.wikipedia.org/wiki/Main_Page".to_string()];
	let results = async_std::task::block_on(many_requests(requests));

	for result in results {
		match result {
			Ok(response) => println!("*** {}\n", response),
			Err(err) => eprintln!("error: {}\n", err),
		}
	}
}
```


20 references

[explain any feature in words](https://riptutorial.com/rust)

[the cargo book](https://doc.rust-lang.org/cargo/index.html)

[Rust Design Patterns](https://rust-unofficial.github.io/patterns/intro.html)

[Effective Rust(35 Specific Ways to Improve Your Rust Code)](https://www.lurklurk.org/effective-rust/cover.html)

[Rust by Example](https://doc.rust-lang.org/rust-by-example/index.html#rust-by-examples)

[Cooking with Rust](https://rust-lang-nursery.github.io/rust-cookbook/intro.html)

This Rust Cookbook is a collection of simple examples that demonstrate good
practices to accomplish common programming tasks, using the crates of the
Rust ecosystem.

Read more about Rust Cookbook, including tips for how to read the book, how
to use the examples, and notes on conventions.

- Compression
- Cryptography


[The Little Book of Rust Macros](https://veykril.github.io/tlborm/)

[The Rustonomicon](https://doc.rust-lang.org/nomicon/)

[Asynchronous Programming in Rust](https://rust-lang.github.io/async-book/)

[async/.await introduction](https://blog.ediri.io/how-to-asyncawait-in-rust-an-introduction)

[async-std](https://book.async.rs/overview/async-std.html)

[tokio](https://tokio.rs/tokio/tutorial/async)

[async concept](https://dev.to/rogertorres/asynchronous-rust-basic-concepts-44ed)

[async/.await](https://www.youtube.com/watch?v=9_3krAQtD2k&t=3004s)

[async decision](https://without.boats/blog/await-decision/)

[async/.await](https://os.phil-opp.com/async-await/)

[futures](https://aturon.github.io/blog/2016/08/11/futures/)


# smol

## smol executor

###  Core Architecture

1. Main Components

  The executor consists of four main types:
  - Executor<'a> - Multi-threaded executor with work-stealing capabilities (src/lib.rs:91)
  - LocalExecutor<'a> - Single-threaded executor (src/lib.rs:437)
  - StaticExecutor - Leaked version of Executor optimized for static usage (src/static_executors.rs:138)
  - StaticLocalExecutor - Leaked version of LocalExecutor (src/static_executors.rs:325)

2. State Management

  The core state is managed through a State struct (src/lib.rs:653) containing:
  - Global queue: ConcurrentQueue<Runnable> for cross-thread task sharing
  - Local queues: RwLock<Vec<Arc<ConcurrentQueue<Runnable>>>> for work-stealing optimization
  - Notification system: AtomicBool and Mutex<Sleepers> for efficient wake-ups
  - Active tasks: Mutex<Slab<Waker>> tracking running tasks

###  Task Spawning and Scheduling

  1. Task Creation Process

  When spawning a task (src/lib.rs:165):
  1. Future wrapping: The future is wrapped with AsyncCallOnDrop for cleanup
  2. Task building: Uses async-task::Builder to create a (Runnable, Task) pair
  3. Waker registration: Stores the task's waker in the active slab
  4. Immediate scheduling: Calls runnable.schedule() to queue the task

  2. Scheduling Strategy

  The scheduler function (src/lib.rs:353) simply:
  - Pushes runnables to the global queue via state.queue.push(runnable)
  - Notifies sleeping threads through state.notify()

###  Polling and Wake-up System

  1. Ticker Architecture

  The Ticker struct (src/lib.rs:832) handles individual task polling:
  - Sleep management: Tracks sleeping state with unique IDs
  - Notification handling: Manages waker registration/deregistration
  - Task polling: Runs futures exactly once per tick

  2. Runner Work-Stealing

  The Runner struct (src/lib.rs:960) implements sophisticated work-stealing:
  - Local-first: Always tries local queue first (src/lib.rs:997)
  - Global stealing: Steals from global queue with batch optimization (src/lib.rs:1002-1004)
  - Peer stealing: Randomly selects other runners to steal from (src/lib.rs:1008-1027)
  - Fairness mechanism: Periodically steals from global queue every 64 ticks (src/lib.rs:1037-1040)

  3. Notification System

  The Sleepers struct (src/lib.rs:758) efficiently manages sleeping threads:
  - ID-based tracking: Assigns unique IDs to sleeping tickers
  - Batch notifications: Can wake multiple threads efficiently
  - Memory optimization: Reuses IDs through a free list

###  Thread Safety and Concurrency

  1. Send/Sync Implementation

  - Executor: Both Send and Sync - can be shared across threads (src/lib.rs:100-102)
  - LocalExecutor: Neither Send nor Sync - confined to single thread (src/lib.rs:442)
  - State sharing: All internal state uses appropriate synchronization primitives

  2. Lock-Free Operations

  - Queue operations: Uses concurrent-queue for lock-free push/pop
  - Atomic notifications: AtomicBool for efficient wake-up coordination
  - Minimal contention: Locks only held briefly for critical sections

  3. Work-Stealing Synchronization

  - Read-write locks: Local queue registration uses RwLock for concurrent access
  - Atomic operations: State pointers managed with atomic compare-and-swap
  - Randomized stealing: Reduces contention through random selection

###  Execution Modes

  1. Non-blocking Execution

  - try_tick(): Polls one task if available, returns immediately (src/lib.rs:306)
  - Immediate return: No waiting if no tasks are ready

  2. Blocking Execution

  - tick(): Waits for a task to become available, then polls once (src/lib.rs:329)
  - run(): Executes tasks continuously until the provided future completes (src/lib.rs:348)

  3. Execution Strategy in run()

  The run() method (src/lib.rs:737) uses a sophisticated approach:
  - Concurrent execution: Runs provided future alongside executor loop
  - Batch processing: Processes 200 tasks before yielding (src/lib.rs:744)
  - Cooperative yielding: Uses future::yield_now() to prevent starvation
  - Early termination: Stops when the main future completes

###  Memory Management and Optimization

  1. State Allocation

  - Lazy initialization: State allocated only when first accessed (src/lib.rs:366)
  - Arc-based sharing: State shared through reference counting
  - Pinned memory: State is pinned to prevent moves during async operations

  2. Static Optimization

  Static executors (src/static_executors.rs) provide optimizations:
  - No drop overhead: Never deallocated, eliminating cleanup costs
  - Direct state access: Avoids atomic pointer dereference
  - Simplified scheduling: Fewer synchronization requirements

  3. Task Cleanup

  - Automatic cleanup: AsyncCallOnDrop ensures tasks are removed from active slab
  - Waker management: Active wakers are properly cleaned up on executor drop
  - Queue draining: Remaining tasks are drained during executor destruction

###  Performance Characteristics

  1. Scalability Features

  - Work-stealing: Excellent load balancing across threads
  - Lock-free queues: Minimal contention for task scheduling
  - Local queues: Improved cache locality for single-threaded work

  2. Fairness Mechanisms

  - Global queue stealing: Prevents local queue starvation
  - Random stealing: Distributes load evenly across runners
  - Batch processing: Balances throughput with responsiveness

  3. Memory Efficiency

  - Slab allocation: Efficient waker storage with reused slots
  - Bounded local queues: 512-task limit prevents unbounded growth
  - Minimal metadata: Compact state representation

  The smol executor achieves its "smol" nature through careful optimization of common cases while maintaining full async compatibility and excellent multi-threaded
  performance characteristics.


## smol task

###  Overview

  The async-task crate provides a foundational abstraction for building async executors. It implements a lightweight, efficient task system that separates the concerns of
  task storage, scheduling, and execution.

###  Core Architecture

####  Key Components

  1. Task (task.rs:49)
  - A handle to a spawned future that can be awaited for its output
  - Contains a raw pointer to the heap-allocated task data and metadata
  - Implements Future trait to be awaitable
  - Provides cancellation capabilities via cancel() and detach() methods

  2. Runnable (runnable.rs:694)
  - A handle that can execute a task by polling its future
  - Only exists when the task is scheduled for running
  - Calling run() polls the future once, then vanishes until rescheduled
  - Contains the same raw pointer as Task but with different semantics

  3. Header (header.rs:18)
  - Stores task metadata and state in a heap-allocated structure
  - Contains atomic state flags, awaiter waker, vtable, and user metadata
  - Manages waker registration and notification through register() and notify()

  4. RawTask (raw.rs:79)
  - Low-level task representation with pointers to all task components
  - Handles memory layout, allocation, and deallocation
  - Implements the core task execution logic via vtable functions

####  State Management (state.rs)

  The system uses atomic bit flags for task state:

  - SCHEDULED (bit 0): Task is scheduled for running
  - RUNNING (bit 1): Task is currently executing
  - COMPLETED (bit 2): Future returned Poll::Ready
  - CLOSED (bit 3): Task is canceled or output consumed
  - TASK (bit 4): Task handle still exists
  - AWAITER (bit 5): Someone is waiting on the task
  - REGISTERING (bit 6): Currently registering an awaiter
  - NOTIFYING (bit 7): Currently notifying awaiters

  Reference counting is stored in upper bits (starting at bit 8).

####  Task Lifecycle

  1. Creation (runnable.rs:362)

  let (runnable, task) = async_task::spawn(future, schedule);

  - Allocates heap memory for header, scheduler, and future
  - Initializes state to SCHEDULED | TASK | REFERENCE
  - Returns both Runnable and Task handles

  2. Scheduling (runnable.rs:738)

  runnable.schedule(); // Calls the user-provided schedule function

  - Passes Runnable to the user's schedule function
  - Schedule function typically adds it to an executor queue
  - Does not modify task state, just dispatches for execution

  3. Execution (raw.rs:484)

  let woke_while_running = runnable.run();

  Execution flow:
  1. Create execution context with task's waker
  2. Update state: SCHEDULED → RUNNING
  3. Poll the future with Future::poll()
  4. Handle result:
    - Poll::Ready(output): Store output, mark COMPLETED
    - Poll::Pending: Check if rescheduled while running

  Key insight: If the task wakes itself during execution (yields), run() returns true and the task gets rescheduled immediately.

  4. Completion/Cancellation

  - Completion: Output stored, COMPLETED flag set, awaiters notified
  - Cancellation: CLOSED flag set, future dropped, cleanup performed

####  Memory Layout (raw.rs:106)

  Tasks use a carefully designed memory layout:
```
  [ Header<M> ][ Schedule Function S ][ Union { Future F | Output T } ]
```

  The future and output share the same memory location since they're never needed simultaneously.

  Waker Implementation (raw.rs:139)

  Waker vtable operations:
  - clone_waker: Increments reference count
  - wake/wake_by_ref: Marks task as SCHEDULED, calls schedule function
  - drop_waker: Decrements reference count, potentially triggers cleanup

  Optimization: If task is already scheduled, waking just synchronizes memory without rescheduling.

  Scheduling Integration

  The design is executor-agnostic:

```
  let schedule = |runnable| queue.send(runnable).unwrap();
  let (runnable, task) = async_task::spawn(future, schedule);
```

  - Users provide a schedule function that handles Runnable placement
  - Can be a simple queue, priority queue, work-stealing deque, etc.
  - Supports metadata for custom scheduling decisions

###  Key Design Patterns

  1. Zero-Cost Abstraction

  - No runtime overhead when not used (scheduling info is zero-sized by default)
  - Efficient atomic operations with minimal state transitions

  2. Memory Safety

  - Reference counting prevents use-after-free
  - Careful state machine prevents race conditions
  - Panic safety with guard structures

  3. Flexibility

  - Generic over future type, output type, scheduler, and metadata
  - Supports both Send and !Send futures via spawn_local()
  - Optional panic propagation with std feature

  4. Performance Optimizations

  - Futures ≥2KB allocated on heap automatically (runnable.rs:516)
  - Waker optimizations for zero-sized schedule functions
  - Lock-free atomic operations throughout

###  Usage Example

```
  // Simple executor
  let (sender, receiver) = flume::unbounded();
  let schedule = move |runnable| sender.send(runnable).unwrap();

  // Spawn task
  let (runnable, task) = async_task::spawn(async { 42 }, schedule);
  runnable.schedule();

  // Execute tasks
  while let Ok(runnable) = receiver.recv() {
      runnable.run();
  }

  // Await result  
  let result = smol::future::block_on(task); // 42
```

This design provides a solid foundation for async executors like smol, tokio, and others,
offering efficient task management with flexible scheduling capabilities.



# tokio vs. io_uring

## overview

### how does tokio provide upper layer interface for io_uring?

### Rust does not yet allow traits to have asynchronous methods.


# Rust async vs. ublk coroutine

## overview

### async/await vs. io_uring

[tokio](https://moslehian.com/posts/2023/1-intro-async-rust-tokio/)

[tokio](https://github.com/rust-lang/rust/issues/60589)

[monoio](https://www.cloudwego.io/blog/2023/04/17/introducing-monoio-a-high-performance-rust-runtime-based-on-io-uring/)


### questions

1) how to let io_uring's completion(cqe) move on/wait up rust .await?

2) can join_all(local_tasks).await really works?

3) bytedance example?

### how to write future to support io_uring wakeup in libublk-rs?

1) design libublk-rs future for io_uring?

2) how to integrate network code with other future implementation?

3) is it possible to customize future of tokio?

- how does tokio/async_std deal with multiple different kind of futures?


### understand await/async

#### .await completion condition is implemented in future's poll(), so each
async function has to implement one kind of future?

- io_uring submission future: for monitoring if the io_uring IO is completed

- meta completion future: for checking if the meta IO is done


#### how to support nested futures?

#### join(f1, f2)?

#### where is future allocated from? heap or stack?

#### how to support one future for waiting multiple IOs submitted via io_uring?

#### how to support io submission retry(-EAGAIN)?


## async/await design for rublk-qcow2


### plain IO


### meta IO

#### plain IO depends on meta data, so:

- meta data is started in current plain IO code path

- meta data(in-progress) is needed from another plain IO code path,

- meta data count limit:
	-- lru style, if the last meta cache is in-progress, start the new meta IO
	until the oldest cache is done
	-- so wait on the oldest cache

#### meta data lifetime


# Rust Closures Under the Hood

[Comparing impl Fn and Box\<dyn Fn\>](https://eventhelix.com/rust/rust-to-assembly-return-impl-fn-vs-dyn-fn/)


## Key Takeaways

The Rust compiler captures the environment and stores it in a closure
environment struct.

If a closure is returned as impl Fn, the closure environment is stored
on the stack and a thin pointer is returned to the caller.

In many cases the compiler completely inlines the closure and the
closure environment is not stored on the stack.

If a closure is returned as a Box<dyn Fn>, the closure environment is
stored on the heap and a fat pointer is returned to the caller. The fat
pointer contains the address of the closure environment and the address
of the vtable.

The vtable contains the destructor for the closure environment, the size
and alignment of the closure environment, and the call method for the closure.

# Understanding Async Await in Rust:  

[From State Machines to Assembly Code](https://eventhelix.com/rust/rust-to-assembly-async-await/)


# Rust async function and its parameter's lifetime

## overview

[thread::scope](https://doc.rust-lang.org/std/thread/fn.scope.html)


[Rust async function parameters and lifetimes](https://stackoverflow.com/questions/75291899/rust-async-function-parameters-and-lifetimes)

async functions return a future, and that future holds the string reference . The
do_async_thing function in my answer is essentially the de-sugared form of the
async function in your question. 

[Lifetime trouble with traits and Box::pin](https://www.reddit.com/r/rust/comments/jsxtsz/lifetime_trouble_with_traits_and_boxpin/)

