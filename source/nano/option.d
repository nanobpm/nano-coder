/// `Option!T`: a value that may be absent, where using it forces you to
/// handle the absent case (Rust's `Option<T>`).
///
/// D's own `std.typecons.Nullable` doesn't force anything: `.get` compiles
/// without a check, and in release builds an empty `.get` silently returns
/// `T.init` (the assert is stripped). For classes it is worse: a
/// `Nullable!C(null)` says it holds a value while holding null. A plain
/// class reference has the same problem: nothing says whether null is a
/// state the reader must handle.
///
/// The value is private, so the only ways to reach it are:
///
/// - `o.match!(x => ..., () => ...)`: both cases, or it doesn't compile;
/// - `foreach (x; o) { ... }`: run a block only when present (`if let`);
///   `return` works in it, `break`/`continue` don't reach an outer loop;
/// - `o.ifSome((x) { ... })`: do something only when present;
/// - `o.orElse(fallback)` and `o.map!(x => ...)`;
/// - `o.unwrap("why it can't be absent")`, which halts with `assert(0)` (kept
///   in release builds) and is easy to grep for.
///
/// `some(x)` halts on a null class or pointer, so a `some` is never null and
/// there is exactly one way to be absent. `isSome`/`isNone` answer the
/// question without handing out the value.
///
/// (It is not a `std.sumtype.SumType!(None, T)`: assigning a SumType that
/// holds a reference is @system, and optional references get reassigned.
/// The forcing comes from the private field, not the representation.)
///
/// scripts/check-safe.sh caps `Nullable!` uses and null checks on class
/// references, so new optional values use this.
module nano.option;
@safe:

/// The absent case.
struct None {}

/// `Option!T.init` and `none` are both absent.
enum None none = None();

struct Option(T)
{
    private T value;
    private bool present;

    /// Present; halts if `x` is a null reference (use `none` for absent).
    this(T x)
    {
        static if (is(T == class) || is(T == interface) || is(T : U*, U))
            if (x is null) assert(0, "some(null): use none for an absent " ~ T.stringof);
        value = x;
        present = true;
    }

    /// Absent.
    this(None) {}

    void opAssign(None) pure { value = T.init; present = false; }

    /// `opt = null` doesn't compile: absent is `none`.
    @disable void opAssign(typeof(null));

    void opAssign(Option!T o) pure { value = o.value; present = o.present; }

    /// `foreach (x; opt) { ... }` runs the body once with the value when
    /// present: D's `if let Some(x) = opt`. A `return` in the body returns
    /// from the enclosing function, but `break`/`continue` apply to this
    /// one-element loop, not to a loop around it.
    int opApply(scope int delegate(T) @safe dg)
    {
        return present ? dg(value) : 0;
    }

    bool isSome() pure const { return present; }

    bool isNone() pure const { return !present; }
}

/// Marks a class-typed field or global that may be null on purpose, with
/// the reason: `@nullable("set once startup finishes") Agent agent;`.
/// nano.nullaudit reports bare class references without it, and check-safe
/// counts the marks (scripts/nullable-mark-budget).
struct nullable { string why; }

/// A class or interface reference that is never null: construction and
/// assignment halt on null, and there is no default (`NotNull!C x;` doesn't
/// compile). It reads as the reference itself (`alias this`), so a field can
/// move from `C` to `NotNull!C` without touching its uses.
struct NotNull(T) if (is(T == class) || is(T == interface))
{
    private T value;

    @disable this();

    this(T x)
    {
        if (load(x) is null) assert(0, "NotNull!" ~ T.stringof ~ " given null");
        store(value, x);
    }

    void opAssign(T x) pure
    {
        if (load(x) is null) assert(0, "NotNull!" ~ T.stringof ~ " given null");
        store(value, x);
    }

    @disable void opAssign(typeof(null));

    static if (is(T == shared))
    {
        // Held in a shared object (a field of a `shared` class).
        this(T x) shared
        {
            if (load(x) is null) assert(0, "NotNull!" ~ T.stringof ~ " given null");
            store(value, x);
        }

        T nonNull() pure const { return load(value); }
        T nonNull() pure const shared { return load(value); }
    }
    else
        inout(T) nonNull() pure inout { return value; }

    alias nonNull this;
}

/// Reads and writes of a reference, atomic when it is `shared`
/// (-preview=nosharedaccess treats even reading a shared parameter as access).
private auto load(R)(ref R r) pure
{
    static if (is(R == shared))
    {
        import core.atomic : atomicLoad;
        return atomicLoad(r);
    }
    else
        return r;
}

private void store(R)(ref R r, ref R v) pure
{
    static if (is(R == shared))
    {
        import core.atomic : atomicLoad, atomicStore;
        atomicStore(r, atomicLoad(v));
    }
    else
        r = v;
}

/// `NotNull!T(x)` with the type inferred; halts on null.
NotNull!T notNull(T)(T x) pure { return NotNull!T(load(x)); }

unittest
{
    static class C { int n = 7; }
    auto c = notNull(new C);
    assert(c.n == 7);           // reads through to the reference
    C plain = c;                // and converts back to it
    assert(plain.n == 7);
    c = new C;
    static assert(!__traits(compiles, { NotNull!C x; }));
    static assert(!__traits(compiles, { auto x = notNull(new C); x = null; }));
    struct Holder { NotNull!C c; }
    static assert(!__traits(compiles, { Holder h; }));
}

unittest
{
    static class S { int read() shared const @safe { return 3; } }
    auto s = notNull(new shared S);
    assert(s.read == 3);         // atomic read, then the shared method
}

/// A present `Option`; halts on a null reference.
Option!T some(T)(T x) pure { return Option!T(x); }

enum isOption(O) = is(O : Option!T, T);

/// Both cases: `onSome` gets the value, `onNone` gets nothing.
auto match(alias onSome, alias onNone, T)(Option!T o)
{
    return o.present ? onSome(o.value) : onNone();
}

/// Runs `f` with the value when present.
void ifSome(T, F)(Option!T o, scope F f)
{
    if (o.present) f(o.value);
}

/// The value, or `fallback` when absent.
T orElse(T)(Option!T o, T fallback) pure
{
    return o.present ? o.value : fallback;
}

/// `f(value)` wrapped in an `Option`, or `none`.
auto map(alias f, T)(Option!T o) pure
{
    alias R = typeof(f(T.init));
    return o.present ? Option!R(f(o.value)) : Option!R(none);
}

/// The value; halts when absent. `why` says why it can't be: the caller has
/// ruled the absent case out, and a reviewer checks that claim.
T unwrap(T)(Option!T o, string why) pure
{
    if (!o.present) assert(0, "unwrap on none: " ~ why);
    return o.value;
}

unittest
{
    Option!int a;
    assert(a.isNone && !a.isSome);
    a = some(3);
    assert(a.isSome);
    assert(a.match!(x => x * 2, () => -1) == 6);
    assert(a.orElse(9) == 3);
    assert(a.map!(x => x + 1).orElse(0) == 4);
    a = none;
    assert(a.match!(x => x * 2, () => -1) == -1);
    assert(a.orElse(9) == 9);
    assert(a.map!(x => x + 1).isNone);
    int seen;
    a.ifSome((int x) { seen = x; });
    assert(seen == 0);
    some(5).ifSome((int x) { seen = x; });
    assert(seen == 5);
    assert(some(7).unwrap("just set") == 7);
    int calls;
    foreach (x; some(4)) { calls += x; }
    foreach (x; Option!int.init) { calls += 100; }
    assert(calls == 4);
    int early(Option!int o) { foreach (x; o) return x; return -1; }
    assert(early(some(2)) == 2 && early(Option!int.init) == -1);
}

unittest
{
    static class C { int n = 1; }
    Option!C c;
    assert(c.isNone);
    c = some(new C);
    assert(c.match!(x => x.n, () => 0) == 1);
    // A some is never null: some(null) halts (a compile error in CTFE).
    static assert(!__traits(compiles, { enum x = some!C(null).isSome; }));
    // unwrap on none halts too.
    static assert(!__traits(compiles, { enum x = Option!int.init.unwrap("x"); }));
    static assert(__traits(compiles, { enum x = some(1).unwrap("x"); }));
    // There is no .get: the value is only reached through the helpers.
    static assert(!__traits(compiles, c.get));
    static assert(!__traits(compiles, { Option!C o; o = null; }));
    // match needs both cases.
    static assert(!__traits(compiles, c.match!(x => x.n)));
}
