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
    static if (name.length >= 2 && name[0 .. 2] == "__") {} // compiler-generated
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

private struct Probe
{
    int n;
    int get() const { return n; }
    int twice() const pure { return 2 * n; }
    struct Inner { void touch() { } }
}

private int freeImpure() { return 0; }
private int freePure() pure { return 0; }

unittest
{
    // This module is `pure:`, which covers freeImpure; the struct members are
    // what the label misses.
    static assert(impureFunctions!(nano.pureaudit)() == ["pureaudit.Probe.get", "pureaudit.Probe.Inner.touch"]);
}
