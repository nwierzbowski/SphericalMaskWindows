from setuptools import setup
from torch.utils.cpp_extension import BuildExtension, CUDAExtension
import os


if __name__ == "__main__":

    os.environ["DISTUTILS_USE_SDK"] = "1"
    os.environ["MSSdk"] = "1"

    SPARSEHASH_SRC_DIR = r"D:\vcpkg\installed\x64-windows\include"

    # Optional: Add a check to ensure the directory exists for better error messages
    if not os.path.isdir(SPARSEHASH_SRC_DIR):
        raise RuntimeError(
            f"ERROR: Google SparseHash 'src' directory not found at '{SPARSEHASH_SRC_DIR}'. "
            "Please download SparseHash, extract it, and update SPARSEHASH_SRC_DIR in setup.py."
        )

    setup(
        name="spherical_mask",
        version="1.0",
        description="spherical_mask",
        author="sangyun shin",
        packages=["spherical_mask"],
        package_data={"spherical_mask.ops": ["*/*.pyd"]},
        ext_modules=[
            CUDAExtension(
                name="spherical_mask.ops.ops",
                sources=[
                    "spherical_mask/ops/src/isbnet_api.cpp",
                    "spherical_mask/ops/src/isbnet_ops.cpp",
                    "spherical_mask/ops/src/cuda.cu",
                ],
                include_dirs=[SPARSEHASH_SRC_DIR],
                extra_compile_args={
                    "cxx": [],
                    "nvcc": [
                        "-O2",
                        "--expt-relaxed-constexpr",
                        "-Xcompiler",
                        "/wd4819",
                        "-Xcompiler",
                        "/wd4251",
                        "-Xcompiler",
                        "/wd4244",
                        "-Xcompiler",
                        "/wd4267",
                    ],
                },
            )
        ],
        cmdclass={"build_ext": BuildExtension},
    )
