/// `Result!(T, E)`: a value or an error, returned rather than thrown (Rust's
/// `Result<T, E>`). The failure is part of the signature, so a caller sees it
/// and has to handle it; a pure function can report one without unwinding.
///
/// As with `Option`, the fields are private, so the only ways in are:
///
/// - `r.match!(v => ..., e => ...)`: both cases, or it doesn't compile;
/// - `r.map!(v => ...)`, `r.mapErr!(e => ...)`, `r.andThen!(v => result)`;
/// - `r.orElse(fallback)`, `r.toOption`, `r.errOption`;
/// - `r.unwrap("why it can't fail")`, which halts (kept in release builds);
/// - `r.orThrow!(e => new SomeException(...))` at the I/O edge, where code
///   that reports errors by throwing takes over.
///
/// Make one with `R.ok(v)` / `R.err(e)` (`alias R = Result!(T, E)`), or
/// `return typeof(return).ok(v)`. `E` is usually a small struct or enum that
/// says what went wrong, or `string` for a message.
module nano.result;
@safe:
pure:

import nano.option : Option, some, none;

struct Result(T, E)
{
    private T value;
    private E error;
    private bool good;

    static Result ok(T v) { Result r; r.value = v; r.good = true; return r; }

    static Result err(E e) { Result r; r.error = e; return r; }

    bool isOk() const { return good; }

    bool isErr() const { return !good; }
}

enum isResult(R) = is(R : Result!(T, E), T, E);

/// Both cases: `onOk` gets the value, `onErr` the error.
auto match(alias onOk, alias onErr, T, E)(Result!(T, E) r)
{
    return r.good ? onOk(r.value) : onErr(r.error);
}

/// `f(value)` as a result; an error passes through.
auto map(alias f, T, E)(Result!(T, E) r)
{
    alias R = Result!(typeof(f(T.init)), E);
    return r.good ? R.ok(f(r.value)) : R.err(r.error);
}

/// `f(error)` as the error; a value passes through.
auto mapErr(alias f, T, E)(Result!(T, E) r)
{
    alias R = Result!(T, typeof(f(E.init)));
    return r.good ? R.ok(r.value) : R.err(f(r.error));
}

/// `f(value)`, which itself returns a `Result!(U, E)`; an error passes through.
auto andThen(alias f, T, E)(Result!(T, E) r)
{
    alias R = typeof(f(T.init));
    static assert(isResult!R, "andThen: f must return a Result");
    return r.good ? f(r.value) : R.err(r.error);
}

/// The value, or `fallback` on an error.
T orElse(T, E)(Result!(T, E) r, T fallback)
{
    return r.good ? r.value : fallback;
}

/// The value as an `Option` (the error is dropped).
Option!T toOption(T, E)(Result!(T, E) r)
{
    return r.good ? some(r.value) : Option!T(none);
}

/// The error as an `Option`.
Option!E errOption(T, E)(Result!(T, E) r)
{
    return r.good ? Option!E(none) : some(r.error);
}

/// The value; halts on an error. `why` says why it can't fail, for a reviewer.
T unwrap(T, E)(Result!(T, E) r, string why)
{
    if (!r.good) assert(0, "unwrap on err: " ~ why);
    return r.value;
}

/// The value, or throws `mk(error)`: for the I/O edge, where code that
/// reports failure by throwing calls into code that returns it. Not pure
/// only in that throwing an exception allocated by `mk` is allowed here.
T orThrow(alias mk, T, E)(Result!(T, E) r)
{
    if (!r.good) throw mk(r.error);
    return r.value;
}

unittest
{
    alias R = Result!(int, string);
    auto a = R.ok(3), b = R.err("bad");
    assert(a.isOk && !a.isErr && b.isErr);
    assert(a.match!(v => v * 2, e => -1) == 6);
    assert(b.match!(v => v * 2, e => cast(int) e.length) == 3);
    assert(a.map!(v => v + 1).orElse(0) == 4);
    assert(b.map!(v => v + 1).orElse(0) == 0);
    assert(b.mapErr!(e => e.length).match!(v => 0, e => e) == 3);
    static R half(int v) { return v % 2 ? R.err("odd") : R.ok(v / 2); }
    assert(R.ok(8).andThen!half.orElse(-1) == 4);
    assert(a.andThen!half.match!(v => "", e => e) == "odd");
    assert(b.andThen!half.match!(v => "", e => e) == "bad");
    assert(a.toOption.isSome && b.toOption.isNone);
    assert(b.errOption.isSome && a.errOption.isNone);
    assert(a.unwrap("just made") == 3);
    static assert(!__traits(compiles, { enum x = R.err("e").unwrap("x"); }));
    static assert(!__traits(compiles, a.match!(v => v)));
}

unittest
{
    import std.exception : collectExceptionMsg;
    alias R = Result!(int, string);
    assert(R.ok(1).orThrow!(e => new Exception(e)) == 1);
    assert(collectExceptionMsg(R.err("boom").orThrow!(e => new Exception(e))) == "boom");
}
