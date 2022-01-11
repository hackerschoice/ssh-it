#! /bin/bash


BASEDIR="$(cd "$(dirname "${0}")/../" || exit; pwd)"
source "${BASEDIR}/packaging/build_func.sh"

[[ -f "${SRCTGZ}" ]] || make dist || errexit "Aborted"

# <osarch> <ssh-param>
build_static()
{
	OSARCH="$1"
	DST_SRCDIR="/tmp/${PRGNAME}-${VER}"
	exists "$OSARCH" "ptyspy_bin" && return

	echo >&2 "Building $OSARCH on \"$2\""
	$2 "cd /tmp; tar xfz -" <"${SRCTGZ}" && \
	$2 "cd \"${DST_SRCDIR}\" && OSARCH=\"$OSARCH\" ./configure --enable-static && make all && strip src/ptyspy_bin.${OSARCH}" && \
	$2 "cat \"${DST_SRCDIR}/src/ptyspy_bin.${OSARCH}\"; rm -rf \"${DST_SRCDIR}\"" >"${PKG_DIR}/ptyspy_bin.${OSARCH}" && \
	chmod 755 "${PKG_DIR}/ptyspy_bin.${OSARCH}" && \
	ok "DONE ${OSARCH}" || errexit "Failed in $OSARCH"

}

build_static x86_64-osx "bash -c" && \
build_static armv6l-linux "ssh gsnet@192.168.1.19" && \
build_static aarch64-linux "ssh -p 64222 -i ~/.ssh/aws-1.cer ec2-user@gs-aarch64" && \
ok "DONE ALL"
