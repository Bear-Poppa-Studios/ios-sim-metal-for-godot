#!/usr/bin/env bash
# Builds a Godot 4.7.2 iOS debug export template whose simulator slice is an arm64 build with
# the Metal renderer enabled.
#
# Usage: ./build.sh [templates]
#   templates  the official Godot_v4.7.2-stable_export_templates.tpz, or the ios.zip taken from
#              it. Omitted: the .tpz is downloaded from the Godot release and its SHA-512 checked.
#
# Environment:
#   DEVELOPER_DIR  Xcode to build with (default: /Applications/Xcode-27.1-RC.app/Contents/Developer)
#   JOBS           parallel scons jobs (default: the CPU count)
#
# Output: dist/ios_sim_debug.zip and dist/SHA256SUMS. Work files go to src/ and build/.

set -euo pipefail

GODOT_VERSION="4.7.2"
GODOT_TAG="${GODOT_VERSION}-stable"
GODOT_REPO="https://github.com/godotengine/godot.git"
RELEASE_URL="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}"
TPZ_NAME="Godot_v${GODOT_TAG}_export_templates.tpz"
SIM_LIB="libgodot.ios.debug.xcframework/ios-arm64_x86_64-simulator/libgodot.a"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src/godot"
WORK="$ROOT/build"
DIST="$ROOT/dist"
PATCH="$ROOT/patches/all.patch"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1-RC.app/Contents/Developer}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

check_prerequisites() {
	[ "$(uname -s)" = Darwin ] || die "macOS is required."
	[ "$(uname -m)" = arm64 ] || die "An Apple Silicon Mac is required: the iOS 27 simulator runs arm64 apps only."
	[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at DEVELOPER_DIR=$DEVELOPER_DIR."
	local tool
	for tool in git scons python3 curl unzip zip lipo shasum; do
		command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed."
	done
	local sdk
	sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)" || die "No iOS Simulator SDK in $DEVELOPER_DIR."
	say "iOS Simulator SDK $sdk ($DEVELOPER_DIR)"
}

fetch_source() {
	if [ ! -d "$SRC/.git" ]; then
		say "Cloning Godot $GODOT_TAG"
		mkdir -p "$(dirname "$SRC")"
		git clone --quiet --depth 1 --branch "$GODOT_TAG" "$GODOT_REPO" "$SRC"
	fi
	if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
		say "Applying patches"
		git -C "$SRC" apply "$PATCH"
	elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
		say "Patches already applied"
	else
		die "patches/all.patch neither applies to nor is applied in $SRC; delete src/ and rerun."
	fi
}

build_library() {
	say "Building the arm64 simulator library (scons -j$JOBS)"
	(cd "$SRC" && scons platform=ios target=template_debug arch=arm64 ios_simulator=yes "-j$JOBS")
	LIB_ARM64="$SRC/bin/libgodot.ios.template_debug.arm64.simulator.a"
	[ -f "$LIB_ARM64" ] || die "scons did not produce $LIB_ARM64."
}

# Leaves the official ios.zip at $WORK/ios.zip.
official_template() {
	local given="${1:-}" tpz
	mkdir -p "$WORK"
	rm -f "$WORK/ios.zip"
	case "$given" in
	*.zip)
		[ -f "$given" ] || die "$given not found."
		cp "$given" "$WORK/ios.zip"
		return
		;;
	*.tpz)
		[ -f "$given" ] || die "$given not found."
		tpz="$given"
		;;
	"")
		tpz="$WORK/$TPZ_NAME"
		if [ ! -f "$tpz" ]; then
			say "Downloading $TPZ_NAME"
			curl -fL --progress-bar -o "$tpz.part" "$RELEASE_URL/$TPZ_NAME"
			mv "$tpz.part" "$tpz"
		fi
		local expected actual
		expected="$(curl -fsL "$RELEASE_URL/SHA512-SUMS.txt" | awk -v f="$TPZ_NAME" '$2 == f { print $1 }')"
		[ -n "$expected" ] || die "No SHA-512 for $TPZ_NAME in the release's SHA512-SUMS.txt."
		actual="$(shasum -a 512 "$tpz" | awk '{ print $1 }')"
		[ "$expected" = "$actual" ] || die "SHA-512 mismatch for $tpz; delete it and rerun."
		say "SHA-512 verified"
		;;
	*)
		die "Expected a .tpz or an ios.zip, got: $given"
		;;
	esac
	unzip -p "$tpz" templates/ios.zip >"$WORK/ios.zip" || die "templates/ios.zip not found in $tpz."
}

splice_template() {
	local stage="$WORK/stage" official="$WORK/official_sim_libgodot.a" x86="$WORK/libgodot.x86_64.a"
	say "Splicing the simulator library into the template"
	rm -rf "$stage"
	mkdir -p "$stage/$(dirname "$SIM_LIB")"
	unzip -p "$WORK/ios.zip" "$SIM_LIB" >"$official" || die "$SIM_LIB not found in ios.zip."

	# The official simulator library is x86_64 only; keep that slice next to the new arm64 one.
	case " $(lipo -archs "$official") " in
	*" x86_64 "*) ;;
	*) die "The official simulator library has no x86_64 slice." ;;
	esac
	if [ "$(lipo -archs "$official")" = x86_64 ]; then
		cp "$official" "$x86"
	else
		lipo "$official" -thin x86_64 -output "$x86"
	fi
	lipo -create "$x86" "$LIB_ARM64" -output "$stage/$SIM_LIB"

	mkdir -p "$DIST"
	cp "$WORK/ios.zip" "$DIST/ios_sim_debug.zip"
	(cd "$stage" && zip -q "$DIST/ios_sim_debug.zip" "$SIM_LIB")

	local staged packed
	staged="$(shasum -a 256 "$stage/$SIM_LIB" | awk '{ print $1 }')"
	packed="$(unzip -p "$DIST/ios_sim_debug.zip" "$SIM_LIB" | shasum -a 256 | awk '{ print $1 }')"
	[ "$staged" = "$packed" ] || die "The spliced library in the zip does not match the staged one."
	(cd "$DIST" && shasum -a 256 ios_sim_debug.zip >SHA256SUMS)
}

check_prerequisites
fetch_source
build_library
official_template "${1:-}"
splice_template
say "Done: $DIST/ios_sim_debug.zip"
cat "$DIST/SHA256SUMS"
