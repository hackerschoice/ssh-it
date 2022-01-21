#! /usr/bin/env bash

BINDIR="$(cd "$(dirname "${0}")" || exit; pwd)"
source "${BINDIR}/funcs" || exit 254

[[ -z $THC_PWD_FILE ]] && ERREXIT 123 "THC_PWD_FILE= not set"

MYDIR="$(cd "$(dirname "${0}")" || exit; pwd)"

[[ ! -f "${THC_PWD_FILE}" ]] && ERREXIT 124 "Not found: ${THC_PWD_FILE}"
source "${THC_PWD_FILE}" 2>/dev/null || ERREXIT 125 "bad content in ${THC_PWD_FILE}"

# Check if password was used:
SSH_PASSWORD=
[[ -z $LOG_PASSWORD ]] && LOG_PASSWORD="thc-was-empty-pwd"

export SSH_ASKPASS="${MYDIR}/askpass.sh"
export SSH_ASKPASS_REQUIRE="force"
export SSH_PASSWORD="$LOG_PASSWORD"
DEBUGF "Using SSH_PASSWORD=${SSH_PASSWORD}"

SSH_CMD="$(tail -n1 "${THC_PWD_FILE}" | cut -f2 -d\#)"
[[ -z $SSH_CMD ]] && ERREXIT 126 "SSH_CMD= not set"

DEBUGF "SSH_CMD             = $SSH_CMD"
DEBUGF "SSH_ASKPASS         = ${SSH_ASKPASS}"
DEBUGF "SSH_ASKPASS_REQUIRE = ${SSH_ASKPASS_REQUIRE}"
DEBUGF "SSH_PASSWORD        = ${SSH_PASSWORD}"

# FIXME: some SSH-versions do not support SSH_ASKPASS_REQUIRED=force.
# In this case we must undo the tty using setsid (if available).
# FIXME: setsid is not always available. Implement a cheap setsid()
# in ptyspy.
# If this is still a TTY then use 'setsid' to make it non-tty:
tty &>/dev/null && command -v setsid && { DISPLAY= exec setsid -w $SSH_CMD $@ || ERREXIT 126 "Cant execute '$SSH_CMD $@'"; }

DISPLAY= exec $SSH_CMD $@ || ERREXIT 126 "Cant execute '$SSH_CMD $@'"

