dune ignores jbuild-workspace files:

  $ dune build --root jbuilder-default-name
  Entering directory 'jbuilder-default-name'

dune uses a versioned file. If the version is missing, then we get an error.

  $ dune build --root dune-no-version
  Entering directory 'dune-no-version'
  File "dune-workspace", line 1, characters 0-19:
  1 | (context (default))
      ^^^^^^^^^^^^^^^^^^^
  Error: Invalid first line, expected: (lang <lang> <version>)
  [1]

specifying the workspace file is possible:

  $ dune build --root custom-workspace --workspace custom-workspace/dune-workspace.dev
  Entering directory 'custom-workspace'

Workspaces let you set custom profiles

  $ dune runtest --root custom-profile
  Entering directory 'custom-profile'
  build profile: foobar

A workspace context can be defined using an opam switch. This test is disabled
because we don't really have a way to mock an opam switch.

#  $ dune build --root opam --display quiet 2>&1

Workspaces also allow you to set "target" for cross compilation. This feature is
a bit hard to test since it requires mocking more than one context. But we can
see how we can set a "native" target. Which is the default.

  $ dune exec ./foo.exe --root targets-native
  Entering directory 'targets-native'
  Entering directory 'targets-native'
  message from targets-native test

Workspaces also allow you to set the env for a context:

  $ dune printenv --root workspace-env --profile default
  Entering directory 'workspace-env'
  
   ((flags
     (-w -40 -machin))
    (ocamlc_flags
     (-g -verbose))
    (ocamlopt_flags (-g))
    (c_flags ())
    (cxx_flags ()))
  
A workspace context can be used to build an executable using
feedback-direct optimizations (fdo). The name of the context is
determined from the name of the target executable for fdo and the
default switch name, unless a name field is provided explicitly.
It should work for both default and opam switches, but we don't have
a way to test opam switches.

This test should build all three contexts:

  $ dune build src/foo.exe --root fdo --workspace fdo/dune-workspace.1
  Entering directory 'fdo'

  $ ./fdo/_build/default/src/foo.exe
  <root>/_build/default/src/foo.exe: hello from fdo!

  $ ./fdo/_build/default-fdo-foo/src/foo.exe
  <root>/_build/default-fdo-foo/src/foo.exe: hello from fdo!

  $ ./fdo/_build/foofoo/src/foo.exe
  <root>/_build/foofoo/src/foo.exe: hello from fdo!

This is intended to fail

  $ dune build --root fdo --workspace fdo/dune-workspace.2
  Entering directory 'fdo'
  File "$TESTCASE_ROOT/fdo/dune-workspace.2", line 15, characters 9-66:
  15 | (context (default
  16 |            (name default-fdo-test2)
  17 |            ))
  Error: second definition of build context "default-fdo-test2"
  [1]

  $ dune build --root fdo --workspace fdo/dune-workspace.3
  Entering directory 'fdo'
  File "$TESTCASE_ROOT/fdo/dune-workspace.3", line 15, characters 9-97:
  15 | (context (default
  16 |            (name default-fdo-test2)
  17 |            (fdo src/test2.exe)
  18 |            ))
  Error: second definition of build context "default-fdo-test2"
  [1]

