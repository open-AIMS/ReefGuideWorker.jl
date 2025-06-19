"""
Builds a hash by combining strings and hashing result
"""
function build_hash_from_components(components::Vector{String})::String
    return string(hash(join(components, "|")))
end

"""
Returns a hash component for bounded criteria 

Carefully orders hash predictably and only includes present criteria
"""
function get_hash_components_from_regional_criteria(
    criteria::ReefGuide.BoundedCriteriaDict
)::Vector{String}
    @debug "Hashing criteria..." criteria
    components::Vector{String} = []
    for id in keys(ReefGuide.ASSESSMENT_CRITERIA)
        components = vcat(components,
            haskey(criteria, id) ?
            [
                id, string(criteria[id].bounds.min), string(criteria[id].bounds.max)
            ] : []
        )
    end
    return components
end
