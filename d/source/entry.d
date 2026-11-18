/// The executable's entry point. The program lives in `app`: dub leaves the
/// main source file out of `dub test`, so keeping `main` here is what gets
/// app.d's unittests built and run.
module entry;

@safe:

import app : appMain;

int main(string[] args) { return appMain(args); }
