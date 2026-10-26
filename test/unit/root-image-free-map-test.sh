#!/bin/bash
#
# Unit tests for builder/root-image-free-map: the device ranges a btrfs image
# does not use, from its chunk tree and extent tree. btrfs-progs is stood in
# for by a script that serves the dumps below, so this needs no image.
#
# The pretend image is 32 MiB, nodesize 16 KiB:
#   [1 MiB, 9 MiB)    DATA chunk A, logical 1 MiB: extents at 1 MiB (2 MiB)
#                     and 4 MiB (5 MiB), so [3 MiB, 4 MiB) is free
#   [9 MiB, 13 MiB)   METADATA|DUP chunk B, logical 9 MiB, first stripe:
#   [13 MiB, 17 MiB)   second stripe. A 1 MiB extent at 9 MiB, a tree block
#                     at 10 MiB + 64 KiB, then an extent to the end, so
#                     [10 MiB, 10 MiB + 64 KiB) is free on both stripes
#   [17 MiB, 25 MiB)  DATA chunk C, logical 13 MiB, one extent: nothing free
# The extent tree dump also carries a node's child keys (no "item" prefix)
# and a BLOCK_GROUP_ITEM, both of which must be ignored.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

M=$((1024 * 1024))
K=1024
cat >"$work/super.txt" <<EOF
superblock: bytenr=65536, device=$work/image
---------------------------------------------------------
total_bytes		33554432
bytes_used		25165824
sectorsize		4096
nodesize		16384
EOF
cat >"$work/chunks.txt" <<EOF
chunk tree key (CHUNK_TREE ROOT_ITEM 0)
	item 0 key (DEV_ITEMS DEV_ITEM 1) itemoff 16185 itemsize 98
		devid 1 total_bytes 33554432 bytes_used 25165824
	item 1 key (FIRST_CHUNK_TREE CHUNK_ITEM $((1 * M))) itemoff 16105 itemsize 80
		length $((8 * M)) owner 2 stripe_len 65536 type DATA|single
		io_align 65536 io_width 65536 sector_size 4096
		num_stripes 1 sub_stripes 1
			stripe 0 devid 1 offset $((1 * M))
	item 2 key (FIRST_CHUNK_TREE CHUNK_ITEM $((9 * M))) itemoff 15993 itemsize 112
		length $((4 * M)) owner 2 stripe_len 65536 type METADATA|DUP
		io_align 65536 io_width 65536 sector_size 4096
		num_stripes 2 sub_stripes 1
			stripe 0 devid 1 offset $((9 * M))
			stripe 1 devid 1 offset $((13 * M))
	item 3 key (FIRST_CHUNK_TREE CHUNK_ITEM $((13 * M))) itemoff 15913 itemsize 80
		length $((8 * M)) owner 2 stripe_len 65536 type DATA|single
		io_align 65536 io_width 65536 sector_size 4096
		num_stripes 1 sub_stripes 1
			stripe 0 devid 1 offset $((17 * M))
total bytes 33554432
bytes used 25165824
EOF
cat >"$work/extent.txt" <<EOF
extent tree key (EXTENT_TREE ROOT_ITEM 0)
node 30000000 level 1 items 2 free space 491 generation 7 owner EXTENT_TREE
	key ($((1 * M)) EXTENT_ITEM $((2 * M))) block 30016384 gen 7
	key ($((3 * M)) EXTENT_ITEM $((1 * M))) block 30032768 gen 7
leaf 30016384 items 7 free space 15000 generation 7 owner EXTENT_TREE
	item 0 key ($((1 * M)) EXTENT_ITEM $((2 * M))) itemoff 16230 itemsize 53
		refs 1 gen 7 flags DATA
	item 1 key ($((1 * M)) BLOCK_GROUP_ITEM $((8 * M))) itemoff 16206 itemsize 24
		block group used 7340032 chunk_objectid 256 flags DATA
	item 2 key ($((4 * M)) EXTENT_ITEM $((5 * M))) itemoff 16153 itemsize 53
		refs 1 gen 7 flags DATA
	item 3 key ($((9 * M)) EXTENT_ITEM $((1 * M))) itemoff 16100 itemsize 53
		refs 1 gen 7 flags DATA
	item 4 key ($((10 * M + 64 * K)) METADATA_ITEM 0) itemoff 16067 itemsize 33
		refs 1 gen 7 flags TREE_BLOCK
	item 5 key ($((10 * M + 80 * K)) EXTENT_ITEM $((4 * M - 1 * M - 80 * K))) itemoff 16014 itemsize 53
		refs 1 gen 7 flags DATA
	item 6 key ($((13 * M)) EXTENT_ITEM $((8 * M))) itemoff 15961 itemsize 53
		refs 1 gen 7 flags DATA
EOF

mkdir -p "$work/bin"
cat >"$work/bin/btrfs" <<EOF
#!/bin/bash
case "\$*" in
  *"dump-super"*) cat "$work/super.txt" ;;
  *"-t chunk"*) cat "$work/chunks.txt" ;;
  *"-t extent"*) cat "$work/extent.txt" ;;
  *) echo "unexpected: btrfs \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/btrfs"
truncate -s $((32 * M)) "$work/image"

PATH="$work/bin:$PATH" "$ROOT/builder/root-image-free-map" "$work/image" >"$work/got" 2>"$work/err" ||
  fail "root-image-free-map succeeds" "$(cat "$work/err")"
sort -n "$work/got" >"$work/got.sorted"
sort -n >"$work/want.sorted" <<EOF
0 65536
69632 $((1 * M - 69632))
$((3 * M)) $((1 * M))
$((10 * M)) $((64 * K))
$((14 * M)) $((64 * K))
$((25 * M)) $((7 * M))
EOF
diff -u "$work/want.sorted" "$work/got.sorted" >&2 ||
  fail "the free ranges: unallocated gaps with the superblock kept, A's gap, B's gap on both stripes, nothing of C"
pass "unallocated gaps (superblock kept), a gap between extents, a DUP gap on both stripes, a full chunk gives nothing"

[[ $(awk '($1 % 4096) || ($2 % 4096)' "$work/got" | wc -l) == 0 ]] || fail "every range is 4096-byte aligned"
pass "every range is 4096-byte aligned"

# An extent that reaches past its chunk is a corrupt tree: refuse, say so.
cp "$work/extent.txt" "$work/extent.good"
sed -i "s/item 2 key ($((4 * M)) EXTENT_ITEM $((5 * M)))/item 2 key ($((4 * M)) EXTENT_ITEM $((6 * M)))/" "$work/extent.txt"
if PATH="$work/bin:$PATH" "$ROOT/builder/root-image-free-map" "$work/image" >"$work/got2" 2>"$work/err2"; then
  fail "refuses an extent that crosses its chunk" "exit 0"
fi
grep -q "crosses a chunk" "$work/err2" || fail "says why it refused" "$(cat "$work/err2")"
pass "refuses an extent that crosses its chunk, and says so"

# An extent outside every chunk, likewise.
cp "$work/extent.good" "$work/extent.txt"
sed -i "s/item 6 key ($((13 * M)) EXTENT_ITEM $((8 * M)))/item 6 key ($((30 * M)) EXTENT_ITEM $((1 * M)))/" "$work/extent.txt"
if PATH="$work/bin:$PATH" "$ROOT/builder/root-image-free-map" "$work/image" >"$work/got3" 2>"$work/err3"; then
  fail "refuses an extent in no chunk" "exit 0"
fi
grep -q "in no chunk" "$work/err3" || fail "says why it refused" "$(cat "$work/err3")"
pass "refuses an extent in no chunk, and says so"
