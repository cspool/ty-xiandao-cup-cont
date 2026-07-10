# Split artifact restore

The original file exceeded GitHub's normal 100 MB single-file limit and is stored as numbered parts in:

`remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so.parts/`

Restore with:

`cat remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so.parts/part-* > remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so`

Then verify:

`sha256sum -c remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so.sha256`
