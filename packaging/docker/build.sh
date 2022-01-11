#! /bin/sh
#  ^^^^^^^Mutli OS must use /bin/sh (alpine uses ash, debian uses dash)

# This script is executed inside a docker container.
# It is used to build gs-netcat as staticly linked binary for various OSes.

test -d /src/src-build || { echo >&2 "/src/src-build does not exists."; exit 255; }

cd /src/src-build || exit 127
OSARCH="$(src/x.sh osarch)"
BINFILE="src/ptyspy_bin.${OSARCH}"

./configure $(cat /src/src-build/configure-parameters.txt) && \
make clean all && \
strip "${BINFILE}" && \
# Can not do self-test when cross compiling
# THC_EXEC_TEST=1 ./"${BINFILE}" || { rm -f "${BINFILE}" ; exit 127; }
true
