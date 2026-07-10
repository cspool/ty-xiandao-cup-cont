# Restore Large Artifacts

GitHub normal Git rejects files larger than 100 MB. Two vLLM build shared objects were stored as split parts.

Run from repository root after cloning:

```bash
cat remote-home/vllm_cscc/build/temp.linux-x86_64-cpython-310/_C.abi3.so.parts/part-* \
  > remote-home/vllm_cscc/build/temp.linux-x86_64-cpython-310/_C.abi3.so
sha256sum -c remote-home/vllm_cscc/build/temp.linux-x86_64-cpython-310/_C.abi3.so.sha256

cat remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so.parts/part-* \
  > remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so
sha256sum -c remote-home/vllm_cscc/build/lib.linux-x86_64-cpython-310/vllm/_C.abi3.so.sha256
```
