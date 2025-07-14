using PackageCompiler

ext = if Sys.iswindows()
    "dll"
elseif Sys.isapple()
    "dynlib"
elseif Sys.islinux()
    "so"
else
    throw(SystemError("Unknown or unsupported platform."))
end

# cpu_targets taken from: https://docs.julialang.org/en/v1/devdocs/sysimg/#Specifying-multiple-system-image-targets
create_sysimage(
    ["ReefGuideWorker"];
    sysimage_path="reefguide_img.$ext",
    sysimage_build_args=`--strip-metadata`, # `--strip-ir --strip-metadata  --incremental=false`
    cpu_target="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1);znver4,-rdrnd,base(1)",  # ;x86_64; haswell;skylake;skylake-avx512;tigerlake
    import_into_main=true,
    include_transitive_dependencies=true
)

# Now should be able to start with custom sysimage:
# julia -q -J reefguide_worker.so
