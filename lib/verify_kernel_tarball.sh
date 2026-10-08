#!/bin/bash
#
# lib/verify_kernel_tarball.sh -- sourced helper; defines verify_kernel_tarball.
#
#     verify_kernel_tarball <tarball-path> <version>
#
# Checks <tarball-path> (linux-<version>.tar.xz) against the SHA-256 that
# kernel.org publishes in sha256sums.asc.  Fails closed: any problem returns
# non-zero, prints the reason to stderr and deletes the tarball so that
# `wget -c` can never resume a poisoned file.
#
# Not covered (follow-up): verifying the GPG signature of sha256sums.asc.  The
# sums file is fetched over HTTPS, which protects against truncation and
# on-path tampering but not against a compromised mirror.

_vkt_fail() {
	echo "verify_kernel_tarball: $1" >&2
	rm -f -- "$_vkt_tarball"
	[[ -n $_vkt_sums ]] && rm -f -- "$_vkt_sums"
	return 1
}

verify_kernel_tarball() {
	_vkt_tarball=$1
	local version=$2
	_vkt_sums=""

	if [[ -z $_vkt_tarball || -z $version ]]; then
		echo "verify_kernel_tarball: usage: verify_kernel_tarball <tarball-path> <version>" >&2
		return 1
	fi
	# the version is interpolated into a URL and a regex: allow digits and dots only
	if [[ ! $version =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
		_vkt_fail "invalid kernel version '$version'"
		return 1
	fi

	local major=${version%%.*}
	local name="linux-$version.tar.xz"
	local url="https://cdn.kernel.org/pub/linux/kernel/v$major.x/sha256sums.asc"

	if [[ ! -f $_vkt_tarball ]]; then
		_vkt_fail "tarball not found: $_vkt_tarball"
		return 1
	fi

	_vkt_sums=$(mktemp) || { _vkt_fail "cannot create a temporary file"; return 1; }
	if ! wget -q -O "$_vkt_sums" "$url" || [[ ! -s $_vkt_sums ]]; then
		_vkt_fail "could not download $url"
		return 1
	fi

	local pattern="^[0-9a-f]{64}  ${name//./\\.}\$"
	local matches
	matches=$(grep -E "$pattern" "$_vkt_sums" | wc -l | tr -d ' ')
	if [[ $matches -eq 0 ]]; then
		_vkt_fail "no checksum for $name in $url"
		return 1
	elif [[ $matches -gt 1 ]]; then
		_vkt_fail "$matches checksums for $name in $url (expected exactly one)"
		return 1
	fi
	local expected
	expected=$(grep -E "$pattern" "$_vkt_sums" | cut -c1-64)

	local actual
	if command -v sha256sum > /dev/null 2>&1; then
		actual=$(sha256sum "$_vkt_tarball" | cut -c1-64)
	elif command -v shasum > /dev/null 2>&1; then
		actual=$(shasum -a 256 "$_vkt_tarball" | cut -c1-64)
	else
		_vkt_fail "neither sha256sum nor shasum is available"
		return 1
	fi

	if [[ -z $actual || $actual != "$expected" ]]; then
		_vkt_fail "SHA-256 mismatch for $name: expected ${expected:0:12}..., got ${actual:0:12}...; tarball deleted"
		return 1
	fi

	rm -f -- "$_vkt_sums"
	echo "verified $name (sha256 ${actual:0:12}...)"
	return 0
}
