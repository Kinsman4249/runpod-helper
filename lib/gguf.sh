# lib/gguf.sh - "custom GGUF" model path: point at any Hugging Face GGUF repo
# and pick a quant from what that repo actually publishes, instead of needing a
# hand-written PRESET_TABLE row (lib/launch.sh) for it first. Sourced by
# startup.sh and e2e-test.sh; driven by pick_preset_and_gpu() in lib/select.sh.
#
# llama.cpp's --hf-repo takes "<repo>:<quant tag>" directly (the exact syntax
# the built-in GGUF presets already use, see PRESET_TABLE) and downloads/serves
# the matching file itself, so all this path has to do is help you choose a real
# quant tag and size a GPU/volume for it. The quant list and byte sizes come
# from the HF tree API (huggingface.co/api/models/<repo>/tree/main), which
# returns lfs.size per GGUF - confirmed live 2026-08-15 against
# mradermacher/...-GGUF. The "recommended" hint is a best-effort scan of the
# repo's README: publishers like mradermacher and bartowski mark quants
# "recommended" on the same markdown table row as the quant name (both formats
# confirmed live 2026-08-15) - it's a convenience flag on the menu, never a
# gate, and simply absent for a repo whose README doesn't say.

# Approx VRAM headroom (GB) added on top of a quant's on-disk weight size to get
# the GPU-list floor for a custom GGUF. Covers llama.cpp's KV cache + compute
# buffers at a modest context. Deliberately rough: a GGUF repo rarely states an
# architecture we could size exactly the way the built-in presets were sized
# (see PRESET_TABLE's qwen3.5-40b-deckard-gguf comment for a real hand
# computation), so this errs toward a small cushion and is labeled approximate
# everywhere it's surfaced. The GPU menu still shows every card at/above it, so
# a too-low guess just means you pick a bigger card yourself.
GGUF_VRAM_HEADROOM_GB=4

# Fetches $1's GGUF quants and prints one TAB-separated row per quant, smallest
# first:  <quant tag>\t<size bytes>\t<recommended: 1|0>
# Skips non-model .gguf sidecars (mmproj multimodal projectors). Multi-part
# quants (a single quant split across ...-00001-of-00003.gguf files) collapse to
# one row whose size is the sum of the parts. Prints nothing and returns 1 if
# the API call fails or the repo exposes no usable GGUF file.
list_gguf_quants() {
  local repo="$1"
  local tree rows readme
  # recursive=true so quants a repo tucks into subfolders are still seen; the
  # tag-based grouping below doesn't care what directory a file lives in.
  tree="$(curl -fsSL --max-time 30 "https://huggingface.co/api/models/$repo/tree/main?recursive=true" 2>/dev/null)" \
    || return 1

  # One row per distinct quant tag, smallest first. The quant tag is the last
  # quant-shaped token in the filename (case-insensitive: Q2_K, Q4_K_M, IQ4_XS,
  # BF16, F16, F32...), matched with a non-capturing regex so jq's scan returns
  # plain strings; multi-part files share a tag and get summed by group_by.
  rows="$(jq -r '
    [ .[]
      | select(.type == "file")
      | .path as $p
      | select(($p | ascii_downcase) | endswith(".gguf"))
      | select(($p | ascii_downcase) | test("mmproj") | not)
      | ($p | split("/") | last) as $base
      | ([$base | scan("(?:iq|q)[0-9](?:_[a-z0-9]+)*|bf16|f16|f32"; "i")] | last) as $q
      | select($q != null)
      | {quant: $q, size: (.lfs.size // .size)} ]
    | group_by(.quant)
    | map({quant: .[0].quant, size: (map(.size) | add)})
    | sort_by(.size)
    | .[] | [.quant, (.size | tostring)] | @tsv
  ' <<< "$tree" 2>/dev/null)" || return 1
  [[ -n "$rows" ]] || return 1

  # README is best-effort only - a missing/unreadable one just means no
  # "recommended" hints, never a failure.
  readme="$(curl -fsSL --max-time 20 "https://huggingface.co/$repo/raw/main/README.md" 2>/dev/null || true)"

  local quant size rec
  while IFS=$'\t' read -r quant size; do
    rec=0
    if [[ -n "$readme" ]]; then
      # A table row that names this exact quant tag and also says
      # "recommended" (but not "not recommended"). Underscore is NOT treated as
      # a tag boundary, so a bare "Q6_K" hint can't bleed onto a "Q6_K_L" row.
      if grep -iE "(^|[^a-z0-9_])$quant([^a-z0-9_]|\$)" <<< "$readme" \
           | grep -i "recommended" | grep -vi "not recommended" | grep -q .; then
        rec=1
      fi
    fi
    printf '%s\t%s\t%s\n' "$quant" "$size" "$rec"
  done <<< "$rows"
}

# Bytes -> "NN.NGB" for menu display, matching how the rest of the tool talks
# about sizes (GiB, quoted loosely as "GB" - same unit RunPod's own memoryInGb
# GPU field uses, so a quant size and a card's VRAM are directly comparable).
gguf_human_size() {
  awk -v b="$1" 'BEGIN { printf "%.1fGB", b / 1073741824 }'
}

# Whole GB a quant's weights occupy, rounded up - the base the GPU-list VRAM
# floor and the suggested network-volume size are both built on.
gguf_weight_gb_ceil() {
  awk -v b="$1" 'BEGIN { g = b / 1073741824; r = int(g); if (g > r) r += 1; print r }'
}
