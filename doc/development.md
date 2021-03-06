# Development environment and compiler

Use Linux instead of OSX as the tooling for ELF files is more complete than for
Mach-O on OSX. Also Swift libraries on OSX have have extra code for Objective-C
integration which just causes more issues.

~~I currently use the swift-2.2-stable branch to reduce the amount of compiler
issues caused by tracking the latest and greatest however there is one issue
stopping the use of the Swift releases that can be downloaded from swift.org.~~

Ive moved to Swift-3.0 since this is where the latest changes are happening
and I will need to move to it anyway at some point so its easier to track the
syntax changes as they occur. However you will need to compile a custom version
of Swift and its Stdlib for building the kernel but a normal snapshot for the
utils that are run on Linux.


## Red zone

Because we are writing kernel code that has to run interrupt and exception
handlers in kernel mode we need to make sure that the code from the Swift
compiler and Stdlib libraries do not use the [redzone](https://en.wikipedia.org/wiki/Red_zone_(computing)).
Currently there isn't a `-disable-red-zone` option for swiftc like there is for
clang so swift and stdlib need to be recompiled to disable its use.

I forked swift and added a `-disable-red-zone` option for compiling and removed
the floating point code and other unneeded bits from Stdlib so that it could be
compiled without using SSE registers. See https://github.com/spevans/swift/blob/kernel-lib/KERNEL_LIB.txt
for how to build and install the compiler


## Using the compiler

When compiling you can compile related source files into a module and then link
the modules together or compile all source files at once and produce one .o file.
Obviously with lots of files it will eventually become slow recompiling them
every time but currently its useful since the `-whole-module-optimization` flag
can be used.

Compilation command looks something like:

```
swift -frontend -gnone -O -Xfrontend -disable-red-zone -Xcc -mno-red-zone -Xcc -mno-mmx -Xcc -mno-sse -Xcc -mno-sse2 -parse-as-library -import-objc-header <file.h> -whole-module-optimization -module-name MyModule -emit-object -o <output.o> <file1.swift> <file2.swift>
```

`-gnone` disables debug information which probably isn't very useful until you
have some sort of debugger support

`-O` is for optimisation, the other options being `-Onone` which turns it off
but produces a larger amount of code and `-Ounchecked` which is `-O` but without
extra checks after certain operations. `-O` produces good code but does tend to
inline everything into one big function which can make it hard to workout what
went wrong when an exception handler simply gives the instruction pointer as the
source of an error.

`-Xfrontend -disable-red-zone` ensures that code generated from the swiftc
doesn't generate red zone code.

`-Xcc -mno-red-zone` tells the `clang` compiler not to use the red zone on any
files it compiles. `clang` is used if there is any code in the header file you
use which will probably be the case as will be shown.

`-Xcc -mno-mmx -Xcc -mno-sse -Xcc -mno-sse2` uses clang options to tell swiftc
not to use MMX/SSE/SSE2

`-parse-as-library` means that the code is not a script.

`-import-objc-header`
allows a .h header file to be imported that allows access to C function and type
definitions.

`-module-name` is required although is only used in fully qualifying the method
and function names. However actual module files are not created with this option.

## Libraries

Now that a .o ELF file has been produced it needs to be linked to a final
executable. Swift requires that its stdlib is linked in as this provides some
basic functions that are needed by Swift at runtime.

The library name is `libswiftCore.a` and should be in `lib/swift_static/linux`
under the install directory.

`libswiftCore.a` relies on libc, libcpp and a few other system libraries
however they wont be available so the missing functions need to be emulated. The
full list of symbols that need to be implemented is [here](https://github.com/spevans/swift-project1/blob/master/doc/symbols.txt)

## C & assembly required to get binary starting up

The libcpp functions consist of the usual `new()`, `delete()` and a few
`std::_throw_*` functions however the bulk of them are `std::string*`. Note
that not every function needs to be implemented but require at least a
function declaration. An example libcpp, written in C to simplify building
can be seen [here](https://github.com/spevans/swift-project1/blob/master/fakelib/linux_libcpp.c).

The libc functions include the  usual `malloc`, `free` and `malloc_usable_size`
(although there is no need for `realloc`), `mem*`, `str*` and various versions
of `putchar`.

These all need to be written, example versions can be seen [here](https://github.com/spevans/swift-project1/tree/master/fakelib). These functions will form the C
interface between your Swift code and the machine it is running on.

Note that using debug versions of swift and libswiftCore.a will increase the
number of undefined symbols because some of the  C++ string functions are not
inlined anymore and so must be implemented. Currently I have found no benefit to
using the debug versions since they also increase the size of the binary and in
addition require more stack space.

A list of library calls made for the following simple 'Hello World' can be seen
[here](https://github.com/spevans/swift-project1/blob/master/doc/startup_calls.txt)
```swift
@_silgen_name("startup")
public func startup() {
    print("Hello World!")
}
```

## Stdlib

As I was maintaining a separate branch of the swift compiler I decided to remove
some bits of Stdlib mostly to remove floating point and the use of SSE. I also
removed the math functions (sin, cos, etc) as these are not needed and help
reduce the size of the stdlib library file.

## Swift modules

I originally use Swift modules when building the project, making each
subdirectory (kernel/devices, kernel/init, kernel/traps etc) into their own
module and then linked them all afterwards. However there were two problems with
this:

1. Circular dependencies between modules. If module A needed to use a function
in module B and vice versa they couldn't as module A would require module B to
built first so that it could then be imported however this would fail as B also
needed A to be built.

2. `-whole-module-optimization` cannot be used to active the best code output.

However the downside of not using modules is that build time is increased as
everything is compiled together. For a small project this is not such an issue
but for a large kernel it could be.

I may revisit this decision later I think the main problem was that I split the
core up into modules when they should have just been one in the first place.
If there are eventually multiple device drivers and other parts that dont have
interdependencies on each other then it should be possible to do it this way.
Swift modules compile to 2 files, the object file and a binary header file that
is used by the `import` statement so it should not be a problem in the future to
take the ELF object file and load it dynamically into the kernel in some way.


## Why is there so much C in the code?

The fakelib directory contains all the symbols required to satisfy the
linker even though a lot of them are left unimplemented and simply print
a message and then halt. Most of the functions do the bare minimum to
satisfy the Swift startup or pretend to (eg the pthread functions dont
actually do any locking or unlocking etc).

When a Swift function is first called there is some global
initialisation performed in the libraries (wrapped in a `pthread_once()/
dispatch_once()`). This calls `malloc()/free()` and some C++ string
functions so all of the C code is required to perform this basic
initialisation. The TTY driver in C is required for any debugging / oops
messages until Swift is initialised and can take over the display.

Originally I had planned to add more functionality in Swift but it took
longer than I expected to get this far although I hope to add more
memory management and some simple device drivers to see how easy it is
to do in Swift.


## Will it build on OSX?

Currently it will not build on OSX. I originally started developing on OSX
against the libswiftCore.dylib shipped with the latest Xcode including writing
a static linker to link the .dylib with the stub C functions to produce a
binary. This was working however I got stuck doing the stubs for the Obj-C
functions. Then Swift went open source and since the linux library is not
compiled with Obj-C support it removed a whole slew of functions and symbols
that would need to be supported.

The linux version also has the advantage that it builds a more efficient binary
since it is using proper ELF files and the standard ld linker. The static linker
I wrote just dumps the .dylib and relocates it in place but it suffers from the
fact that ZEROFILL sections have to be stored as blocks of zeros in the binary
and there is no optimisation of cstring sections etc. Also, changes in the
latest .dylib built from the Swift repo seem to add some new header flags which
I have yet to support. It may be possible to build against the static stdlib on
OSX but at the moment its not that interesting for me to do. As of now the OSX
fakelib support has been removed.
