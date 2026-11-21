# Build and run small C programs against the objects of the pinned nginx build, so a lab can
# call ngx_pool_t, ngx_hash_t and friends directly. Source it after lib.sh:
#
#   . "$(dirname "$0")/../lib.sh"
#   . "$LAB/../ctest.sh"         # lib.sh has already changed to the lab directory
#   ctest pool.c          # builds out/run/pool from labs/<id>/pool.c and runs it
#
# The program links every object of objs/nginx except nginx.o, which is rebuilt with
# main renamed (it also defines ngx_core_module and the globals the other objects use).

SRC=${SRC:-$ROOT/.nginx-src/release-1.31.9}
[[ -f "$SRC/objs/Makefile" ]] || { echo "no objs/Makefile in $SRC; run tools/build.sh first" >&2; exit 2; }

# _ctest_var NAME: a Makefile variable, following "\" continuation lines
_ctest_var() {
    awk -v n="$1" '$0 ~ "^" n " =" { f = 1; sub("^" n " =", "") } f { c = sub(/\\$/, ""); printf "%s ", $0; if (!c) exit }' \
        "$SRC/objs/Makefile"
}

_ctest_prepare() {
    [[ -f out/run/ctest/nomain.o ]] && return 0
    mkdir -p out/run/ctest
    CTEST_CFLAGS=$(_ctest_var CFLAGS)
    CTEST_INCS=$(_ctest_var ALL_INCS)
    # the object list and the libraries of the objs/nginx link rule
    sed -n '/^objs\/nginx:/,/^$/p' "$SRC/objs/Makefile" | tr -d '\\' | tr -s ' \t' '\n' \
        | grep -E '^objs/.*\.o$' | grep -v '^objs/src/core/nginx.o$' > out/run/ctest/objs.txt
    # the libraries are on the last line of the recipe that follows the dependency list
    awk '/^objs\/nginx:/ { f = 1 } f && /-lz|-lcrypto|-lpcre/ { print; exit }' "$SRC/objs/Makefile" \
        | tr -s ' \t' '\n' | grep -E '^-(L|l)' | awk '!seen[$0]++' | tr '\n' ' ' > out/run/ctest/libs.txt
    # shellcheck disable=SC2086
    (cd "$SRC" && cc -c $CTEST_CFLAGS -Wno-error $CTEST_INCS -Dmain=ngx_original_main \
        -o "$LAB/out/run/ctest/nomain.o" src/core/nginx.c)
    echo "$CTEST_CFLAGS" > out/run/ctest/cflags.txt
    echo "$CTEST_INCS" > out/run/ctest/incs.txt
}

# ctest FILE.c [args...]: compile labs/<id>/FILE.c and link it (once per run), then run it
ctest() {
    local c=$1 bin
    shift
    _ctest_prepare
    bin=out/run/ctest/$(basename "$c" .c)
    if [[ ! -x $bin ]]; then
        local objs
        objs=$(sed "s#^#$SRC/#" out/run/ctest/objs.txt | tr '\n' ' ')
        # shellcheck disable=SC2046,SC2086
        (cd "$SRC" && cc $(cat "$LAB/out/run/ctest/cflags.txt") -Wno-error $(cat "$LAB/out/run/ctest/incs.txt") \
        -o "$LAB/$bin" "$LAB/$c" "$LAB/out/run/ctest/nomain.o" $objs $(cat "$LAB/out/run/ctest/libs.txt"))
    fi
    "./$bin" "$@"
}
