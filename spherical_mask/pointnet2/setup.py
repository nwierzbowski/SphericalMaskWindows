# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import os

# Force specific MSVC version
os.environ["DISTUTILS_USE_SDK"] = "1"
os.environ["MSSdk"] = "1"
os.environ["MSVC_VERSION"] = "14.32"
os.environ["PlatformToolset"] = "v143"

from setuptools import setup
from torch.utils.cpp_extension import BuildExtension, CUDAExtension
import glob
import os.path as osp

this_dir = osp.dirname(osp.abspath(__file__))

_ext_src_root = "_ext_src"
_ext_sources = glob.glob("{}/src/*.cpp".format(_ext_src_root)) + glob.glob(
    "{}/src/*.cu".format(_ext_src_root)
)
_ext_headers = glob.glob("{}/include/*".format(_ext_src_root))

setup(
    name="pointnet2",
    ext_modules=[
        CUDAExtension(
            name="pointnet2._ext",
            sources=_ext_sources,
            extra_compile_args={
                "cxx": [
                    "-O2",
                    "-I{}".format("{}/include".format(_ext_src_root)),
                    "/D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH",
                ],
                "nvcc": [
                    "-O2",
                    "-I{}".format("{}/include".format(_ext_src_root)),
                    "-allow-unsupported-compiler",
                ],
            },
            include_dirs=[osp.join(this_dir, _ext_src_root, "include")],
        )
    ],
    cmdclass={"build_ext": BuildExtension},
)
