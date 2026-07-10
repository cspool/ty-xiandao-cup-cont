#include <hip/hip_runtime.h>
#include <roctx.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK_HIP(cmd)                                                       \
  do {                                                                       \
    hipError_t err__ = (cmd);                                                \
    if (err__ != hipSuccess) {                                               \
      std::fprintf(stderr, "HIP error %s at %s:%d\n",                       \
                   hipGetErrorString(err__), __FILE__, __LINE__);            \
      std::exit(1);                                                          \
    }                                                                        \
  } while (0)

__global__ void vector_add_roctx_kernel(const float* a, const float* b,
                                        float* c, int n) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n) {
    c[idx] = a[idx] + b[idx];
  }
}

int main() {
  constexpr int n = 1 << 20;
  constexpr int block = 256;
  const int grid = (n + block - 1) / block;

  hipDeviceProp_t prop{};
  CHECK_HIP(hipGetDeviceProperties(&prop, 0));
  std::printf("Device name %s\n", prop.name);

  std::vector<float> h_a(n, 1.0f), h_b(n, 2.0f), h_c(n, 0.0f);
  float* d_a = nullptr;
  float* d_b = nullptr;
  float* d_c = nullptr;
  CHECK_HIP(hipMalloc(&d_a, n * sizeof(float)));
  CHECK_HIP(hipMalloc(&d_b, n * sizeof(float)));
  CHECK_HIP(hipMalloc(&d_c, n * sizeof(float)));

  roctxMark("before h2d memcpy");
  CHECK_HIP(hipMemcpy(d_a, h_a.data(), n * sizeof(float),
                      hipMemcpyHostToDevice));
  CHECK_HIP(hipMemcpy(d_b, h_b.data(), n * sizeof(float),
                      hipMemcpyHostToDevice));

  int range_id = roctxRangeStart("vector_add_roctx_kernel range");
  roctxRangePush("vector_add_roctx_kernel push");
  hipLaunchKernelGGL(vector_add_roctx_kernel, dim3(grid), dim3(block), 0, 0,
                     d_a, d_b, d_c, n);
  CHECK_HIP(hipGetLastError());
  CHECK_HIP(hipDeviceSynchronize());
  roctxRangePop();
  roctxRangeStop(range_id);
  roctxMark("after vector_add_roctx_kernel");

  CHECK_HIP(hipMemcpy(h_c.data(), d_c, n * sizeof(float),
                      hipMemcpyDeviceToHost));
  CHECK_HIP(hipFree(d_a));
  CHECK_HIP(hipFree(d_b));
  CHECK_HIP(hipFree(d_c));

  for (int i = 0; i < n; ++i) {
    if (h_c[i] != 3.0f) {
      std::fprintf(stderr, "mismatch at %d: got=%f\n", i, h_c[i]);
      return 2;
    }
  }
  std::puts("PASSED vector_add_roctx");
  return 0;
}
