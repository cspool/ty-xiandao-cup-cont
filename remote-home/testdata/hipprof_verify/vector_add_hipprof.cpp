#include <hip/hip_runtime.h>
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

__global__ void vector_add_kernel(const float* a, const float* b, float* c,
                                  int n) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n) {
    c[idx] = a[idx] + b[idx];
  }
}

int main() {
  constexpr int n = 1 << 20;
  constexpr int block = 256;
  const int grid = (n + block - 1) / block;

  int device = 0;
  hipDeviceProp_t prop{};
  CHECK_HIP(hipGetDevice(&device));
  CHECK_HIP(hipGetDeviceProperties(&prop, device));
  std::printf("Device name %s\n", prop.name);

  std::vector<float> h_a(n), h_b(n), h_c(n);
  for (int i = 0; i < n; ++i) {
    h_a[i] = static_cast<float>(i % 1024);
    h_b[i] = static_cast<float>((i * 3) % 1024);
  }

  float* d_a = nullptr;
  float* d_b = nullptr;
  float* d_c = nullptr;
  CHECK_HIP(hipMalloc(&d_a, n * sizeof(float)));
  CHECK_HIP(hipMalloc(&d_b, n * sizeof(float)));
  CHECK_HIP(hipMalloc(&d_c, n * sizeof(float)));

  CHECK_HIP(hipMemcpy(d_a, h_a.data(), n * sizeof(float),
                      hipMemcpyHostToDevice));
  CHECK_HIP(hipMemcpy(d_b, h_b.data(), n * sizeof(float),
                      hipMemcpyHostToDevice));

  hipLaunchKernelGGL(vector_add_kernel, dim3(grid), dim3(block), 0, 0, d_a, d_b,
                     d_c, n);
  CHECK_HIP(hipGetLastError());
  CHECK_HIP(hipDeviceSynchronize());

  CHECK_HIP(hipMemcpy(h_c.data(), d_c, n * sizeof(float),
                      hipMemcpyDeviceToHost));
  CHECK_HIP(hipFree(d_a));
  CHECK_HIP(hipFree(d_b));
  CHECK_HIP(hipFree(d_c));

  for (int i = 0; i < n; ++i) {
    float expected = h_a[i] + h_b[i];
    if (h_c[i] != expected) {
      std::fprintf(stderr, "mismatch at %d: got=%f expected=%f\n", i, h_c[i],
                   expected);
      return 2;
    }
  }
  std::puts("PASSED vector_add_hipprof");
  return 0;
}
