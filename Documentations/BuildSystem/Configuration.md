# Build Configuration Files

This document details the property sheets located in `Build/Configs/`, which control the primary configuration for all C++ projects.

---

## `DefaultTarget.props`

This file defines the target hardware architecture for code generation.

-   **`<Usagi_TargetArchitecture>`**: Specifies the target CPU microarchitecture.
    -   **Value**: `skylake`
    -   **Compiler Flag**: `-march=skylake` (for Clang)
    -   **Purpose**: Instructs the compiler to generate code optimized for the Intel Skylake architecture. This provides a good balance of modern instruction sets (AVX2, FMA3) and wide hardware compatibility. If this property is not set, the build system defaults to `haswell` as a safe baseline.

---

## `DefaultCpp.props`

This file configures C++ language features, metaprogramming limits, and experimental extensions.

### CppCommon

-   **`<Usagi_CppEnableCpp26>`**: Enables C++26 support. This is the master switch for the latest language features.
-   **`<Usagi_CppDisableBuiltinStdForwardLike>`**: A workaround for a bug in certain Clang versions by disabling the compiler's intrinsic `std::forward_like`.

### CppMetaprogramming

These properties increase compiler limits to support advanced compile-time programming.

-   **`<Usagi_CppMaximumConstexprDepth>`**: Sets the `constexpr` function recursion depth limit.
-   **`<Usagi_CppMaximumTemplateDepth>`**: Sets the template instantiation depth limit.
-   **`<Usagi_CppConstexprBacktraceLimit>`**: Controls the length of the backtrace on `constexpr` evaluation errors. It is set to `0` to disable the backtrace for cleaner output.

### CppStaticReflection

These flags enable experimental features from the C++26 reflection proposal (P2996) as implemented in a custom version of Clang.

-   **`<Usagi_CppEnableP3096>`**: `-fparameter-reflection`
-   **`<Usagi_CppEnableP1306>`**: `-fexpansion-statements`
-   **`<Usagi_CppEnableP3289>`**: `-fconsteval-blocks`
-   **`<Usagi_CppEnableP3381>`**: `-freflection-new-syntax`

---

## `DefaultCommon.props`

This file sets up the most common compiler and linker settings that apply to all configurations (Debug and Release).

### Compiler Settings (`<ClCompile>`)

-   **`<CharacterSet>`**: Set to `Unicode` for proper international character support in Windows.
-   **`<RuntimeLibrary>`**: Set to `MultiThreaded` (Release) or `MultiThreadedDebug` (Debug). This links the static C Runtime Library, avoiding a dependency on the VC++ Redistributable DLLs.
-   **`<SDLCheck>`**: Enabled in Debug builds to add Security Development Lifecycle checks.
-   **`<LanguageStandard>`**: Set to `stdcpplatest` to use the latest available C++ standard features.
-   **`<WarningLevel>`**: Set to `Level3`, a standard for production-quality warnings.
-   **`<ConformanceMode>`**: Set to `true` (`/permissive-`) to enforce strict C++ standards compliance.
-   **`<TreatWarningAsError>`**: Set to `true` (`/WX`) to enforce a high standard of code quality.
-   **`<DiagnosticsFormat>`**: Set to `Caret` to produce more readable, column-specific error messages.
-   **`<BrowseInformation>`**: Set to `true` (`/FR`). While obsolete for modern IntelliSense, this is retained for potential use by external static analysis or code browsing tools.

### Linker Settings (`<Link>`)

-   **`<GenerateDebugInformation>`**: Enabled to produce `.pdb` files, which are essential for debugging.
-   **`<SubSystem>`**: Set to `Console` as the default for executables.

### Manifest Settings (`<Manifest>`)

-   **`<EnableDpiAwareness>`**: Set to `PerMonitorHighDPIAwareV2` to ensure applications render correctly on modern high-DPI displays.
