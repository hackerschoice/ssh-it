#! /bin/bash

BASEDIR="$(cd "$(dirname "${0}")/../" || exit; pwd)"
source "${BASEDIR}/packaging/build_func.sh"

add_gs-netcat()
{
	local OSARCH

	GSNC_BINDIR="${BASEDIR}/../binary/gsocket/bin/"
	[[ -d "$GSNC_BINDIR" ]] || warn "gs-netcat static binaries not available. Skipping."

	mkdir -p "${PKG_DIR}/gsnc" 2>/dev/null

	for f in "${PKG_DIR}"/ptyspy_bin.*; do
		[[ $f =~ 'ptyspy_bin.*' ]] && errexit "ptyspy_bin.* missing"
		OSARCH="$(echo "$(basename "$f")" | cut -f2 -d.)"
		gsnc_tgz="${GSNC_BINDIR}/gs-netcat_${OSARCH}.tar.gz"
		gsnc_dst="${PKG_DIR}/gsnc/gs-netcat.${OSARCH}"
		[[ -f "${gsnc_tgz}" ]] || { warn "Not found: ${gsnc_tgz}"; continue; }
		[[ "${gsnc_tgz}" -nt "${gsnc_dst}" ]] || { exists "$OSARCH" "gsnc/gs-netcat" && continue; }
		(cd "${PKG_DIR}/gsnc" && tar xfz "${gsnc_tgz}" && chmod 755 gs-netcat && touch -r "${gsnc_tgz}" gs-netcat && mv gs-netcat "gs-netcat.${OSARCH}" ) || errexit "Aborted"
		ok "DONE adding gs-netcat.${OSARCH}"
	done
}

"${BASEDIR}/packaging/build_static.sh" && \
"${BASEDIR}/packaging/build_docker.sh" && \

# Copy all other supporting files
(cd "${BASEDIR}/src" && cp x.sh hook.sh "${PKG_DIR}/" || false ) && \
# Add gs-netcat if exist
add_gs-netcat
(cd "${PKG_TOP_DIR}" && \
	tar cfz ssh-it-pkg.tar.gz $TARUIDGID ssh-it-pkg && \
	ls -al ssh-it-pkg.tar.gz && \
	md5sum ssh-it-pkg.tar.gz && \
	true || false ) && \
ok "DONE" || errexit "Aborted"
