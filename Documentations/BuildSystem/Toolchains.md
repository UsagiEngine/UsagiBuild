# Build Toolchain Files

This document details the property sheets located in `Build/Toolchains/`, which configure settings specific to a compiler toolchain.

---

## `Clang.props`

This is the central configuration file for using the Clang toolchain (`ClangCL`) within Visual Studio.

### Toolchain Setup

-   **`<PlatformToolset>`**: Sets the MSBuild toolset to `ClangCL`.
-   **`<LLVMInstallDir>`**: Specifies the installation path of LLVM. This is sourced from the `LLVM_INSTALL_DIR` environment variable, making the setup portable across different machines.
-   **`GetClangVersion` Target**: A custom MSBuild target that runs before the build. It executes `clang-cl.exe -v` to automatically detect the installed Clang version and sets the `<LLVMToolsVersion>` property. This ensures the build system uses the correct version-specific properties and avoids manual configuration.

### Compiler Arguments (`<ItemDefinitionGroup>`)

This is where the command-line arguments for `clang-cl.exe` are dynamically constructed based on the properties defined in the `Build/Configs/` files. This is done using a temporary property, `_Usagi_ClangArgs`, which is built up incrementally.

The following arguments are added:

1.  **`-Xclang -std=c++26`**: Enables C++26 mode.
2.  **`-march=$(Usagi_TargetArchitecture)`**: Sets the target CPU architecture for optimization (e.g., `skylake`). Defaults to `haswell` if not specified.
3.  **`-Wno-pragma-pack`**: Suppresses warnings related to `#pragma pack`.
4.  **`-Xclang -finput-charset=UTF-8`**: **Crucially, this flag ensures all source code files are interpreted as UTF-8**, preventing issues with non-ASCII characters in strings or comments.
5.  **`-Xclang -fno-builtin-std-forward_like`**: A workaround for a compiler bug.
6.  **Metaprogramming Limits**: Sets the constexpr depth, template depth, and backtrace limit from the properties in `DefaultCpp.props`.
7.  **Static Reflection Flags**: Appends the experimental reflection flags if they are enabled in `DefaultCpp.props`.

Finally, the assembled string in `_Usagi_ClangArgs` is passed to the compiler via the `<AdditionalOptions>` property.

### Preprocessor Definitions

-   **`_HAS_CXX26`, `_HAS_CXX23`, etc.**: These are defined to enable C++ standard library features that correspond to the enabled language standard.
