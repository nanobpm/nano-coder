/// Compile-time check that a module is all pure. `pure:` at the top of a
/// module covers its free functions (and templates), but not the member
/// functions of its structs and classes; this walks those too.
/// nano.pure_core_test runs it over every module that starts with `pure:`.
module nano.pureaudit;
@safe:
pure:

import std.traits : FunctionAttribute, functionAttributes, isSomeFunction;

/// Names of the non-template functions declared in module `M`, or in the
/// structs and classes it declares, that are not `pure`.
string[] impureFunctions(alias M)()
{
    string[] found;
    static foreach (name; __traits(allMembers, M))
    {{
        static if (__traits(compiles, __traits(getMember, M, name)))
        {
            alias S = __traits(getMember, M, name);
            static if (__traits(compiles, __traits(parent, S)) && __traits(isSame, __traits(parent, S), M))
                found ~= check!(M, name)(M.stringof[7 .. $]);
        }
    }}
    return found;
}

/// Member `name` of `P` (a module or an aggregate): its overloads if it is a
/// function, its members if it is a struct or class.
private string[] check(alias P, string name)(string path)
{
    string[] found;
    // Other `__` names are compiler-generated; user-written constructors,
    // destructors and postblits are `__ctor`, `__dtor` and `__postblit`.
    static if (name.length >= 2 && name[0 .. 2] == "__" && name != "__ctor" && name != "__dtor" && name != "__postblit") {}
    else static if (is(__traits(getMember, P, name) == struct) || is(__traits(getMember, P, name) == class))
    {
        alias A = __traits(getMember, P, name);
        static foreach (m; __traits(allMembers, A))
        {{
            static if (__traits(compiles, __traits(getMember, A, m)))
            {
                static if (__traits(compiles, __traits(parent, __traits(getMember, A, m)))
                    && __traits(isSame, __traits(parent, __traits(getMember, A, m)), A))
                    found ~= check!(A, m)(path ~ "." ~ name);
            }
        }}
    }
    else
    {
        static foreach (f; __traits(getOverloads, P, name))
        {{
            static if (isSomeFunction!f && !(functionAttributes!f & FunctionAttribute.pure_))
                found ~= path ~ "." ~ name;
        }}
    }
    return found;
}

/// Functions of module `M` (as `impureFunctions` walks them) that are only
/// weakly pure: a parameter (`ref`, `out`, or a type reaching mutable
/// memory) lets a call change what the caller passed. A method may still
/// update its own struct. Results and errors come back as return values
/// (`Option`, `Result`, a new value) instead.
string[] weaklyPureFunctions(alias M)()
{
    string[] found;
    static foreach (name; __traits(allMembers, M))
    {{
        static if (__traits(compiles, __traits(getMember, M, name)))
        {
            alias S = __traits(getMember, M, name);
            static if (__traits(compiles, __traits(parent, S)) && __traits(isSame, __traits(parent, S), M))
                found ~= checkWeak!(M, name)(M.stringof[7 .. $]);
        }
    }}
    return found;
}

private string[] checkWeak(alias P, string name)(string path)
{
    import std.traits : Parameters, ParameterStorageClass, ParameterStorageClassTuple, hasAliasing,
        isMutable;
    string[] found;
    // Constructors take arguments too; other `__` names are compiler-generated.
    static if (name.length >= 2 && name[0 .. 2] == "__" && name != "__ctor") {}
    else static if ((is(__traits(getMember, P, name) == struct) || is(__traits(getMember, P, name) == class))
        && __traits(getVisibility, __traits(getMember, P, name)) == "private") {} // inside a pure entry point
    else static if (is(__traits(getMember, P, name) == struct) || is(__traits(getMember, P, name) == class))
    {
        alias A = __traits(getMember, P, name);
        static foreach (m; __traits(allMembers, A))
        {{
            static if (__traits(compiles, __traits(getMember, A, m)))
            {
                static if (__traits(compiles, __traits(parent, __traits(getMember, A, m)))
                    && __traits(isSame, __traits(parent, __traits(getMember, A, m)), A))
                    found ~= checkWeak!(A, m)(path ~ "." ~ name);
            }
        }}
    }
    else
    {
        static foreach (f; __traits(getOverloads, P, name))
        {{
            static if (isSomeFunction!f && (functionAttributes!f & FunctionAttribute.pure_))
            {
                bool weak; // a method may update its own struct (`this`): parsers and state machines do
                alias stc = ParameterStorageClassTuple!f;
                static foreach (i, T; Parameters!f)
                {
                    static if ((stc[i] & (ParameterStorageClass.ref_ | ParameterStorageClass.out_)) && isMutable!T)
                        weak = true;
                    else static if (reachesMutable!T)
                        weak = true;
                }
                if (weak) found ~= path ~ "." ~ name;
            }
        }}
    }
    return found;
}

/// Whether a value of type `T` reaches memory it may change: a pointer,
/// slice, associative array or class reference whose target is mutable,
/// directly or through fields. (`T.init` can't tell: a null slice converts to
/// immutable.) Delegates and functions are callbacks, not data, so they pass.
template reachesMutable(T, Seen...)
{
    import std.traits : isMutable, isPointer, isDynamicArray, isAssociativeArray, isStaticArray, isSomeFunction,
        FieldTypeTuple, KeyType, ValueType, PointerTarget, Unqual;
    import std.meta : anySatisfy, staticIndexOf;
    // A recursive type (a message holding messages) is decided at its first
    // visit; seeing it again adds nothing.
    static if (staticIndexOf!(Unqual!T, Seen) >= 0) enum reachesMutable = false;
    else
    {
        template inner(U) { enum inner = reachesMutable!(U, Unqual!T, Seen); }
        static if (isSomeFunction!T || is(T == delegate)) enum reachesMutable = false;
        else static if (isPointer!T)
            enum reachesMutable = isMutable!(PointerTarget!T) || inner!(PointerTarget!T);
        else static if (isDynamicArray!T)
            enum reachesMutable = isMutable!(typeof(T.init[0])) || inner!(typeof(T.init[0]));
        else static if (isStaticArray!T) enum reachesMutable = inner!(typeof(T.init[0]));
        else static if (isAssociativeArray!T)
            // A table is shared, not copied: a mutable one lets the callee
            // `remove` entries from its caller's table whatever its values are.
            enum reachesMutable = isMutable!T || isMutable!(ValueType!T) || inner!(ValueType!T) || inner!(KeyType!T);
        else static if (is(T == class) || is(T == interface)) enum reachesMutable = isMutable!T;
        else static if (is(T == struct)) enum reachesMutable = anySatisfy!(inner, FieldTypeTuple!T);
        else enum reachesMutable = false;
    }
}

private struct Probe
{
    int n;
    int get() const { return n; }
    int twice() const pure { return 2 * n; }
    struct Inner { void touch() { } }
    this(int x) { n = x; }
    this(this) { }
    ~this() { }
}

private int freeImpure() { return 0; }

// Probes for weaklyPureFunctions: mutable through ref/out, a slice, a
// pointer, or a struct field; const and immutable inputs and plain values pass.
private void weakRef(ref int x) pure { }
private void weakOut(out int x) pure { x = 1; }
private void weakSlice(int[] xs) pure { }
private void weakPointer(int* p) pure { }
private struct Holder { int[] xs; }
private void weakField(Holder h) pure { }
private int strongConst(const int[] xs, const(int)* p, const Holder h) pure { return 0; }
private int strongValue(int x, string s, immutable(int)[] xs, const ref Holder h) pure { return x; }
/// A constructor that changes its argument (package, so the private-struct
/// exemption doesn't hide it).
package struct CtorProbe { int n; this(ref int x) pure { n = x++; } }
private struct Counter { int n; void bump() pure { n++; } } // a method may update its own struct

private int freePure() pure { return 0; }

unittest
{
    // This module is `pure:`, which covers freeImpure; the struct members are
    // what the label misses.
    static assert(impureFunctions!(nano.pureaudit)() == ["pureaudit.Probe.get", "pureaudit.Probe.Inner.touch", "pureaudit.Probe.__ctor",
        "pureaudit.Probe.__postblit", "pureaudit.Probe.__dtor", "pureaudit.Probe.opAssign"]);
    static assert(weaklyPureFunctions!(nano.pureaudit)() == ["pureaudit.weakRef", "pureaudit.weakOut",
        "pureaudit.weakSlice", "pureaudit.weakPointer", "pureaudit.weakField", "pureaudit.CtorProbe.__ctor"]);
    static assert(reachesMutable!(int[]) && reachesMutable!(int*) && reachesMutable!Holder && reachesMutable!(int[string])
        && reachesMutable!(const(int)[string]) && reachesMutable!(immutable(int)[string]));
    static assert(!reachesMutable!(const(int[string])) && !reachesMutable!(immutable(int[string])));
    static assert(!reachesMutable!(const(int)[]) && !reachesMutable!string && !reachesMutable!(const Holder)
        && !reachesMutable!int && !reachesMutable!(int delegate() pure));
}
