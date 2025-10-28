# UsagiBuild System Overview

The UsagiBuild system is a custom C++ build environment for Visual Studio, designed around MSBuild's property sheet mechanism. It is engineered to provide a centralized, consistent, and easily maintainable configuration for all projects within the solution.

## Core Philosophy

1.  **Centralized Configuration**: Instead of configuring each `.vcxproj` file individually, all common settings are defined in shared `.props` files located in the `Build/` directory. This ensures that compiler flags, linker settings, and other build options are applied uniformly.
2.  **Modularity**: The system is broken down into logical modules.
    *   `Build/Configs`: Contains property sheets for general configuration, such as C++ standards, warning levels, and target architecture.
    *   `Build/Toolchains`: Contains property sheets specific to a compiler toolchain (e.g., Clang).
3.  **Convention over Configuration**: Projects are expected to include the relevant property sheets. This minimizes boilerplate in the `.vcxproj` files and makes them cleaner and more focused on project-specific files and dependencies.
4.  **Explicitness and Clarity**: The property sheets are heavily commented to explain the purpose of each setting, its corresponding compiler/linker flag, and the rationale behind its inclusion. This documentation-in-code approach is critical for long-term maintenance.

## How It Works

A typical project (`.vcxproj`) in this solution will import one or more of these `.props` files. MSBuild evaluates these imports, assembling a final set of properties and item definitions that are used to compile and link the project.

This structure makes it simple to:
-   Update a compiler flag across all projects simultaneously.
-   Introduce a new build configuration.
-   Switch or update a toolchain by modifying a single file.

This documentation provides a detailed breakdown of each of the core property sheets.
