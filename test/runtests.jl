using ReefGuideWorker
using ReefGuide
using DataFrames
using Test

@testset "prepare_target_regional_data error handling" begin
    # Seed the in-memory cache with an empty region set so the lookup inside
    # `ReefGuide.load_target_region` is what fails, exercising the catch block.
    ReefGuideWorker.REGIONAL_DATA = ReefGuide.RegionalData(;
        regions=Dict{String,ReefGuide.RegionalDataEntry}(), reef_outlines=DataFrame()
    )

    # A bogus region_id should surface the real KeyError from the dict lookup,
    # not an UndefVarError from referencing the unbound `region_metadata`/`e`
    # in the catch block.
    @test_throws KeyError ReefGuideWorker.prepare_target_regional_data(;
        data_path=tempdir(), region_id="bogus"
    )
end
