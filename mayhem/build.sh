#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# lldpd is autotools. autogen.sh is NOT used: it runs `git submodule update` (network), and the
# air-gapped PATCH re-run has none. The system libevent is used (--without-embedded-libevent).
if [ ! -x configure ]; then
    libtoolize --copy --force
    autoreconf -vif -I m4
fi

COMMON_CONF=(--without-embedded-libevent --without-snmp --with-xml --disable-shared --enable-static
             --disable-silent-rules)

# 1) Sanitized project builds, out of tree (gitignored by upstream's /build*/ rule).
#    build-fuzz/   : coverage-instrumented (-fsanitize=fuzzer-no-link) so libFuzzer sees inside liblldpd.
#    build-decode/ : plain sanitized, for the file-input `decode` target (Mayhem instruments it itself).
#    FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION is upstream's own switch for fuzz builds (skips the EDP
#    checksum so the fuzzer can get past it).
build_tree() {
    local dir="$1" cov="$2"
    mkdir -p "$dir"
    if [ ! -f "$dir/config.status" ]; then
        (cd "$dir" && ../configure "${COMMON_CONF[@]}" CC="$CC" \
            CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $cov" \
            CPPFLAGS="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION")
    fi
    make -C "$dir" -j"$MAYHEM_JOBS" all
}
build_tree build-fuzz -fsanitize=fuzzer-no-link
build_tree build-decode ""

# 2) Harnesses: libFuzzer binary + run-once standalone reproducer each, with leaks switched off.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o

LLDPD_LIB=build-fuzz/src/daemon/.libs/liblldpd.a           # coverage-instrumented, for the fuzzers
PLAIN_LIB=build-decode/src/daemon/.libs/liblldpd.a          # no coverage hooks, for the standalone reproducers
HARNESS_CFLAGS=(-funsigned-char -DHAVE_CONFIG_H -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
    -I"$SRC/build-fuzz" -I"$SRC/include" $(pkg-config --cflags libbsd-overlay))
LDLIBS=($(pkg-config --libs libevent libcap libbsd-overlay) -pthread)

for proto in lldp cdp sonmp edp; do
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${HARNESS_CFLAGS[@]}" -DDECODER=${proto}_decode \
        $LIB_FUZZING_ENGINE "$SRC/mayhem/harnesses/fuzz_decode.c" build-fuzz/lsan_off.o \
        "$LLDPD_LIB" "${LDLIBS[@]}" -o "/mayhem/fuzz-$proto"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${HARNESS_CFLAGS[@]}" -DDECODER=${proto}_decode \
        build-fuzz/standalone_main.o "$SRC/mayhem/harnesses/fuzz_decode.c" build-fuzz/lsan_off.o \
        "$PLAIN_LIB" "${LDLIBS[@]}" -o "/mayhem/fuzz-$proto-standalone"
done

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem/harnesses/fuzz_pattern_match.cpp" \
    build-fuzz/lsan_off.o "$LLDPD_LIB" "${LDLIBS[@]}" -o /mayhem/fuzz-pattern-match
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS build-fuzz/standalone_main.o "$SRC/mayhem/harnesses/fuzz_pattern_match.cpp" \
    build-fuzz/lsan_off.o "$PLAIN_LIB" "${LDLIBS[@]}" -o /mayhem/fuzz-pattern-match-standalone

# decode: upstream's own pcap-decoding CLI (tests/decode.c), a file-input target, relinked with the
# leak-off hook.
make -C build-decode/tests decode.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS build-decode/tests/decode.o build-fuzz/lsan_off.o \
    "$PLAIN_LIB" \
    "${LDLIBS[@]}" -o /mayhem/decode

# 3) The project's own unit tests (libcheck), built with NORMAL flags in build-tests/ so test.sh
#    only RUNS them.
mkdir -p build-tests
if [ ! -f build-tests/config.status ]; then
    (cd build-tests && env -u CFLAGS -u CPPFLAGS -u LDFLAGS ../configure "${COMMON_CONF[@]}" CC="$CC" \
        CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS")
fi
make -C build-tests -j"$MAYHEM_JOBS" all
make -C build-tests/tests -j"$MAYHEM_JOBS" check TESTS=
