#!/usr/bin/env bash
# Stage 0: build llama.cpp with Vulkan, then measure GPU and CPU speed with llama-bench.
# Run as your user on a GPU boot (native Mesa active). Only "deps" uses sudo.
#   llm/stage0.sh deps     install cmake, glslc and SPIR-V headers (sudo password)
#   llm/stage0.sh build    clone and build llama.cpp
#   llm/stage0.sh models   download the test models (about 7 GB)
#   llm/stage0.sh bench    run llama-bench, Vulkan and CPU, write results
#   llm/stage0.sh check    same prompt on the GPU and the CPU, the text must match
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
	cmake --build build -j"$(nproc)" --target llama-bench llama-completion
	cmake -B build-cpu -DGGML_VULKAN=OFF -DCMAKE_BUILD_TYPE=Release
	cmake --build build-cpu -j"$(nproc)" --target llama-bench llama-completion
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
	# Vulkan must load the native Mesa driver. Without this, a shell outside the desktop
	# session (SSH) loads the distribution's Mesa, which cannot run compute on new GPUs.
	if [ -z "${VK_DRIVER_FILES:-}" ]; then
		for p in /opt/mesa-agx /opt/mesa-m3; do
			[ -f "$p/share/vulkan/icd.d/asahi_icd.aarch64.json" ] && { export VK_DRIVER_FILES="$p/share/vulkan/icd.d/asahi_icd.aarch64.json"; break; }
		done
	fi
	B="$WORK/llama.cpp/build/bin/llama-bench"
	out="$WORK/results/bench-$(date +%Y%m%d-%H%M)"
	mkdir -p "$out"
	{ uname -r; echo "VK_DRIVER_FILES=${VK_DRIVER_FILES:-}"; vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverInfo' || true; } > "$out/system.txt"
	for m in "$WORK"/models/*.gguf; do
		n="$(basename "$m" .gguf)"
		"$B" -m "$m" -p 512 -n 128 -r 3 -ngl 99 -fa 1 -o md > "$out/$n-vulkan.md" 2>"$out/$n-vulkan.err" || echo "vulkan failed: $n" >> "$out/failures"
		# CPU numbers need a build without Vulkan (build-cpu): with Vulkan, llama.cpp sends
		# large prompt batches to the GPU even with -ngl 0.
		[ -x "$WORK/llama.cpp/build-cpu/bin/llama-bench" ] && "$WORK/llama.cpp/build-cpu/bin/llama-bench" \
			-m "$m" -p 512 -n 128 -r 3 -t 6 -o md > "$out/$n-cpu.md" 2>"$out/$n-cpu.err" || echo "cpu failed: $n" >> "$out/failures"
	done
	if grep -qs "SUBMIT failed" "$out"/*-vulkan.err; then
		echo "GPU jobs failed (SUBMIT failed): the Vulkan numbers are not valid" | tee "$out/INVALID-vulkan"
	fi
	echo "results: $out"
	;;
check)
	[ -z "${VK_DRIVER_FILES:-}" ] && for p in /opt/mesa-agx /opt/mesa-m3; do
		[ -f "$p/share/vulkan/icd.d/asahi_icd.aarch64.json" ] && { export VK_DRIVER_FILES="$p/share/vulkan/icd.d/asahi_icd.aarch64.json"; break; }
	done
	P="The capital of France is Paris. List the first five prime numbers, separated by commas:"
	m="$(ls "$WORK"/models/*.gguf | head -1)"
	"$WORK/llama.cpp/build/bin/llama-completion" -m "$m" -p "$P" -n 40 --temp 0 --seed 1 -ngl 99 -fa on \
		-no-cnv --no-display-prompt 2>/dev/null > "$WORK/results/check-gpu.txt"
	"$WORK/llama.cpp/build-cpu/bin/llama-completion" -m "$m" -p "$P" -n 40 --temp 0 --seed 1 \
		-no-cnv --no-display-prompt 2>/dev/null > "$WORK/results/check-cpu.txt"
	cat "$WORK/results/check-gpu.txt"
	cmp -s "$WORK/results/check-gpu.txt" "$WORK/results/check-cpu.txt" && echo CHECK_SAME || { echo CHECK_DIFFERENT; exit 1; }
	;;
*)
	sed -n '2,9p' "$0"; exit 1
	;;
esac
