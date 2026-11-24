/// The session-log handles this thread holds open and locked. A leaf module
/// (no `nano` imports) so its thread destructor adds no module-constructor
/// cycle to `nano.session`'s import graph.
module nano.loghandles;

@safe:

import std.stdio : File;

/// A locked log handle shared by this thread's writers of one path.
package struct Held { File file; size_t refs; }

/// Logs this thread holds open and locked, so an in-process reopen shares
/// the locked handle instead of opening an unlocked second description.
package Held*[string] openHere;

/// Close the handles a never-closed `SessionLog` left behind when this
/// thread ends, while throwing is still allowed. Left to the GC, the final
/// collection in `rt_term` finalizes them, and a failing `fclose` there
/// throws inside a finalizer: an InvalidMemoryOperationError that fails the
/// whole process after every test passed.
static ~this()
{
    import std.exception : collectException;
    foreach (h; openHere.byValue)
        // The thread is ending: a failed close leaves nothing to recover.
        if (collectException(h.file.close())) {}
    openHere = null;
}

/// Register `f` as the locked handle for `path`, with one writer.
package Held* shareHandle(string path, File f)
{
    auto h = new Held(f, 1);
    openHere[path] = h;
    return h;
}

// A handle left registered is closed by the thread destructor, not the GC.
unittest
{
    import std.file : tempDir, remove;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-loghandles-test");
    scope (exit) remove(p);
    auto h = shareHandle(p, File(p, "w"));
    assert(h.file.isOpen && openHere[p] is h);
    openHere.remove(p);
    h.file.close();
}
