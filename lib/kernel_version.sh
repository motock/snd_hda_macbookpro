#!/bin/bash
#
# lib/kernel_version.sh -- sourced helpers; define version_lt and
# is_kernel_release.
#
#     version_lt <a> <b>        true when version a is strictly below version b
#     is_kernel_release <rel>   true when rel starts with MAJOR.MINOR[.PATCH]
#
# Versions compare numerically per component (sort -V), so 6.9 < 6.17 and
# 6.100 > 6.17; a string comparison gets both wrong.

version_lt() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

is_kernel_release() {
	[[ $1 =~ ^[0-9]+\.[0-9]+ ]]
}
