/// Compile-time audit of class-typed storage: every field (of a struct or
/// class) and every module-level variable whose type is a bare class or
/// interface reference is reported, unless it is marked `@nullable("why")`.
///
/// A bare reference says nothing about whether null is a state the reader
/// must handle. Its replacements say it in the type:
///
/// - `NotNull!C`: always there (construction halts on null);
/// - `Option!C`: may be absent, and using it forces the absent case;
/// - `@nullable("why") C`: a reviewed exception, counted by check-safe.
///
/// The compiler resolves the types, so `auto`, aliases and types from other
/// modules are all seen. It can't see inside function bodies: locals,
/// parameters and `is null` tests there are left to scripts/class-null.awk.
/// Arrays and associative arrays of classes are not checked.
///
/// Run by `null_audit_test.d`, which imports every module.
module nano.nullaudit;
@safe:

import std.traits : Unqual, isSomeFunction;
import nano.option : nullable;

/// Is `T` (ignoring const/immutable/shared) a class or interface reference?
enum isBareRef(T) = is(Unqual!T == class) || is(Unqual!T == interface);

/// Was the symbol declared `@nullable(...)`?
template hasNullableMark(alias sym)
{
    enum hasNullableMark = () {
        bool found;
        static foreach (a; __traits(getAttributes, sym))
            static if (is(typeof(a) == nullable)) found = true;
        return found;
    }();
}

/// Names of the `@nullable` symbols in module `M` (fields and globals).
string[] markedNullable(alias M)() { return walkModule!(M, true)(); }

/// Unmarked bare class references declared in module `M`, as
/// "module.Type.field: Class" lines.
string[] bareRefs(alias M)() { return walkModule!(M, false)(); }

private string[] walkModule(alias M, bool marked)()
{
    string[] found;
    static foreach (name; __traits(allMembers, M))
    {{
        static if (__traits(compiles, __traits(getMember, M, name)))
        {
            alias S = __traits(getMember, M, name);
            static if (__traits(compiles, __traits(parent, S)) && __traits(isSame, __traits(parent, S), M))
            {
                static if (is(S == struct) || is(S == class))
                    found ~= walkAggregate!(S, marked)(M.stringof[7 .. $] ~ "." ~ name);
                else static if (!is(S) && !isSomeFunction!S && __traits(compiles, { auto p = &S; })
                    && isBareRef!(typeof(S)))
                {
                    if (hasNullableMark!S == marked)
                        found ~= M.stringof[7 .. $] ~ "." ~ name ~ ": " ~ typeof(S).stringof;
                }
            }
        }
    }}
    return found;
}

private string[] walkAggregate(S, bool marked)(string path)
{
    string[] found;
    static foreach (i, F; typeof(S.tupleof))
    {{
        static if (isBareRef!F)
            if (hasNullableMark!(S.tupleof[i]) == marked)
                found ~= path ~ "." ~ __traits(identifier, S.tupleof[i]) ~ ": " ~ F.stringof;
    }}
    // Types declared inside this one.
    static foreach (name; __traits(allMembers, S))
    {{
        static if (__traits(compiles, __traits(getMember, S, name)))
        {
            alias N = __traits(getMember, S, name);
            static if ((is(N == struct) || is(N == class)) && !is(N == S)
                && __traits(compiles, __traits(parent, N)) && __traits(isSame, __traits(parent, N), S))
                found ~= walkAggregate!(N, marked)(path ~ "." ~ name);
        }
    }}
    return found;
}

unittest
{
    static class C {}
    static struct Clean { int n; string s; }
    static struct Dirty { C a; @nullable("test") C b; const(C) c; }
    static assert(walkAggregate!(Clean, false)("x").length == 0);
    static assert(walkAggregate!(Dirty, false)("x") == ["x.a: C", "x.c: const(C)"]);
    static assert(walkAggregate!(Dirty, true)("x") == ["x.b: C"]);
}
