
[[ -z $VER ]] && VER="$(grep AC_INIT "${BASEDIR}/configure.ac" | cut -f3 -d"[" | cut -f1 -d']')"

PRGNAME="ssh-it"
SRCDIR="${BASEDIR}"
PKG_DIR="${BASEDIR}/packaging/ssh-it-pkg"
PKG_TOP_DIR="$(dirname "$PKG_DIR")"
SRCTGZ="${BASEDIR}/${PRGNAME}-${VER}.tar.gz"

TARUIDGID="--owner 0 --group 0" #linux
[[ $OSTYPE =~ darwin ]] && TARUIDGID="--uid 0 --gid 0"

CY="\033[1;33m" # yellow
CG="\033[1;32m" # green
CR="\033[1;31m" # red
CC="\033[1;36m" # cyan
CM="\033[1;35m" # magenta
CN="\033[0m"    # none

errexit()
{
	echo -e >&2 "${CR}$@${CN}"
	exit 255
}

ok()
{
	echo -e "${CG}$@${CN}"
}

warn()
{
	echo -e >&2 "WARN: ${CY}$@${CN}"
}

# <osarch> <file>
# exists i386-alpine ptyspy_bin
exists()
{
	local OSARCH
	OSARCH="$1"
	local FN
	FN="$2"
	[[ -f "${PKG_DIR}/${FN}.${OSARCH}" ]] && { warn "${FN}.${OSARCH} already exists. Skipping..."; echo -e >&2 "--> Try \"${CC}rm -rf ${PKG_DIR}${CN}\""; return 0; }
	return 1
}

mkdir -p "${PKG_DIR}" 2>/dev/null
cd "${BASEDIR}"
