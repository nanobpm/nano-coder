/// Size arithmetic that can't silently wrap.
///
/// Token counts, context windows, character budgets and buffer lengths are
/// unsigned (`size_t`), and D, like Rust in release builds, wraps on
/// underflow: `window - reserved` with `reserved > window` is a number near
/// 2^64, which then reads as an enormous budget. The token-budget modules
/// (context.d, agent.d) do their size arithmetic through these helpers, and
/// scripts/check-safe.sh caps the raw subtractions left there and bans the
/// hand-written guard these replace (`a > b ? a - b : 0`, which is easy to
/// get subtly wrong: swapped operands, `>=` against `>`, a third term).
///
/// - `saturatingSub` is for "what's left, or nothing": a budget that may
///   already be spent. It is Rust's `saturating_sub`.
/// - `checkedSub`, `checkedAdd` and `checkedMul` are for arithmetic whose
///   overflow would be a bug. They halt with `assert(0)`, which, unlike a
///   plain `assert`, stays in release builds, so a broken invariant crashes
///   at the cause instead of wrapping into a wrong size downstream.
module nano.arith;
@safe:
pure:

import std.traits : isIntegral, isSigned;


/// `a - b`, or 0 when `b` is larger (Rust's `saturating_sub`).
///
/// Two signed operands (Unix times, durations) give a `long`. Otherwise the
/// result is a `size_t`: a signed operand mixed in (usually a literal such
/// as `1`) must not be negative when subtracted, which halts like
/// `checkedSub`, and a negative left operand gives 0.
auto saturatingSub(A, B)(A a, B b) pure nothrow @nogc
if (isIntegral!A && isIntegral!B)
{
    static if (isSigned!A && isSigned!B)
    {
        long x = a, y = b;
        return x > y ? x - y : 0L;
    }
    else
    {
        static if (isSigned!B) if (b < 0) assert(0, "negative subtrahend");
        static if (isSigned!A) if (a < 0) return size_t(0);
        size_t x = cast(size_t) a, y = cast(size_t) b;
        return x > y ? x - y : size_t(0);
    }
}

/// `a - b`; halts if `b` is larger, which the caller has ruled out.
size_t checkedSub(size_t a, size_t b) pure nothrow @nogc
{
    if (b > a) assert(0, "size underflow");
    return a - b;
}

/// `a + b`; halts on overflow.
size_t checkedAdd(size_t a, size_t b) pure nothrow @nogc
{
    import core.checkedint : addu;
    bool overflow;
    auto r = addu(a, b, overflow);
    if (overflow) assert(0, "size overflow");
    return r;
}

/// `a + b`, or `size_t.max` when that overflows (Rust's `saturating_add`).
///
/// For totals fed by outside numbers — a provider's reported token usage, a
/// stored count read back from a file — where clamping to the largest
/// representable size keeps a downstream "is the context too big?" check
/// conservative, while halting would let a malformed report crash a
/// successful operation's bookkeeping.
size_t saturatingAdd(size_t a, size_t b) pure nothrow @nogc
{
    import core.checkedint : addu;
    bool overflow;
    auto r = addu(a, b, overflow);
    return overflow ? size_t.max : r;
}

/// `a * b`; halts on overflow.
size_t checkedMul(size_t a, size_t b) pure nothrow @nogc
{
    import core.checkedint : mulu;
    bool overflow;
    auto r = mulu(a, b, overflow);
    if (overflow) assert(0, "size overflow");
    return r;
}

unittest
{
    assert(saturatingSub(10, 3) == 7);
    assert(saturatingSub(3, 10) == 0);
    assert(saturatingSub(5, 5) == 0);
    assert(saturatingSub(size_t(0), size_t.max) == 0);
    assert(saturatingSub(10L, -5L) == 15);
    assert(saturatingSub(-5L, 10L) == 0);
    static assert(is(typeof(saturatingSub(10L, 5L)) == long));
    static assert(is(typeof(saturatingSub(size_t(10), 1)) == size_t));
    assert(saturatingSub(size_t(10), 1) == 9);
    assert(saturatingSub(-3, size_t(2)) == 0);
    assert(checkedSub(10, 3) == 7);
    assert(checkedSub(4, 4) == 0);
    assert(checkedAdd(size_t.max - 1, 1) == size_t.max);
    assert(saturatingAdd(size_t.max - 1, 1) == size_t.max);
    assert(saturatingAdd(size_t.max, 1) == size_t.max);
    assert(saturatingAdd(3, 4) == 7);
    assert(checkedMul(1 << 20, 1 << 10) == 1 << 30);
}

unittest
{
    // The halts are `assert(0)`, an Error that @safe code can't catch. In
    // CTFE the same `assert(0)` is a compile error, which checks that each
    // one fires instead of wrapping.
    static assert(!__traits(compiles, { enum x = checkedSub(3, 4); }));
    static assert(!__traits(compiles, { enum x = saturatingSub(size_t(3), -1); }));
    static assert(!__traits(compiles, { enum x = checkedAdd(size_t.max, 1); }));
    static assert(!__traits(compiles, { enum x = checkedMul(size_t.max / 2 + 1, 2); }));
    static assert(__traits(compiles, { enum x = checkedSub(4, 3); }));
    static assert(__traits(compiles, { enum x = checkedAdd(1, 2); }));
    static assert(__traits(compiles, { enum x = saturatingAdd(size_t.max, 1); }));
    static assert(saturatingAdd(size_t.max, 1) == size_t.max);
    static assert(__traits(compiles, { enum x = checkedMul(3, 2); }));
}

/// A count or index from outside (JSON, config, a file) as a `size_t`:
/// throws `ConvException` when it is negative (or, for `ulong` on 32-bit,
/// too large), so bad input fails where it enters instead of wrapping to an
/// enormous size downstream.
size_t toSize(T)(T v) if (isIntegral!T)
{
    import std.conv : to;
    return v.to!size_t;
}

/// `toSize` without throwing: `none` when `v` doesn't fit.
auto trySize(T)(T v) nothrow @nogc if (isIntegral!T)
{
    import nano.option : Option, some, none;
    static if (isSigned!T) if (v < 0) return Option!size_t(none);
    static if (T.max > size_t.max) if (v > size_t.max) return Option!size_t(none);
    return some(size_t(v));
}

/// A length as a `long`, for arithmetic that may go negative. Halts if it
/// doesn't fit (a length over 2^63 is a broken invariant, not input).
long toLong(size_t v) nothrow @nogc
{
    if (v > long.max) assert(0, "length overflow");
    return long(v);
}

unittest
{
    import std.conv : ConvException;
    import nano.option : orElse;
    import std.exception : assertThrown;
    assert(toSize(5L) == 5);
    assert(toSize(0) == 0);
    assertThrown!ConvException(toSize(-1L));
    assert(trySize(7L).orElse(size_t(0)) == 7);
    assert(trySize(-7L).isNone);
    assert(toLong(size_t(9)) == 9);
    static assert(!__traits(compiles, { enum x = toLong(size_t.max); }));
}
