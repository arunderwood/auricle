#!/bin/sh
# Asserts that `Log.debug` compiles to an empty function in a release build.
#
# `Log.debug` wraps its body in `#if DEBUG` so that field redaction and message
# assembly cost nothing in a shipped binary. A release build that succeeds says
# nothing about that: with the guard deleted the code still compiles and the
# suite, which runs in debug, still passes. What differs is the machine code, so
# this reads the release object for `Core`'s `Log.swift` and requires every
# `Log.debug` symbol in it to be a single instruction (the return).
#
# Matching the mangled prefix, not the demangled signature, keeps the check
# independent of the parameter types. Finding no `Log.debug` symbol is an error:
# a rename would otherwise make the assertion pass vacuously.
#
# Run after `swift build -c release`; scripts/check.sh's release phase does.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

object="$(swift build -c release --show-bin-path)/Core.build/Log.swift.o"
if [ ! -f "$object" ]; then
    echo "::error::Release strip check: $object not found — run 'swift build -c release' first."
    exit 1
fi

# `otool -tvV` prints each symbol as a `label:` line followed by one line per
# instruction, each starting with a hex address. Every `Log.debug` label must
# be followed by exactly one instruction before the next label (or the end).
otool -tvV "$object" | awk '
    function close_symbol() {
        if (in_debug) {
            found++
            if (count != 1) {
                printf "::error::Release strip check: %s has %d instructions, expected 1 — is the `#if DEBUG` guard in Log.debug gone?\n", symbol, count
                bad = 1
            }
        }
        in_debug = 0
    }
    /^[A-Za-z_$][^\t]*:$/ {
        close_symbol()
        if ($0 ~ /^_\$s4Core3LogV5debug/) {
            in_debug = 1
            symbol = substr($0, 1, length($0) - 1)
            count = 0
        }
        next
    }
    in_debug { count++ }
    END {
        close_symbol()
        if (found == 0) {
            print "::error::Release strip check: no Log.debug symbol found in the release object — the check would pass vacuously."
            exit 1
        }
        exit bad
    }
'

echo "Log.debug compiles to a single instruction in the release build."
