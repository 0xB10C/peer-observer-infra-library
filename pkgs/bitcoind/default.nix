{
  stdenv,
  lib,
  # nativeBuildInputs
  pkg-config,
  cmake,
  # buildInputs
  boost,
  libsystemtap,
  libevent,
  capnproto,
}:

{
  # allows to set a fake version during build. This can be used
  # to avoid poking out as vXX.99 development builds or as release
  # candidate testers. This is useful when wanting to avoid detection
  # of the honey pot nodes.
  fakeVersionMajor ? null,
  fakeVersionMinor ? null,
  # optional args specifiying which commit, branch and repo to use
  gitURL ? "https://github.com/bitcoin/bitcoin.git",
  gitBranch ? "master",
  gitCommit ? "8ee24d764a2820259fe42f8def93fd8a2c36a4cf", # master at 2026-02-19
  sanitizersAddressUndefined ? false,
  sanitizersThread ? false,
}:

# ensure either thread or address+undefined sanitizers are enabled
# (thread <-> address sanitizer aren't compatible)
assert sanitizersAddressUndefined -> !sanitizersThread;
assert sanitizersThread -> !sanitizersAddressUndefined;

stdenv.mkDerivation rec {
  name = "bitcoind";
  version = "${gitURL}-${gitBranch}-${gitCommit}";

  # passthru these to be able to access them via e.g. package.gitURL
  passthru = {
    inherit
      fakeVersionMajor
      fakeVersionMinor
      gitCommit
      gitBranch
      gitURL
      sanitizersAddressUndefined
      sanitizersThread
      ;
  };

  src = builtins.fetchGit {
    url = gitURL;
    ref = gitBranch;
    rev = gitCommit;
  };

  nativeBuildInputs = [
    pkg-config
    libsystemtap
    capnproto
    cmake
  ];

  buildInputs = [
    boost
    libevent
    libsystemtap
    capnproto
  ];

  # Don't strip the binaries to have debug symbols for debugging.
  dontStrip = true;

  postPatch = ''
    ${lib.optionalString (fakeVersionMajor != null) ''
      echo "Patching MAJOR version number in CMakeLists.txt to ${fakeVersionMajor}"
      sed -i 's/set(CLIENT_VERSION_MAJOR [0-9]\+)/set(CLIENT_VERSION_MAJOR ${fakeVersionMajor})/' CMakeLists.txt
    ''}
    ${lib.optionalString (fakeVersionMinor != null) ''
      echo "Patching MINOR version number in CMakeLists.txt to ${fakeVersionMinor}"
      sed -i 's/set(CLIENT_VERSION_MINOR [0-9]\+)/set(CLIENT_VERSION_MINOR ${fakeVersionMinor})/' CMakeLists.txt
    ''}
  '';

  cmakeFlags = [
    "-DWITH_USDT=ON"
    "-DBUILD_TESTS=OFF"
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DENABLE_WALLET=OFF"

    # We use DCMAKE_BUILD_TYPE=Debug for more debug checks, but enable -O3 optimizations below similar to
    # https://github.com/bitcoin/bitcoin/blob/38e6ea9f3a6ba9c987936e1316ff17a51a73040d/.github/ci-test-each-commit-exec.py#L36-L38
    # Running in debug mode also makes 'assumes()' to behave like asserts().
    "-DCMAKE_BUILD_TYPE=Debug"
    # Debug mode defaults to -O0 -g3, but we want our binaries to have -O3.
    "-DAPPEND_CXXFLAGS=-O3"
    "-DAPPEND_CFLAGS=-O3"
    # TODO: check: does -O3 harm some of the sanitizers?
    (lib.optional sanitizersThread "-DSANITIZERS=thread")
    (lib.optional sanitizersAddressUndefined "-DSANITIZERS=address,undefined")
  ];

  # We can't set multiple flags in cmakeFlags with -DAPPEND_* as a space is
  # treated as separate argument to cmake.
  #
  # For continues profiling, these help to have better stack traces:
  # -ggdb3: Maximum debug info for GDB-compatible tools
  # -fno-omit-frame-pointer: Required for accurate stack traces
  # -fno-inline: Prevent function inlining
  # -fno-optimize-sibling-calls: Avoid tail-call elimination
  preConfigure = ''
    export CXXFLAGS="$CXXFLAGS -ggdb3 -fno-omit-frame-pointer -fno-inline -fno-optimize-sibling-calls"
  '';

  doCheck = false;
  enableParallelBuilding = true;
}
