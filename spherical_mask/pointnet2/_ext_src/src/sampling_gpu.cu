// Copyright (c) Facebook, Inc. and its affiliates.


#include <stdio.h>
#include <stdlib.h>

#include "cuda_utils.h"

// input: points(b, c, n) idx(b, m)
// output: out(b, c, m)
__global__ void gather_points_kernel(int b, int c, int n, int m,
                                     const float *__restrict__ points,
                                     const int *__restrict__ idx,
                                     float *__restrict__ out) {
  for (int i = blockIdx.x; i < b; i += gridDim.x) {
    for (int l = blockIdx.y; l < c; l += gridDim.y) {
      for (int j = threadIdx.x; j < m; j += blockDim.x) {
        int a = idx[i * m + j];
        out[(i * c + l) * m + j] = points[(i * c + l) * n + a];
      }
    }
  }
}

void gather_points_kernel_wrapper(int b, int c, int n, int npoints,
                                  const float *points, const int *idx,
                                  float *out) {
  gather_points_kernel<<<dim3(b, c, 1), opt_n_threads(npoints), 0,
                         at::cuda::getCurrentCUDAStream()>>>(b, c, n, npoints,
                                                             points, idx, out);

  CUDA_CHECK_ERRORS();
}

// input: grad_out(b, c, m) idx(b, m)
// output: grad_points(b, c, n)
__global__ void gather_points_grad_kernel(int b, int c, int n, int m,
                                          const float *__restrict__ grad_out,
                                          const int *__restrict__ idx,
                                          float *__restrict__ grad_points) {
  for (int i = blockIdx.x; i < b; i += gridDim.x) {
    for (int l = blockIdx.y; l < c; l += gridDim.y) {
      for (int j = threadIdx.x; j < m; j += blockDim.x) {
        int a = idx[i * m + j];
        atomicAdd(grad_points + (i * c + l) * n + a,
                  grad_out[(i * c + l) * m + j]);
      }
    }
  }
}

void gather_points_grad_kernel_wrapper(int b, int c, int n, int npoints,
                                       const float *grad_out, const int *idx,
                                       float *grad_points) {
  gather_points_grad_kernel<<<dim3(b, c, 1), opt_n_threads(npoints), 0,
                              at::cuda::getCurrentCUDAStream()>>>(
      b, c, n, npoints, grad_out, idx, grad_points);

  CUDA_CHECK_ERRORS();
}

__device__ void __update(float *__restrict__ dists, int *__restrict__ dists_i,
                         int idx1, int idx2) {
  const float v1 = dists[idx1], v2 = dists[idx2];
  const int i1 = dists_i[idx1], i2 = dists_i[idx2];
  dists[idx1] = max(v1, v2);
  dists_i[idx1] = v2 > v1 ? i2 : i1;
}

// Input dataset: (b, n, 3), tmp: (b, n)
// Ouput idxs (b, m)
template <unsigned int block_size>
__global__ void furthest_point_sampling_kernel(
    int b, int n, int m, const float *__restrict__ dataset,
    float *__restrict__ temp, int *__restrict__ idxs) {
  if (m <= 0) return;
  __shared__ float dists[block_size];
  __shared__ int dists_i[block_size];

  int batch_index = blockIdx.x;
  dataset += batch_index * n * 3;
  temp += batch_index * n;
  idxs += batch_index * m;

  int tid = threadIdx.x;
  const int stride = block_size;

  int old = 0;
  if (threadIdx.x == 0) idxs[0] = old;

  __syncthreads();
  for (int j = 1; j < m; j++) {
    int besti = 0;
    float best = -1;
    float x1 = dataset[old * 3 + 0];
    float y1 = dataset[old * 3 + 1];
    float z1 = dataset[old * 3 + 2];
    for (int k = tid; k < n; k += stride) {
      float x2, y2, z2;
      x2 = dataset[k * 3 + 0];
      y2 = dataset[k * 3 + 1];
      z2 = dataset[k * 3 + 2];
      float mag = (x2 * x2) + (y2 * y2) + (z2 * z2);
      if (mag <= 1e-3) continue;

      float d =
          (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1) + (z2 - z1) * (z2 - z1);

      float d2 = min(d, temp[k]);
      temp[k] = d2;
      besti = d2 > best ? k : besti;
      best = d2 > best ? d2 : best;
    }
    dists[tid] = best;
    dists_i[tid] = besti;
    __syncthreads();

    if (block_size >= 512) {
      if (tid < 256) {
        __update(dists, dists_i, tid, tid + 256);
      }
      __syncthreads();
    }
    if (block_size >= 256) {
      if (tid < 128) {
        __update(dists, dists_i, tid, tid + 128);
      }
      __syncthreads();
    }
    if (block_size >= 128) {
      if (tid < 64) {
        __update(dists, dists_i, tid, tid + 64);
      }
      __syncthreads();
    }
    if (block_size >= 64) {
      if (tid < 32) {
        __update(dists, dists_i, tid, tid + 32);
      }
      __syncthreads();
    }
    if (block_size >= 32) {
      if (tid < 16) {
        __update(dists, dists_i, tid, tid + 16);
      }
      __syncthreads();
    }
    if (block_size >= 16) {
      if (tid < 8) {
        __update(dists, dists_i, tid, tid + 8);
      }
      __syncthreads();
    }
    if (block_size >= 8) {
      if (tid < 4) {
        __update(dists, dists_i, tid, tid + 4);
      }
      __syncthreads();
    }
    if (block_size >= 4) {
      if (tid < 2) {
        __update(dists, dists_i, tid, tid + 2);
      }
      __syncthreads();
    }
    if (block_size >= 2) {
      if (tid < 1) {
        __update(dists, dists_i, tid, tid + 1);
      }
      __syncthreads();
    }

    old = dists_i[0];
    if (tid == 0) idxs[j] = old;
  }
}

void furthest_point_sampling_kernel_wrapper(int b, int n, int m,
                                            const float *dataset, float *temp,
                                            int *idxs) {
  unsigned int n_threads = opt_n_threads(n);

  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  switch (n_threads) {
    case 512:
      furthest_point_sampling_kernel<512>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 256:
      furthest_point_sampling_kernel<256>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 128:
      furthest_point_sampling_kernel<128>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 64:
      furthest_point_sampling_kernel<64>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 32:
      furthest_point_sampling_kernel<32>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 16:
      furthest_point_sampling_kernel<16>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 8:
      furthest_point_sampling_kernel<8>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 4:
      furthest_point_sampling_kernel<4>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 2:
      furthest_point_sampling_kernel<2>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    case 1:
      furthest_point_sampling_kernel<1>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
      break;
    default:
      furthest_point_sampling_kernel<512>
          <<<b, n_threads, 0, stream>>>(b, n, m, dataset, temp, idxs);
  }

  CUDA_CHECK_ERRORS();
}

template <unsigned int block_size>
__global__ void furthest_point_sampling_weights_kernel(int b, int n, int m,
    const float *__restrict__ xyz, const float *__restrict__ weights, float *__restrict__ temp, int *__restrict__ idxs) {
    // xyz: (B, N, 3)
    // weights: (B, N)
    // tmp: (B, N)
    // output:
    //      idx: (B, M)

    if (m <= 0) return;
    __shared__ float dists[block_size];
    __shared__ int dists_i[block_size];

    int batch_index = blockIdx.x;
    xyz += batch_index * n * 3;
    weights += batch_index * n;
    temp += batch_index * n;
    idxs += batch_index * m;

    int tid = threadIdx.x;
    const int stride = block_size;

    int old = 0;
    if (threadIdx.x == 0) idxs[0] = old;

    __syncthreads();
    for (int j = 0; j < m; j++) {
    int besti = 0;
    float best = -1;
    float x1 = xyz[old * 3 + 0];
    float y1 = xyz[old * 3 + 1];
    float z1 = xyz[old * 3 + 2];
    for (int k = tid; k < n; k += stride) {
        if (j == 0) {  // select the point with the largest weight in the first round
            float d = weights[k];
            besti = d > best ? k : besti;
            best = d > best ? d : best;
        }
        else {
            float x2, y2, z2;
            x2 = xyz[k * 3 + 0];
            y2 = xyz[k * 3 + 1];
            z2 = xyz[k * 3 + 2];

            float d = (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1) + (z2 - z1) * (z2 - z1);
            d = min(d, temp[k]);
            temp[k] = d;
            float d2 = d * max(weights[k], 1e-12);  // dist[old][k] * weights[k]
            besti = d2 > best ? k : besti;
            best = d2 > best ? d2 : best;
        }
    }
    dists[tid] = best;
    dists_i[tid] = besti;
    __syncthreads();

    if (block_size >= 512) {
        if (tid < 256) {
            __update(dists, dists_i, tid, tid + 256);
        }
        __syncthreads();
    }
    if (block_size >= 256) {
        if (tid < 128) {
            __update(dists, dists_i, tid, tid + 128);
        }
        __syncthreads();
    }
    if (block_size >= 128) {
        if (tid < 64) {
            __update(dists, dists_i, tid, tid + 64);
        }
        __syncthreads();
    }
    if (block_size >= 64) {
        if (tid < 32) {
            __update(dists, dists_i, tid, tid + 32);
        }
        __syncthreads();
    }
    if (block_size >= 32) {
        if (tid < 16) {
            __update(dists, dists_i, tid, tid + 16);
        }
        __syncthreads();
    }
    if (block_size >= 16) {
        if (tid < 8) {
            __update(dists, dists_i, tid, tid + 8);
        }
        __syncthreads();
    }
    if (block_size >= 8) {
        if (tid < 4) {
            __update(dists, dists_i, tid, tid + 4);
        }
        __syncthreads();
    }
    if (block_size >= 4) {
        if (tid < 2) {
            __update(dists, dists_i, tid, tid + 2);
        }
        __syncthreads();
    }
    if (block_size >= 2) {
        if (tid < 1) {
            __update(dists, dists_i, tid, tid + 1);
        }
        __syncthreads();
    }

    old = dists_i[0];
    if (tid == 0)
        idxs[j] = old;
    }
}


void furthest_point_sampling_weights_kernel_wrapper(int b, int n, int m,
    const float *xyz, const float *weights, float *temp, int *idxs) {
    unsigned int n_threads = opt_n_threads(n);

    cudaStream_t stream = at::cuda::getCurrentCUDAStream();

    switch (n_threads) {
      case 512:
        furthest_point_sampling_weights_kernel<512>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 256:
        furthest_point_sampling_weights_kernel<256>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 128:
        furthest_point_sampling_weights_kernel<128>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 64:
        furthest_point_sampling_weights_kernel<64>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 32:
        furthest_point_sampling_weights_kernel<32>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 16:
        furthest_point_sampling_weights_kernel<16>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 8:
        furthest_point_sampling_weights_kernel<8>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 4:
        furthest_point_sampling_weights_kernel<4>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 2:
        furthest_point_sampling_weights_kernel<2>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      case 1:
        furthest_point_sampling_weights_kernel<1>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
        break;
      default:
        furthest_point_sampling_weights_kernel<512>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, weights, temp, idxs);
    }

    CUDA_CHECK_ERRORS();
}


template <unsigned int block_size>
__global__ void furthest_point_sampling_hybrid_kernel(int b, int n, int m,
    const float *__restrict__ xyz, const float *__restrict__ xyz_offset, float *__restrict__ temp, int *__restrict__ idxs, const float ratio) {
    // xyz: (B, N, 3)
    // weights: (B, N)
    // tmp: (B, N)
    // output:
    //      idx: (B, M)

    if (m <= 0) return;
    __shared__ float dists[block_size];
    __shared__ int dists_i[block_size];

    int batch_index = blockIdx.x;
    xyz += batch_index * n * 3;
    xyz_offset += batch_index * n * 3;
    temp += batch_index * n;
    idxs += batch_index * m;

    int tid = threadIdx.x;
    const int stride = block_size;

    int old = 0;
    if (threadIdx.x == 0) idxs[0] = old;

    __syncthreads();
    for (int j = 1; j < m; j++) {
      int besti = 0;
      float best = -1;

      float x1, y1, z1;
      if (j * ratio < m) {
        x1 = xyz[old * 3 + 0];
        y1 = xyz[old * 3 + 1];
        z1 = xyz[old * 3 + 2];
      }
      else {
        x1 = xyz_offset[old * 3 + 0];
        y1 = xyz_offset[old * 3 + 1];
        z1 = xyz_offset[old * 3 + 2];
      }

      
      for (int k = tid; k < n; k += stride) {
        float x2, y2, z2;

        if (j * ratio < m) {
          x2 = xyz[k * 3 + 0];
          y2 = xyz[k * 3 + 1];
          z2 = xyz[k * 3 + 2];
        }
        else {
          x2 = xyz_offset[k * 3 + 0];
          y2 = xyz_offset[k * 3 + 1];
          z2 = xyz_offset[k * 3 + 2];
        }


        float mag = (x2 * x2) + (y2 * y2) + (z2 * z2);
        if (mag <= 1e-3) continue;

        float d =
            (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1) + (z2 - z1) * (z2 - z1);

        float d2 = min(d, temp[k]);
        temp[k] = d2;
        besti = d2 > best ? k : besti;
        best = d2 > best ? d2 : best;

        // FIXME check again
        // if (j * ratio == m - 1) {
        //   temp[k] = 1e10;
        // }
      }
      dists[tid] = best;
      dists_i[tid] = besti;
      __syncthreads();

      if (block_size >= 512) {
          if (tid < 256) {
              __update(dists, dists_i, tid, tid + 256);
          }
          __syncthreads();
      }
      if (block_size >= 256) {
          if (tid < 128) {
              __update(dists, dists_i, tid, tid + 128);
          }
          __syncthreads();
      }
      if (block_size >= 128) {
          if (tid < 64) {
              __update(dists, dists_i, tid, tid + 64);
          }
          __syncthreads();
      }
      if (block_size >= 64) {
          if (tid < 32) {
              __update(dists, dists_i, tid, tid + 32);
          }
          __syncthreads();
      }
      if (block_size >= 32) {
          if (tid < 16) {
              __update(dists, dists_i, tid, tid + 16);
          }
          __syncthreads();
      }
      if (block_size >= 16) {
          if (tid < 8) {
              __update(dists, dists_i, tid, tid + 8);
          }
          __syncthreads();
      }
      if (block_size >= 8) {
          if (tid < 4) {
              __update(dists, dists_i, tid, tid + 4);
          }
          __syncthreads();
      }
      if (block_size >= 4) {
          if (tid < 2) {
              __update(dists, dists_i, tid, tid + 2);
          }
          __syncthreads();
      }
      if (block_size >= 2) {
          if (tid < 1) {
              __update(dists, dists_i, tid, tid + 1);
          }
          __syncthreads();
      }

      old = dists_i[0];
      if (tid == 0)
          idxs[j] = old;
      }
}


void furthest_point_sampling_hybrid_kernel_wrapper(int b, int n, int m,
    const float *xyz, const float *xyz_offset, float *temp, int *idxs, float ratio) {
    unsigned int n_threads = opt_n_threads(n);

    cudaStream_t stream = at::cuda::getCurrentCUDAStream();

    switch (n_threads) {
      case 512:
        furthest_point_sampling_hybrid_kernel<512>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 256:
        furthest_point_sampling_hybrid_kernel<256>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 128:
        furthest_point_sampling_hybrid_kernel<128>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 64:
        furthest_point_sampling_hybrid_kernel<64>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 32:
        furthest_point_sampling_hybrid_kernel<32>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 16:
        furthest_point_sampling_hybrid_kernel<16>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 8:
        furthest_point_sampling_hybrid_kernel<8>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 4:
        furthest_point_sampling_hybrid_kernel<4>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 2:
        furthest_point_sampling_hybrid_kernel<2>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      case 1:
        furthest_point_sampling_hybrid_kernel<1>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
        break;
      default:
        furthest_point_sampling_hybrid_kernel<512>
            <<<b, n_threads, 0, stream>>>(b, n, m, xyz, xyz_offset, temp, idxs, ratio);
    }

    CUDA_CHECK_ERRORS();
}



template <unsigned int block_size>
__global__ void furthest_point_sampling_with_dist_kernel(int b, int n, int m, 
    const float *__restrict__ dataset, float *__restrict__ temp, int *__restrict__ idxs) {
    // dataset: (B, N, N)
    // tmp: (B, N)
    // output:
    //      idx: (B, M)

    if (m <= 0) return;
    __shared__ float dists[block_size];
    __shared__ int dists_i[block_size];

    int batch_index = blockIdx.x;
    dataset += batch_index * n * n;
    temp += batch_index * n;
    idxs += batch_index * m;

    int tid = threadIdx.x;
    const int stride = block_size;

    int old = 0;
    if (threadIdx.x == 0)
    idxs[0] = old;

    __syncthreads();
    for (int j = 1; j < m; j++) {
    int besti = 0;
    float best = -1;
    // float x1 = dataset[old * 3 + 0];
    // float y1 = dataset[old * 3 + 1];
    // float z1 = dataset[old * 3 + 2];
    for (int k = tid; k < n; k += stride) {
        // float x2, y2, z2;
        // x2 = dataset[k * 3 + 0];
        // y2 = dataset[k * 3 + 1];
        // z2 = dataset[k * 3 + 2];
        
        // float d = (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1) + (z2 - z1) * (z2 - z1);
        float d = dataset[old * n + k];
        
        float d2 = min(d, temp[k]);
        temp[k] = d2;
        besti = d2 > best ? k : besti;
        best = d2 > best ? d2 : best;
    }
    dists[tid] = best;
    dists_i[tid] = besti;
    __syncthreads();

    if (block_size >= 1024) {
        if (tid < 512) {
            __update(dists, dists_i, tid, tid + 512);
        }
        __syncthreads();
    }

    if (block_size >= 512) {
        if (tid < 256) {
            __update(dists, dists_i, tid, tid + 256);
        }
        __syncthreads();
    }
    if (block_size >= 256) {
        if (tid < 128) {
            __update(dists, dists_i, tid, tid + 128);
        }
        __syncthreads();
    }
    if (block_size >= 128) {
        if (tid < 64) {
            __update(dists, dists_i, tid, tid + 64);
        }
        __syncthreads();
    }
    if (block_size >= 64) {
        if (tid < 32) {
            __update(dists, dists_i, tid, tid + 32);
        }
        __syncthreads();
    }
    if (block_size >= 32) {
        if (tid < 16) {
            __update(dists, dists_i, tid, tid + 16);
        }
        __syncthreads();
    }
    if (block_size >= 16) {
        if (tid < 8) {
            __update(dists, dists_i, tid, tid + 8);
        }
        __syncthreads();
    }
    if (block_size >= 8) {
        if (tid < 4) {
            __update(dists, dists_i, tid, tid + 4);
        }
        __syncthreads();
    }
    if (block_size >= 4) {
        if (tid < 2) {
            __update(dists, dists_i, tid, tid + 2);
        }
        __syncthreads();
    }
    if (block_size >= 2) {
        if (tid < 1) {
            __update(dists, dists_i, tid, tid + 1);
        }
        __syncthreads();
    }

    old = dists_i[0];
    if (tid == 0)
        idxs[j] = old;
    }
}


void furthest_point_sampling_with_dist_kernel_wrapper(int b, int n, int m, 
    const float *dataset, float *temp, int *idxs) {
    // dataset: (B, N, N)
    // tmp: (B, N)
    // output:
    //      idx: (B, M)

    cudaError_t err;
    unsigned int n_threads = opt_n_threads(n);

    switch (n_threads) {
        case 1024:
        furthest_point_sampling_with_dist_kernel<1024><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 512:
        furthest_point_sampling_with_dist_kernel<512><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 256:
        furthest_point_sampling_with_dist_kernel<256><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 128:
        furthest_point_sampling_with_dist_kernel<128><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 64:
        furthest_point_sampling_with_dist_kernel<64><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 32:
        furthest_point_sampling_with_dist_kernel<32><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 16:
        furthest_point_sampling_with_dist_kernel<16><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 8:
        furthest_point_sampling_with_dist_kernel<8><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 4:
        furthest_point_sampling_with_dist_kernel<4><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 2:
        furthest_point_sampling_with_dist_kernel<2><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        case 1:
        furthest_point_sampling_with_dist_kernel<1><<<b, n_threads>>>(b, n, m, dataset, temp, idxs); break;
        default:
        furthest_point_sampling_with_dist_kernel<512><<<b, n_threads>>>(b, n, m, dataset, temp, idxs);
    }

    err = cudaGetLastError();
    if (cudaSuccess != err) {
        fprintf(stderr, "CUDA kernel failed : %s\n", cudaGetErrorString(err));
        throw std::runtime_error("CUDA kernel failed" + std::string(cudaGetErrorString(err)));
    }
}