using ReefGuideWorker
using ReefGuide
using DataFrames
using Dates
using GeometryOps
using JSON3
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

@testset "fast assessment job types" begin
    @test ReefGuideWorker.FAST_REGIONAL_ASSESSMENT isa ReefGuideWorker.JobType
    @test ReefGuideWorker.FAST_SUITABILITY_ASSESSMENT isa ReefGuideWorker.JobType

    # Handlers must be registered against the fast job types (see
    # ReefGuideWorker.__init__), with the same output types as the
    # non-fast counterparts (they share result schemas).
    @test ReefGuideWorker.JOB_REGISTRY.input_types[ReefGuideWorker.FAST_REGIONAL_ASSESSMENT] ==
        ReefGuideWorker.FastRegionalAssessmentInput
    @test ReefGuideWorker.JOB_REGISTRY.output_types[ReefGuideWorker.FAST_REGIONAL_ASSESSMENT] ==
        ReefGuideWorker.RegionalAssessmentOutput
    @test ReefGuideWorker.JOB_REGISTRY.input_types[ReefGuideWorker.FAST_SUITABILITY_ASSESSMENT] ==
        ReefGuideWorker.FastSuitabilityAssessmentInput
    @test ReefGuideWorker.JOB_REGISTRY.output_types[ReefGuideWorker.FAST_SUITABILITY_ASSESSMENT] ==
        ReefGuideWorker.SuitabilityAssessmentOutput
end

@testset "spatialScopeSchema JSON3 tag dispatch" begin
    # Mirrors the TS `spatialScopeSchema` discriminated union on `type`
    # (reefguide/packages/types/src/jobs.ts) - exercised the same way
    # `validate_job_input` parses real job payloads: JSON3.write then
    # JSON3.read into the typed struct.
    bbox_payload = Dict(
        "region" => "test-region",
        "reef_type" => "slopes",
        "depth_min" => nothing, "depth_max" => nothing,
        "high_tide_min" => nothing, "high_tide_max" => nothing,
        "low_tide_min" => nothing, "low_tide_max" => nothing,
        "rugosity_min" => nothing, "rugosity_max" => nothing,
        "slope_min" => nothing, "slope_max" => nothing,
        "turbidity_min" => nothing, "turbidity_max" => nothing,
        "waves_height_min" => nothing, "waves_height_max" => nothing,
        "waves_period_min" => nothing, "waves_period_max" => nothing,
        "scope" => Dict("type" => "bbox", "bounds" => [1.0, 2.0, 3.0, 4.0])
    )
    parsed = JSON3.read(
        JSON3.write(bbox_payload), ReefGuideWorker.FastRegionalAssessmentInput
    )
    @test parsed.scope isa ReefGuideWorker.BBoxScopeInput
    @test parsed.scope.bounds == (1.0, 2.0, 3.0, 4.0)
    @test parsed.region == "test-region"

    polygon_payload = merge(
        bbox_payload,
        Dict(
            "scope" => Dict(
                "type" => "polygon",
                "geometry" => Dict(
                    "type" => "Polygon",
                    "coordinates" => [[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [1.0, 2.0]]]
                )
            )
        )
    )
    parsed_polygon = JSON3.read(
        JSON3.write(polygon_payload), ReefGuideWorker.FastRegionalAssessmentInput
    )
    @test parsed_polygon.scope isa ReefGuideWorker.PolygonScopeInput
    @test parsed_polygon.scope.geometry.coordinates ==
        [[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [1.0, 2.0]]]

    # Same union also round-trips through FastSuitabilityAssessmentInput
    suitability_payload = merge(
        bbox_payload,
        Dict("threshold" => nothing, "x_dist" => 100, "y_dist" => 100)
    )
    parsed_suitability = JSON3.read(
        JSON3.write(suitability_payload), ReefGuideWorker.FastSuitabilityAssessmentInput
    )
    @test parsed_suitability.scope isa ReefGuideWorker.BBoxScopeInput
    @test parsed_suitability.x_dist == 100
end

@testset "regional_job_from_fast_regional_job / suitability_job_from_fast_suitability_job" begin
    scope = ReefGuideWorker.BBoxScopeInput("bbox", (1.0, 2.0, 3.0, 4.0))

    fast_regional = ReefGuideWorker.FastRegionalAssessmentInput(
        "test-region", "slopes",
        1.0, 2.0, nothing, nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing,
        scope
    )
    regional = ReefGuideWorker.regional_job_from_fast_regional_job(fast_regional)
    @test regional isa ReefGuideWorker.RegionalAssessmentInput
    @test regional.region == "test-region"
    @test regional.depth_min == 1.0
    @test regional.depth_max == 2.0

    fast_suitability = ReefGuideWorker.FastSuitabilityAssessmentInput(
        "test-region", "slopes",
        1.0, 2.0, nothing, nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing,
        50, 100, 200,
        scope
    )
    suitability = ReefGuideWorker.suitability_job_from_fast_suitability_job(
        fast_suitability
    )
    @test suitability isa ReefGuideWorker.SuitabilityAssessmentInput
    @test suitability.threshold == 50
    @test suitability.x_dist == 100
    @test suitability.y_dist == 200
end

@testset "scope cache-key correctness" begin
    # Correctness-critical (see plan): two different viewports must not
    # collide in the fast-assessment cache. Test the pure hash-component
    # helper directly, since building a full ReefGuide.RegionalAssessmentParameters
    # requires real region raster/parquet fixtures unavailable in unit tests.
    bbox_a = ReefGuideWorker.BBoxScopeInput("bbox", (1.0, 2.0, 3.0, 4.0))
    bbox_b = ReefGuideWorker.BBoxScopeInput("bbox", (5.0, 6.0, 7.0, 8.0))
    @test ReefGuideWorker.get_hash_components_from_scope(bbox_a) !=
        ReefGuideWorker.get_hash_components_from_scope(bbox_b)
    @test ReefGuideWorker.build_hash_from_components(
        ReefGuideWorker.get_hash_components_from_scope(bbox_a)
    ) != ReefGuideWorker.build_hash_from_components(
        ReefGuideWorker.get_hash_components_from_scope(bbox_b)
    )

    polygon_a = ReefGuideWorker.PolygonScopeInput(
        "polygon",
        ReefGuideWorker.GeoJSONPolygonInput(
            "Polygon", [[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [1.0, 2.0]]]
        )
    )
    polygon_b = ReefGuideWorker.PolygonScopeInput(
        "polygon",
        ReefGuideWorker.GeoJSONPolygonInput(
            "Polygon", [[[9.0, 9.0], [3.0, 4.0], [5.0, 6.0], [9.0, 9.0]]]
        )
    )
    @test ReefGuideWorker.get_hash_components_from_scope(polygon_a) !=
        ReefGuideWorker.get_hash_components_from_scope(polygon_b)

    # A bbox and a polygon scope must not collide even with coincidentally
    # similar numbers.
    @test ReefGuideWorker.get_hash_components_from_scope(bbox_a) !=
        ReefGuideWorker.get_hash_components_from_scope(polygon_a)
end

@testset "build_geo_interface_polygon" begin
    geometry = ReefGuideWorker.GeoJSONPolygonInput(
        "Polygon", [[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [1.0, 2.0]]]
    )
    polygon = ReefGuideWorker.build_geo_interface_polygon(geometry)
    @test GeometryOps.GI.trait(polygon) isa GeometryOps.GI.PolygonTrait
    ring = first(GeometryOps.GI.getring(polygon))
    points = collect(GeometryOps.GI.getpoint(ring))
    @test length(points) == 4
    @test (GeometryOps.GI.x(points[1]), GeometryOps.GI.y(points[1])) == (1.0, 2.0)
end

@testset "build_spatial_scope" begin
    # `ReefGuide.BBoxScope`/`ReefGuide.PolygonScope` arrived in the registered
    # ReefGuide.jl 0.3.0; before that `build_spatial_scope` threw `UndefVarError`.
    bbox = ReefGuideWorker.build_spatial_scope(
        ReefGuideWorker.BBoxScopeInput("bbox", (1.0, 2.0, 3.0, 4.0))
    )
    @test bbox isa ReefGuide.BBoxScope

    polygon = ReefGuideWorker.build_spatial_scope(
        ReefGuideWorker.PolygonScopeInput(
            "polygon",
            ReefGuideWorker.GeoJSONPolygonInput(
                "Polygon", [[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [1.0, 2.0]]]
            )
        )
    )
    @test polygon isa ReefGuide.PolygonScope
end

@testset "login backoff / circuit breaker" begin
    creds = ReefGuideWorker.Credentials("worker@example.com", "pw")
    mkclient() = ReefGuideWorker.AuthApiClient("http://localhost:9/api", creds)

    # A single failure advances the counter and arms a future retry window.
    c = mkclient()
    ReefGuideWorker._login_failed!(c, "HTTP 401")
    @test c.consecutive_login_failures == 1
    @test c.login_retry_after isa DateTime

    # While the window is open, `login!` fails fast with a 429 ApiError, no network call.
    c.login_retry_after = Dates.now(Dates.UTC) + Dates.Minute(5)
    err = try
        ReefGuideWorker.login!(c)
        nothing
    catch e
        e
    end
    @test err isa ReefGuideWorker.ApiError
    @test err.status_code == 429

    # A success closes the breaker.
    ReefGuideWorker._login_succeeded!(c)
    @test c.consecutive_login_failures == 0
    @test isnothing(c.login_retry_after)

    # After LOGIN_MAX_CONSECUTIVE_FAILURES failures in a row, give up with LoginGaveUpError
    # rather than backing off forever.
    c2 = mkclient()
    lim = ReefGuideWorker.LOGIN_MAX_CONSECUTIVE_FAILURES
    for _ in 1:(lim - 1)
        ReefGuideWorker._login_failed!(c2, "HTTP 429")
    end
    @test c2.consecutive_login_failures == lim - 1
    @test_throws ReefGuideWorker.LoginGaveUpError ReefGuideWorker._login_failed!(
        c2, "HTTP 429"
    )
end
