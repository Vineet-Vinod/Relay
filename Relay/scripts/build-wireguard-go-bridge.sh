#!/bin/sh
set -eu

find_go_bin() {
	for candidate in \
		"${GO_BIN:-}" \
		/opt/homebrew/opt/go@1.24/bin/go \
		/opt/homebrew/opt/go@1.23/bin/go \
		/opt/homebrew/opt/go@1.22/bin/go \
		/usr/local/opt/go@1.24/bin/go \
		/usr/local/opt/go@1.23/bin/go \
		/usr/local/opt/go@1.22/bin/go
	do
		if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done

	command -v go 2>/dev/null || true
}

find_checkout() {
	if [ -n "${WIREGUARD_APPLE_CHECKOUT:-}" ] && [ -d "${WIREGUARD_APPLE_CHECKOUT}/Sources/WireGuardKitGo" ]; then
		printf '%s\n' "${WIREGUARD_APPLE_CHECKOUT}/Sources/WireGuardKitGo"
		return 0
	fi

	for candidate in \
		"${SRCROOT:-}/SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo" \
		"${PROJECT_DIR:-}/SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo" \
		"${BUILD_DIR:-}/../../SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo" \
		"${BUILD_ROOT:-}/../../SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo" \
		"${OBJROOT:-}/../../SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo"
	do
		if [ -d "${candidate}" ]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done

	for candidate in "${HOME}"/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo
	do
		if [ -d "${candidate}" ]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done

	return 1
}

GO_BIN="$(find_go_bin)"
if [ -z "${GO_BIN}" ]; then
	echo "Unable to locate a Go toolchain. Install Homebrew Go first." >&2
	exit 1
fi

export PATH="$(dirname "${GO_BIN}"):${PATH}:/opt/homebrew/bin:/usr/local/bin"

GO_VERSION="$("${GO_BIN}" env GOVERSION 2>/dev/null || "${GO_BIN}" version | awk '{print $3}')"
case "${GO_VERSION}" in
	go1.25*|go1.26*|go1.27*|go1.28*|go1.29*)
		echo "WireGuardKitGo is not currently building cleanly with ${GO_VERSION}." >&2
		echo "Install Homebrew go@1.24 and rebuild, or set GO_BIN to a compatible Go binary." >&2
		exit 1
		;;
esac

WIREGUARD_KIT_GO_DIR="$(find_checkout || true)"
if [ -z "${WIREGUARD_KIT_GO_DIR}" ]; then
	echo "Unable to locate the wireguard-apple package checkout." >&2
	echo "Resolve Swift packages in Xcode first, or set WIREGUARD_APPLE_CHECKOUT." >&2
	exit 1
fi

REAL_GOROOT="${REAL_GOROOT:-$("${GO_BIN}" env GOROOT 2>/dev/null || true)}"
if [ -z "${REAL_GOROOT}" ]; then
	echo "Unable to resolve GOROOT. Install Go and ensure 'go env GOROOT' works." >&2
	exit 1
fi

cd "${WIREGUARD_KIT_GO_DIR}"
exec /usr/bin/make REAL_GOROOT="${REAL_GOROOT}"
