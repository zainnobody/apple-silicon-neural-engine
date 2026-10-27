#!/usr/bin/env bash
# Stage 0: build llama.cpp with Vulkan, then measure GPU and CPU speed with llama-bench.
# Run as your user on a GPU boot (native Mesa active). Only "deps" uses sudo.
#   llm/stage0.sh deps     install cmake, glslc and SPIR-V headers (sudo password)
#   llm/stage0.sh build    clone and build llama.cpp
#   llm/stage0.sh models   download the test models (about 7 GB)
#   llm/stage0.sh bench    run llama-bench, Vulkan and CPU, write results
set -euo pipefail

WORK="${LLM_WORK:-$HOME/llm-work}"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
LLAMA_COMMIT="${LLAMA_COMMIT:-}"   # empty: current master, the commit is logged
MODELS=(
	"bartowski/Llama-3.2-3B-Instruct-GGUF Llama-3.2-3B-Instruct-Q4_K_M.gguf"
	"bartowski/Meta-Llama-3.1-8B-Instruct-GGUF Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
)
mkdir -p "$WORK/models" "$WORK/results"

case "${1:-}" in
deps)
	sudo dnf install -y cmake glslc libshaderc-devel spirv-headers-devel vulkan-headers vulkan-loader-devel
	;;
build)
	[ -d "$WORK/llama.cpp" ] || git clone "$LLAMA_REPO" "$WORK/llama.cpp"
	cd "$WORK/llama.cpp"
	[ -n "$LLAMA_COMMIT" ] && git checkout -q "$LLAMA_COMMIT"
	git rev-parse HEAD > "$WORK/results/llama-commit"
	cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
	cmake --build build -j"$(nproc)" --target llama-bench llama-cli
	;;
models)
	for m in "${MODELS[@]}"; do
		set -- $m
		if [ ! -f "$WORK/models/$2" ]; then
			curl -fsSL --retry 3 -o "$WORK/models/$2.part" "https://huggingface.co/$1/resolve/main/$2"
			mv -f "$WORK/models/$2.part" "$WORK/models/$2"
		fi
		sha256sum "$WORK/models/$2"
	done | tee "$WORK/results/models.sha256"
	;;
bench)
	B="$WORK/llama.cpp/build/bin/llama-bench"
	out="$WORK/results/bench-$(date +%Y%m%d-%H%M)"
	mkdir -p "$out"
	{ uname -r; vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverInfo' || true; } > "$out/system.txt"
	for m in "$WORK"/models/*.gguf; do
		n="$(basename "$m" .gguf)"
		"$B" -m "$m" -p 512 -n 128 -r 3 -ngl 99 -o md > "$out/$n-vulkan.md" 2>"$out/$n-vulkan.err" || echo "vulkan failed: $n" >> "$out/failures"
		"$B" -m "$m" -p 512 -n 128 -r 3 -ngl 0 -t 6 -o md > "$out/$n-cpu.md" 2>"$out/$n-cpu.err" || echo "cpu failed: $n" >> "$out/failures"
	done
	if grep -qs "SUBMIT failed" "$out"/*-vulkan.err; then
		echo "GPU jobs failed (SUBMIT failed): the Vulkan numbers are not valid" | tee "$out/INVALID-vulkan"
	fi
	echo "results: $out"
	;;
*)
	sed -n '2,8p' "$0"; exit 1
	;;
esac
