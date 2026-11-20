/// nano.result from outside the module, where `private` applies, beside
/// nano.option (whose helpers share names with Result's).
module nano.result_test;
@safe:

import nano.option;
import nano.result;

unittest
{
    alias R = Result!(int, string);
    auto a = R.ok(3);
    // The value and error are reached only through the helpers.
    static assert(!__traits(compiles, a.value));
    static assert(!__traits(compiles, a.error));
    // Option's and Result's orElse/map resolve side by side.
    assert(a.map!(v => v + 1).orElse(0) == 4);
    assert(a.toOption.orElse(0) == 3);
    assert(R.err("e").errOption.orElse("") == "e");
}
